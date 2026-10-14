import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// 双向同步的核心状态机。与运行环境无关：
/// 越狱路线由 LaunchAgent 守护进程驱动它，TrollStore 路线由 App 内线程驱动它——
/// 同一份代码，两种常驻方式。
public final class SCSyncEngine {

    public enum Action: String {
        case idle          // 两端都没变
        case pulled        // 远端 → 本地
        case pushed        // 本地 → 远端
        case skipped       // 出于安全考虑不动
        case failed
    }

    public struct Stats {
        public var action: Action
        public var note: String

        public init(action: Action = .idle, note: String = "") {
            self.action = action
            self.note = note
        }
    }

    /// engine 内部对「上一次见到的两端内容」的记忆
    public struct State: Equatable {
        /// 上次成功对齐时本地剪贴板的文本 hash（nil = 本地无文本）
        public var lastLocalHash: String?
        /// 上次成功对齐时远端 profile 的 hash（大写）
        public var lastRemoteHash: String = ""
        /// 上次发现「本地变了」的时刻，冲突仲裁用
        public var localDirtySince: Date?
        /// 是否已完成首次对齐
        public var primed: Bool = false

        public init() {}
    }

    public private(set) var state = State()

    /// 最近一次拉到的远端 profile / 文本（给 UI 展示用，不额外发请求）
    public private(set) var lastRemoteProfile: SCProfile?
    public private(set) var lastRemoteText: String?
    /// 最近一次同步结果
    public private(set) var lastStats: Stats?

    private let client: SCClient
    private let config: SCConfig

    /// 已经拉取过的附件缓存：dataName → 完整文本
    private var transferCache: [String: String] = [:]

    public init(config: SCConfig) {
        self.config = config
        self.client = SCClient(config: config)
    }

    public var startupSync: SCConfig.StartupSync { config.startupSync }
    public var pollInterval: TimeInterval { config.pollInterval }

    /// 配置热更新后，把旧引擎的对齐状态接过来，避免重建后整轮重来。
    public func adopt(state previous: State) {
        state = previous
    }

    // MARK: - 单次同步

    /// 完整跑一遍「读本地 → 读远端 → 仲裁 → 收敛」。
    ///
    /// 注意：所有 async 方法都不使用 inout 参数（Swift 的 async 函数不允许 inout），
    /// 内部改用「构造并返回 Stats」的方式。
    @discardableResult
    public func syncOnce() async -> Stats {
        #if canImport(UIKit)
        return await syncWithUIKit()
        #else
        return Stats(action: .failed, note: "当前编译目标没有 UIKit，无法访问剪贴板")
        #endif
    }

    #if canImport(UIKit)

    private func syncWithUIKit() async -> Stats {
        let s = await performSync()
        lastStats = s
        return s
    }

    private func performSync() async -> Stats {

        // ---- 1. 本地剪贴板情况 ----
        let localText = SCPasteboard.readText()
        let localHash: String? = localText.map { SCProfile.textHash($0) }

        // 剪贴板里有内容、但一个字符串都没有（例如刚复制了图片）：
        // 用户正在用剪贴板，这一轮什么都别动，免得把图片顶掉。
        if localText == nil && !SCPasteboard.typeIdentifiers.isEmpty {
            state.lastLocalHash = nil
            return Stats(action: .skipped,
                         note: "剪贴板是非文本内容（\(SCPasteboard.typeIdentifiers.joined(separator: ","))），本轮不动")
        }

        // ---- 2. 远端情况 ----
        let remote: SCProfile
        do {
            remote = try await client.fetchProfile()
        } catch {
            // 网络不通不算「本地变了」：本轮的本地改动保持「未处理」状态，
            // 等下一轮真正连通时再推上去，避免断网期间的改动被静默丢掉。
            return Stats(action: .failed, note: "拉取远端失败：\(error)")
        }

        let remoteHash = remote.normalizedHash
        let remoteText = await resolveText(of: remote)
        lastRemoteProfile = remote
        lastRemoteText = remoteText

        // ---- 3. 首次对齐 ----
        if !state.primed {
            return await prime(localHash: localHash, localText: localText,
                               remoteHash: remoteHash, remote: remote,
                               remoteText: remoteText)
        }

        // ---- 4. 变更判定 ----
        let localDirty = (localHash != nil) && (localHash != state.lastLocalHash)
        let remoteDirty = (remoteHash != state.lastRemoteHash)

        // 记录「本地从什么时候开始脏的」，冲突仲裁要用
        if localDirty {
            if state.localDirtySince == nil { state.localDirtySince = Date() }
        } else {
            state.localDirtySince = nil
        }

        if !localDirty && !remoteDirty {
            return Stats(action: .idle, note: "")
        }

        // ---- 5. 仲裁 ----
        if localDirty && remoteDirty {
            // 两边都变了：远端有 syncedAt 且晚于「本地开始脏」的时刻 → 判定远端是后来者，拉取
            let remoteWins: Bool
            if let syncedAt = remote.syncedAt,
               let remoteDate = SCSyncEngine.parseISO(syncedAt),
               let since = state.localDirtySince {
                remoteWins = remoteDate > since
            } else {
                // 拿不到可信时间戳时保守取远端：宁可本地被覆盖，也不要把服务器上的内容顶掉
                remoteWins = true
            }
            SCLog.info("两端都变了，仲裁：\(remoteWins ? "以远端为准（拉取）" : "以本地为准（推送）")")

            if remoteWins {
                return await applyRemote(remote, text: remoteText)
            }
            guard let text = localText, let hash = localHash else {
                return await applyRemote(remote, text: remoteText)
            }
            return await pushLocal(text: text, hash: hash)
        }

        if remoteDirty {
            return await applyRemote(remote, text: remoteText)
        }

        guard let text = localText, let hash = localHash else {
            return Stats(action: .idle, note: "")
        }
        return await pushLocal(text: text, hash: hash)
    }

    // MARK: - 首次对齐

    private func prime(localHash: String?, localText: String?,
                       remoteHash: String, remote: SCProfile,
                       remoteText: String?) async -> Stats {
        switch config.startupSync {

        case .none:
            state.lastLocalHash = localHash
            state.lastRemoteHash = remoteHash
            state.primed = true
            return Stats(action: .idle, note: "startupSync=none：只记录两端状态，不做任何覆盖")

        case .push:
            if let text = localText, let hash = localHash {
                return await pushLocal(text: text, hash: hash)
            }
            // 本地没有文本可推，退化成拉取
            return await applyRemote(remote, text: remoteText)

        case .pull:
            if remoteText != nil {
                return await applyRemote(remote, text: remoteText)
            }
            state.lastLocalHash = localHash
            state.lastRemoteHash = remoteHash
            state.primed = true
            return Stats(action: .idle, note: "远端暂无可同步文本，先跟随本地")
        }
    }

    // MARK: - 两个方向

    private func pushLocal(text: String, hash: String) async -> Stats {
        let profile = SCProfile.text(text)
        do {
            try await client.putProfile(profile)
            state.lastLocalHash = hash
            state.lastRemoteHash = profile.normalizedHash
            state.localDirtySince = nil
            state.primed = true
            SCLog.info("推送：\(profile.summary)")
            return Stats(action: .pushed, note: "已推送 \(text.utf8.count) 字节到服务器")
        } catch {
            SCLog.error("推送失败：\(error)")
            // 故意不更新 state：本地改动保持「未处理」，下一轮重试
            return Stats(action: .failed, note: "推送失败：\(error)")
        }
    }

    private func applyRemote(_ remote: SCProfile, text: String?) async -> Stats {
        guard let body = text, !body.isEmpty else {
            // 远端是图片/文件（v1 不支持），或者内容是空的（清空剪贴板不该同步过来）
            state.lastRemoteHash = remote.normalizedHash
            let why = (text == nil)
                ? "远端是 \(remote.type.rawValue) 类型，v1 只同步文本"
                : "远端文本为空，已忽略（不会用它清空本地剪贴板）"
            SCLog.debug("跳过远端内容：\(why)")
            return Stats(action: .skipped, note: why)
        }

        let bodyHash = SCProfile.textHash(body)

        // 已经是同一份内容就别写剪贴板了（避免无谓地抬高 changeCount）
        if let current = SCPasteboard.readText(), SCProfile.textHash(current) == bodyHash {
            state.lastLocalHash = bodyHash
            state.lastRemoteHash = remote.normalizedHash
            state.localDirtySince = nil
            state.primed = true
            return Stats(action: .idle, note: "两端内容已一致，无需写入")
        }

        SCPasteboard.writeText(body)
        state.lastLocalHash = bodyHash
        state.lastRemoteHash = remote.normalizedHash
        state.localDirtySince = nil
        state.primed = true
        SCLog.info("拉取：\(remote.summary)")
        return Stats(action: .pulled, note: "已写入本地剪贴板（\(body.utf8.count) 字节）")
    }

    #endif  // canImport(UIKit)

    // MARK: - 附件解析（Text + hasData 的情况）

    /// 拿到 profile 的完整文本。
    /// 内联的直接用 text；Text 类型带 hasData 的必须去 /file/ 取全文
    /// —— 服务端在这种情况下只把开头一截放进 text 字段。
    private func resolveText(of profile: SCProfile) async -> String? {
        guard profile.type == .text else { return nil }

        guard profile.hasData, let dataName = profile.dataName else {
            return profile.text
        }

        if let cached = transferCache[dataName] { return cached }

        do {
            let data = try await client.getFile(dataName: dataName,
                                                expectedTransferDataHash: profile.transferDataHash)
            guard let body = String(data: data, encoding: .utf8) else {
                SCLog.warn("附件 \(dataName) 不是合法 UTF-8，退化为使用 text 字段")
                return profile.text
            }
            transferCache[dataName] = body
            if transferCache.count > 8 { transferCache.removeAll() }
            return body
        } catch {
            SCLog.error("拉取附件 \(dataName) 失败：\(error)，退化为使用 text 字段")
            return profile.text
        }
    }

    // MARK: - 供 CLI 使用的直接操作

    public func manualSet(_ text: String) async throws {
        try await client.putProfile(SCProfile.text(text))
        state.lastLocalHash = SCProfile.textHash(text)
        state.lastRemoteHash = SCProfile.textHash(text)
        state.primed = true
    }

    public func manualGet() async throws -> String? {
        let remote = try await client.fetchProfile()
        return await resolveText(of: remote)
    }

    public func remoteProfile() async throws -> SCProfile {
        try await client.fetchProfile()
    }

    public func probeServer() async -> SCClient.ServerInfo {
        await client.probeServer()
    }

    // MARK: - 工具

    public static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
