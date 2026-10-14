import Foundation
import NetworkExtension
import UIKit
import PasteProbeShared

/// 探针的流程控制。
///
/// 这条链上的每一步都可能失败，而且失败原因差别很大：
///   saveToPreferences 失败   → 系统不认伪造的 NE entitlement（路线基本结束）
///   startVPNTunnel 抛错      → 隧道进程起不来（appex 签名 / Info.plist / 入口点）
///   起来了但没日志            → App Group 不可用，或 appex 入口不对
///   有日志但没 echo           → 隧道进程碰不到剪贴板
/// 所以每一步都要单独说清楚，别把六种失败压成一句"没成功"。
final class ProbeRunner {

    var onLine: ((String) -> Void)?
    /// 隧道联网测试要打的 URL（界面上可改）
    var testURL = ""

    private(set) var manager: NETunnelProviderManager?
    private(set) var session: NETunnelProviderSession?
    private(set) var nonce = ""
    private(set) var echoSeen = false

    private var savedClipboard: String?
    private var polls = 0
    private var lastStatus: NEVPNStatus?
    private var pollTimer: Timer?

    // MARK: - 入口一：nonce/echo 往返（v1 的用法，仍保留）

    func run() {
        say("=============== 探针开始（echo 往返）===============")
        if Probe.containerURL == nil {
            say("⚠️ App Group 容器拿不到，跨进程日志会缺一半；"
              + "但剪贴板往返这条通道不依赖 App Group，核心结论照样能拿到。")
        }
        saveAndWriteNonce()
    }

    // MARK: - 入口二：只读剪贴板（v2 新增，真正关键的那个实验）

    /// 这个实验**不改剪贴板**，隧道只读一次。
    ///
    /// 为什么必须有它：v1 是「App 先写 nonce → 隧道读出来」。而读**自己写**的内容
    /// 在 iOS 上永远不弹提示，所以 v1 证明不了真实现最需要的那件事 ——
    /// 读 Safari / 微信 写进去的内容会不会被拦。
    func readClipboardNow() {
        say("========== 只读剪贴板实验（不改剪贴板内容）==========")
        say("注意看这段时间屏幕顶部有没有弹「允许粘贴」的横幅 —— 那也是结果的一部分。")

        // App 侧读一次作为基线。App 与隧道带的是同一组粘贴板 entitlement，
        // 所以这一行是参照物：
        //   它拿到内容 → 说明当前 entitlement 下「读别人的内容」是放行的，问题只会出在隧道侧
        //   它是 nil   → 说明连前台 App 都被拦，那不是隧道的锅
        let board = UIPasteboard.general
        let text = board.string
        let summary = "changeCount=\(board.changeCount) "
                    + "string=\(text == nil ? "nil（读不到）" : "\(text!.count) 字") "
                    + "前缀=\(String((text ?? "").prefix(64)))"
        say("App 侧基线：\(summary)")
        // 也写进 App Group 日志，这样和隧道侧的记录能在同一时间轴上对比
        ProbeLog.append(source: "app", kind: "pasteboard.baseline", detail: summary)

        if session?.status == .connected {
            say("隧道已在跑 → 直接让它读（不重启隧道、不动剪贴板）")
            send(json: ["cmd": "readPasteboard"], label: "readPasteboard")
        } else {
            say("隧道没在跑 → 拉起来（mode=readOnly）")
            prepareConfiguration { manager in
                self.start(manager: manager, options: ["mode": "readOnly" as NSString])
            }
        }
    }

    // MARK: - 入口三：App ↔ 隧道通信

    func pingTunnel() {
        say("========== App ↔ 隧道 通信测试 ==========")
        say("走的是官方通道 sendProviderMessage / handleAppMessage（真实现要靠它下发配置）")
        send(json: ["cmd": "ping"], label: "ping")
    }

    // MARK: - 入口四：隧道联网测试

    func fetchViaTunnel() {
        say("========== 隧道联网测试 ==========")
        let url = testURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            say("先在上面填一个 URL。填你的 SyncClipboard 服务器地址就行，")
            say("例如 http://192.168.1.10:5033/api/version —— 这里要验的是")
            say("「隧道进程能不能自己发请求」，而不是那个地址本身对不对。")
            return
        }
        say("让隧道进程去 GET \(url)")
        send(json: ["cmd": "fetch", "url": url], label: "fetch")
    }

    // MARK: - 停止 / 自启 / 还原

    func stopTunnel() {
        guard let manager = manager else {
            say("还没有配置，先跑一次探针")
            return
        }
        manager.connection.stopVPNTunnel()
        say("已请求停止隧道")
    }

    /// 开机自启（on-demand）。这是「App 被杀也还在」之外的第二个关键问题：
    /// 重启手机后隧道会不会自己起来（= 真守护进程的行为）。
    func enableOnDemand() {
        prepareConfiguration { manager in
            manager.isOnDemandEnabled = true
            manager.onDemandRules = [NEOnDemandRuleConnect()]
            manager.saveToPreferences { error in
                DispatchQueue.main.async {
                    if let error = error {
                        self.say("❌ 开启开机自启失败：\(Self.describe(error))")
                    } else {
                        self.say("✅ 已开启 on-demand 自动连接。")
                        self.say("   → 现在重启手机，然后**不要打开这个 App**，过两分钟再打开看日志：")
                        self.say("     日志里有重启时间之后的心跳 = 隧道能开机自启 = 等价于守护进程。")
                    }
                }
            }
        }
    }

    func restoreClipboard() {
        guard let saved = savedClipboard else {
            say("没有保存过原剪贴板内容（只读实验不会改剪贴板，所以不需要还原）")
            return
        }
        UIPasteboard.general.string = saved
        say("已还原剪贴板（\(saved.count) 字）")
    }

    func dumpTunnelLog(tail: Int = 60) {
        let (records, note) = ProbeLog.read()
        say("---- App Group 日志（\(note)）----")
        if records.isEmpty {
            say("（空）")
            return
        }
        for r in records.suffix(tail) {
            say("  " + r.line)
        }
    }

    // MARK: - 配置管理

    /// 复用已有配置，**不删除**。
    ///
    /// v1 里每次运行都先删掉旧配置再建新的，副作用是：删配置会连带把正在跑的隧道
    /// 停掉（日志里那条 `stopTunnel reason=…`）。真实现绝不能让 App 一启动就把
    /// 常驻的隧道掐了，所以这里改成「有就复用」。
    private func prepareConfiguration(_ done: @escaping (NETunnelProviderManager) -> Void) {
        say("读取本 App 以前建过的 VPN 配置…")
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.say("读配置出错（继续尝试建新的）：\(Self.describe(error))")
                }
                let existing = (managers ?? []).first {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                        .providerBundleIdentifier == Probe.tunnelBundleID
                }
                if let existing = existing {
                    self.say("✅ 复用已有配置（不删除 —— 删配置会把正在跑的隧道一起停掉）")
                    self.manager = existing
                    self.session = existing.connection as? NETunnelProviderSession
                    done(existing)
                    return
                }
                self.say("没有可用配置，新建一条")
                self.say("（系统会弹一次「允许添加 VPN 配置」，需要面容/密码确认）")
                let manager = NETunnelProviderManager()
                let proto = NETunnelProviderProtocol()
                proto.serverAddress = "pasteprobe.local"
                proto.providerBundleIdentifier = Probe.tunnelBundleID
                manager.protocolConfiguration = proto
                manager.localizedDescription = "PasteProbe 探针"
                manager.isEnabled = true
                manager.saveToPreferences { error in
                    DispatchQueue.main.async {
                        if let error = error {
                            self.say("❌ saveToPreferences 失败：\(Self.describe(error))")
                            self.say("   → 这一步失败的含义：系统不认这个由伪造签名带进来的")
                            self.say("     networkextension entitlement。NE 路线到此为止，")
                            self.say("     改走音频/位置保活。（先把 entitlement 与 StosVPN 对齐再试一次，")
                            self.say("     见 docs/probe.md 的「失败了怎么办」）")
                            return
                        }
                        self.say("✅ saveToPreferences 成功 —— 系统接受了这个 VPN 配置")
                        manager.loadFromPreferences { _ in
                            DispatchQueue.main.async {
                                self.manager = manager
                                self.session = manager.connection as? NETunnelProviderSession
                                done(manager)
                            }
                        }
                    }
                }
            }
        }
    }

    /// 拉起隧道。
    ///
    /// 参数收 manager 而不是 session，是因为 `prepareConfiguration` 交出来的就是
    /// manager —— 之前这里收 session，两处调用都传了 manager，CI 上四个编译错误
    /// 全出在这个类型不匹配上。顺便把 session 存下来，IPC 要用。
    private func start(manager: NETunnelProviderManager, options: [String: NSObject]) {
        guard let session = manager.connection as? NETunnelProviderSession else {
            say("❌ manager.connection 不是 NETunnelProviderSession，无法启动")
            finish()
            return
        }
        self.session = session
        do {
            try session.startVPNTunnel(options: options)
            say("✅ startVPNTunnel 已被接受，等隧道进程起来（最多等 30 秒）")
            startPolling()
        } catch {
            say("❌ startVPNTunnel 抛错：\(Self.describe(error))")
            finish()
        }
    }

    // MARK: - 发消息给隧道

    private func send(json: [String: Any], label: String) {
        guard let session = session else {
            say("还没有隧道会话 —— 先点「运行探针」或「只读取剪贴板」把隧道建起来")
            return
        }
        guard let data = Probe.json(json) else {
            say("消息序列化失败")
            return
        }
        do {
            try session.sendProviderMessage(data) { [weak self] reply in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if let reply = reply, let text = String(data: reply, encoding: .utf8) {
                        self.say("隧道回复：\(text)")
                        if label == "readPasteboard" {
                            self.say("   ↑ 看 length / prefix：如果内容和 App 侧基线一样，")
                            self.say("     那「隧道能读别人的剪贴板」就成立了。")
                            self.say("     如果 length 是 -1 或 prefix 为空 → 隧道侧读到 nil，被拦了。")
                        }
                    } else {
                        self.say("隧道没有回复（nil）")
                        self.say("   → 要么隧道没在跑，要么 handleAppMessage 没被调用。")
                        self.say("     先去「刷新日志」看 App Group 日志里有没有 ipc.command 那一条：")
                        self.say("       有 → 隧道收到了但回话通道不通")
                        self.say("       没有 → 消息根本没到隧道")
                    }
                    self.say("（记得点「刷新日志」看隧道侧自己写的记录）")
                }
            }
            say("已发出：\(label)")
        } catch {
            say("❌ sendProviderMessage 失败：\(Self.describe(error))")
            say("   → 常见原因是隧道当前不是 connected 状态。先跑一次探针把隧道拉起来。")
        }
    }

    // MARK: - v1 的 echo 往返流程

    private func saveAndWriteNonce() {
        let board = UIPasteboard.general
        let current = board.string ?? ""
        if current.hasPrefix(Probe.echoPrefix) {
            say("剪贴板里是上一次的 echo，不覆盖已保存的原内容")
        } else {
            savedClipboard = current
            say("已保存原剪贴板（\(current.count) 字），探针结束会还原")
        }

        nonce = String(UUID().uuidString.prefix(8)).lowercased()
        board.string = Probe.txPrefix + nonce
        say("已把剪贴板写成 \(Probe.txPrefix)\(nonce)")
        prepareConfiguration { manager in
            self.start(manager: manager, options: ["echoPasteboard": "1" as NSString])
        }
    }

    // MARK: - 轮询

    private func startPolling() {
        polls = 0
        lastStatus = nil
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollOnce()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func pollOnce() {
        polls += 1

        if let session = session {
            let status = session.status
            if lastStatus != status {
                lastStatus = status
                say("隧道状态 → \(Self.statusName(status))")
            }
        }

        let text = UIPasteboard.general.string ?? ""
        if text.hasPrefix(Probe.echoPrefix) {
            echoSeen = true
            stopPolling()
            say("✅✅ 剪贴板里出现 echo：\(text)")
            say("    结论：隧道进程既能读剪贴板，也能写剪贴板。")
            say("    ——「把同步逻辑搬进隧道进程」这条路线成立。")
            finish()
            return
        }

        if polls >= 30 {
            stopPolling()
            let status = session?.status ?? .invalid
            say("⏱ 30 秒内没等到 echo。connection.status=\(status.rawValue)（\(Self.statusName(status))）")
            if status == .connected {
                say("    隧道是连着的，但隧道进程没有回写剪贴板。看下面的 App Group 日志：")
                say("      - 有 heartbeat 但 pasteboard.* 报错 → 进程碰不到剪贴板")
                say("      - 完全没有 heartbeat            → 跨进程日志不通，或 appex 入口点不对")
                say("      - 有 fakeEntry                  → 链接器入口没生效（构建问题）")
            } else {
                say("    隧道压根没连上。这一般是 appex 没被系统接受（签名/Info.plist/入口点），")
                say("    查 docs/probe.md 的「失败了怎么办」。")
            }
            finish()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func finish() {
        stopPolling()
        dumpTunnelLog(tail: 60)
        say("=============== 探针结束 ===============")
    }

    // MARK: - 工具

    private func say(_ text: String) {
        onLine?(text)
    }

    static func describe(_ error: Error) -> String {
        let e = error as NSError
        var s = "\(e.domain) code=\(e.code) “\(e.localizedDescription)”"
        if let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError {
            s += " ← \(underlying.domain) code=\(underlying.code)"
        }
        return s
    }

    static func statusName(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}
