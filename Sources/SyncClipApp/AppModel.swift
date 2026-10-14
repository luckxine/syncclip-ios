import Foundation
import SwiftUI
import UIKit
import SyncClipCore

/// App 的中枢：持有设置、同步循环、后台保活、日志和诊断结果。
/// 所有状态都在主线程上更新（`@MainActor`），剪贴板读写也因此在主线程上发生。
@MainActor
final class AppModel: ObservableObject {

    // MARK: - 连接状态

    enum Connection: Equatable {
        case unknown
        case checking
        case ok(String)          // 服务端版本或说明
        case failed(String)

        var label: String {
            switch self {
            case .unknown: return "未测试"
            case .checking: return "测试中…"
            case .ok: return "已连接"
            case .failed: return "连接失败"
            }
        }

        var detail: String {
            switch self {
            case .unknown: return "还没测过服务器"
            case .checking: return "正在请求服务器…"
            case .ok(let s): return s
            case .failed(let s): return s
            }
        }

        var isOK: Bool { if case .ok = self { return true }; return false }
        var isBad: Bool { if case .failed = self { return true }; return false }
    }

    struct Diagnostics {
        var binaryPath: String = ""
        var entitlements: [String] = []
        var entitlementError: String?
        var pasteboardChangeCount: Int = -1
        var pasteboardTypes: [String] = []
        var pasteboardText: String?
        var readMillis: Double = 0
        var note: String = ""

        /// 地基是否就位：没有这几条 entitlement，读剪贴板就会弹「允许粘贴」
        var pasteboardEntitlementsPresent: Bool {
            let needed = [
                "com.apple.Pasteboard.background-access",
                "com.apple.private.webkit.pasteboard",
            ]
            return needed.allSatisfy { entitlements.contains($0) }
        }
    }

    // MARK: - 状态

    @Published var settings: SCAppSettings
    @Published var connection: Connection = .unknown
    @Published var isLoopRunning = false
    @Published var lastSyncAt: Date?
    @Published var lastAction = "尚未同步"
    @Published var pushCount = 0
    @Published var pullCount = 0
    @Published var failureCount = 0
    @Published var localPreview: String = ""
    @Published var remotePreview: String = ""
    @Published var logs: [SCInAppLog.Entry] = []
    @Published var diagnostics = Diagnostics()
    @Published var toast: String?
    @Published var keepAliveError: String?

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
        // 日志太长会拖慢 SwiftUI 列表，只保留最近的
        logger.onAppend = { [weak self] entry in
            // 显式跳回主线程：onAppend 会从任意线程调用，而 @Published 必须在主线程改
            Task { @MainActor in
                guard let self else { return }
                self.logs.append(entry)
                if self.logs.count > 300 { self.logs.removeFirst(self.logs.count - 300) }
            }
        }
        self.logs = logger.snapshot()
    }

    // MARK: - 生命周期

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true

        SCLog.level = settings.verboseLogging ? .debug : .info
        SCLog.info("剪贴板同步启动，配置文件：\(SCAppSettings.defaultURL.path)")

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

        Task { await testConnection(silent: true) }
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
            if let e = keepAliveError {
                SCLog.error("后台保活启动失败：\(e)")
            }
        } else {
            keeper.stop()
            keepAliveError = nil
        }
    }

    // MARK: - 同步循环

    private func startLoopIfPossible() {
        loop?.cancel()
        loop = nil
        isLoopRunning = false

        guard settings.syncEnabled else {
            SCLog.info("同步已关闭（设置里打开了总开关才会轮询）")
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

        let engine = SCSyncEngine(config: config)
        self.engine = engine
        isLoopRunning = true
        SCLog.info("同步循环启动：\(config.baseURL.absoluteString) 每 \(String(format: "%.1f", config.pollInterval))s，启动策略=\(config.startupSync.rawValue)")

        loop = Task { [weak self] in
            var firstRound = true
            while !Task.isCancelled {
                guard let self else { return }
                if firstRound {
                    firstRound = false
                    // 首次：顺手做一次连通性检查，UI 上立刻有反馈
                    await self.testConnection(silent: true)
                }
                await self.runOneRound()
                let interval = max(0.5, config.pollInterval)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func runOneRound() async {
        // 先记节拍：这一段的间隔就是“后台有没有被挂起”的直接证据
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
        let stats = await engine.syncOnce()
        lastSyncAt = Date()
        lastAction = describe(stats)

        switch stats.action {
        case .pulled: pullCount += 1
        case .pushed: pushCount += 1
        case .failed:
            failureCount += 1
            connection = .failed(stats.note)
        default: break
        }
        if stats.action != .failed && stats.action != .skipped {
            connection = .ok("最近一次同步成功")
        }

        refreshPreviews(from: engine)
    }

    private func describe(_ stats: SCSyncEngine.Stats) -> String {
        switch stats.action {
        case .idle: return stats.note.isEmpty ? "两端一致，无需动作" : stats.note
        case .pulled: return "拉到远端内容 → 已写入剪贴板"
        case .pushed: return "本地内容 → 已推送到服务器"
        case .skipped: return "已跳过：\(stats.note)"
        case .failed: return "失败：\(stats.note)"
        }
    }

    // MARK: - 手动操作

    func syncNow(silent: Bool = false) async {
        guard isLoopRunning else {
            if !silent { toast = "同步未启动：请先在设置里填好服务器" }
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
            lastSyncAt = Date()
            toast = "已推送 \(text.utf8.count) 字节"
        } catch {
            failureCount += 1
            lastAction = "手动推送失败"
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
                lastSyncAt = Date()
                toast = "已拉取 \(text.utf8.count) 字节"
            } else {
                toast = "远端当前不是可同步的文本"
            }
        } catch {
            failureCount += 1
            lastAction = "手动拉取失败"
            toast = "拉取失败：\(error)"
            SCLog.error("手动拉取失败：\(error)")
        }
        refreshPreviews(from: engine)
    }

    func testConnection(silent: Bool = false) async {
        connection = .checking
        let config: SCConfig
        do {
            config = try settings.toConfig()
        } catch {
            connection = .failed("\(error)")
            if !silent { toast = "\(error)" }
            return
        }
        let probe = SCSyncEngine(config: config)
        let info = await probe.probeServer()
        if info.reachable {
            var detail = "服务器可达"
            if let v = info.version, !v.isEmpty { detail += "，版本 \(v)" }
            connection = .ok(detail)
            if !silent { toast = detail }
        } else {
            connection = .failed(info.message)
            if !silent { toast = "连接失败" }
        }
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

    // MARK: - URL scheme
    //
    // syncclip://sync          立即同步
    // syncclip://push          把当前剪贴板推到服务器
    // syncclip://pull          把远端内容拉到剪贴板
    //
    // 用途：iOS 15 没有 App Intents，快捷指令里只能靠「打开 URL」，
    // 但配合「轻点背面」触发，这是不打开 App 就能同步的最省事办法。
    func handle(url: URL) {
        guard url.scheme?.lowercased() == "syncclip" else { return }
        let action = url.host?.lowercased() ?? ""
        SCLog.info("收到 URL 动作：\(action)")
        Task {
            switch action {
            case "push": await pushCurrentClipboard()
            case "pull": await pullRemote()
            default: await syncNow()
            }
        }
    }

    // MARK: - 诊断

    func runDiagnostics() async {
        var d = Diagnostics()

        // 1) 自己二进制里内嵌的 entitlement
        d.binaryPath = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "?"
        do {
            let dict = try SCEntitlementInspector.entitlements(atPath: d.binaryPath)
            d.entitlements = dict.keys.sorted()
            d.entitlementError = nil
        } catch {
            d.entitlementError = "\(error)"
        }

        // 2) 剪贴板读取（这一步如果弹了「允许粘贴」，说明 entitlement 没生效）
        d.pasteboardChangeCount = SCPasteboard.changeCount
        d.pasteboardTypes = SCPasteboard.typeIdentifiers
        let t0 = Date()
        d.pasteboardText = SCPasteboard.readText()
        d.readMillis = Date().timeIntervalSince(t0) * 1000

        var notes: [String] = []
        if d.entitlementError != nil {
            notes.append("读不到二进制签名段。App 是以未签名/被剥离签名的形式跑起来的，本地记录是运行时状态")
        } else if !d.pasteboardEntitlementsPresent {
            notes.append("缺关键 entitlement —— 读剪贴板会弹系统提示。检查 Config/entitlements 与构建时的 ldid 签名")
        } else {
            notes.append("entitlement 就位")
        }
        if d.pasteboardTypes.isEmpty {
            notes.append("剪贴板当前是空的")
        }
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
}
