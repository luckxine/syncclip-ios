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

    private(set) var manager: NETunnelProviderManager?
    private(set) var nonce = ""
    private(set) var echoSeen = false

    private var savedClipboard: String?
    private var polls = 0
    private var lastStatus: NEVPNStatus?
    private var pollTimer: Timer?

    // MARK: - 对外入口

    func run() {
        say("================ 探针开始 ================")
        if Probe.containerURL == nil {
            say("⚠️ App Group 容器拿不到，跨进程日志会缺一半；"
              + "但剪贴板往返这条通道不依赖 App Group，核心结论照样能拿到。")
        }
        saveAndWriteNonce()
    }

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
        let create: (NETunnelProviderManager) -> Void = { manager in
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
        if let manager = manager {
            create(manager)
            return
        }
        NETunnelProviderManager.loadAllFromPreferences { managers, _ in
            DispatchQueue.main.async {
                guard let first = managers?.first else {
                    self.say("还没有配置，先跑一次探针再开自启")
                    return
                }
                self.manager = first
                create(first)
            }
        }
    }

    func restoreClipboard() {
        guard let saved = savedClipboard else {
            say("没有保存过原剪贴板内容")
            return
        }
        UIPasteboard.general.string = saved
        say("已还原剪贴板（\(saved.count) 字）")
    }

    func dumpTunnelLog(tail: Int = 40) {
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

    // MARK: - 步骤

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
        resetConfiguration()
    }

    private func resetConfiguration() {
        say("读取本 App 以前建过的 VPN 配置…")
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.say("读配置出错：\(Self.describe(error))")
                }
                let list = managers ?? []
                self.say("现有配置 \(list.count) 条")
                if list.isEmpty {
                    self.createConfiguration()
                } else {
                    self.removeAll(list)
                }
            }
        }
    }

    private func removeAll(_ managers: [NETunnelProviderManager]) {
        guard !managers.isEmpty else {
            createConfiguration()
            return
        }
        let head = managers[0]
        let tail = Array(managers.dropFirst())
        head.removeFromPreferences { error in
            DispatchQueue.main.async {
                if let error = error {
                    self.say("删除旧配置失败：\(Self.describe(error))")
                }
                self.removeAll(tail)
            }
        }
    }

    private func createConfiguration() {
        let manager = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.serverAddress = "pasteprobe.local"
        proto.providerBundleIdentifier = Probe.tunnelBundleID
        manager.protocolConfiguration = proto
        manager.localizedDescription = "PasteProbe 探针"
        manager.isEnabled = true

        say("建配置：providerBundleIdentifier=\(Probe.tunnelBundleID)")
        say("（系统会弹一次「允许添加 VPN 配置」，需要面容/密码确认）")

        manager.saveToPreferences { error in
            DispatchQueue.main.async {
                if let error = error {
                    self.say("❌ saveToPreferences 失败：\(Self.describe(error))")
                    self.say("   → 这一步失败的含义：系统不认这个由伪造签名带进来的")
                    self.say("     networkextension entitlement。NE 路线到此为止，")
                    self.say("     改走音频/位置保活。（先把 entitlement 与 StosVPN 对齐再试一次，")
                    self.say("     见 docs/probe.md 的「失败了怎么办」）")
                    self.finish()
                    return
                }
                self.say("✅ saveToPreferences 成功 —— 系统接受了这个 VPN 配置")
                self.manager = manager
                self.startTunnel()
            }
        }
    }

    private func startTunnel() {
        guard let manager = manager else { return }
        manager.loadFromPreferences { error in
            DispatchQueue.main.async {
                if let error = error {
                    self.say("loadFromPreferences 出错（可忽略，继续）：\(Self.describe(error))")
                }
                guard let session = manager.connection as? NETunnelProviderSession else {
                    self.say("❌ connection 不是 NETunnelProviderSession")
                    self.finish()
                    return
                }
                let options: [String: NSObject] = ["echoPasteboard": "1" as NSString]
                do {
                    try session.startVPNTunnel(options: options)
                    self.say("✅ startVPNTunnel 已被接受，等隧道进程起来（最多等 30 秒）")
                    self.startPolling()
                } catch {
                    self.say("❌ startVPNTunnel 抛错：\(Self.describe(error))")
                    self.finish()
                }
            }
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

        if let manager = manager {
            let status = manager.connection.status
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
            let status = manager?.connection.status ?? .invalid
            say("⏱ 30 秒内没等到 echo。connection.status=\(status.rawValue)（\(Self.statusName(status))）")
            if status == .connected {
                say("    隧道是连着的，但隧道进程没有回写剪贴板。看下面的 App Group 日志：")
                say("      - 有 heartbeat 但 pasteboard.* 报错 → 进程碰不到剪贴板")
                say("      - 完全没有 heartbeat            → 跨进程日志不通，或 appex 入口点不对")
                say("      - 有 fakeEntry                  → 链接器入口没生效（构建问题）")
            } else {
                say("    隧道压根没连上。这一般是 appex 没被系统接受（签名/Info.plist/入口点）,")
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
        dumpTunnelLog(tail: 40)
        say("================ 探针结束 ================")
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
