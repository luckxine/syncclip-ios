import Foundation
import NetworkExtension
import UIKit
import PasteProbeShared

/// 探针的流程控制。
///
/// 真机上踩到的失败形态（都写进了 docs/probe.md）：
///   `saveToPreferences` 失败           → 系统不认伪造的 NE entitlement（路线基本结束）
///   `startVPNTunnel` 抛 code=2         → 配置被禁用（重装 App 会撂成 isEnabled=false）
///   `startVPNTunnel` 接受但停在 connecting、隧道侧零日志
///                                      → appex 压根没被拉起（配置指向的东西已经没了）
///   起来了但没 echo                    → 隧道进程碰不到剪贴板
/// 所以每一步都要单独说清楚，别把这么多种失败压成一句"没成功"。
final class ProbeRunner {

    var onLine: ((String) -> Void)?
    /// 隧道联网测试要打的 URL（界面上可改）
    var testURL = ""

    private(set) var manager: NETunnelProviderManager?
    private(set) var session: NETunnelProviderSession?

    private var savedClipboard: String?

    private var polls = 0
    private var sawConnected = false
    private var lastStatus: NEVPNStatus?
    private var pollTimer: Timer?
    private var pendingOptions: [String: NSObject] = [:]
    private var pendingRetry = false
    private var finished = false
    /// 隧道连上之后要自动执行的东西（②③④ 都排在这儿，避免「没连上就发消息」的静默失败）
    private var pendingWhenConnected: (() -> Void)?

    // MARK: - 入口一：nonce/echo 往返

    func run() {
        say("=============== 探针开始（echo 往返）===============")
        if Probe.containerURL == nil {
            say("⚠️ App Group 容器拿不到，跨进程日志会缺一半；"
              + "但剪贴板往返这条通道不依赖 App Group，核心结论照样能拿到。")
        }
        saveAndWriteNonce()
    }

    // MARK: - 入口二：只读剪贴板（真正关键的那个实验）

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
        let lengthText = text.map { "\($0.count) 字" } ?? "nil（读不到）"
        let summary = "changeCount=\(board.changeCount) string=\(lengthText) "
                    + "前缀=\(String((text ?? "").prefix(64)))"
        say("App 侧基线：\(summary)")
        // 也写进 App Group 日志，这样和隧道侧的记录能在同一时间轴上对比
        ProbeLog.append(source: "app", kind: "pasteboard.baseline", detail: summary)

        if text?.hasPrefix(Probe.txPrefix) == true {
            say("⚠️ 剪贴板里现在放的是探针自己写的 nonce（\(Probe.txPrefix)…），"
              + "不是你在 Safari 里复制的内容。")
            say("   这样即使读到，也只能证明「隧道能读自己写的东西」，答不了真正的问题。")
            say("   建议：去 Safari 复制一段文字，再点这个按钮。")
        }

        whenTunnelReady(tag: "只读剪贴板") {
            self.send(json: ["cmd": "readPasteboard"], label: "readPasteboard")
        }
    }

    // MARK: - 入口三：隧道联网测试

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
        whenTunnelReady(tag: "隧道联网") {
            self.send(json: ["cmd": "fetch", "url": url], label: "fetch")
        }
    }

    // MARK: - 入口四：App ↔ 隧道

    func pingTunnel() {
        say("========== App ↔ 隧道 通信测试 ==========")
        say("走的是官方通道 sendProviderMessage / handleAppMessage（真实现要靠它下发配置）")
        whenTunnelReady(tag: "App↔隧道") {
            self.send(json: ["cmd": "ping"], label: "ping")
        }
    }

    // MARK: - 入口五：列出所有 VPN 配置

    /// 把系统里**每一条** VPN 配置都列出来。
    ///
    /// 为什么要这个：真机上出现过 `stopTunnel reason=11`（superceded = 被另一条配置取代）。
    /// 「被取代」意味着系统里可能还留着一条幽灵/重复配置在顶我们 ——
    /// 而我只删「providerBundleIdentifier 等于本探针」的那些，看不到别人。
    /// 一串出来，有几条、都是谁的，一目了然。
    func listConfigurations() {
        say("========== 列出系统里所有 VPN 配置 ==========")
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.say("读配置出错：\(Self.describe(error))")
                }
                let all = managers ?? []
                self.say("一共 \(all.count) 条：")
                if all.isEmpty {
                    self.say("  （空）")
                }
                for (index, manager) in all.enumerated() {
                    let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
                    self.say("  [\(index)] \(manager.localizedDescription ?? "（没有名字）")")
                    self.say("      provider=\(proto?.providerBundleIdentifier ?? "nil") "
                           + "isEnabled=\(manager.isEnabled) 按需=\(manager.isOnDemandEnabled) "
                           + "连接=\(Self.statusName(manager.connection.status))")
                }
                let ours = all.filter { Self.isOurs($0) }
                self.say("其中属于本探针的：\(ours.count) 条")
                if ours.count > 1 {
                    self.say("  ⚠️ 多于一条 —— 这可能就是 superceded 的来源，"
                           + "点「重置 VPN 配置」会把它们全删掉。")
                }
            }
        }
    }

    // MARK: - 停止 / 自启 / 还原 / 重置

    func stopTunnel() {
        guard let manager = manager else {
            say("还没有配置，先跑一次探针")
            return
        }
        manager.connection.stopVPNTunnel()
        say("已请求停止隧道")
    }

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

    /// 重置：删掉本探针的 VPN 配置，下次运行会新建一条崭新的。
    ///
    /// 为什么这是必要的：真机上 `reason=11 (superceded)` 之后，
    /// 那条配置虽然能被重新启用（isEnabled=true），但 `startVPNTunnel` 会被接受
    /// 却一直停在 connecting、appex 从不启动 —— 说明问题在配置**指向的东西**
    /// （重装 App 之后旧记录失效），光改开关修不了。删掉重建能换掉整条记录。
    func resetConfiguration() {
        say("========== 重置 VPN 配置 ==========")
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.say("读配置出错：\(Self.describe(error))")
                }
                let ours = (managers ?? []).filter { Self.isOurs($0) }
                self.say("找到 \(ours.count) 条属于本探针的配置，逐条删除…")
                self.removeAll(ours) {
                    self.manager = nil
                    self.session = nil
                    self.say("✅ 已删完。再点「① 运行探针」会新建一条启用的配置。")
                }
            }
        }
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

    static func isOurs(_ manager: NETunnelProviderManager) -> Bool {
        (manager.protocolConfiguration as? NETunnelProviderProtocol)?
            .providerBundleIdentifier == Probe.tunnelBundleID
    }

    /// 拿到一条可用的配置：有就复用（不删 —— 删配置会把正在跑的隧道一起停掉），
    /// 没有就新建。两条路径最后都过 `reloadAndEnable`。
    private func prepareConfiguration(_ done: @escaping (NETunnelProviderManager) -> Void) {
        say("读取本 App 以前建过的 VPN 配置…")
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.say("读配置出错（继续尝试建新的）：\(Self.describe(error))")
                }
                let ours = (managers ?? []).filter { Self.isOurs($0) }
                if ours.count > 1 {
                    self.say("⚠️ 有 \(ours.count) 条配置都指向本探针的 appex —— 这很可疑，"
                           + "建议点「重置 VPN 配置」清掉再来。")
                }
                if let existing = ours.first {
                    self.say("✅ 找到已有配置（不删除 —— 删配置会把正在跑的隧道一起停掉）")
                    self.manager = existing
                    self.session = existing.connection as? NETunnelProviderSession
                    self.reloadAndEnable(existing, done: done)
                    return
                }
                self.createConfiguration(done)
            }
        }
    }

    /// 从系统里**重新读一遍**配置，必要时重新启用，然后交出去。
    ///
    /// 为什么必须重读：`loadAllFromPreferences` 拿到的 manager 只是「注册表里的一条
    /// 记录」，要真正操作它（尤其是启动）得先 `loadFromPreferences`。
    ///
    /// 为什么必须查 isEnabled：真机实测过 —— 隧道先被系统以 `reason=11 (superceded)`
    /// 停掉，之后**每一次** `startVPNTunnel` 都报 `NEVPNErrorDomain code=2`
    /// （ConfigurationDisabled）。配置被禁用是「用户能在设置里干、系统也能替你干」的
    /// 事（重装 App 就可能触发），一个常驻服务必须能自己发现并重新启用。
    private func reloadAndEnable(_ manager: NETunnelProviderManager,
                                done: @escaping (NETunnelProviderManager) -> Void) {
        manager.loadFromPreferences { error in
            DispatchQueue.main.async {
                if let error = error {
                    self.say("⚠️ loadFromPreferences 出错（继续试）：\(Self.describe(error))")
                }
                self.say("配置状态：\(self.stateDescription(manager))")
                guard !manager.isEnabled else {
                    done(manager)
                    return
                }
                self.say("⚠️ 配置处于**禁用**状态（isEnabled=false）—— 这正是 code=2")
                self.say("   （ConfigurationDisabled）的成因。现在自动重新启用…")
                manager.isEnabled = true
                manager.saveToPreferences { error in
                    DispatchQueue.main.async {
                        if let error = error {
                            self.say("❌ 重新启用失败：\(Self.describe(error))")
                            self.say("   用「重置 VPN 配置」按钮重建，或到 设置 → 通用 →")
                            self.say("   VPN与设备管理 → VPN 里把那条配置删掉。")
                            return
                        }
                        self.say("✅ 已重新启用")
                        done(manager)
                    }
                }
            }
        }
    }

    private func createConfiguration(_ done: @escaping (NETunnelProviderManager) -> Void) {
        say("新建一条配置")
        say("（系统会弹一次「允许添加 VPN 配置」，需要面容/密码确认）")
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
                self.manager = manager
                self.session = manager.connection as? NETunnelProviderSession
                self.reloadAndEnable(manager, done: done)
            }
        }
    }

    /// 删掉一批配置（给「重置」和「卡住后重建」用）
    private func removeAll(_ managers: [NETunnelProviderManager], done: @escaping () -> Void) {
        guard let head = managers.first else {
            done()
            return
        }
        head.removeFromPreferences { error in
            DispatchQueue.main.async {
                if let error = error {
                    self.say("删除一条配置失败：\(Self.describe(error))")
                }
                self.removeAll(Array(managers.dropFirst()), done: done)
            }
        }
    }

    /// 一整行配置状态 —— 启动失败时这一行比任何猜测都有用
    private func stateDescription(_ manager: NETunnelProviderManager) -> String {
        let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
        return "isEnabled=\(manager.isEnabled) "
             + "按需=\(manager.isOnDemandEnabled) "
             + "连接=\(Self.statusName(manager.connection.status)) "
             + "provider=\(proto?.providerBundleIdentifier ?? "nil")"
    }

    // MARK: - 隧道就绪之后再干活

    /// 「隧道连上了再执行」。
    ///
    /// 真机上踩过：②③④ 在隧道还没连上时就发 `sendProviderMessage`，
    /// 结果是**静默不回复**（消息发给了一个不存在/没起来的进程），
    /// 界面上只显示「隧道没有回复（nil）」—— 非常容易被误判成「IPC 坏了」。
    /// 所以统一排队：没连上就先拉起来，连上之后自动把命令发出去。
    private func whenTunnelReady(tag: String, action: @escaping () -> Void) {
        if session?.status == .connected {
            say("隧道已连接 → 直接执行（\(tag)）")
            action()
            return
        }

        pendingWhenConnected = action
        pendingOptions = ["mode": "readOnly" as NSString]
        pendingRetry = false

        let status = session?.status
        if let status = status, status == .connecting || status == .reasserting {
            say("隧道正在 \(Self.statusName(status)) —— 不重复启动")
            say("   （重复 startVPNTunnel 会把会话卡死，真机上踩过）")
            say("   挂上去等它连上，连上后自动执行（\(tag)）")
            startPolling()
            return
        }

        if let manager = manager {
            say("隧道没在跑 → 用已有配置拉起来（\(tag) 已排队）")
            start(manager: manager, options: ["mode": "readOnly" as NSString])
        } else {
            say("还没有配置 → 先建一条并拉起来（\(tag) 已排队）")
            prepareConfiguration { manager in
                self.start(manager: manager, options: ["mode": "readOnly" as NSString])
            }
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

        let nonce = String(UUID().uuidString.prefix(8)).lowercased()
        board.string = Probe.txPrefix + nonce
        say("已把剪贴板写成 \(Probe.txPrefix)\(nonce)")
        pendingWhenConnected = nil
        prepareConfiguration { manager in
            self.start(manager: manager, options: ["echoPasteboard": "1" as NSString])
        }
    }

    // MARK: - 启动隧道

    private func start(manager: NETunnelProviderManager,
                       options: [String: NSObject],
                       isRetry: Bool = false) {
        guard let session = manager.connection as? NETunnelProviderSession else {
            say("❌ manager.connection 不是 NETunnelProviderSession，无法启动")
            finish()
            return
        }
        self.session = session
        say("启动前状态：\(stateDescription(manager))")

        let status = session.status
        if status == .connecting || status == .reasserting {
            say("⚠️ 这个会话已经是 \(Self.statusName(status)) —— 不再重复调用 startVPNTunnel")
            say("   （重复启动会把会话卡死，真机上踩过）")
            pendingOptions = options
            pendingRetry = isRetry
            startPolling()
            return
        }

        do {
            try session.startVPNTunnel(options: options)
            say("✅ startVPNTunnel 已被接受，等隧道进程起来（最多等 30 秒，别点别的按钮）")
            pendingOptions = options
            pendingRetry = isRetry
            startPolling()
        } catch {
            say("❌ startVPNTunnel 抛错：\(Self.describe(error))")
            let ns = error as NSError
            let configBroken = ns.domain == "NEVPNErrorDomain" && [1, 2, 4].contains(ns.code)
            if !isRetry && configBroken {
                say("   这三个 code 都不是「隧道起不来」，是「这条配置不能用了」：")
                say("     1=ConfigurationInvalid  2=ConfigurationDisabled  4=ConfigurationStale")
                say("   → 删掉现有配置、重建一条崭新的，再试一次")
                rebuildAndRetry(options: options)
                return
            }
            if isRetry {
                say("   ⚠️ 重建配置之后还是同样的错 —— 那就不是配置可用性的问题了。")
                say("   去 设置 → 通用 → VPN与设备管理 → VPN 看那条配置在不在、是不是关着的。")
            }
            finish()
        }
    }

    /// 配置级错误的自救：删掉重建，然后重试一次。
    /// 只重试一次，不循环 —— 否则如果错误另有原因，会变成删配置死循环，
    /// 反而把「用户手动建好的、可能本来能跑的配置」反复洗掉。
    private func rebuildAndRetry(options: [String: NSObject]) {
        NETunnelProviderManager.loadAllFromPreferences { managers, _ in
            DispatchQueue.main.async {
                let ours = (managers ?? []).filter { Self.isOurs($0) }
                self.removeAll(ours) {
                    self.manager = nil
                    self.session = nil
                    self.say("已删掉 \(ours.count) 条旧配置，重建一条新的…")
                    self.prepareConfiguration { manager in
                        self.start(manager: manager, options: options, isRetry: true)
                    }
                }
            }
        }
    }

    // MARK: - 轮询

    private func startPolling() {
        polls = 0
        finished = false
        sawConnected = (session?.status == .connected)
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
                let line = "隧道状态 → \(Self.statusName(status))"
                say(line)
                ProbeLog.append(source: "app", kind: "status", detail: line)
            }
            if status == .connected && !sawConnected {
                sawConnected = true
                say("🎉 第一次看到 connected —— 隧道进程真的起来了")
                let action = pendingWhenConnected
                pendingWhenConnected = nil
                if let action = action {
                    say("   现在执行刚才排队的那条命令")
                    action()
                }
            }
        }

        // echo 往返只在①里期待（剪贴板被探针写成了 nonce）
        if pendingOptions["echoPasteboard"] != nil {
            let text = UIPasteboard.general.string ?? ""
            if text.hasPrefix(Probe.echoPrefix) {
                say("✅✅ 剪贴板里出现 echo：\(text)")
                say("    结论：隧道进程既能读剪贴板，也能写剪贴板。")
                say("    ——「把同步逻辑搬进隧道进程」这条路线成立。")
                finish()
                return
            }
        }

        if polls >= 30 {
            stopPolling()
            let status = session?.status ?? .invalid
            let logLineCount = ProbeLog.read().records.filter { $0.source == "tunnel" }.count
            say("⏱ 30 秒到了。connection.status=\(status.rawValue)（\(Self.statusName(status))）")
            say("   App Group 里隧道侧累计日志：\(logLineCount) 条")

            if !sawConnected && !pendingRetry {
                // 这次真机上的形态：startVPNTunnel 被接受，但一直停在 connecting，
                // 而且隧道侧**一条日志都没有** —— 说明 appex 从来没被拉起。
                // superceded 之后那条配置指向的记录可能已经失效，
                // isEnabled=true 修不了它，只能把整条记录换掉。
                say("   ⚠️ 从来没连上过（一直 \(Self.statusName(status))），"
                  + "而且隧道侧没有新日志 → appex 压根没被拉起。")
                say("   这通常是「配置指向的东西已经不存在了」（重装 App 之后会出现）。")
                say("   → 删掉配置重建一条，再试一次")
                rebuildAndRetry(options: pendingOptions)
                return
            }

            if status == .connected {
                say("   隧道连上了，但隧道进程没有做出预期反应。看 App Group 日志：")
                say("     - 有 heartbeat 但 pasteboard.* 报错 → 进程碰不到剪贴板")
                say("     - 完全没有 heartbeat / 没有 startTunnel → 跨进程日志不通")
                say("     - 有 fakeEntry → 链接器入口没生效（构建问题）")
            } else {
                say("   隧道没连上。若隧道侧有新日志 → appex 起来了但网络设置失败；")
                say("   若没有 → appex 没起来。查 docs/probe.md 的「失败了怎么办」。")
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
        if finished { return }
        finished = true
        dumpTunnelLog(tail: 60)
        say("=============== 探针结束 ===============")
    }

    // MARK: - 发消息给隧道

    private func send(json: [String: Any], label: String) {
        guard let session = session else {
            say("还没有隧道会话 —— 先点「① 运行探针」把隧道建起来")
            return
        }
        guard session.status == .connected else {
            say("隧道当前是 \(Self.statusName(session.status))，不是 connected —— 先不发，"
              + "等它连上（这是为了避免「消息发出去但静默不回复」那种假象）")
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
                        self.say("⚠️ 隧道没有回复（nil）。")
                        self.say("   隧道是 connected 状态的，所以这次不是「没起来」——")
                        self.say("   要么 handleAppMessage 没被调用，要么回复通道不通。")
                        self.say("   去「刷新日志」看有没有 ipc.command 那一条：")
                        self.say("     有 → 隧道收到了但回话通道不通")
                        self.say("     没有 → 消息根本没到隧道")
                    }
                    self.say("（记得点「刷新日志」看隧道侧自己写的记录）")
                    self.finish()
                }
            }
            say("已发出：\(label)")
        } catch {
            say("❌ sendProviderMessage 失败：\(Self.describe(error))")
        }
    }

    // MARK: - 工具

    private func say(_ text: String) {
        onLine?(text)
    }

    static func describe(_ error: Error) -> String {
        let e = error as NSError
        var s = "\(e.domain) code=\(e.code) “\(e.localizedDescription)”"
        if e.domain == "NEVPNErrorDomain" {
            s += "\n     → \(vpnErrorName(e.code))"
        }
        if let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError {
            s += " ← \(underlying.domain) code=\(underlying.code)"
        }
        return s
    }

    /// 把 NEVPNErrorDomain 的数字翻译成名字。
    /// 真机上最要紧的就是 code=2（ConfigurationDisabled）——
    /// 光看数字完全看不出是「配置被禁用了」而不是「隧道起不来」。
    static func vpnErrorName(_ code: Int) -> String {
        switch code {
        case 1: return "ConfigurationInvalid：配置无效，得删掉重建"
        case 2: return "ConfigurationDisabled：配置被禁用（本 App 会自动重新启用并重试；"
                     + "不行就用「重置 VPN 配置」）"
        case 3: return "ConnectionFailed：连接失败（隧道进程起不来）"
        case 4: return "ConfigurationStale：配置过期，需要重新 load/save"
        case 5: return "ConfigurationReadWriteFailed：配置写入失败"
        case 6: return "ConfigurationUnknown：未知配置错误"
        default: return "未知的 NEVPNError code"
        }
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
