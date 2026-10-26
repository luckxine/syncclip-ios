#if canImport(UIKit)
import Foundation
import UIKit
import UniformTypeIdentifiers

/// 系统剪贴板封装。
///
/// 无提示读写依赖二进制上的这组 entitlement（见 syncclipd.entitlements）：
///   com.apple.private.webkit.pasteboard
///   com.apple.private.pasteboard.check-pasteboard
///   com.apple.Pasteboard.background-access
///   com.apple.Pasteboard.paste-unchecked
///
/// 重要：**必须以 mobile（用户域）身份运行**。pasteboardd 是每用户的 launchd 服务，
/// root 的系统域进程连不上它，会表现为「读到空」。所以守护进程走 LaunchAgent。
public enum SCPasteboard {

    // MARK: - 文本

    /// 当前剪贴板文本。读不到（非文本内容等）返回 nil。
    public static func readText() -> String? {
        let pb = UIPasteboard.general
        // 用 string 而不是 strings：空剪贴板/非文本内容时 strings 可能给出空数组
        guard let s = pb.string, !s.isEmpty else { return nil }
        return s
    }

    /// 写入文本。
    @discardableResult
    public static func writeText(_ text: String) -> Bool {
        let pb = UIPasteboard.general
        pb.string = text
        return true
    }

    // MARK: - 图片

    /// 图片字节可能挂在剪贴板上的 UTI，按优先级探测。
    /// 截图=png，相册=heic，Safari/微信=jpeg 或 gif，网页拷贝偶尔给 tiff。
    public static let imageUTICandidates = [
        "public.png", "public.jpeg", "com.compuserve.gif",
        "public.heic", "public.heif", "public.tiff"
    ]

    /// 从剪贴板读图片。
    ///
    /// 返回形态有两种，语义完全不同（引擎按此分派）：
    ///   - raw：拿到了原始字节 —— 首选，GIF 保动图、字节不漂移；
    ///   - decoded：原始字节拿不到（个别来源只提供解码后的 UIImage）——
    ///     兜底可用，但系统已替你转码过（动图丢帧），引擎推送时会在日志里注明。
    public enum ImagePayload {
        case raw(data: Data, uti: String)
        case decoded(UIImage)
    }

    public static func readImagePayload() -> ImagePayload? {
        let pb = UIPasteboard.general
        for uti in imageUTICandidates {
            if let data = pb.data(forPasteboardType: uti), !data.isEmpty {
                return .raw(data: data, uti: uti)
            }
        }
        // 兜底：个别来源不带任何标准 UTI 字节，但系统愿意给解码后的图
        if pb.hasImages, let image = pb.image {
            return .decoded(image)
        }
        return nil
    }

    /// 把图片**原始字节**写进剪贴板。
    ///
    /// 刻意 setData 而不是写 UIImage：写 UIImage 系统会转成 PNG，
    /// 动图丢帧、字节漂移，服务器端的 hash 对不上（设计稿 §4.1）。
    @discardableResult
    public static func writeImage(data: Data, uti: String) -> Bool {
        UIPasteboard.general.setData(data, forPasteboardType: uti)
        return true
    }

    /// 剪贴板里是否含有图片
    public static var hasImage: Bool {
        let pb = UIPasteboard.general
        if pb.types.contains(where: { imageUTICandidates.contains($0) }) { return true }
        return pb.hasImages
    }

    // MARK: - 文件引用

    public static let fileURLUTI = UTType.fileURL.identifier

    /// 剪贴板里是否含有文件引用
    public static var hasFileURL: Bool {
        UIPasteboard.general.types.contains(fileURLUTI)
    }

    public enum FileError: Error, CustomStringConvertible {
        case noFileItem
        case loadFailed(String)
        case timedOut

        public var description: String {
            switch self {
            case .noFileItem:
                return "剪贴板里没有文件（先去文件 App 长按文件 → 拷贝）"
            case .loadFailed(let why):
                return "读取文件失败：\(why)"
            case .timedOut:
                return "读取文件超时（15 秒）"
            }
        }
    }

    /// 从剪贴板拷贝出的文件副本。
    public struct CopiedFile {
        /// 已拷进本 App 临时目录的副本 —— 系统给的临时 URL 在回调返回后即失效，
        /// 所以必须先拷走，这个 URL 才是真正可用的。
        public let url: URL
        public let suggestedName: String?
        /// 这条副本是哪条路读出来的（探针/日志用，直接读字节的兜底链见实现）
        public let via: String
    }

    /// 读「文件 App 里拷贝的文件」。
    ///
    /// iOS 15.5 没有 `UIPasteboard.itemProviders`（那是 iOS 16 的 API），
    /// 所以路径是三级兜底，哪级通了就在返回值里注明 —— M0 的 P2 探针
    /// 就是为了在真机上把这三级的真实可用性钉死：
    ///   1. `public.file-url` 字节 → URL → NSFileCoordinator 协调读（对文件 App 来源最正）
    ///   2. 同一 URL 直接读（部分来源的 URL 本身就在可读位置）
    ///   3. iOS 16+ 才有的 itemProviders + loadFileRepresentation（给未来系统留的）
    public static func readCopiedFile(timeout: TimeInterval = 15) async throws -> CopiedFile {
        let pb = UIPasteboard.general

        if let copied = try await readViaFileURLData(timeout: timeout) {
            return copied
        }

        if #available(iOS 16, *) {
            return try await readViaItemProviders(timeout: timeout)
        }

        throw FileError.noFileItem
    }

    /// 路径 1/2：剪贴板里的 public.file-url 字节解析成 URL，再想办法把字节读出来
    private static func readViaFileURLData(timeout: TimeInterval) async throws -> CopiedFile? {
        guard let data = UIPasteboard.general.data(forPasteboardType: fileURLUTI),
              let url = URL(dataRepresentation: data, relativeTo: nil) else {
            return nil
        }

        // 先试协调读：文件 App 拷出的 URL 常在 file provider 域里，
        // 直接读会被沙盒挡，协调读是系统给「别人拷给我的文件」的正门。
        if let copied = await coordinatedCopy(of: url, timeout: timeout, via: "file-url+协调读") {
            return copied
        }
        // 再试直接读：部分来源（以及其他 App 的部分场景）URL 本身可读
        if let copied = try? directCopy(of: url, via: "file-url+直接读") {
            return copied
        }
        return nil
    }

    /// 路径 3：iOS 16+ 的 itemProviders。15.5 上走不到，留着是给将来换机用的。
    @available(iOS 16, *)
    private static func readViaItemProviders(timeout: TimeInterval) async throws -> CopiedFile {
        guard let provider = UIPasteboard.general.itemProviders
            .first(where: { $0.hasItemConformingToTypeIdentifier(fileURLUTI) }) else {
            throw FileError.noFileItem
        }
        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            let work = DispatchWorkItem {
                guard !resumed else { return }
                resumed = true
                cont.resume(throwing: FileError.timedOut)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
            provider.loadFileRepresentation(forTypeIdentifier: fileURLUTI) { url, error in
                work.cancel()
                guard !resumed else { return }
                resumed = true
                if let error {
                    cont.resume(throwing: FileError.loadFailed(error.localizedDescription))
                    return
                }
                guard let url else {
                    cont.resume(throwing: FileError.loadFailed("系统没有给出文件"))
                    return
                }
                do {
                    let dest = Self.tempCopyDestination(for: url)
                    try FileManager.default.copyItem(at: url, to: dest)
                    cont.resume(returning: CopiedFile(url: dest,
                                                      suggestedName: provider.suggestedName,
                                                      via: "itemProviders"))
                } catch {
                    cont.resume(throwing: FileError.loadFailed("\(error)"))
                }
            }
        }
    }

    /// NSFileCoordinator 协调读：把别人域里的文件按规矩借出来拷一份。
    private static func coordinatedCopy(of url: URL, timeout: TimeInterval, via: String) async -> CopiedFile? {
        await withCheckedContinuation { (cont: CheckedContinuation<CopiedFile?, Never>) in
            var coordinationError: NSError?
            let coordinator = NSFileCoordinator()
            var resumed = false
            let work = DispatchWorkItem {
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: nil)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)

            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { src in
                guard !resumed else { return }
                do {
                    let dest = Self.tempCopyDestination(for: src)
                    try FileManager.default.copyItem(at: src, to: dest)
                    work.cancel()
                    guard !resumed else { return }
                    resumed = true
                    cont.resume(returning: CopiedFile(url: dest,
                                                       suggestedName: url.lastPathComponent,
                                                       via: via))
                } catch {
                    work.cancel()
                    guard !resumed else { return }
                    resumed = true
                    cont.resume(returning: nil)
                }
            }
            if coordinationError != nil {
                work.cancel()
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: nil)
            }
        }
    }

    private static func directCopy(of url: URL, via: String) throws -> CopiedFile {
        let dest = tempCopyDestination(for: url)
        try FileManager.default.copyItem(at: url, to: dest)
        return CopiedFile(url: dest, suggestedName: url.lastPathComponent, via: via)
    }

    private static func tempCopyDestination(for source: URL) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("copied-\(UUID().uuidString.prefix(8))-\(source.lastPathComponent)")
    }

    /// 把「收件箱里的文件」写进剪贴板（写的是 file-url 引用，不是字节）。
    ///
    /// 置信中等 —— 跨 App 能不能粘出文件由 M0 的 P3 探针真机验证，
    /// 验证通过前 UI 不暴露此开关（设计稿 §4.2）。
    @discardableResult
    public static func writeFileReference(_ url: URL) -> Bool {
        UIPasteboard.general.setItems([[fileURLUTI: url.dataRepresentation]])
        return true
    }

    // MARK: - 变更检测

    /// 剪贴板变更计数。**这是变更检测的首选手段**：它由 pasteboardd 维护，
    /// 每次写入都会 +1，读它不需要额外权限，也不受内容类型影响。
    /// 比「读内容再比字符串」更可靠，而且不会因为系统弹「允许粘贴」而失败。
    public static var changeCount: Int {
        UIPasteboard.general.changeCount
    }

    /// 剪贴板里是否含有文本
    public static var hasText: Bool {
        UIPasteboard.general.hasStrings
    }

    // MARK: - 诊断

    /// 剪贴板里有哪些 UTI（用于 CLI 诊断，不参与同步逻辑）
    public static var typeIdentifiers: [String] {
        UIPasteboard.general.types
    }

    /// 每个 item 每个 UTI 的字节数 —— M0 探针 P0：看清「拷贝一张图」之后
    /// 剪贴板里到底放了什么，比任何文档都准。
    public static func itemDump() -> [(uti: String, bytes: Int)] {
        var out: [(uti: String, bytes: Int)] = []
        for item in UIPasteboard.general.items {
            for (uti, value) in item.sorted(by: { $0.key < $1.key }) {
                let bytes = (value as? Data)?.count ?? -1
                out.append((uti, bytes))
            }
        }
        return out
    }
}
#endif
