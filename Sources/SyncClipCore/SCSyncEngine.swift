import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// 双向同步的核心状态机。与运行环境无关：
/// 越狱路线由 LaunchAgent 守护进程驱动它，TrollStore 路线由 App 内线程驱动它——
/// 同一份代码，两种常驻方式。
///
/// v2（全类型）：本地内容的分类从「只有文本」泛化为「文本 / 图片 / 文件」，
/// 远端 profile 的应用也按 type 分派（Group 解包进收件箱，不经剪贴板）。
/// 判定、仲裁、首次对齐的结构与 v1 完全一致，文本路径的行为保持不变。
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

    /// 本地剪贴板当前的内容类型。
    /// file = 文件 App「拷贝」出的单文件引用；group 只出现在手动多选推送后的
    /// 远端状态里 —— iOS 剪贴板没有「多文件」形态，Group 永远不经剪贴板。
    public enum LocalKind: String {
        case none
        case text
        case image
        case file
        case group
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
        /// 剪贴板里 public.file-url 的原始字节（M2）：分类期只读这个轻量数据，
        /// 真正的文件字节等推送时才经 readCopiedFile 拷出
        var fileURLData: Data? = nil
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
        } else if let fileURL = board.data(forPasteboardType: SCPasteboard.fileURLUTI),
                  !fileURL.isEmpty {
            // 文件引用（设计稿 §3 第 3 优先级）。digest 只用 file-url 字节：
            // 读真正的文件内容要过协调读/临时拷贝，不该发生在分类期。
            // 代价：同名文件改完内容再拷一次，URL 字节不变 → 判不出「变了」，
            // 这轮不推 —— 已知限制，M2 真机验收观察项。
            snap.kind = .file
            snap.fileURLData = fileURL
            snap.digest = "F:" + SCCrypto.sha256Hex(fileURL)
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
        if snap.kind == .file && !config.fileSyncEnabled {
            // 文件同步关着：与图片同一语义 —— 整轮不动，开关打开后引擎重建
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
        if !config.fileSyncEnabled && snap.utiList.contains(SCPasteboard.fileURLUTI) {
            return "剪贴板是文件，文件同步未开启（设置里可开）"
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
                        || ((remote.type == .file || remote.type == .group) && remote.hasData)
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
        case .file:
            return await pushClipboardFile(snap)
        case .group, .none:
            // group 不会出现在剪贴板分类里；这里是防御性兑底
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

    /// 剪贴板里的文件引用 → 单文件直传（M2 入口 A）。
    ///
    /// 字节真正拷出（readCopiedFile：协调读/直接读/itemProviders 三级兑底）
    /// 只发生在推送这一步，而不是分类期 —— 拷贝要过 NSFileCoordinator，贵。
    /// 成功后 lastLocalDigest 记的是分类期的 file-url 字节 hash，
    /// 与 cachedSnapshot 一致，下一轮不会重复推。
    private func pushClipboardFile(_ snap: LocalSnapshot) async -> Stats {
        guard config.fileSyncEnabled else {
            return Stats(action: .skipped, note: skipReason(for: snap))
        }
        do {
            let copied = try await SCPasteboard.readCopiedFile()
            let name = copied.suggestedName ?? copied.url.lastPathComponent
            let stats = await pushSingleFile(at: copied.url, fileName: name)
            // readCopiedFile 落在临时目录的副本用完即删，不留垃圾
            try? FileManager.default.removeItem(at: copied.url)
            if stats.action == .pushed {
                state.lastLocalDigest = snap.digest
                state.lastLocalKind = .file
                state.localDirtySince = nil
            }
            return stats
        } catch {
            SCLog.warn("读取剪贴板文件失败：\(error)")
            return Stats(action: .skipped, note: "读取剪贴板文件失败：\(error)", notify: true)
        }
    }

    // MARK: - 拉取方向

    /// 远端 profile 的统一入口：按 type 分派。
    private func applyRemoteProfile(_ remote: SCProfile) async -> Stats {
        switch remote.type {
        case .text:
            return applyRemoteText(remote)
        case .image:
            return await applyRemoteImage(remote)
        case .file:
            return await applyRemoteFile(remote)
        case .group:
            return await applyRemoteGroup(remote)
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

    /// 远端单文件 → 收件箱（+ 可选写剪贴板 file-url）。剪贴板默认不动：
    /// 「跨 App 粘出文件」的置信度由 P3 探针把关，开关默认关（设计稿 §4.2）；
    /// 收件箱 + 文件 App 永远是主路径。
    private func applyRemoteFile(_ remote: SCProfile) async -> Stats {
        guard config.fileSyncEnabled else {
            state.lastRemoteHash = remote.normalizedHash
            return Stats(action: .skipped, note: "远端是文件，文件同步未开启（设置里可开）")
        }
        guard remote.hasData, let dataName = remote.dataName, !dataName.isEmpty else {
            state.lastRemoteHash = remote.normalizedHash
            return Stats(action: .skipped, note: "远端文件 profile 缺 dataName，已拦截")
        }
        if let size = remote.size, Int(size) > config.maxFileBytes {
            state.lastRemoteHash = remote.normalizedHash
            let mb = Self.megabytes(Int(size))
            let limit = Self.megabytes(config.maxFileBytes)
            SCLog.warn("远端文件 \(mb) MB 超过上限，未拉取")
            return Stats(action: .skipped,
                         note: String(format: "远端文件 %.1f MB 超过上限 %.0f MB，未拉取（设置里可调）", mb, limit),
                         notify: true)
        }

        let data: Data
        do {
            // 传输层已按 transferDataHash 校验；不符会抛错 —— 不落盘坏文件
            data = try await client.getFile(dataName: dataName,
                                            expectedTransferDataHash: remote.transferDataHash)
        } catch {
            SCLog.error("拉取文件 \(dataName) 失败：\(error)")
            return Stats(action: .failed, note: "拉取文件失败：\(error)", notify: true)
        }

        let saved: URL
        do {
            saved = try SCInbox.shared.save(data: data, name: dataName)
        } catch {
            SCLog.error("写入收件箱失败：\(error)")
            return Stats(action: .failed, note: "写入收件箱失败：\(error)", notify: true)
        }

        var note = String(format: "已存入收件箱：%@（%.1f MB）",
                          saved.lastPathComponent, Self.megabytes(data.count))
        if config.fileClipboardWriteEnabled {
            SCPasteboard.writeFileReference(saved)
            // 写了剪贴板就必须同步快照：否则下一轮 changeCount 变了，
            // 刚写入的 file-url 会被当成「本地新内容」又推回去
            let digest = "F:" + SCCrypto.sha256Hex(saved.dataRepresentation)
            state.lastLocalDigest = digest
            state.lastLocalKind = .file
            state.lastChangeCount = SCPasteboard.changeCount
            state.localDirtySince = nil
            cachedSnapshot = LocalSnapshot(kind: .file, digest: digest, text: nil,
                                           imageData: nil, imageUTI: nil, imageIsDecoded: false,
                                           fileURLData: saved.dataRepresentation,
                                           utiList: [SCPasteboard.fileURLUTI])
            note += "，并写入剪贴板文件引用"
        }
        // 没写剪贴板时不动 lastLocalDigest / localDirtySince：剪贴板里可能还挂着
        // 没推上去的本地内容，它的「脏」不该被这轮拉取抹掉

        state.lastRemoteHash = remote.normalizedHash
        state.primed = true
        SCLog.info("拉取文件：\(dataName) → 收件箱")
        return Stats(action: .pulled, note: note, notify: true)
    }

    /// 远端 Group → 解 zip 到收件箱子目录。Group 永远不碰剪贴板
    /// （iOS 剪贴板没有多文件形态，设计稿 §4.3），产物只进收件箱。
    private func applyRemoteGroup(_ remote: SCProfile) async -> Stats {
        guard config.groupSyncEnabled else {
            state.lastRemoteHash = remote.normalizedHash
            return Stats(action: .skipped, note: "远端是多文件（Group），Group 同步未开启（设置里可开）")
        }
        guard remote.hasData, let dataName = remote.dataName, !dataName.isEmpty else {
            state.lastRemoteHash = remote.normalizedHash
            return Stats(action: .skipped, note: "远端 Group profile 缺 dataName，已拦截")
        }
        if let size = remote.size, Int(size) > config.maxFileBytes {
            state.lastRemoteHash = remote.normalizedHash
            let mb = Self.megabytes(Int(size))
            let limit = Self.megabytes(config.maxFileBytes)
            SCLog.warn("远端 Group \(mb) MB 超过上限，未拉取")
            return Stats(action: .skipped,
                         note: String(format: "远端多文件共 %.1f MB 超过上限 %.0f MB，未拉取（设置里可调）", mb, limit),
                         notify: true)
        }

        let data: Data
        do {
            data = try await client.getFile(dataName: dataName,
                                            expectedTransferDataHash: remote.transferDataHash)
        } catch {
            SCLog.error("拉取 Group \(dataName) 失败：\(error)")
            return Stats(action: .failed, note: "拉取多文件失败：\(error)", notify: true)
        }

        let dir: URL
        do {
            dir = try SCInbox.shared.extractGroup(zipData: data, zipName: dataName)
        } catch {
            SCLog.error("解包 Group \(dataName) 失败：\(error)")
            return Stats(action: .failed, note: "解包多文件失败：\(error)", notify: true)
        }

        // 产物在收件箱不在剪贴板：本地对齐记忆保持原样，只记远端 ——
        // 剪贴板里原有的内容与这轮拉取互不干扰
        state.lastRemoteHash = remote.normalizedHash
        state.primed = true
        SCLog.info("拉取 Group：\(dataName) → \(dir.lastPathComponent)/")
        return Stats(action: .pulled,
                     note: "已解包多文件到收件箱：\(dir.lastPathComponent)（来自 \(dataName)）",
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

    // MARK: - 收件箱拉取（M2/M3 入口 C：不动剪贴板，直接落收件箱）

    /// 把远端的文件/文件组拉进收件箱（不动剪贴板）。
    /// 远端是文本/图片时拒绝 —— 这条路只服务文件场景，避免和剪贴板路径打架。
    @discardableResult
    public func pullIntoInbox() async -> Stats {
        let remote: SCProfile
        do {
            remote = try await client.fetchProfile()
        } catch {
            return Stats(action: .failed, note: "拉取远端失败：\(error)")
        }
        guard remote.type == .file || remote.type == .group else {
            return Stats(action: .skipped,
                         note: "远端不是文件（现在是 \(remote.type)），拉取到收件箱只服务文件")
        }
        guard let dataName = remote.dataName, remote.hasData else {
            return Stats(action: .skipped, note: "远端 profile 缺附件，已拦截")
        }
        let mb = Double(remote.size ?? 0) / 1_048_576
        if mb > Double(config.maxFileBytes) / 1_048_576 {
            let limit = Self.megabytes(config.maxFileBytes)
            return Stats(action: .skipped,
                         note: "远端 \(String(format: "%.1f", mb)) MB 超过上限 \(limit)，未拉取")
        }
        do {
            let data = try await client.getFile(dataName: dataName,
                                                expectedTransferDataHash: remote.transferDataHash)
            if remote.type == .group {
                let dir = try SCInbox.shared.extractGroup(zipData: data, zipName: dataName)
                SCLog.info("拉取 Group 进收件箱：\(dataName) → \(dir.lastPathComponent)/")
                return Stats(action: .pulled, note: "已解包 \(dataName) 进收件箱")
            } else {
                let url = try SCInbox.shared.save(data: data, name: dataName)
                SCLog.info("拉取文件进收件箱：\(dataName)")
                return Stats(action: .pulled, note: "已存 \(url.lastPathComponent) 进收件箱")
            }
        } catch {
            SCLog.error("拉取到收件箱失败：\(error)")
            return Stats(action: .failed, note: "拉取失败：\(error)")
        }
    }

    // MARK: - 文件 / Group 手动推送（M2/M3 入口 B：App 内多选 picker）

    /// 把用户选中的文件推上去。单文件走 File 直传；多文件打成一个 zip 按
    /// Group 上传 —— 与 Windows 端「多选复制 = Group」语义对齐，对端一次粘贴出全部。
    /// picker 本身在 UI 层，这里只吃 URL。
    @discardableResult
    public func pushFiles(urls: [URL]) async -> Stats {
        guard !urls.isEmpty else {
            return Stats(action: .skipped, note: "没有选中任何文件")
        }
        if urls.count == 1 {
            return await pushSingleFile(at: urls[0], fileName: urls[0].lastPathComponent)
        }
        guard config.groupSyncEnabled else {
            return Stats(action: .skipped, note: "多文件（Group）同步未开启（设置里可开）", notify: true)
        }

        let fm = FileManager.default
        var names: [String] = []
        var totalSize: Int64 = 0
        for url in urls {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            totalSize += (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            names.append(Self.safeFileName(url.lastPathComponent))
        }
        if Set(names).count != names.count {
            // zip entry 与 groupHash 都拿文件名当路径，重名会互相顶掉，宁可拒掉
            return Stats(action: .skipped, note: "所选文件存在同名，无法打包（先重命名再试）", notify: true)
        }
        if Int(totalSize) > config.maxFileBytes {
            let mb = Self.megabytes(Int(totalSize))
            let limit = Self.megabytes(config.maxFileBytes)
            SCLog.warn("Group 共 \(mb) MB 超过上限 \(limit) MB，未上传")
            return Stats(action: .skipped,
                         note: String(format: "共 %.1f MB 超过上限 %.0f MB，未上传（设置里可调）", mb, limit),
                         notify: true)
        }

        // groupHash 必须用各文件真实字节算（设计稿 §4.3）：它是跨客户端判等的依据，
        // zip 只是运输容器，zip 内容 hash 代替不了 entry hash
        var hashEntries: [(path: String, isDirectory: Bool, size: Int64, sha256: String?)] = []
        var archivePayload: [(name: String, url: URL)] = []
        for (url, name) in zip(urls, names) {
            guard let data = try? Data(contentsOf: url) else {
                return Stats(action: .failed, note: "读取文件失败：\(name)", notify: true)
            }
            hashEntries.append((path: name, isDirectory: false,
                                size: Int64(data.count), sha256: SCCrypto.sha256Hex(data)))
            archivePayload.append((name: name, url: url))
        }

        let zipName = Self.groupZipName()
        let tempZip = fm.temporaryDirectory.appendingPathComponent(zipName)
        defer { try? fm.removeItem(at: tempZip) }   // 打包产物只在上传这口气里活着
        do {
            try SCZip.archive(files: archivePayload, to: tempZip)
            let zipData = try Data(contentsOf: tempZip)
            let profile = SCProfile.group(zipName: zipName,
                                          fileNames: names,
                                          content: zipData,
                                          groupHash: SCProfile.groupHash(entries: hashEntries))
            // 协议铁律：先 PUT 文件再 PUT JSON，顺序反了服务器 404（设计稿 §1）
            try await client.putFile(dataName: zipName, content: zipData)
            try await client.putProfile(profile)
            state.lastRemoteHash = profile.normalizedHash
            state.primed = true
            SCLog.info("推送 Group：\(names.count) 个文件，\(zipName) \(Self.megabytes(zipData.count)) MB")
            return Stats(action: .pushed,
                         note: String(format: "已推送 %d 个文件（Group，%.1f MB）",
                                      names.count, Self.megabytes(zipData.count)))
        } catch {
            SCLog.error("Group 上传失败：\(error)")
            return Stats(action: .failed, note: "Group 上传失败：\(error)", notify: true)
        }
    }

    /// 单文件直传（剪贴板路径与 pushFiles 共用）。字节先守卫再进内存，
    /// 超限文件连读都不用读。
    private func pushSingleFile(at url: URL, fileName rawName: String) async -> Stats {
        let fileName = Self.safeFileName(rawName)

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let known = (attrs?[.size] as? NSNumber)?.int64Value, Int(known) > config.maxFileBytes {
            let mb = Self.megabytes(Int(known))
            let limit = Self.megabytes(config.maxFileBytes)
            SCLog.warn("文件 \(fileName) \(mb) MB 超过上限 \(limit) MB，未上传")
            return Stats(action: .skipped,
                         note: String(format: "文件 %.1f MB 超过上限 %.0f MB，未上传（设置里可调）", mb, limit),
                         notify: true)
        }
        guard let data = try? Data(contentsOf: url) else {
            return Stats(action: .failed, note: "读取文件失败：\(fileName)", notify: true)
        }
        if data.count > config.maxFileBytes {
            let mb = Self.megabytes(data.count)
            let limit = Self.megabytes(config.maxFileBytes)
            return Stats(action: .skipped,
                         note: String(format: "文件 %.1f MB 超过上限 %.0f MB，未上传（设置里可调）", mb, limit),
                         notify: true)
        }

        let profile = SCProfile.fileEntry(fileName: fileName, content: data)
        do {
            try await client.putFile(dataName: fileName, content: data)
            try await client.putProfile(profile)
        } catch {
            SCLog.error("文件上传失败：\(error)")
            return Stats(action: .failed, note: "文件上传失败：\(error)", notify: true)
        }
        // 来源是剪贴板副本或 picker，不等于剪贴板当前内容：lastLocalDigest 不动；
        // 只记 lastRemoteHash，下一轮就不会把刚推上去的又当远端新内容拉回来。
        // （剪贴板来源的 lastLocalDigest 由 pushClipboardFile 补记）
        state.lastRemoteHash = profile.normalizedHash
        state.primed = true
        SCLog.info("推送文件：\(fileName) \(Self.megabytes(data.count)) MB")
        return Stats(action: .pushed,
                     note: String(format: "已推送文件 %.1f MB（%@）",
                                  Self.megabytes(data.count), fileName))
    }

    /// 文件名清洗：dataName 会进 URL 路径与服务器存储名，传输层拒含分隔符的名字，
    /// 这里先把任何路径成分剥掉，只剩裸文件名。
    private static func safeFileName(_ raw: String) -> String {
        let last = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        return last.isEmpty ? "file" : last
    }

    /// 上游 Group 传输名 `File_{时间戳}_{随机}.zip`（CreateNewDataFileName）。
    /// 随机段刻意短（6 位 hex）：只为避免同一秒两次推送撞名，不作安全用途。
    private static func groupZipName(at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let random = String(format: "%06X", UInt32.random(in: 0..<0xFFFFFF))
        return "File_\(f.string(from: date))_\(random).zip"
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
