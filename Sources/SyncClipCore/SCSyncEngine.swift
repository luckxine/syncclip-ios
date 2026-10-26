import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// 双向同步的核心状态机。与运行环境无关：
/// 越狱路线由 LaunchAgent 守护进程驱动它，TrollStore 路线由 App 内线程驱动它——
/// 同一份代码，两种常驻方式。
///
/// v2（全类型）：本地内容的分类从「只有文本」泛化为「文本 / 图片 /（未来的）文件」，
/// 远端 profile 的应用也按 type 分派。判定、仲裁、首次对齐的结构与 v1 完全一致，
/// 文本路径的行为保持不变。
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
        /// 该不该发本地通知（后台拉到图片 / 超限跳过这类用户该知道的事）。
        /// 前台轮询的普通 idle/push 不打扰人。
        public var notify: Bool

        public init(action: Action = .idle, note: String = "", notify: Bool = false) {
            self.action = action
            self.note = note
            self.notify = notify
        }
    }

    /// 本地剪贴板当前的内容类型（file/group 是 M2/M3，先留位）
    public enum LocalKind: String {
        case none
        case text
        case image
    }

    /// engine 内部对「上一次见到的两端内容」的记忆
    public struct State: Equatable {
        /// 上次成功对齐时本地内容的 digest（"T:"+文本hash / "I:"+图片字节hash；nil = 本地无内容）
        public var lastLocalDigest: String?
        public var lastLocalKind: LocalKind
        /// 上次分类时的剪贴板 changeCount —— 没变就不重新读剪贴板、不重复哈希图片
        public var lastChangeCount: Int
        /// 上次成功对齐时远端 profile 的 hash（大写）
        public var lastRemoteHash: String = ""
        /// 上次发现「本地变了」的时刻，冲突仲裁用
        public var localDirtySince: Date?
        /// 是否已完成首次对齐
        public var primed: Bool = false

        public init() {
            self.lastLocalDigest = nil
            self.lastLocalKind = .none
            self.lastChangeCount = -1
        }
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

    public init(config: SCConfig) throws {
        self.config = config
        self.client = try SCClient(config: config)
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
        let s = await performSync()
        lastStats = s
        return s
        #else
        return Stats(action: .failed, note: "当前编译目标没有 UIKit，无法访问剪贴板")
        #endif
    }

    #if canImport(UIKit)

    // MARK: - 本地内容分类

    /// 一轮开始时对剪贴板的快照。imageData 只在「changeCount 变了」的那一轮读取
    /// —— 图片字节哈希比文本贵，靠 changeCount 门控住重复劳动。
    internal struct LocalSnapshot {
        var kind: LocalKind = .none
        var digest: String?
        var text: String?
        var imageData: Data?
        var imageUTI: String?
        /// 原始字节拿不到、只能拿解码后 UIImage 的兜底（推送时会注明转码损失）
        var imageIsDecoded = false
        var utiList: [String] = []
    }

    /// changeCount 没变时直接复用上一轮的分类结果（内存里最多挂一份 ≤ 上限的图片字节，
    /// 下一次剪贴板变化即释放）。
    private var cachedSnapshot = LocalSnapshot()

    internal func classifyLocal(force: Bool) -> LocalSnapshot {
        let board = UIPasteboard.general
        let cc = board.changeCount

        if !force, state.primed, cc == state.lastChangeCount {
            return cachedSnapshot
        }

        var snap = LocalSnapshot()
        snap.utiList = board.types

        // 类型判定优先级（设计稿 §3）：文本优先 —— 网页复制常同时带图和 URL，
        // 按文本走保持 v1 行为；其次图片；文件引用留给 M2。
        if board.hasStrings, let s = board.string, !s.isEmpty {
            snap.kind = .text
            snap.text = s
            snap.digest = "T:" + SCProfile.textHash(s)
        } else if let payload = SCPasteboard.readImagePayload() {
            snap.kind = .image
            switch payload {
            case .raw(let data, let uti):
                snap.imageData = data
                snap.imageUTI = uti
                snap.digest = "I:" + SCCrypto.sha256Hex(data)
            case .decoded(let image):
                // 解码兜底没有原始字节，digest 用像素渲染结果近似：
                // 同一张图重复解码结果稳定，不会造成循环。
                if let jpeg = image.jpegData(compressionQuality: 0.9) {
                    snap.imageData = jpeg
                    snap.imageIsDecoded = true
                    snap.imageUTI = "public.jpeg"
                    snap.digest = "I:" + SCCrypto.sha256Hex(jpeg)
                } else {
                    snap.kind = .none
                }
            }
        }

        state.lastChangeCount = cc
        cachedSnapshot = snap
        return snap
    }

    private func performSync() async -> Stats {

        // ---- 1. 本地剪贴板情况 ----
        let snap = classifyLocal(force: !state.primed)

        if snap.kind == .none && !snap.utiList.isEmpty {
            // 用户剪贴板里放着「认识但暂不同步 / 不认识」的内容：
            // 这一轮什么都不动，免得把用户正在用的剪贴板顶掉（v1 语义保持）。
            state.lastLocalDigest = nil
            state.lastLocalKind = .none
            let why = skipReason(for: snap)
            SCLog.debug("跳过本地内容：\(why)")
            return Stats(action: .skipped, note: why)
        }
        if snap.kind == .image && !config.imageSyncEnabled {
            // 图片同步关着：同样整轮不动（v1 语义）。开关打开后引擎会重建，不受影响。
            state.lastLocalDigest = nil
            state.lastLocalKind = .none
            let why = skipReason(for: snap)
            SCLog.debug("跳过本地内容：\(why)")
            return Stats(action: .skipped, note: why)
        }
        // 剪贴板为空：不算错误，继续看远端（远端可能变了要拉）

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
        lastRemoteProfile = remote
        lastRemoteText = remote.type == .text ? await resolveText(of: remote) : nil

        // ---- 3. 首次对齐 ----
        if !state.primed {
            return await prime(snap: snap, remote: remote, remoteHash: remoteHash)
        }

        // ---- 4. 变更判定 ----
        let localDirty = (snap.digest != nil) && (snap.digest != state.lastLocalDigest)
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
            let remoteWins = resolveConflict(remote: remote)
            SCLog.info("两端都变了，按「\(config.conflictResolution.displayName)」仲裁："
                       + (remoteWins ? "以远端为准（拉取）" : "以本地为准（推送）"))

            if remoteWins {
                return await applyRemoteProfile(remote)
            }
            return await pushSnapshot(snap)
        }

        if remoteDirty {
            return await applyRemoteProfile(remote)
        }

        return await pushSnapshot(snap)
    }

    /// 为什么本轮不动本地内容（跳过原因必须可见，设计稿原则 2）
    private func skipReason(for snap: LocalSnapshot) -> String {
        if snap.utiList.isEmpty {
            return "剪贴板是空的，没有可推送的内容"
        }
        if !config.imageSyncEnabled && SCPasteboard.hasImage {
            return "剪贴板是图片，图片同步未开启（设置里可开）"
        }
        if snap.utiList.contains(SCPasteboard.fileURLUTI) {
            return "剪贴板是文件引用，文件同步将在 M2 版本提供"
        }
        return "剪贴板是不支持的内容类型（\(snap.utiList.joined(separator: ","))），本轮不动"
    }

    // MARK: - 冲突仲裁

    /// 两端同时变了，以谁为准。策略来自设置里的「冲突解决」。
    private func resolveConflict(remote: SCProfile) -> Bool {
        switch config.conflictResolution {
        case .local:
            return false
        case .remote:
            return true
        case .newest:
            // 比时间戳：远端晚于「本地开始脏」的时刻 → 判远端是后来者
            if let syncedAt = remote.syncedAt,
               let remoteDate = SCSyncEngine.parseISO(syncedAt),
               let since = state.localDirtySince {
                return remoteDate > since
            }
            // 拿不到可信时间戳时保守取远端：宁可本地被覆盖，
            // 也不要把服务器上已经存在的内容顶掉
            return true
        }
    }

    // MARK: - 首次对齐

    private func prime(snap: LocalSnapshot,
                       remote: SCProfile,
                       remoteHash: String) async -> Stats {
        switch config.startupSync {

        case .none:
            state.lastLocalDigest = snap.digest
            state.lastLocalKind = snap.kind
            state.lastRemoteHash = remoteHash
            state.primed = true
            return Stats(action: .idle, note: "startupSync=none：只记录两端状态，不做任何覆盖")

        case .push:
            if snap.kind != .none {
                return await pushSnapshot(snap)
            }
            // 本地没有可推的内容，退化成拉取
            return await applyRemoteProfile(remote)

        case .pull:
            let pullable = (remote.type == .text && !(lastRemoteText ?? "").isEmpty)
                        || (remote.type == .image && remote.hasData)
            if pullable {
                return await applyRemoteProfile(remote)
            }
            state.lastLocalDigest = snap.digest
            state.lastLocalKind = snap.kind
            state.lastRemoteHash = remoteHash
            state.primed = true
            return Stats(action: .idle, note: "远端暂无可同步内容，先跟随本地")
        }
    }

    // MARK: - 推送方向

    private func pushSnapshot(_ snap: LocalSnapshot) async -> Stats {
        guard snap.digest != nil else {
            return Stats(action: .idle, note: "")
        }
        switch snap.kind {
        case .text:
            return await pushText(snap)
        case .image:
            return await pushImage(snap)
        case .none:
            return Stats(action: .idle, note: "")
        }
    }

    private func pushText(_ snap: LocalSnapshot) async -> Stats {
        guard let text = snap.text else {
            return Stats(action: .idle, note: "")
        }
        let profile = SCProfile.text(text)
        do {
            try await client.putProfile(profile)
            state.lastLocalDigest = snap.digest
            state.lastLocalKind = .text
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

    private func pushImage(_ snap: LocalSnapshot) async -> Stats {
        guard config.imageSyncEnabled else {
            return Stats(action: .skipped, note: skipReason(for: snap))
        }
        guard let raw = snap.imageData else {
            return Stats(action: .skipped, note: "图片字节不可用，本轮跳过")
        }

        var payload = raw
        var format = SCImageCodec.sniff(raw)
        if format == .heic {
            guard let jpeg = SCImageCodec.heicToJPEG(raw) else {
                SCLog.warn("HEIC 转码失败，跳过本轮")
                return Stats(action: .skipped,
                             note: "HEIC 图片转码失败，本轮跳过（剪贴板未动）", notify: true)
            }
            payload = jpeg
            format = .jpeg
        }
        guard let finalFormat = format else {
            return Stats(action: .skipped,
                         note: "无法识别的图片格式（uti=\(snap.imageUTI ?? "?")），已跳过",
                         notify: true)
        }
        if payload.count > config.maxImageBytes {
            let mb = Self.megabytes(payload.count)
            let limit = Self.megabytes(config.maxImageBytes)
            SCLog.warn("图片 \(mb) MB 超过上限 \(limit) MB，未上传")
            return Stats(action: .skipped,
                         note: String(format: "图片 %.1f MB 超过上限 %.0f MB，未上传（设置里可调）",
                                      mb, limit),
                         notify: true)
        }

        let fileName = SCImageCodec.imageFileName(for: finalFormat)
        let profile = SCProfile.image(fileName: fileName, content: payload)

        do {
            // 协议铁律：先 PUT 文件再 PUT JSON，顺序反了服务器 404（设计稿 §1）
            try await client.putFile(dataName: fileName, content: payload)
            try await client.putProfile(profile)
        } catch {
            SCLog.error("图片上传失败：\(error)")
            // 同文本路径：不更新 state，下一轮自动重试；putFile 幂等，重传安全
            return Stats(action: .failed, note: "图片上传失败：\(error)")
        }

        state.lastLocalDigest = snap.digest
        state.lastLocalKind = .image
        state.lastRemoteHash = profile.normalizedHash
        state.localDirtySince = nil
        state.primed = true
        let via = snap.imageIsDecoded ? "（来源只给了解码后的图，动图会丢帧）" : ""
        SCLog.info("推送图片：\(fileName) \(Self.megabytes(payload.count)) MB\(via)")
        return Stats(action: .pushed,
                     note: String(format: "已推送图片 %.1f MB（%@）%@", Self.megabytes(payload.count), fileName, via))
    }

    // MARK: - 拉取方向

    /// 远端 profile 的统一入口：按 type 分派。
    private func applyRemoteProfile(_ remote: SCProfile) async -> Stats {
        switch remote.type {
        case .text:
            return applyRemoteText(remote)
        case .image:
            return await applyRemoteImage(remote)
        case .file, .group:
            state.lastRemoteHash = remote.normalizedHash
            let why = "远端是 \(remote.type.rawValue) 类型，文件同步将在后续版本（M2/M3）提供"
            SCLog.debug("跳过远端内容：\(why)")
            return Stats(action: .skipped, note: why)
        }
    }

    private func applyRemoteText(_ remote: SCProfile) -> Stats {
        let text = lastRemoteText
        guard let body = text, !body.isEmpty else {
            // 内容是空的：清空剪贴板不该同步过来
            state.lastRemoteHash = remote.normalizedHash
            let why = "远端文本为空，已忽略（不会用它清空本地剪贴板）"
            SCLog.debug("跳过远端内容：\(why)")
            return Stats(action: .skipped, note: why)
        }

        let digest = "T:" + SCProfile.textHash(body)

        // 已经是同一份内容就别写剪贴板了（避免无谓地抬高 changeCount）
        if state.primed, state.lastLocalDigest == digest {
            state.lastRemoteHash = remote.normalizedHash
            state.localDirtySince = nil
            return Stats(action: .idle, note: "两端内容已一致，无需写入")
        }
        if let current = SCPasteboard.readText(),
           SCProfile.textHash(current) == SCProfile.textHash(body) {
            state.lastLocalDigest = digest
            state.lastLocalKind = .text
            state.lastRemoteHash = remote.normalizedHash
            state.localDirtySince = nil
            state.primed = true
            return Stats(action: .idle, note: "两端内容已一致，无需写入")
        }

        SCPasteboard.writeText(body)
        state.lastLocalDigest = digest
        state.lastLocalKind = .text
        state.lastChangeCount = SCPasteboard.changeCount
        cachedSnapshot = LocalSnapshot(kind: .text, digest: digest, text: body,
                                       imageData: nil, imageUTI: nil, imageIsDecoded: false,
                                       utiList: ["public.utf8-plain-text"])
        state.lastRemoteHash = remote.normalizedHash
        state.localDirtySince = nil
        state.primed = true
        SCLog.info("拉取：\(remote.summary)")
        return Stats(action: .pulled, note: "已写入本地剪贴板（\(body.utf8.count) 字节）")
    }

    private func applyRemoteImage(_ remote: SCProfile) async -> Stats {
        guard config.imageSyncEnabled else {
            state.lastRemoteHash = remote.normalizedHash
            return Stats(action: .skipped, note: "远端是图片，图片同步未开启（设置里可开）")
        }
        guard remote.hasData, let dataName = remote.dataName else {
            state.lastRemoteHash = remote.normalizedHash
            return Stats(action: .skipped, note: "远端图片 profile 缺 dataName，已拦截")
        }
        if let size = remote.size, Int(size) > config.maxImageBytes {
            state.lastRemoteHash = remote.normalizedHash
            let mb = Self.megabytes(Int(size))
            let limit = Self.megabytes(config.maxImageBytes)
            SCLog.warn("远端图片 \(mb) MB 超过上限，未拉取")
            return Stats(action: .skipped,
                         note: String(format: "远端图片 %.1f MB 超过上限 %.0f MB，未拉取", mb, limit),
                         notify: true)
        }

        let data: Data
        do {
            // 传输层已按 transferDataHash 校验；不符会抛错 —— 剪贴板绝不被污染
            data = try await client.getFile(dataName: dataName,
                                            expectedTransferDataHash: remote.transferDataHash)
        } catch {
            SCLog.error("拉取图片 \(dataName) 失败：\(error)")
            return Stats(action: .failed, note: "拉取图片失败：\(error)", notify: true)
        }

        guard let format = SCImageCodec.sniff(data) else {
            state.lastRemoteHash = remote.normalizedHash
            return Stats(action: .skipped,
                         note: "服务器上的 \(dataName) 不是可识别图片，已拦截（剪贴板未动）",
                         notify: true)
        }

        let digest = "I:" + SCCrypto.sha256Hex(data)

        // 已经是同一张图就别再写了（避免抬高 changeCount 造成来回顶）
        if state.primed, state.lastLocalDigest == digest {
            state.lastRemoteHash = remote.normalizedHash
            state.localDirtySince = nil
            return Stats(action: .idle, note: "两端图片已一致，无需写入")
        }

        SCPasteboard.writeImage(data: data, uti: format.uti)
        state.lastLocalDigest = digest
        state.lastLocalKind = .image
        state.lastChangeCount = SCPasteboard.changeCount
        cachedSnapshot = LocalSnapshot(kind: .image, digest: digest, text: nil,
                                       imageData: data, imageUTI: format.uti,
                                       imageIsDecoded: false, utiList: [format.uti])
        state.lastRemoteHash = remote.normalizedHash
        state.localDirtySince = nil
        state.primed = true
        SCLog.info("拉取图片：\(dataName) \(Self.megabytes(data.count)) MB")
        return Stats(action: .pulled,
                     note: String(format: "已写入剪贴板：图片 %.1f MB（%@）",
                                  Self.megabytes(data.count), dataName),
                     notify: true)
    }

    // MARK: - 服务器实时推来的内容

    /// 处理「服务器主动推来的新剪贴板」（SignalR 的 RemoteProfileChanged）。
    ///
    /// 走的是和轮询完全相同的收敛逻辑，所以推送与轮询不会打架：
    /// applyRemoteProfile 内部会先比对 digest，「已经是同一份内容就别写剪贴板」
    /// 那一步照旧生效，不会因为来了个推送就无谓地抬高 changeCount。
    ///
    /// 首次对齐还没做时（App 刚起来、推送先到了）按 `startupSync` 的策略走，
    /// 与轮询路径保持一致 —— 不能因为「这次是推送进来的」就把用户设的策略绕过去。
    @discardableResult
    public func applyPushedRemote(_ profile: SCProfile) async -> Stats {
        lastRemoteProfile = profile
        lastRemoteText = profile.type == .text ? await resolveText(of: profile) : nil

        if !state.primed {
            let snap = classifyLocal(force: true)
            return await prime(snap: snap, remote: profile, remoteHash: profile.normalizedHash)
        }
        return await applyRemoteProfile(profile)
    }

    // MARK: - 手动操作（App 的「推送剪贴板 / 拉取远端」按钮）

    /// 把当前剪贴板内容（文本或图片）推上去。
    @discardableResult
    public func pushNow() async -> Stats {
        let snap = classifyLocal(force: true)
        if snap.kind == .none {
            return Stats(action: .skipped, note: skipReason(for: snap))
        }
        return await pushSnapshot(snap)
    }

    /// 拉取远端内容并按类型应用。
    @discardableResult
    public func pullNow() async -> Stats {
        let remote: SCProfile
        do {
            remote = try await client.fetchProfile()
        } catch {
            return Stats(action: .failed, note: "拉取远端失败：\(error)")
        }
        lastRemoteProfile = remote
        lastRemoteText = remote.type == .text ? await resolveText(of: remote) : nil
        if !state.primed {
            let snap = classifyLocal(force: true)
            return await prime(snap: snap, remote: remote, remoteHash: remote.normalizedHash)
        }
        return await applyRemoteProfile(remote)
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
        state.lastLocalDigest = "T:" + SCProfile.textHash(text)
        state.lastLocalKind = .text
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

    public func probeServer() async -> SCProbeResult {
        await client.probeServer()
    }

    // MARK: - 工具

    static func megabytes(_ bytes: Int) -> Double {
        Double(bytes) / 1024 / 1024
    }

    public static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
