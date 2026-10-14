import Foundation
import AVFoundation

/// 后台保活。
///
/// 这是 TrollStore 路线（无越狱）最关键的一块：iOS 会在 App 进入后台约 30 秒后挂起它，
/// 挂起后轮询就停了。没有越狱就注册不了 launchd 守护进程，所以只能走
/// 「声明 UIBackgroundModes=audio + 持续播放一段听不见的音频」这条系统允许的路子。
///
/// 两个实现细节值得说明：
///
/// 1. **不要用纯数字静音**（全 0 采样）。系统在部分版本上会把「输出恒为 0」的会话
///    判定成没有实际播放，从而照样挂起。这里生成的是幅度 ±1（16bit 里最低有效位，
///    ≈ -90 dBFS）的波形：人耳完全听不见，但确实是有内容的信号。
///
/// 2. 用 `.mixWithOthers`，避免抢占用户的音乐会话（否则你一放歌后台同步就断了，
///    而且控制中心会被这个 App 顶掉）。
///
/// 代价：确实费电，而且系统设置里的「后台 App 刷新」无关。用户在设置页可以随时关掉它。
final class BackgroundKeeper {

    private var player: AVAudioPlayer?
    private var running = false
    private var observers: [NSObjectProtocol] = []

    var isRunning: Bool { running }

    deinit { stop() }

    /// - Returns: 启动失败时的原因；成功返回 nil
    @discardableResult
    func start() -> String? {
        guard !running else { return nil }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            return "音频会话激活失败：\(error.localizedDescription)"
        }

        do {
            let player = try AVAudioPlayer(data: BackgroundKeeper.inaudibleWAV())
            player.numberOfLoops = -1          // 无限循环
            player.volume = 1.0                // 音量交给波形本身控制，这里不衰减
            player.prepareToPlay()
            guard player.play() else {
                return "AVAudioPlayer.play() 返回 false"
            }
            self.player = player
        } catch {
            return "静音音频播放失败：\(error.localizedDescription)"
        }

        observeInterruptions()
        running = true
        SCLog.info("后台保活已开启（静音音频会话）")
        return nil
    }

    func stop() {
        guard running || player != nil else { return }
        player?.stop()
        player = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        if running { SCLog.info("后台保活已关闭") }
        running = false
    }

    /// 被电话/其它 App 打断后要自己接回来，否则保活就断了
    private func observeInterruptions() {
        let center = NotificationCenter.default
        let handler: (Notification) -> Void = { [weak self] note in
            guard let self else { return }
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

            switch type {
            case .began:
                SCLog.warn("音频会话被系统打断，后台保活暂时中断")
            case .ended:
                SCLog.info("音频会话打断结束，尝试恢复保活")
                self.player?.play()
            @unknown default:
                break
            }
        }
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main, using: handler))
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
