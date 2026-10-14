import Foundation
import SwiftUI
import UIKit
import SyncClipCore

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
        var pasteboardText: String?
        var readMillis: Double = 0

        var sigV4Passed: Bool = false
        var sigV4Detail: String = ""
        var darwinNotifyAvailable: Bool = false
        var endpointDescription: String = ""

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
    private var didBootstrap = false
    private var pasteboardObserver: NSObjectProtocol?

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

        refreshLocalPreview()
        startLoopIfPossible()
        applyKeepAlive()

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
    }

    private func applyKeepAlive() {
        if settings.keepAliveEnabled {
            keepAliveError = keeper.start()
            if let e = keepAliveError { SCLog.error("后台保活启动失败：\(e)") }
        } else {
            keeper.stop()
            keepAliveError = nil
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
        SCLog.info("同步循环启动：[\(config.serverType.displayName)] "
                   + "\(config.profile.displaySubtitle)，每 \(String(format: "%.1f", config.pollInterval))s，"
                   + "启动=\(config.startupSync.rawValue)，冲突=\(config.conflictResolution.rawValue)")

        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runOneRound()
                let interval = max(0.5, config.pollInterval)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
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
        guard let engine, let text = SCPasteboard.readText(), !text.isEmpty else {
            toast = "剪贴板里没有可同步的文本"
            return
        }
        do {
            try await engine.manualSet(text)
            pushCount += 1
            lastAction = "已手动推送当前剪贴板"
            lastActionKind = .pushed
            lastSyncAt = Date()
            toast = "已推送 \(text.utf8.count) 字节"
        } catch {
            failureCount += 1
            lastAction = "手动推送失败"
            lastActionKind = .failed
            toast = "推送失败：\(error)"
            SCLog.error("手动推送失败：\(error)")
        }
        refreshPreviews(from: engine)
    }

    func pullRemote() async {
        guard let engine else { toast = "同步尚未启动"; return }
        do {
            if let text = try await engine.manualGet(), !text.isEmpty {
                SCPasteboard.writeText(text)
                pullCount += 1
                lastAction = "已手动拉取远端并写入剪贴板"
                lastActionKind = .pulled
                lastSyncAt = Date()
                toast = "已拉取 \(text.utf8.count) 字节"
            } else {
                toast = "远端当前不是可同步的文本"
            }
        } catch {
            failureCount += 1
            lastAction = "手动拉取失败"
            lastActionKind = .failed
            toast = "拉取失败：\(error)"
            SCLog.error("手动拉取失败：\(error)")
        }
        refreshPreviews(from: engine)
    }

    // MARK: - 预览

    private func refreshLocalPreview() {
        localPreview = SCPasteboard.readText() ?? ""
    }

    private func refreshPreviews(from engine: SCSyncEngine) {
        refreshLocalPreview()
        if let remote = engine.lastRemoteText {
            remotePreview = remote
        } else if let profile = engine.lastRemoteProfile {
            remotePreview = "（远端是 \(profile.type.rawValue) 类型，v1 只同步文本）"
        } else {
            remotePreview = ""
        }
    }

    /// 手动刷新本地预览（下拉刷新时用）
    func refreshPreviews() {
        refreshLocalPreview()
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
        let t0 = Date()
        d.pasteboardText = SCPasteboard.readText()
        d.readMillis = Date().timeIntervalSince(t0) * 1000

        let sig = SCSigV4.selfTest()
        d.sigV4Passed = sig.passed
        d.sigV4Detail = sig.detail

        d.darwinNotifyAvailable = SCDarwinNotify.isAvailable

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
