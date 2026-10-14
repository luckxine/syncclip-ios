import Foundation
import NetworkExtension
import UIKit
import PasteProbeShared

/// 探针的隧道进程。
///
/// 它什么都不转发 —— 目标只是回答三个问题：
///   1. 伪造签名（TrollStore）能不能真的建起一条 VPN 隧道？
///   2. 隧道进程是不是独立于 App 活着（App 退到后台、被杀掉，它还活着）？
///   3. **隧道进程能不能读写剪贴板？**（这决定了「把同步逻辑搬进隧道」这条路走不走得通）
///
/// 第 3 条是整条路线成立与否的关键，而它没有公开先例：EasyTier / StosVPN 这些
/// 真实项目都只用隧道转发网络，从不碰 UIKit。所以这里要主动试，并把结果、
/// 包括失败时的报错原样记进日志。
final class ProbeTunnelProvider: NEPacketTunnelProvider {

    private var heartbeat: DispatchSourceTimer?
    private var ticks = 0

    // MARK: - 生命周期

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        ProbeLog.append(source: "tunnel", kind: "startTunnel",
                        detail: "被拉起，options=\(options?.keys.sorted().joined(separator: ",") ?? "(空)")")

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.11.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.11.0.2"], subnetMasks: ["255.255.255.0"])
        // 只声明一条「谁也不去」的路由：包含一个我们自己的 /24，其余全部排除。
        // 这样隧道是活的，但用户的流量一点都不经过我们 —— 和 StosVPN 同一个手法。
        // 排除项写成 0.0.0.0/0.0.0.0，不用 NEIPv4Route.default()（那个方法名是 Swift 关键字，
        // 写起来容易踩编译器，语义完全等价）。
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "10.11.0.0", subnetMask: "255.255.255.0")]
        ipv4.excludedRoutes = [NEIPv4Route(destinationAddress: "0.0.0.0", subnetMask: "0.0.0.0")]
        settings.ipv4Settings = ipv4

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                ProbeLog.append(source: "tunnel", kind: "setTunnelNetworkSettings.fail",
                                detail: "\(error)")
                completionHandler(error)
                return
            }
            ProbeLog.append(source: "tunnel", kind: "tunnelUp", detail: "网络设置已生效，隧道进程开始跑")
            self.startPacketPump()
            self.startHeartbeat()

            if options?["echoPasteboard"] != nil {
                self.probePasteboard(tag: "startTunnel")
            }
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        ProbeLog.append(source: "tunnel", kind: "stopTunnel",
                        detail: "被要求停止，reason=\(reason.rawValue)")
        heartbeat?.cancel()
        heartbeat = nil
        completionHandler()
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
            // 收到什么原样写回去。没有这一步隧道仍然是"连着"的，
            // 但我们要它保持网络栈活跃，免得系统判定这条隧道没在干活。
            self.packetFlow.writePackets(packets, withProtocols: protocols)
            self.startPacketPump()
        }
    }

    // MARK: - 核心实验：隧道进程碰剪贴板

    /// 两条路径都试，因为「能不能碰」和「在哪个线程碰」是两个独立的问题，
    /// 而我没有公开资料能确定 appex 的主队列是否会被排空。
    /// 两边都记日志，谁失败都留下证据，别让"没反应"成为结论。
    private func probePasteboard(tag: String) {
        DispatchQueue.global(qos: .utility).async {
            self.pasteboardRoundTrip(tag: "\(tag)/后台线程")
        }
        DispatchQueue.main.async {
            self.pasteboardRoundTrip(tag: "\(tag)/主线程")
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
}
