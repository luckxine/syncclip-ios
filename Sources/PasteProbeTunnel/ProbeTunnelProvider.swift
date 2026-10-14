import Foundation
import NetworkExtension
import UIKit
import PasteProbeShared

/// 探针的隧道进程。
///
/// 它什么都不转发 —— 目标只是回答几个问题：
///   1. 伪造签名（TrollStore）能不能真的建起一条 VPN 隧道？
///   2. 隧道进程是不是独立于 App 活着（App 退到后台、被杀掉，它还活着）？
///   3. **隧道进程能不能读写剪贴板？**（这决定了「把同步逻辑搬进隧道」这条路走不走得通）
///   4. **隧道进程能不能读「别人写的」剪贴板内容而不弹提示？**（v2 补上）
///   5. 隧道进程能不能自己发 HTTP 请求（真实现里它要挂 WebSocket / 轮询服务器）？
///   6. App 和隧道之间能不能通过 sendProviderMessage 双向通信？
///
/// v1 的实测结论（见 docs/probe.md）：
///   - 前三条全通过：隧道建得起来，隧道进程读写剪贴板都成功
///   - **主队列不会被排空**：从 DispatchQueue.main 派出去的任务一次都没执行，
///     所以隧道里所有活儿都必须放后台队列（v2 加了更精确的判定，见 probeMainQueue）
final class ProbeTunnelProvider: NEPacketTunnelProvider {

    private var heartbeat: DispatchSourceTimer?
    private var ticks = 0
    private var lastClipboard: [String: Any] = [:]

    // MARK: - 生命周期

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let keys = options?.keys.sorted().joined(separator: ",") ?? "(空)"
        ProbeLog.append(source: "tunnel", kind: "startTunnel", detail: "被拉起，options=\(keys)")

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.11.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.11.0.2"], subnetMasks: ["255.255.255.0"])
        // 只声明一条「谁也不去」的路由：包含一个我们自己的 /24，其余全部排除。
        // 这样隧道是活的，但用户的流量一点都不经过我们 —— 和 StosVPN 同一个手法。
        // 排除项写成 0.0.0.0/0.0.0.0，不用 NEIPv4Route.default()（那个方法名是 Swift 关键字）。
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "10.11.0.0", subnetMask: "255.255.255.0")]
        ipv4.excludedRoutes = [NEIPv4Route(destinationAddress: "0.0.0.0", subnetMask: "0.0.0.0")]
        settings.ipv4Settings = ipv4

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                ProbeLog.append(source: "tunnel", kind: "setTunnelNetworkSettings.fail", detail: "\(error)")
                completionHandler(error)
                return
            }
            ProbeLog.append(source: "tunnel", kind: "tunnelUp", detail: "网络设置已生效，隧道进程开始跑")
            self.startPacketPump()
            self.startHeartbeat()

            // mode=readOnly 是 v2 新增的：只读剪贴板、什么都不改。
            // v1 的做法是先把剪贴板写成自己的 nonce 再让隧道读，那样只能证明
            // 「隧道能读到自己写的东西」—— 而读自己的内容在 iOS 上永远不弹提示，
            // 证明不了真实现最需要的那件事：读**别人**（Safari/微信）写的内容会不会被拦。
            let mode = options?["mode"] as? String
            switch mode {
            case "readOnly":
                self.probeMainQueue(tag: "startTunnel")
                self.snapshotOnBackground(tag: "startTunnel/只读模式")
            default:
                if options?["echoPasteboard"] != nil {
                    self.probeMainQueue(tag: "startTunnel")
                    self.pasteboardRoundTrip(tag: "startTunnel")
                }
            }
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        ProbeLog.append(source: "tunnel", kind: "stopTunnel",
                        detail: "被要求停止，reason=\(reason.rawValue)（\(Self.reasonName(reason))）")
        heartbeat?.cancel()
        heartbeat = nil
        completionHandler()
    }

    /// NEProviderStopReason 没有公开的字符串描述，这里手写一份，免得日志里只剩一个数字
    static func reasonName(_ reason: NEProviderStopReason) -> String {
        switch reason {
        case .none: return "none"
        case .userInitiated: return "用户主动断开"
        case .providerFailed: return "provider 失败"
        case .noNetworkAvailable: return "无网络"
        case .unmetSystemRequirements: return "系统要求不满足"
        case .userSwitch: return "用户切换"
        case .appUpdate: return "App 更新"
        case .configurationChange: return "配置变更"
        case .idleTimeout: return "闲置超时"
        case .systemInitiated: return "系统发起"
        case .userLogout: return "用户登出"
        default: return "未知"
        }
    }

    // MARK: - 心跳

    /// 用 DispatchSourceTimer 而不是 Timer：Timer 依赖某个 RunLoop 在转，
    /// 而 appex 的主线程 RunLoop 由系统托管，不一定在转。
    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.ticks += 1
            ProbeLog.append(source: "tunnel", kind: "heartbeat",
                            detail: "第 \(self.ticks) 次心跳，隧道进程还活着")
        }
        timer.resume()
        heartbeat = timer
    }

    // MARK: - 转发（其实只是原样放回，什么都不改）

    private func startPacketPump() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self else { return }
            self.packetFlow.writePackets(packets, withProtocols: protocols)
            self.startPacketPump()
        }
    }

    // MARK: - 主队列到底会不会被排空

    /// v1 只看到他派到主队列的剪贴板操作没执行，于是有两个可能：主队列没被排空，
    /// 或者主队列被执行了但卡在剪贴板那一步。这两个原因的修法完全不同，
    /// 所以这里派两个任务：一个不碰剪贴板（只记日志），一个真读剪贴板。
    ///   只看到 mainQueue.ran        → 主队列是活的，是剪贴板调用在主线程上卡住
    ///   两个都没有                  → 主队列根本没被排空，主队列里什么都别放
    private func probeMainQueue(tag: String) {
        DispatchQueue.main.async {
            ProbeLog.append(source: "tunnel", kind: "mainQueue.ran",
                            detail: "[\(tag)] 主队列确实被排空了（派上去的任务执行到了）")
        }
        DispatchQueue.main.async { [weak self] in
            self?.pasteboardRoundTrip(tag: "\(tag)/主队列")
        }
        ProbeLog.append(source: "tunnel", kind: "mainQueue.probe",
                        detail: "[\(tag)] 已向主队列派两个任务（一个不碰剪贴板、一个读剪贴板），"
                              + "若日志里看不到任何 mainQueue.* 就是主队列没被排空")
    }

    // MARK: - 剪贴板

    /// 两种探测都跑，因为「能不能碰」和「在哪个线程碰」是两个独立问题。
    /// 全部走后台队列 —— v1 已证实主队列不可靠。
    private func pasteboardRoundTrip(tag: String) {
        DispatchQueue.global(qos: .utility).async {
            self.pasteboardRoundTrip(tag: "\(tag)/后台线程")
        }
    }

    private func pasteboardRoundTrip(tag: String) {
        let board = UIPasteboard.general
        let count = board.changeCount
        let text = board.string ?? ""

        ProbeLog.append(source: "tunnel", kind: "pasteboard.read",
                        detail: "[\(tag)] changeCount=\(count) 长度=\(text.count) "
                              + "内容前缀=\(String(text.prefix(48)))")

        guard text.hasPrefix(Probe.txPrefix) else {
            ProbeLog.append(source: "tunnel", kind: "pasteboard.noNonce",
                            detail: "[\(tag)] 剪贴板里没有 App 放进去的 nonce，无法确认"
                                  + "「读到的是 App 写的内容」")
            return
        }

        let nonce = String(text.dropFirst(Probe.txPrefix.count))
        let echo = "\(Probe.echoPrefix) \(nonce)"
        board.string = echo
        ProbeLog.append(source: "tunnel", kind: "pasteboard.echo",
                        detail: "[\(tag)] 读到了 App 的 nonce 并已回写 echo=\(echo)")
    }

    /// 只读快照：不动剪贴板，把读到的东西原样记下来。
    /// 这是 v2 的核心实验 —— 用户先在 Safari 复制一段文字，再让隧道读。
    private func snapshotOnBackground(tag: String) {
        DispatchQueue.global(qos: .utility).async {
            self.snapshot(tag: "\(tag)/后台线程")
        }
    }

    @discardableResult
    private func snapshot(tag: String) -> [String: Any] {
        let board = UIPasteboard.general
        let count = board.changeCount
        let text: String? = board.string
        let types = board.types.joined(separator: ",")
        let prefix = String((text ?? "").prefix(64))

        ProbeLog.append(source: "tunnel", kind: "pasteboard.snapshot",
                        detail: "[\(tag)] changeCount=\(count) "
                              + "string=\(text == nil ? "nil（读不到）" : "\(text!.count) 字") "
                              + "types=[\(types)] 前缀=\(prefix)")

        let info: [String: Any] = [
            "changeCount": count,
            "length": text?.count ?? -1,
            "prefix": prefix,
            "types": types,
            "source": "tunnel",
        ]
        lastClipboard = info
        return info
    }

    // MARK: - App ↔ 隧道通信（sendProviderMessage）

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let thread = Thread.isMainThread ? "主线程" : "后台线程"
        guard let obj = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
              let cmd = obj["cmd"] as? String else {
            ProbeLog.append(source: "tunnel", kind: "ipc.bad", detail: "收到无法解析的 App 消息")
            completionHandler?(Probe.json(["ok": false, "error": "bad command"]))
            return
        }
        ProbeLog.append(source: "tunnel", kind: "ipc.command", detail: "收到 App 消息 cmd=\(cmd)（回调在\(thread)）")

        switch cmd {
        case "ping":
            completionHandler?(Probe.json([
                "ok": true,
                "ticks": ticks,
                "thread": thread,
                "lastClipboard": lastClipboard.isEmpty ? NSNull() : lastClipboard,
            ]))

        case "readPasteboard":
            // 从后台队列做，reply 时再回调（回调在哪都行）
            DispatchQueue.global(qos: .utility).async {
                let info = self.snapshot(tag: "ipc/readPasteboard")
                var out = info
                out["ok"] = true
                completionHandler?(Probe.json(out))
            }

        case "fetch":
            let url = obj["url"] as? String ?? ""
            fetch(url) { result in
                completionHandler?(Probe.json(result))
            }

        default:
            completionHandler?(Probe.json(["ok": false, "error": "unknown cmd \(cmd)"]))
        }
    }

    /// 隧道进程自己发 HTTP 请求。真实现里这条连接（WebSocket 或轮询）的成败
    /// 决定了整个架构能不能「零轮询推送」，所以在这里先证明它能联网。
    private func fetch(_ urlString: String, reply: @escaping ([String: Any]) -> Void) {
        guard let url = URL(string: urlString), !urlString.isEmpty else {
            ProbeLog.append(source: "tunnel", kind: "fetch.skip", detail: "URL 空或不合格：\(urlString)")
            reply(["ok": false, "error": "bad url"])
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("PasteProbe/1.0", forHTTPHeaderField: "User-Agent")
        ProbeLog.append(source: "tunnel", kind: "fetch.begin", detail: "GET \(urlString)")

        let started = Date()
        URLSession.shared.dataTask(with: request) { data, response, error in
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if let error = error {
                ProbeLog.append(source: "tunnel", kind: "fetch.fail",
                                detail: "\(urlString) 失败（\(ms) ms）：\(error.localizedDescription)")
                reply(["ok": false, "ms": ms, "error": error.localizedDescription])
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bytes = data?.count ?? 0
            let head = data.map { String(data: $0.prefix(120), encoding: .utf8) ?? "（非文本）" } ?? ""
            ProbeLog.append(source: "tunnel", kind: "fetch.done",
                            detail: "HTTP \(status)，\(bytes) 字节，\(ms) ms，正文前缀=\(head)")
            reply(["ok": true, "status": status, "bytes": bytes, "ms": ms, "prefix": head])
        }.resume()
    }

}
