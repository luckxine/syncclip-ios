import Foundation
import AVFoundation
import SyncClipCore

/// 后台保活。
///
/// 没有越狱就注册不了 launchd 守护进程，所以走系统允许的那条路：
/// `UIBackgroundModes=audio` + 持续播放一段听不见的音频，让进程不被挂起。
///
/// 但「播上了」和「一直播着」是两件事。真机上的经验（以及同类实现的做法）是：
/// 这个会话随时可能被别的东西弄断，而它断了之后**不会自己好** ——
/// 表现就是「同步无声无息地停了，看起来像 App 挂了」。所以这个类有一半的
/// 代码在处理「怎么发现它断了、怎么接回来」：
///
/// 1. **2 秒一次的自愈看门狗**：只要发现播放器不在播、或者音频会话不再激活，
///    就重建一次。这是最重要的一条 —— 没有它，一次意外的会话失效就会永久断掉。
/// 2. **打断结束要接回来**（来电、闹钟结束后系统不会替你恢复播放）。
/// 3. **`mediaServicesWereReset` 之后整个重建引擎**：这个通知意味着系统的音频栈
///    整体重启过（进程被压制、系统音频服务崩过一次等），旧的播放器对象已经没用了。
/// 4. 波形用「幅度 ±1 的最低有效位」而不是纯零 —— 部分系统版本会把输出恒为 0
///    的会话判定成没有实际播放，从而照样挂起。
/// 5. `.mixWithOthers`，不抢用户的音乐会话。
///
/// 代价：确实费电（量级约每小时百分之几），而且系统大约 3 小时后会静默节流
/// （见 docs/keepalive.md）。设置页可以随时关掉它。
final class BackgroundKeeper {

    private var player: AVAudioPlayer?
    private var running = false
    private var observers: [NSObjectProtocol] = []
    private var watchdog: DispatchSourceTimer?

    /// 自愈次数。诊断页会显示 —— 这个数字很大就说明这里的会话很不稳。
    private(set) var restartCount = 0
    private(set) var lastRestartAt: Date?
    /// 最近一次自愈的原因，出问题时这一行最有用
    private(set) var lastRestartReason: String = ""
    private(set) var startedAt: Date?

    var isRunning: Bool { running }

    /// 当前健康状况的一句话描述（诊断页用）
    var healthDescription: String {
        guard running else { return "未开启" }
        let playing = player?.isPlaying == true
        let others = AVAudioSession.sharedInstance().isOtherAudioPlaying
        var sessionOK = true
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            sessionOK = false
        }
        return "\(playing ? "播放中" : "⚠️ 播放器已停") · \(others ? "有其它音频在播" : "无其它音频")"
             + " · \(sessionOK ? "会话可激活" : "⚠️ 会话激活失败") · 自愈 \(restartCount) 次"
    }

    deinit { stop() }

    // MARK: - 开关

    /// - Returns: 启动失败时的原因；成功返回 nil
    @discardableResult
    func start() -> String? {
        guard !running else { return nil }

        if let failure = activateSession() { return failure }
        if let failure = startPlayer() { return failure }

        observeNotifications()
        startWatchdog()
        running = true
        startedAt = Date()
        SCLog.info("后台保活已开启（静音音频会话，2 秒自愈看门狗）")
        return nil
    }

    func stop() {
        guard running || player != nil else { return }
        watchdog?.cancel()
        watchdog = nil
        player?.stop()
        player = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        if running { SCLog.info("后台保活已关闭") }
        running = false
        startedAt = nil
    }

    // MARK: - 会话与播放器

    private func activateSession() -> String? {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
            return nil
        } catch {
            return "音频会话激活失败：\(error.localizedDescription)"
        }
    }

    private func startPlayer() -> String? {
        do {
            let newPlayer = try AVAudioPlayer(data: BackgroundKeeper.inaudibleWAV())
            newPlayer.numberOfLoops = -1
            newPlayer.volume = 1.0
            newPlayer.prepareToPlay()
            guard newPlayer.play() else { return "AVAudioPlayer.play() 返回 false" }
            self.player = newPlayer
            return nil
        } catch {
            return "静音音频播放失败：\(error.localizedDescription)"
        }
    }

    /// 自愈一次：重建播放器（必要时连会话一起重建）。
    ///
    /// 在主线程上做 —— 这个类只有在进程没被挂起时才有意义，
    /// 而那种情况下主线程是活的；音频 API 也最好在同一个线程上用。
    private func repair(reason: String) {
        guard running else { return }
        let needsSession = activateSession()
        let needsPlayer = startPlayer()

        restartCount += 1
        lastRestartAt = Date()
        lastRestartReason = reason
        var detail = "后台保活自愈（第 \(restartCount) 次）：\(reason)"
        if let needsSession { detail += "；会话：\(needsSession)" }
        if let needsPlayer { detail += "；播放器：\(needsPlayer)" }
        SCLog.warn(detail)
    }

    // MARK: - 看门狗

    /// 每 2 秒检查一次「播放器还在播吗」。这是整个保活里最重要的一段 ——
    /// 没有它，任何一次意外断播都会安静地变成「同步再也不动了」。
    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard self.running else { return }
                guard self.player?.isPlaying != true else { return }
                self.repair(reason: "看门狗发现播放器已停")
            }
        }
        timer.resume()
        watchdog = timer
    }

    // MARK: - 系统通知

    private func observeNotifications() {
        let center = NotificationCenter.default

        // 打断（来电、闹钟、别的 App 抢走会话）
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] note in
            guard let self = self, self.running else { return }
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                SCLog.warn("音频会话被系统打断，后台保活暂时中断（结束后会自己接回来）")
            case .ended:
                // 不依赖系统替我们恢复播放：直接走一次自愈，把会话和播放器都重建
                self.repair(reason: "打断结束，重建以恢复保活")
            @unknown default:
                break
            }
        })

        // 音频栈整体重置：旧对象作废，必须全部重建
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: .main) { [weak self] note in
            guard let self = self, self.running else { return }
            _ = note
            self.player = nil
            self.repair(reason: "系统音频服务重置（mediaServicesWereReset）")
        })

        // 音频路由变化（插拔耳机等）之后也查一次，避免它悄悄停了
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: nil, queue: .main) { [weak self] note in
            guard let self = self, self.running else { return }
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            // 只有「旧的设备不可用」这类才会真的让播放停下来
            if reason == .oldDeviceUnavailable || reason == .newDeviceAvailable {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    guard self.running, self.player?.isPlaying != true else { return }
                    self.repair(reason: "音频路由变化后播放已停")
                }
            }
        })
    }

    // MARK: - 生成听不见的 WAV

    /// 8kHz / 单声道 / 16bit，1 秒，幅度 ±1 的最低有效位
    static func inaudibleWAV() -> Data {
        let sampleRate = 8000
        let seconds = 1
        let channels = 1
        let bitsPerSample = 16
        let frameCount = sampleRate * seconds
        let blockAlign = channels * bitsPerSample / 8
        let dataBytes = frameCount * blockAlign

        var data = Data(capacity: 44 + dataBytes)
        func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func le16(_ v: Int) { data.append(UInt8(v & 0xff)); data.append(UInt8((v >> 8) & 0xff)) }
        func le32(_ v: Int) {
            data.append(UInt8(v & 0xff)); data.append(UInt8((v >> 8) & 0xff))
            data.append(UInt8((v >> 16) & 0xff)); data.append(UInt8((v >> 24) & 0xff))
        }

        ascii("RIFF"); le32(36 + dataBytes); ascii("WAVE")
        ascii("fmt "); le32(16); le16(1)                     // PCM
        le16(channels); le32(sampleRate)
        le32(sampleRate * blockAlign); le16(blockAlign); le16(bitsPerSample)
        ascii("data"); le32(dataBytes)

        // 1 LSB 的方波：听不见，但输出不是恒定 0
        for i in 0..<frameCount {
            let sample = (i % 2 == 0) ? 1 : -1
            le16(sample & 0xffff)
        }
        return data
    }
}
