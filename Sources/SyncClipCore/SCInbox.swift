import Foundation

/// 收件箱：文件类同步（M2 单文件 / M3 Group）在本机落地的唯一去处。
///
/// 为什么放 `Documents/Inbox/`：Info.plist 开了 UIFileSharingEnabled 之后，
/// 文件 App → 我的 iPhone → syncclip → Inbox 直接可见，Windows 推来的文件
/// 用户零操作就能拿到（设计稿 §4.2 的主路径，不依赖任何「实验开关」）。
///
/// 两条铁律：
///   - `save` 永不覆盖：剪贴板 file-url 引用（write-then-provide 语义）指向
///     落盘文件，覆盖会悄悄毁掉别的 App 剪贴板里还挂着的引用
///   - 所有来自远端的名字（dataName）先剥掉路径成分再用 —— dataName 是
///     不可信输入，`../evil.zip` 这类不允许在收件箱外面长出任何东西
public final class SCInbox {

    public static let shared = SCInbox()

    // MARK: - 条目模型

    public struct InboxItem: Equatable {
        /// inbox 内的唯一标识（顶层文件/目录名）。用它而不是绝对路径，
        /// 重装/迁移容器后 UI 的选中态不至于指错地方
        public let id: String
        public let url: URL
        public let name: String
        public let isDirectory: Bool
        /// 文件为自身大小；目录为递归总大小
        public let size: Int64
        public let addedAt: Date
    }

    public enum InboxError: Error, CustomStringConvertible {
        case emptyArchive
        case writeFailed(String)

        public var description: String {
            switch self {
            case .emptyArchive: return "zip 里没有任何文件"
            case .writeFailed(let why): return "写入收件箱失败：\(why)"
            }
        }
    }

    // MARK: - 目录

    private let directory: URL

    /// Documents 不可用（极少数 MDM/越狱环境）时退到临时目录 —— 收件箱宁可
    /// 少活一会儿，也不能让同步引擎因为落不了盘而整轮报错。
    public static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// 单例给引擎与 UI 用；自定义目录留给测试/预览。
    public init(directory inboxDirectory: URL? = nil) {
        self.directory = inboxDirectory
            ?? Self.documentsDirectory.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory,
                                                 withIntermediateDirectories: true)
    }

    public var inboxDirectory: URL { directory }

    // MARK: - 落盘

    /// 存一个文件，返回真实写入的 URL。重名自动加序号（`a.txt` → `a 2.txt`），
    /// 从不覆盖已有文件。
    public func save(data: Data, name rawName: String) throws -> URL {
        let name = Self.sanitized(rawName)
        let target = directory.appendingPathComponent(uniqueName(for: name))
        do {
            try data.write(to: target, options: .atomic)
        } catch {
            throw InboxError.writeFailed("\(name)：\(error)")
        }
        return target
    }

    /// 把远端 Group 的 zip 解到 `Inbox/{zip 名去扩展}/`，返回目录 URL。
    ///
    /// 目标目录已存在时先删再解：重复拉同一个 Group 是幂等覆盖，收件箱不堆
    /// 副本。敢直接删的前提是 file-url 引用只指向 `save` 落的单文件（永不
    /// 覆盖），Group 目录从不是引用目标。
    public func extractGroup(zipData: Data, zipName rawName: String) throws -> URL {
        let base = Self.sanitized(rawName)
        var stem = (base as NSString).deletingPathExtension
        if stem.isEmpty { stem = "Group" }
        let target = directory.appendingPathComponent(stem, isDirectory: true)

        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        do {
            let written = try SCZip.extract(zipData, to: target)
            if written.isEmpty {
                // 空 zip 属于坏数据：目录都不留，免得收件箱里出现僵尸空文件夹
                try? fm.removeItem(at: target)
                throw InboxError.emptyArchive
            }
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
        return target
    }

    // MARK: - 列表 / 删除 / 清理

    /// 收件箱顶层条目（新的在前）。Group 解出的目录算一条，展开是 UI 的事。
    public func items() -> [InboxItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey,
                                      .contentModificationDateKey]
        guard let children = try? fm.contentsOfDirectory(at: directory,
                                                         includingPropertiesForKeys: keys) else {
            return []
        }
        return children
            .filter { !$0.lastPathComponent.hasPrefix(".") }   // .DS_Store 等杂物不展示
            .map { url -> InboxItem in
                let rv = try? url.resourceValues(forKeys: [.isDirectoryKey,
                                                           .creationDateKey,
                                                           .contentModificationDateKey])
                let isDir = rv?.isDirectory ?? false
                return InboxItem(id: url.lastPathComponent,
                                 url: url,
                                 name: url.lastPathComponent,
                                 isDirectory: isDir,
                                 size: Self.size(of: url, isDirectory: isDir),
                                 addedAt: rv?.creationDate
                                     ?? rv?.contentModificationDate
                                     ?? Date())
            }
            .sorted { $0.addedAt > $1.addedAt }
    }

    /// 删除一条（文件或目录都行）。返回 false 表示没删掉（不存在/没权限）。
    @discardableResult
    public func remove(_ item: InboxItem) -> Bool {
        // id 按顶层名重建目标，防外部构造的 InboxItem 把删除指到收件箱外面
        let target = directory.appendingPathComponent(item.id).standardizedFileURL
        guard target.path.hasPrefix(directory.standardizedFileURL.path) else { return false }
        do {
            try FileManager.default.removeItem(at: target)
            return true
        } catch {
            return false
        }
    }

    /// 清掉超龄条目，返回删除数目。
    ///
    /// `excluding`：file-url 还挂在剪贴板上的文件绝不能删（write-then-provide
    /// 语义，设计稿 §4.2）。收件箱自己不知道剪贴板的事，由调用方把要保护的
    /// URL 传进来 —— 引擎在写 file-url 的那一刻起就该把这些文件视为长寿。
    @discardableResult
    public func cleanup(olderThanDays days: Int, excluding: [URL] = []) -> Int {
        guard days >= 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let protectedPaths = Set(excluding.map { $0.standardizedFileURL.path })
        var removed = 0
        for item in items() where item.addedAt < cutoff {
            if protectedPaths.contains(item.url.standardizedFileURL.path) { continue }
            if remove(item) { removed += 1 }
        }
        return removed
    }

    // MARK: - 内部

    /// 任何来自远端的名字都先剥成裸文件名：split 空结果（纯路径串）退 "file"。
    private static func sanitized(_ raw: String) -> String {
        let last = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last
        let name = last.map(String.init) ?? ""
        return name.isEmpty ? "file" : name
    }

    /// `a.txt` → `a.txt` / `a 2.txt` / `a 3.txt`…（文件 App 重复项的同款风格）
    private func uniqueName(for name: String) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.appendingPathComponent(name).path) else {
            return name
        }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for n in 2...1000 {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
                return candidate
            }
        }
        // 千个同名文件：真走到这步说明有人在拿收件箱当垃圾桶，直接用 UUID 兜底
        let extPart = ext.isEmpty ? "" : ".\(ext)"
        return UUID().uuidString + extPart
    }

    private static func size(of url: URL, isDirectory: Bool) -> Int64 {
        if !isDirectory {
            let rv = try? url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(rv?.fileSize ?? 0)
        }
        var total: Int64 = 0
        if let en = FileManager.default.enumerator(at: url,
                                                   includingPropertiesForKeys: [.fileSizeKey]) {
            for case let child as URL in en {
                let rv = try? child.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                if rv?.isDirectory != true {
                    total += Int64(rv?.fileSize ?? 0)
                }
            }
        }
        return total
    }
}
