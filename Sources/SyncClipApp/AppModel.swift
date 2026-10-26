import Foundation
import SwiftUI
import UIKit
import BackgroundTasks
import UserNotifications
import SyncClipApp
import SyncClipCore
import SyncClipApp

/// App 的中枢：持有设置、同步循环、后台保活、日志和诊断结果。
///
/// 所有状态都在主线程上更新（`@MainActor`），剪贴板读写也因此在主线程上发生。
@MainActor
final class AppModel: ObservableObject {

    // MARK: - 连接状态

    enum Connection: Equatable {
        case unknown
        case checking
        case ok(String)          // 说明或版本
        case failed(String)

        var label: String {
            switch self {
            case .unknown: return "未测试"
            case .checking: return "测试中"
            case .ok: return "已连接"
            case .failed: return "连接失败"
            }
        }

        var detail: String {
            switch self {
            case .unknown: return "还没测过这台服务器"
            case .checking: return "正在请求服务器…"
            case .ok(let s): return s
            case .failed(let s): return s
            }
        }

        var isOK: Bool { if case .ok = self { return true }; return false }
        var isBad: Bool { if case .failed = self { return true }; return false }
        var isBusy: Bool { self == .checking }
    }

    struct Diagnostics {
        var binaryPath: String = ""
        var entitlements: [String] = []
        var entitlementError: String?

        var pasteboardChangeCount: Int = -1
        var pasteboardTypes: [String] = []
        var pasteboardItems: [(uti: String, bytes: Int)] = []
        var pasteboardText: String?
        var readMillis: Double = 0

        var sigV4Passed: Bool = false
        var sigV4Detail: String = ""
        var darwinNotifyAvailable: Bool = false
        var endpointDescription: String = ""

        // 实时推送
        var pushState: String = ""
        var pushHub: String = ""
        var pushConnectCount: Int = 0
        var pushProfileCount: Int = 0
        var pushLastEventAt: Date?
        var pushLastDisconnect: String?
        var pollIntervalEffective: TimeInterval = 0

        // 后台保活 / 兜底唤醒
        var keeperHealth: String = ""
        var keeperRestarts: Int = 0
        var bgRefreshScheduledAt: Date?
        var maxTickGap: TimeInterval = 0
        var maxTickGapAt: Date?
        var tickCount: Int = 0

        var note: String = ""

        /// 地基是否就位：没有这几条 entitlement，读剪贴板就会弹「允许粘贴」
        var pasteboardEntitlementsPresent: Bool {
            ["com.apple.Pasteboard.background-access",
             "com.apple.private.webkit.pasteboard"]
                .allSatisfy { entitlements.contains($0) }
        }
    }

    // MARK: - 状态

    @Published var settings: SCAppSettings
    @Published var connection: Connection = .unknown
    /// 每台服务器各自的最近一次探测结果，供服务器列表显示
    @Published var serverStatus: [String: Connection] = [:]
    @Published var isLoopRunning = false
    @Published var lastSyncAt: Date?
    @Published var lastAction = "尚未同步"
    @Published var lastActionKind: SCSyncEngine.Action = .idle
    @Published var pushCount = 0
    @Published var pullCount = 0
    @Published var failureCount = 0
    @Published var localPreview: String = ""
    @Published var remotePreview: String = ""
    @Published var logs: [SCInAppLog.Entry] = []
    @Published var diagnostics = Diagnostics()
    @Published var toast: String?
    @Published var keepAliveError: String?
    @Published var isSyncing = false

    // ---- M2-M5 文件同步 ----
    /// 收件箱列表（远端拉下来的文件/目录），收件箱页直接展示这份
    @Published var inboxItems: [InboxItem] = []
    /// 远端当前内容是不是文件/文件组 —— 首页「去收件箱查看」按钮据此显隐
    @Published var remoteIsFileLike = false

    // ---- M0 机制探针（设计稿 §6）----
    @Published var probeP1Armed = false
    @Published var probeP1Lines: [String] = []
    @Published var probeP2Lines: [String]?
    @Published var probeP3Lines: [String]?

    // ---- 实时推送（SignalR）----
    // 这是「PC 复制 → 手机立刻可用」的那条路：服务器本来就带 Hub，
    // 谁 PUT 了新内容就把内容本身推给所有在线客户端，不必每 2 秒问一次。
    @Published var pushState: String = "未启动"
    @Published var pushEventCount = 0
    @Published var bgRefreshScheduledAt: Date?

    // ---- 后台保活的自愈情况 ----
    @Published var keeperRestartCount = 0
    @Published var keeperHealth: String = "未开启"

    // 后台保活到底有没有用，是这条路线唯一无法静态验证的事。
    // 所以把轮询节拍记下来：App 真被挂起的话，最长间隔会是分钟级而不是几秒。
    @Published var tickCount = 0
    @Published var lastTickAt: Date?
    @Published var maxTickGap: TimeInterval = 0
    @Published var maxTickGapAt: Date?

    // MARK: - 内部

    let logger = SCInAppLog()
    private var engine: SCSyncEngine?
    private var loop: Task<Void, Never>?
    private let keeper = BackgroundKeeper()
    private var signalR: SCSignalR?
    private var didBootstrap = false
    private var pasteboardObserver: NSObjectProtocol?

    /// 后台刷新任务的标识符（必须在 Info.plist 的 BGTaskSchedulerPermittedIdentifiers 里）
    static let refreshTaskID = "com.cxk.syncclip.refresh"

    init(settings: SCAppSettings = SCAppSettings.load()) {
        self.settings = settings
        logger.install()
        logger.onAppend = { [weak self] entry in
            // onAppend 会从任意线程调用，而 @Published 必须在主线程改
            Task { @MainActor in
                guard let self else { return }
                self.logs.append(entry)
                if self.logs.count > 300 { self.logs.removeFirst(self.logs.count - 300) }
            }
        }
        self.logs = logger.snapshot()
    }

    deinit {
        if let pasteboardObserver {
            NotificationCenter.default.removeObserver(pasteboardObserver)
        }
    }

    // MARK: - 生命周期

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true

        SCLog.level = settings.verboseLogging ? .debug : .info
        SCLog.info("剪贴板同步启动，配置：\(SCAppSettings.defaultURL.path)")
        SCLog.info("SigV4 自检：\(SCSigV4.selfTest().detail)")

        // 剪贴板变更通知：有就提前触发一轮，没有也不影响（轮询是保底）
        pasteboardObserver = NotificationCenter.default.addObserver(
            forName: UIPasteboard.changedNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            SCLog.debug("收到 UIPasteboard 变更通知，提前触发一轮同步")
            Task { @MainActor in await self?.syncNow(silent: true) }
        }

        refreshLocalPreview(force: true)
        startLoopIfPossible()
        applyKeepAlive()
        registerBackgroundRefresh()
        setupNotifications()
        exportServerConfigForExtensions()

        Task { await testActiveConnection(silent: true) }
    }

    // MARK: - 设置

    func persistSettings() {
        if let err = settings.save() {
            SCLog.error("保存配置失败：\(err)")
            toast = "保存配置失败"
        } else {
            SCLog.debug("配置已保存")
        }
    }

    /// 设置项改动后的统一入口：落盘 + 按需重启同步循环/保活
    func settingsChanged() {
        SCLog.level = settings.verboseLogging ? .debug : .info
        persistSettings()
        startLoopIfPossible()
        applyKeepAlive()
        exportServerConfigForExtensions()
    }

    private func applyKeepAlive() {
        if settings.keepAliveEnabled {
            keepAliveError = keeper.start()
            if let e = keepAliveError { SCLog.error("后台保活启动失败：\(e)") }
        } else {
            keeper.stop()
            keepAliveError = nil
        }
        refreshKeeperStats()
    }

    /// 保活的自愈次数不会发通知（它在后台线程上自增），所以定期主动取一次
    private func refreshKeeperStats() {
        keeperRestartCount = keeper.restartCount
        keeperHealth = keeper.healthDescription
    }

    // MARK: - 实时推送

    /// （重新）建立实时推送连接。切换服务器、改设置、开关总开关都要走这里。
    private func restartPush() {
        signalR?.stop()
        signalR = nil
        pushState = "未启动"

        guard settings.syncEnabled, settings.pushEnabled else {
            SCLog.info("实时推送已关闭（\(settings.syncEnabled ? "" : "同步总开关关着；")" 
                       + "\(settings.pushEnabled ? "" : "设置里关着")）")
            return
        }
        guard let profile = settings.activeServer else { return }

        guard let client = SCSignalR(profile: profile) else {
            // WebDAV / S3 没有 Hub，这不是错误
            pushState = "此服务器类型不支持"
            return
        }

        client.onEvent = { [weak self] event in
            Task { @MainActor in self?.handlePushEvent(event) }
        }
        client.start()
        signalR = client
        pushState = "连接中"
    }

    private func handlePushEvent(_ event: SCSignalR.Event) {
        switch event {
        case .state(let state):
            pushState = state.label
            if case .waiting(_, let reason) = state {
                SCLog.warn("实时推送断开：\(reason)")
            }
        case .remoteProfile(let profile):
            Task { await applyPushed(profile) }
        case .remoteHistory:
            break
        }
    }

    /// 服务器推来新内容时的处理。
    ///
    /// 走引擎里和轮询同一条收敛路径 —— 所以不会出现「推送和轮询各写一次剪贴板」，
    /// 也不会因为来了个推送就把用户在设置里选的冲突策略绕过去。
    private func applyPushed(_ profile: SCProfile) async {
        guard let engine else { return }
        pushEventCount += 1

        let stats = await engine.applyPushedRemote(profile)
        lastSyncAt = Date()
        lastActionKind = stats.action
        switch stats.action {
        case .pulled: pullCount += 1
        case .pushed: pushCount += 1
        case .failed: failureCount += 1
        case .skipped, .idle: break
        }
        lastAction = describe(stats) + "（实时推送）"
        refreshPreviews(from: engine)
        if stats.action == .pulled { refreshInbox() }
        appendHistoryThrottled(action: stats.action)
        notifyIfNeeded(stats)
    }

    /// 回到前台时叫一下：长连接大概已经被系统掐了，不必等退避
    func enterForeground() {
        signalR?.nudge()
        refreshKeeperStats()
    }

    // MARK: - 后台刷新（BGTaskScheduler）
    //
    // 这是兜底：音频保活会把进程留在后台，BGTask 则是「App 真被杀了之后，
    // 系统还会偶尔把它叫起来跑一轮」的那条路。系统不保证时间，可能几十分钟一次，
    // 也可能一直不叫 —— 所以它是补充，不是指望。

    private func registerBackgroundRefresh() {
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID,
                                                 using: nil) { [weak self] task in
            guard let self = self else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleBackgroundRefresh(task as? BGAppRefreshTask)
        }
        SCLog.info("后台刷新任务注册：\(ok ? "成功" : "失败（标识符可能没写进 Info.plist）")")
    }

    /// 进后台时排下一次。必须在进后台的瞬间排，否则被杀之后系统没理由唤醒你。
    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)   // 只是「最早」，实际由系统决定
        do {
            try BGTaskScheduler.shared.submit(request)
            bgRefreshScheduledAt = Date()
            SCLog.debug("已排下一次后台刷新（最早 15 分钟后）")
        } catch {
            SCLog.warn("后台刷新任务排期失败：\(error)")
        }
    }

    func enterBackground() {
        scheduleBackgroundRefresh()
        refreshKeeperStats()
    }

    private func handleBackgroundRefresh(_ task: BGAppRefreshTask?) {
        SCLog.info("系统唤醒了后台刷新任务，跑一轮同步")
        scheduleBackgroundRefresh()          // 先排下一次，不然就只有这一回
        guard let task = task else { return }
        let work = Task { await self.syncNow(silent: true) }
        task.expirationHandler = { work.cancel() }
        Task {
            _ = await work.value
            task.setTaskCompleted(success: true)
        }
    }

    // MARK: - 服务器管理

    /// 新增或更新一台服务器。若这台的配置完整，顺手测一下连接。
    func saveServer(_ profile: SCServerProfile) {
        settings.upsert(profile)
        persistSettings()
        startLoopIfPossible()
        Task { await testConnection(profile: profile, silent: true) }
    }

    func deleteServer(id: String) {
        let wasActive = settings.activeServer?.id == id
        settings.remove(id: id)
        serverStatus[id] = nil
        persistSettings()
        if wasActive {
            SCLog.info("删除了当前使用的服务器，切换到 \(settings.activeServer?.displayTitle ?? "无")")
            startLoopIfPossible()
        }
    }

    /// 切换当前使用的服务器。切换必须重建引擎——旧引擎的 lastRemoteHash
    /// 属于另一台服务器，带过去会导致第一次比对就出错。
    func selectServer(id: String) {
        guard settings.activeServer?.id != id else { return }
        let name = settings.server(withID: id)?.displayTitle ?? id
        settings.setActive(id: id)
        persistSettings()
        SCLog.info("已切换到服务器：\(name)")
        connection = serverStatus[id] ?? .unknown
        startLoopIfPossible()
        toast = "已切换到 \(name)"
        Task { await testActiveConnection(silent: true) }
    }

    func testConnection(profile: SCServerProfile, silent: Bool = false) async {
        serverStatus[profile.id] = .checking
        if settings.isActive(profile) { connection = .checking }

        let scConfig: SCConfig
        do {
            scConfig = SCConfig(profile: profile,
                                pollInterval: settings.pollInterval,
                                startupSyncRaw: settings.startupSync,
                                conflictRaw: settings.conflictResolution)
        } catch {
            let failed = Connection.failed("\(error)")
            serverStatus[profile.id] = failed
            if settings.isActive(profile) { connection = failed }
            if !silent { toast = "\(error)" }
            return
        }

        let probeEngine = try? SCSyncEngine(config: scConfig)
        let info = await probeEngine?.probeServer()
            ?? SCProbeResult(reachable: false, message: "无法创建同步引擎")

        let result: Connection
        if info.reachable {
            var detail = "服务器可达"
            if let v = info.version, !v.isEmpty { detail += "，版本 \(v)" }
            result = .ok(detail)
            if !silent { toast = detail }
        } else {
            result = .failed(info.message)
            if !silent { toast = "连接失败" }
        }

        serverStatus[profile.id] = result
        if settings.isActive(profile) { connection = result }
    }

    func testActiveConnection(silent: Bool = false) async {
        guard let profile = settings.activeServer else {
            connection = .unknown
            if !silent { toast = "还没有配置服务器" }
            return
        }
        await testConnection(profile: profile, silent: silent)
    }

    // MARK: - 同步循环

    private func startLoopIfPossible() {
        loop?.cancel()
        loop = nil
        isLoopRunning = false
        engine = nil
        // 这里的 stop 是必须的：换服务器之后旧连接还挂着的话，
        // 会把**另一台服务器**的内容推到这个剪贴板上
        signalR?.stop()
        signalR = nil
        pushState = "未启动"

        guard settings.syncEnabled else {
            SCLog.info("同步已关闭（设置里打开总开关才会轮询）")
            return
        }

        let config: SCConfig
        do {
            config = try settings.toConfig()
        } catch {
            connection = .unknown
            SCLog.warn("配置还不完整，暂不启动同步：\(error)")
            return
        }

        let newEngine: SCSyncEngine
        do {
            newEngine = try SCSyncEngine(config: config)
        } catch {
            connection = .failed("\(error)")
            SCLog.error("无法创建同步引擎：\(error)")
            return
        }

        engine = newEngine
        isLoopRunning = true
        restartPush()
        SCLog.info("同步循环启动：[\(config.serverType.displayName)] "
                   + "\(config.profile.displaySubtitle)，每 \(String(format: "%.1f", config.pollInterval))s，"
                   + "启动=\(config.startupSync.rawValue)，冲突=\(config.conflictResolution.rawValue)")

        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runOneRound()
                let interval = self.pollIntervalNow
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// 本轮之后等多久。
    ///
    /// 实时推送连着的时候，轮询只当一根保险丝 —— 没必要再每 2 秒去问一次服务器，
    /// 既省电也省服务器。断了就自动回到用户设的间隔，不会漏内容。
    private var pollIntervalNow: TimeInterval {
        let base = max(0.5, settings.pollInterval)
        if signalR?.snapshot().state.isConnected == true {
            return max(base, 30)
        }
        return base
    }

    private func runOneRound() async {
        // 先记节拍：这一段的间隔就是「后台有没有被挂起」的直接证据
        let now = Date()
        if let prev = lastTickAt {
            let gap = now.timeIntervalSince(prev)
            if gap > maxTickGap {
                maxTickGap = gap
                maxTickGapAt = now
            }
        }
        lastTickAt = now
        tickCount += 1
        refreshKeeperStats()

        checkP1Probe()

        guard let engine else { return }

        isSyncing = true
        let stats = await engine.syncOnce()
        isSyncing = false

        lastSyncAt = Date()
        lastActionKind = stats.action
        lastAction = describe(stats)

        switch stats.action {
        case .pulled: pullCount += 1
        case .pushed: pushCount += 1
        case .failed:
            failureCount += 1
            connection = .failed(stats.note)
        case .skipped:
            connection = .ok("已连接（本轮跳过：\(stats.note)）")
        case .idle:
            if !connection.isOK { connection = .ok("已连接，两端一致") }
        }

        refreshPreviews(from: engine)
        if stats.action == .pulled { refreshInbox() }
        appendHistoryThrottled(action: stats.action)
        notifyIfNeeded(stats)
    }

    private func describe(_ stats: SCSyncEngine.Stats) -> String {
        switch stats.action {
        case .idle: return stats.note.isEmpty ? "两端一致，无需动作" : stats.note
        case .pulled: return "拉到远端内容，已写入剪贴板"
        case .pushed: return "本地内容已推送到服务器"
        case .skipped: return "已跳过：\(stats.note)"
        case .failed: return "失败：\(stats.note)"
        }
    }

    // MARK: - 手动操作

    func syncNow(silent: Bool = false) async {
        guard isLoopRunning else {
            if !silent { toast = "同步未启动，请先在「服务器」里配好一台" }
            return
        }
        await runOneRound()
        if !silent { toast = lastAction }
    }

    func pushCurrentClipboard() async {
        guard let engine else {
            toast = "同步尚未启动，请先在「服务器」里配好一台"
            return
        }
        let stats = await engine.pushNow()
        lastActionKind = stats.action
        switch stats.action {
        case .pushed:
            pushCount += 1
            lastSyncAt = Date()
            lastAction = "已手动推送当前剪贴板"
            toast = stats.note
        case .failed:
            failureCount += 1
            lastAction = "手动推送失败"
            toast = "推送失败：\(stats.note)"
            SCLog.error("手动推送失败：\(stats.note)")
        default:
            lastAction = describe(stats)
            toast = stats.note
        }
        refreshPreviews(from: engine)
    }

    func pullRemote() async {
        guard let engine else { toast = "同步尚未启动"; return }
        let stats = await engine.pullNow()
        lastActionKind = stats.action
        switch stats.action {
        case .pulled:
            pullCount += 1
            lastSyncAt = Date()
            lastAction = "已手动拉取远端并写入剪贴板"
            toast = stats.note
        case .failed:
            failureCount += 1
            lastAction = "手动拉取失败"
            toast = "拉取失败：\(stats.note)"
            SCLog.error("手动拉取失败：\(stats.note)")
        default:
            lastAction = describe(stats)
            toast = stats.note.isEmpty ? lastAction : stats.note
        }
        refreshPreviews(from: engine)
    }

    // MARK: - 文件收发（M2/M3）

    /// 收件箱列表刷新。同步循环拉到文件/文件组后自动调，收件箱页下拉刷新也走这里。
    func refreshInbox() {
        inboxItems = SCInbox.shared.items()
    }

    /// 多选上传：GroupPicker 选完的一组 URL 交给引擎逐个推。
    /// 超限的文件由引擎逐个守卫跳过（会明确通知），这里不提前拦。
    func pushFiles(urls: [URL]) async {
        guard let engine else {
            toast = "同步尚未启动，请先在「服务器」里配好一台"
            return
        }
        guard !urls.isEmpty else { return }

        // 文档选择器给的是安全作用域 URL：读字节前必须先拿权限，
        // await 期间一直持有，推完统一释放
        var accessed: [URL] = []
        for url in urls where url.startAccessingSecurityScopedResource() {
            accessed.append(url)
        }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }

        isSyncing = true
        let stats = await engine.pushFiles(urls: urls)
        isSyncing = false

        lastActionKind = stats.action
        switch stats.action {
        case .pushed:
            pushCount += 1
            lastSyncAt = Date()
            lastAction = "已推送 \(urls.count) 个文件"
            toast = stats.note
        case .failed:
            failureCount += 1
            lastAction = "文件推送失败"
            toast = "推送失败：\(stats.note)"
            SCLog.error("文件推送失败：\(stats.note)")
        default:
            lastAction = describe(stats)
            toast = stats.note
        }
    }

    /// 把远端的文件/文件组拉进收件箱（不动剪贴板）。
    func pullIntoInbox() async {
        guard let engine else {
            toast = "同步尚未启动，请先在「服务器」里配好一台"
            return
        }
        isSyncing = true
        let stats = await engine.pullIntoInbox()
        isSyncing = false

        lastActionKind = stats.action
        switch stats.action {
        case .pulled:
            pullCount += 1
            lastSyncAt = Date()
            lastAction = "远端文件已拉进收件箱"
            toast = stats.note
            refreshInbox()
        case .failed:
            failureCount += 1
            lastAction = "拉取到收件箱失败"
            toast = "拉取失败：\(stats.note)"
            SCLog.error("拉取到收件箱失败：\(stats.note)")
        default:
            lastAction = describe(stats)
            toast = stats.note.isEmpty ? lastAction : stats.note
            refreshInbox()
        }
    }

    // MARK: - 扩展接线（M4/M5）
    //
    // 分享/键盘扩展和主 App 不在一个沙盒里，能共享的只有 App Group：
    //   · 服务器配置：主 App 是唯一可信来源，每次改动都重新导出一份
    //   · 剪贴板历史：同步循环每轮成功后写入，键盘扩展的「基础模式」就靠它
    // App Group 不可用（TrollStore 没给权限 / K1 未过）时全部静默跳过 ——
    // 主 App 自己的功能一个都不依赖它，缺的只是那两个扩展。

    private var lastHistoryAppendAt: Date?
    private var didLogAppGroupUnavailable = false

    /// 把当前设置导出到 App Group 给扩展用。不可用时静默跳过，只记一次日志。
    private func exportServerConfigForExtensions() {
        guard AppGroupStore.isAvailable else {
            if !didLogAppGroupUnavailable {
                didLogAppGroupUnavailable = true
                SCLog.info("App Group 不可用，跳过向分享/键盘扩展导出配置")
            }
            return
        }
        AppGroupStore.exportServerConfig(settings)
    }

    /// 每轮同步成功后把最新内容喸给键盘扩展的历史。轮询最短 1 秒一轮，
    /// 每轮都写文件太频；键盘要的是「最近复制过什么」，分钟级新鲜度足够。
    private func appendHistoryThrottled(action: SCSyncEngine.Action) {
        guard action == .pulled || action == .pushed else { return }
        let now = Date()
        if let last = lastHistoryAppendAt, now.timeIntervalSince(last) < 60 { return }
        guard let profile = engine?.lastRemoteProfile else { return }
        switch profile.type {
        case .text:
            AppGroupStore.appendHistory(kind: "text", text: profile.text, imageHint: nil)
        case .image:
            let name = profile.dataName ?? "image"
            AppGroupStore.appendHistory(kind: "image", text: name, imageHint: name)
        case .file, .group:
            break   // 文件不进历史：键盘只消费文本/图片，文件走收件箱
        }
        lastHistoryAppendAt = now
    }

    // MARK: - 预览

    /// 上次生成预览时的 changeCount：图片预览要读整个字节流，
    /// 没变化就不重读（轮询每 2 秒刷一次预览，不能每次都啿图片）。
    private var lastPreviewChangeCount = -1

    private func refreshLocalPreview(force: Bool = false) {
        let cc = SCPasteboard.changeCount
        guard force || cc != lastPreviewChangeCount else { return }
        lastPreviewChangeCount = cc

        if SCPasteboard.hasImage {
            if case .raw(let data, let uti)? = SCPasteboard.readImagePayload() {
                let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
                localPreview = "[图片] \(uti) · \(size)"
            } else {
                localPreview = "[图片] （原始字节不可得，只能拿解码后的图）"
            }
            return
        }
        if SCPasteboard.hasFileURL {
            localPreview = "[文件引用] 等下一轮同步推送（按文件开关和大小上限）"
            return
        }
        localPreview = SCPasteboard.readText() ?? ""
    }

    private func refreshPreviews(from engine: SCSyncEngine) {
        refreshLocalPreview()
        if let text = engine.lastRemoteText {
            remotePreview = text
            remoteIsFileLike = false
        } else if let profile = engine.lastRemoteProfile {
            remoteIsFileLike = (profile.type == .file || profile.type == .group)
            switch profile.type {
            case .text:
                remotePreview = profile.text.isEmpty ? "（远端为空）" : profile.text
            case .image:
                let size = profile.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "?"
                remotePreview = "[图片] \(profile.dataName ?? "?") · \(size)"
            case .file:
                remotePreview = "[文件] \(profile.text) · 已落收件箱"
            case .group:
                let count = profile.text.split(separator: "\n").count
                remotePreview = "[文件组] \(count) 个文件 · 已落收件箱"
            }
        } else {
            remotePreview = ""
            remoteIsFileLike = false
        }
    }

    /// 手动刷新本地预览（下拉刷新时用）
    func refreshPreviews() {
        refreshLocalPreview(force: true)
        if let engine { refreshPreviews(from: engine) }
    }

    // MARK: - URL scheme
    //
    // syncclip://sync        立即同步
    // syncclip://push        把当前剪贴板推到服务器
    // syncclip://pull        把远端内容拉到剪贴板
    // syncclip://switch?id=  切到指定服务器
    //
    // iOS 15 没有 App Intents，快捷指令里只能靠「打开 URL」，
    // 配合「轻点背面」是不打开 App 就能同步的最省事办法。
    func handle(url: URL) {
        guard url.scheme?.lowercased() == "syncclip" else { return }
        let action = url.host?.lowercased() ?? ""
        SCLog.info("收到 URL 动作：\(action)")

        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "id" }?.value

        Task {
            switch action {
            case "push": await pushCurrentClipboard()
            case "pull": await pullRemote()
            case "switch":
                if let id, settings.server(withID: id) != nil {
                    selectServer(id: id)
                } else {
                    toast = "没有找到那台服务器"
                }
            default: await syncNow()
            }
        }
    }

    // MARK: - M0 机制探针（P1/P2/P3，设计稿 §6）
    //
    // 三个机制风险点先在真机钉死，过了才把设置里的「图片同步」打开：
    //   P1 后台读图 —— 挂在同步循环上，测的就是生产路径本身
    //   P2 读文件 App 拷贝的文件 —— 即点即测
    //   P3 写 file-url 引用 —— 即点即测，结果要去文件 App 里粘一下才算数

    private var p1BaselineChangeCount = -1
    private var p1ArmedAt: Date?

    /// P1 布防：之后用户去拷一张图，循环（前台或保活后台）发现变化就地读一次。
    func armP1() {
        p1BaselineChangeCount = SCPasteboard.changeCount
        p1ArmedAt = Date()
        probeP1Armed = true
        probeP1Lines = [
            "已布防（基线 changeCount=\(p1BaselineChangeCount)）。接下来：",
            "① 截图或去相册，拷贝一张图",
            "② 立刻锁屏或回桌面，等 1 分钟（「后台保活」保持开着）",
            "③ 回到本页看结果 —— 成功失败都算数，别提前打开 App",
            "（5 分钟没等到变化自动解除）"
        ]
        SCLog.info("P1 探针布防：baseline changeCount=\(p1BaselineChangeCount)")
    }

    func disarmP1() {
        probeP1Armed = false
        p1ArmedAt = nil
        probeP1Lines = ["已手动解除"]
    }

    /// 每轮同步开头调用。布防状态下剪贴板一变就抓现场。
    private func checkP1Probe() {
        guard probeP1Armed else { return }
        if let armed = p1ArmedAt, Date().timeIntervalSince(armed) > 300 {
            probeP1Armed = false
            probeP1Lines = ["⏱ 5 分钟没等到剪贴板变化，已自动解除",
                            "（如果这期间同步循环一直在跑，说明拷贝没生效或被其他 App 顶掉）"]
            SCLog.warn("P1 探针超时解除")
            return
        }
        guard SCPasteboard.changeCount != p1BaselineChangeCount else { return }

        let stateName: String
        switch UIApplication.shared.applicationState {
        case .active: stateName = "前台"
        case .inactive: stateName = "不活跃（切换中）"
        case .background: stateName = "后台"
        @unknown default: stateName = "未知"
        }
        let t0 = Date()
        let payload = SCPasteboard.readImagePayload()
        let ms = Date().timeIntervalSince(t0) * 1000
        probeP1Armed = false

        if case .raw(let data, let uti) = payload {
            probeP1Lines = [
                "✅ 读到图片原始字节",
                "UTI：\(uti)",
                "字节：\(data.count)（\(String(format: "%.2f", Double(data.count) / 1024 / 1024)) MB）",
                "耗时：\(String(format: "%.0f", ms)) ms · App 状态：\(stateName)",
                stateName == "后台" ? "结论：后台读图免弹窗成立，图片推送后台可用"
                                   : "结论：\(stateName)可读；后台可用性需状态=后台的那次验证"
            ]
            SCLog.info("P1 ✅ raw uti=\(uti) count=\(data.count) ms=\(Int(ms)) state=\(stateName)")
        } else if case .decoded(let image) = payload {
            probeP1Lines = [
                "⚠️ 只拿到解码后的 UIImage（原始字节不可得）",
                "尺寸：\(Int(image.size.width))×\(Int(image.size.height)) · 耗时 \(String(format: "%.0f", ms)) ms · 状态：\(stateName)",
                "结论：可用但走兑底路径（动图丢帧）——把下面的 UTI dump 抄回来分析"
            ]
            SCLog.info("P1 ⚠️ decoded \(Int(image.size.width))x\(Int(image.size.height)) state=\(stateName)")
        } else {
            probeP1Lines = [
                "❌ changeCount 变了但读不到图（可能拷的是文本触发的）",
                "当前 UTI：\(SCPasteboard.typeIdentifiers.joined(separator: ", "))",
                "若刚拷的确实是图：这就是 P1 失败 —— 后台读图被拦，图片推送退化为仅前台"
            ]
            SCLog.warn("P1 ❌ no image payload; utis=\(SCPasteboard.typeIdentifiers.joined(separator: ","))")
        }
    }

    /// P2：读文件 App 里拷贝的文件。
    func runP2() async {
        probeP2Lines = ["读取中…（若没拷过文件会立刻报「剪贴板里没有文件」）"]
        do {
            let copied = try await SCPasteboard.readCopiedFile()
            let attrs = try FileManager.default.attributesOfItem(atPath: copied.url.path)
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            var lines = [
                "✅ 文件已从剪贴板拷出（路径：\(copied.via)）",
                "文件名：\(copied.url.lastPathComponent)",
                "大小：\(size) 字节"
            ]
            if size <= 16 * 1024 * 1024 {
                let data = try Data(contentsOf: copied.url)
                lines.append("SHA-256：\(SCCrypto.sha256Hex(data))")
                lines.append("校验：去源文件处比大小（文件 App 长按 → 显示简介）")
            } else {
                lines.append("（文件较大，跳过哈希）")
            }
            lines.append("副本：\(copied.url.path)")
            probeP2Lines = lines
            SCLog.info("P2 ✅ \(copied.url.lastPathComponent) \(size)B via=\(copied.via)")
        } catch {
            probeP2Lines = ["❌ \(error)"]
            SCLog.warn("P2 ❌ \(error)")
        }
    }

    /// P3：把一个测试文件的 file-url 写进剪贴板，去文件 App 粘。
    func runP3() {
        let name = "P3-粘贴测试-\(Int(Date().timeIntervalSince1970)).txt"
        let url = SCAppSettings.defaultDirectory.appendingPathComponent(name)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let content = "syncclip P3 探针生成于 \(stamp)\n能在文件 App 里粘贴出这个文件，"
            + "说明 file-url 写剪贴板跨 App 可用。\n"
        do {
            try content.data(using: .utf8)!.write(to: url, options: .atomic)
            SCPasteboard.writeFileReference(url)
            probeP3Lines = [
                "已生成测试文件并写入剪贴板引用：\(name)",
                "现在去 文件 App → 浏览 → 任一文件夹 → 长按空白处 → 粘贴：",
                "· 能粘出 txt = P3 通过（文件拉取可开「写入剪贴板」实验开关）",
                "· 没有「粘贴」选项 = P3 失败（文件拉取只走收件箱，不走剪贴板）",
                "（尽快去粘：沙盒文件引用的可用性随进程状态变化）"
            ]
            SCLog.info("P3 已写入 file-url 引用：\(name)")
        } catch {
            probeP3Lines = ["❌ 生成测试文件失败：\(error)"]
        }
    }

    // MARK: - 本地通知（provisional，不弹授权框）
    //
    // 用 .provisional：首次请求系统不弹窗，通知静默进通知中心 ——
    // 后台拉到图片 / 超限跳过看得见，又不要求用户先点「允许」。
    // 想要横幅去 系统设置 → 通知 → 剪贴板同步 里开。

    private func setupNotifications() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .provisional]) { _, error in
                if let error {
                    SCLog.warn("通知授权失败（不影响同步）：\(error.localizedDescription)")
                }
            }
    }

    private func notifyIfNeeded(_ stats: SCSyncEngine.Stats) {
        guard stats.notify, UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "剪贴板同步"
        content.body = stats.note
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - 诊断

    func runDiagnostics() async {
        var d = Diagnostics()

        d.binaryPath = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "?"
        do {
            let dict = try SCEntitlementInspector.entitlements(atPath: d.binaryPath)
            d.entitlements = dict.keys.sorted()
            d.entitlementError = nil
        } catch {
            d.entitlementError = "\(error)"
        }

        d.pasteboardChangeCount = SCPasteboard.changeCount
        d.pasteboardTypes = SCPasteboard.typeIdentifiers
        d.pasteboardItems = SCPasteboard.itemDump()
        let t0 = Date()
        d.pasteboardText = SCPasteboard.readText()
        d.readMillis = Date().timeIntervalSince(t0) * 1000

        let sig = SCSigV4.selfTest()
        d.sigV4Passed = sig.passed
        d.sigV4Detail = sig.detail

        d.darwinNotifyAvailable = SCDarwinNotify.isAvailable

        if let snapshot = signalR?.snapshot() {
            d.pushState = snapshot.state.label
            d.pushHub = snapshot.hubURL
            d.pushConnectCount = snapshot.connectCount
            d.pushProfileCount = snapshot.profilePushCount
            d.pushLastEventAt = snapshot.lastEventAt
            d.pushLastDisconnect = snapshot.lastDisconnectReason
        } else {
            d.pushState = settings.pushEnabled ? "未启动" : "设置里关着"
        }
        d.pollIntervalEffective = pollIntervalNow
        d.keeperHealth = keeper.healthDescription
        d.keeperRestarts = keeper.restartCount
        d.bgRefreshScheduledAt = bgRefreshScheduledAt
        d.maxTickGap = maxTickGap
        d.maxTickGapAt = maxTickGapAt
        d.tickCount = tickCount

        if let profile = settings.activeServer {
            let cfg = SCConfig(profile: profile,
                               pollInterval: settings.pollInterval,
                               startupSyncRaw: settings.startupSync,
                               conflictRaw: settings.conflictResolution)
            if let client = try? SCClient(config: cfg) {
                d.endpointDescription = client.endpointDescription
            }
        }

        var notes: [String] = []
        if d.entitlementError != nil {
            notes.append("读不到二进制签名段")
        } else if !d.pasteboardEntitlementsPresent {
            notes.append("缺关键 entitlement，读剪贴板会弹系统提示")
        } else {
            notes.append("entitlement 就位")
        }
        if d.pasteboardTypes.isEmpty { notes.append("剪贴板当前是空的") }
        if d.pasteboardText == nil && !d.pasteboardTypes.isEmpty {
            notes.append("剪贴板里有内容但没有可读文本（例如图片）")
        }
        if isLoopRunning {
            if signalR?.snapshot().state.isConnected == true {
                notes.append("实时推送已连接，轮询退到 \(Int(d.pollIntervalEffective))s 当保险丝")
            } else {
                notes.append("实时推送没连上（\(d.pushState)），仍在按 \(String(format: "%.1f", d.pollIntervalEffective))s 轮询")
            }
        }
        if !settings.keepAliveEnabled {
            notes.append("后台保活关着，进后台几十秒后就不再同步")
        } else if keeperRestartCount > 0 {
            notes.append("后台保活自愈过 \(keeperRestartCount) 次")
        }
        d.note = notes.joined(separator: "；")

        diagnostics = d
        SCLog.info("诊断完成：\(d.note)")
    }

    // MARK: - 日志

    func clearLogs() {
        logger.clear()
        logs.removeAll()
    }

    func copyLogs() {
        UIPasteboard.general.string = logger.plainText()
        toast = "日志已复制到剪贴板"
    }

    func copyToClipboard(_ text: String) {
        UIPasteboard.general.string = text
        toast = "已复制"
    }
}
