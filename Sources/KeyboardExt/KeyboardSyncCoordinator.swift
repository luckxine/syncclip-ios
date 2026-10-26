import Foundation
import UIKit
import UniformTypeIdentifiers
import SyncClipCore
import SyncClipApp

/// 键盘唤起即同步协调器。
///
/// 为什么是独立的一个类而不是塞进 KeyboardViewController：
/// 同步逻辑（拉远端→写剪贴板 / 读剪贴板→推远端）本身有状态、有并发门控，
/// 塞进 VC 会让「面板渲染」和「同步」两条线搅在一起，难排障。拆出来后
/// VC 只管"唤起时调一下"，成败只在状态条显示一行。
///
/// **能做什么 / 做不到什么**（这是 iOS 平台的现实，不是设计取舍）：
///   - 能做：键盘唤起的这一刻，静默跑一轮双向同步——拉远端最新到剪贴板、
///     把本地新图片/文件推上去。开了完全访问 + 四条私有 pasteboard entitlement
///     时，读写剪贴板不弹"允许粘贴"。
///   - 做不到：键盘没弹出时（后台/锁屏）的自动同步。iOS 14 起 App 后台
///     监听系统剪贴板被系统禁止，这是微信输入法也绕不过的硬限制。
///     真正后台无感需要 NE 隧道或越狱 daemon，不在键盘这条路线上。
///
/// 并发门控：`inFlight` 保证一次键盘会话里同一时刻只跑一轮；`lastSeenChangeCount`
/// 跨会话记在 App Group，避免上一轮刚推完的内容这一轮又推一次。
final class KeyboardSyncCoordinator {

    /// 状态条引用。由 KeyboardViewController 在 viewDidLoad 里绑（那时 statusLabel 已创建）。
    /// 不能是 `private`：跨文件赋值需要 internal 可见性。
    weak var statusLabel: UILabel?

    /// 跨会话去重状态，落在 App Group（与主 App 共享），文件名同引擎语义。
    /// 没拿到容器就降级成纯内存（不跨会话去重，但同一会话内仍去重）。
    private let stateFile = "keyboard-sync-state.json"

    private struct SyncState: Codable {
        var lastPushedDigest: String?
        var lastPushedAt: Date?
        var lastPulledRemoteHash: String?
        var lastPulledAt: Date?
    }

    /// 内存兜底：App Group 不可用时用这份（进程存活期内有效）
    private var inMemoryState = SyncState()
    /// 同一刻只跑一轮：键盘唤起频率高，防抖
    private var inFlight = false

    init(statusLabel: UILabel? = nil) {
        self.statusLabel = statusLabel
    }

    // MARK: - 入口

    /// 键盘唤起时调。已开完全访问才会真跑，没开时静默（VC 会在状态条提示）。
    /// 全程不阻塞 UI——`Task.detached` 把活儿丢后台队列，VC 的面板渲染不等它。
    func syncOnAppear(hasFullAccess: Bool) {
        // 这三行是「键盘自动同步究竟跑没跑」的唯一真机证据。
        // 用户的判断方法是：主 App → 诊断 → 键盘日志，看有没有 kbsync 开头的行。
        AppGroupStore.appendKeyboardLog("kbsync enter fullAccess=\(hasFullAccess) inFlight=\(inFlight)")
        guard hasFullAccess else { return }
        guard !inFlight else { return }
        inFlight = true

        Task.detached(priority: .utility) { [weak self] in
            await self?.runOneRound()
            self?.inFlight = false
        }
    }

    // MARK: - 一轮双向同步

    private func runOneRound() async {
        guard let (_, settings) = AppGroupStore.loadConfig() else {
            AppGroupStore.appendKeyboardLog("kbsync skip: App Group 里没有配置（主 App 里先配置并同步一次）")
            return
        }
        let config: SCConfig
        do {
            config = try settings.toConfig()
        } catch {
            AppGroupStore.appendKeyboardLog("kbsync skip: 配置不完整 \(error)")
            return
        }
        let client: SCClient
        do {
            client = try SCClient(config: config)
        } catch {
            AppGroupStore.appendKeyboardLog("kbsync skip: 建客户端失败 \(error)")
            return
        }
        AppGroupStore.appendKeyboardLog("kbsync round: server=\(config.serverType.rawValue)")

        // 先推本地（如果有新内容），再拉远端——顺序上"推先于拉"：
        // 如果先拉，刚写进剪贴板的内容会被这一轮推当成"新内容"又推回去，空转。
        await pushLocalIfChanged(client: client, config: config)
        await pullRemoteIfNewer(client: client, config: config)
    }

    // MARK: - 推方向

    /// 读本地剪贴板，若是图片/文件且与上次推的不同，推上去。
    ///
    /// 判等的依据是 digest（与引擎 classifyLocal 同一套口径）：
    ///   - 文本不在这条路上推（键盘唤起推文本会顶掉用户刚复制的东西，
    ///     而且文本同步主 App 在前台时已经做；键盘只补图片/文件这条缝隙）
    ///   - 图片：I: + 内容 SHA-256
    ///   - 文件：F: + file-url 字节 SHA-256（与引擎一致，已知同名改内容的限制）
    private func pushLocalIfChanged(client: SCClient, config: SCConfig) async {
        var state = loadState()

        // 图片优先于文件（与引擎 classifyLocal 同口径）
        if config.imageSyncEnabled, SCPasteboard.hasImage,
           let payload = SCPasteboard.readImagePayload() {
            let data: Data
            let uti: String
            var isDecoded = false
            switch payload {
            case .raw(let d, let u):
                data = d; uti = u
            case .decoded(let image):
                guard let jpeg = image.jpegData(compressionQuality: 0.9) else { return }
                data = jpeg; uti = "public.jpeg"; isDecoded = true
            }
            // 超限不推（上游也有上限，超了会被拒）
            if data.count > config.maxImageBytes {
                AppGroupStore.appendKeyboardLog("kbsync push img skip: \(data.count) > 上限 \(config.maxImageBytes)")
                return
            }
            let digest = "I:" + SCCrypto.sha256Hex(data)
            if digest == state.lastPushedDigest {
                AppGroupStore.appendKeyboardLog("kbsync push img skip: 与上次推的相同")
                return
            }

            let fileName = "img-\(digest.prefix(16)).\(Self.ext(forUTI: uti))"
            let profile = SCProfile.image(fileName: fileName, content: data)
            do {
                try await client.putFile(dataName: fileName, content: data)
                try await client.putProfile(profile)
                state.lastPushedDigest = digest
                state.lastPushedAt = Date()
                saveState(state)
                AppGroupStore.appendKeyboardLog("kbsync push img ok \(data.count)B \(fileName)")
                await Self.touchStatus(label: statusLabel,
                                       text: "已推送图片\(isDecoded ? "（转码）" : "")")
            } catch {
                AppGroupStore.appendKeyboardLog("kbsync push img FAIL \(error)")
                await Self.touchStatus(label: statusLabel, text: "推送图片失败")
            }
            return
        }

        // 文件引用（M2 的 readCopiedFile 三级兜底）
        if config.fileSyncEnabled, SCPasteboard.hasFileURL {
            // 拿 file-url 字节算 digest 做去重（与引擎一致：不在此刻读真文件）
            guard let urlData = UIPasteboard.general
                    .data(forPasteboardType: SCPasteboard.fileURLUTI),
                  !urlData.isEmpty else { return }
            let digest = "F:" + SCCrypto.sha256Hex(urlData)
            if digest == state.lastPushedDigest {
                AppGroupStore.appendKeyboardLog("kbsync push file skip: 与上次推的相同")
                return
            }

            // 真正拷出文件字节（协调读/直接读兜底），贵，只推时做
            let copied: SCPasteboard.CopiedFile
            do {
                copied = try await SCPasteboard.readCopiedFile(timeout: 15)
            } catch {
                AppGroupStore.appendKeyboardLog("kbsync push file FAIL 读剪贴板: \(error)")
                await Self.touchStatus(label: statusLabel, text: "读剪贴板文件失败")
                return
            }
            defer { try? FileManager.default.removeItem(at: copied.url) }

            let name = copied.suggestedName ?? copied.url.lastPathComponent
            do {
                let data = try Data(contentsOf: copied.url)
                if data.count > config.maxFileBytes {
                    AppGroupStore.appendKeyboardLog("kbsync push file skip: \(data.count) > 上限 \(config.maxFileBytes)")
                    await Self.touchStatus(label: statusLabel, text: "文件超限未推")
                    return
                }
                let profile = SCProfile.fileEntry(fileName: name, content: data)
                try await client.putFile(dataName: name, content: data)
                try await client.putProfile(profile)
                state.lastPushedDigest = digest
                state.lastPushedAt = Date()
                saveState(state)
                AppGroupStore.appendKeyboardLog("kbsync push file ok \(data.count)B \(name) via=\(copied.via)")
                await Self.touchStatus(label: statusLabel, text: "已推送文件 \(name)")
            } catch {
                AppGroupStore.appendKeyboardLog("kbsync push file FAIL \(error)")
                await Self.touchStatus(label: statusLabel, text: "推送文件失败")
            }
            return
        }

        AppGroupStore.appendKeyboardLog("kbsync push: 剪贴板里没有图片/文件（img=\(SCPasteboard.hasImage) file=\(SCPasteboard.hasFileURL)）")
    }

    // MARK: - 拉方向

    /// 拉远端最新，只在远端比上次拉到的新时才写剪贴板。
    ///
    /// "新"的判据是远端 profile 的 normalizedHash——不存内容、跨会话可比。
    /// 不用 transferDataHash（那是单次传输校验，不是内容指纹）。
    private func pullRemoteIfNewer(client: SCClient, config: SCConfig) async {
        var state = loadState()

        let remote: SCProfile
        do {
            remote = try await client.fetchProfile()
        } catch {
            AppGroupStore.appendKeyboardLog("kbsync pull FAIL fetchProfile: \(error)")
            return
        }

        // 远端是空内容或纯文本：键盘不主动覆盖用户剪贴板。
        // （文本同步留给用户点"最新"按钮主动取，避免键盘一弹就把
        //   用户刚复制的文本顶掉。）
        if remote.type == .text && !remote.hasData {
            AppGroupStore.appendKeyboardLog("kbsync pull skip: 远端是文本，键盘不覆盖剪贴板")
            return
        }
        // 图片/文件但没数据：坏数据，跳过
        if remote.type != .text && !remote.hasData {
            AppGroupStore.appendKeyboardLog("kbsync pull skip: 远端 \(remote.type.rawValue) 无数据")
            return
        }

        let remoteFingerprint = remote.normalizedHash
        if remoteFingerprint == (state.lastPulledRemoteHash ?? "") {
            AppGroupStore.appendKeyboardLog("kbsync pull skip: 远端没变")
            return  // 远端没变，别顶用户剪贴板
        }

        guard let dataName = remote.dataName else { return }
        do {
            let data = try await client.getFile(
                dataName: dataName,
                expectedTransferDataHash: remote.transferDataHash)

            if remote.type == .image {
                // 图片写原始字节（不走 UIImage，动图保帧、字节不漂移）
                let uti = SCImageCodec.sniff(data)?.uti ?? UTType.data.identifier
                UIPasteboard.general.setData(data, forPasteboardType: uti)
            } else {
                // 文件：落成临时文件再写 file-url 引用。
                // 直接 setData(UTType.data) 粘出来只是一坨裸字节，不是文件 ——
                // 写 file-url 才能让用户粘进文件 App / 微信 / 任意支持文件的输入框。
                let name = remote.text.isEmpty ? dataName : remote.text
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(name)
                try data.write(to: tmp, options: .atomic)
                if !SCPasteboard.writeFileReference(tmp) {
                    AppGroupStore.appendKeyboardLog("kbsync pull FAIL 写 file-url 被拒 \(name)")
                    await Self.touchStatus(label: statusLabel, text: "拉取文件写剪贴板失败")
                    return
                }
            }

            state.lastPulledRemoteHash = remoteFingerprint
            state.lastPulledAt = Date()
            saveState(state)
            let kind = remote.type == .image ? "图片" : "文件"
            AppGroupStore.appendKeyboardLog("kbsync pull ok \(kind) \(data.count)B")
            await Self.touchStatus(label: statusLabel, text: "已拉取最新\(kind)")
        } catch {
            AppGroupStore.appendKeyboardLog("kbsync pull FAIL \(error)")
            await Self.touchStatus(label: statusLabel, text: "拉取远端失败")
        }
    }

    // MARK: - 状态持久化

    private func loadState() -> SyncState {
        guard let dir = AppGroupStore.containerURL else {
            return inMemoryState
        }
        let url = dir.appendingPathComponent(stateFile)
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(SyncState.self, from: data)
        else { return inMemoryState }
        return s
    }

    private func saveState(_ s: SyncState) {
        inMemoryState = s
        guard let dir = AppGroupStore.containerURL else { return }
        let url = dir.appendingPathComponent(stateFile)
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - 小工具

    /// UTI → 扩展名（给上传文件名用，服务器只拿名字当 key）
    private static func ext(forUTI uti: String) -> String {
        switch uti {
        case "public.png": return "png"
        case "public.jpeg": return "jpg"
        case "com.compuserve.gif": return "gif"
        case "public.heic": return "heic"
        case "public.heif": return "heif"
        case "public.tiff": return "tiff"
        default: return "bin"
        }
    }

    /// 状态条更新回到主线程（键盘扩展的 UI 操作必须在主线程）
    @MainActor
    private static func touchStatus(label: UILabel?, text: String) {
        label?.text = text
    }
}
