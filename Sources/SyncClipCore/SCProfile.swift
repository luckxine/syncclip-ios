import Foundation

/// 对应服务端的 ProfileDto。
///
/// 反序列化刻意手写：服务端会**省略**为 null 的可选字段（transferDataHash / size / syncedAt），
/// 甚至可能整段缺字段，用编译器合成的 Codable 会因为缺少非可选 key 直接抛错。
/// 这里全部走 decodeIfPresent + 默认值。
public struct SCProfile: Codable, Equatable {

    public enum Kind: String, Codable {
        case text = "Text"
        case image = "Image"
        case file = "File"
        case group = "Group"
    }

    public var type: Kind
    public var hash: String
    public var text: String
    public var hasData: Bool
    public var dataName: String?
    public var transferDataHash: String?
    public var size: Int64?
    public var syncedAt: String?

    public init(type: Kind = .text,
                hash: String = "",
                text: String = "",
                hasData: Bool = false,
                dataName: String? = nil,
                transferDataHash: String? = nil,
                size: Int64? = nil,
                syncedAt: String? = nil) {
        self.type = type
        self.hash = hash
        self.text = text
        self.hasData = hasData
        self.dataName = dataName
        self.transferDataHash = transferDataHash
        self.size = size
        self.syncedAt = syncedAt
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type, hash, text, hasData, dataName, transferDataHash, size, syncedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.type = SCProfile.decodeKind(from: c)
        self.hash = try c.decodeIfPresent(String.self, forKey: .hash) ?? ""
        self.text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.hasData = try c.decodeIfPresent(Bool.self, forKey: .hasData) ?? false
        self.dataName = try c.decodeIfPresent(String.self, forKey: .dataName)
        self.transferDataHash = try c.decodeIfPresent(String.self, forKey: .transferDataHash)
        self.size = try c.decodeIfPresent(Int64.self, forKey: .size)
        self.syncedAt = try c.decodeIfPresent(String.self, forKey: .syncedAt)

        // 容错：hasData=true 但没有 dataName 属于坏数据，降级成内联文本处理
        if self.hasData && (self.dataName?.isEmpty ?? true) {
            self.hasData = false
            self.dataName = nil
        }
    }

    /// 宽容地解出 type。
    ///
    /// 两种形态都得认，而且不能因为一个字段解不出来就丢掉整条消息：
    ///   - 字符串 "Text"（服务端 DTO 上挂了 JsonStringEnumConverter，常见形态）
    ///   - 数字 0/1/2/3（SignalR 的序列化配置与 MVC 不共享，完全可能吐数字）
    ///
    /// 数字顺序照服务端 `ProfileType` 的声明：**Text=0、File=1、Image=2、Group=3**
    /// （注意 File 在 Image 前面 —— 这个顺序是从源码里核对过的，不是猜的）。
    private static func decodeKind(from c: KeyedDecodingContainer<CodingKeys>) -> Kind {
        if let s = try? c.decodeIfPresent(String.self, forKey: .type), let kind = Kind(rawValue: s) {
            return kind
        }
        if let n = try? c.decodeIfPresent(Int.self, forKey: .type) {
            switch n {
            case 0: return .text
            case 1: return .file
            case 2: return .image
            case 3: return .group
            default: break
            }
        }
        // 小写形态也认一下（有些实现会这么写）
        if let s = try? c.decodeIfPresent(String.self, forKey: .type) {
            let normalized = s.prefix(1).uppercased() + s.dropFirst().lowercased()
            if let kind = Kind(rawValue: normalized) { return kind }
        }
        return .text
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type.rawValue, forKey: .type)
        try c.encode(hash, forKey: .hash)
        try c.encode(text, forKey: .text)
        try c.encode(hasData, forKey: .hasData)
        if let dataName { try c.encode(dataName, forKey: .dataName) }
        if let transferDataHash { try c.encode(transferDataHash, forKey: .transferDataHash) }
        if let size { try c.encode(size, forKey: .size) }
        if let syncedAt { try c.encode(syncedAt, forKey: .syncedAt) }
    }

    // MARK: - 构造与 hash

    /// v1 只发内联文本（hasData=false），文本不长时这是服务端官方客户端也用的形态。
    public static func text(_ body: String) -> SCProfile {
        SCProfile(type: .text,
                  hash: textHash(body),
                  text: body,
                  hasData: false,
                  dataName: nil,
                  transferDataHash: nil,
                  size: Int64(body.utf8.count),
                  syncedAt: nil)
    }

    public static func textHash(_ body: String) -> String {
        SCCrypto.sha256Hex(body)
    }

    /// FileProfile / ImageProfile 的 hash：SHA256(UTF8("文件名|大写内容SHA256"))
    public static func fileHash(fileName: String, content: Data) -> String {
        let inner = SCCrypto.sha256Hex(content)
        return SCCrypto.sha256Hex("\(fileName)|\(inner)")
    }

    /// 图片 profile：文件必须已经在服务器上（先 putFile 再 putProfile，顺序反了 404）。
    /// text 字段按上游约定存文件名。
    public static func image(fileName: String, content: Data) -> SCProfile {
        attachment(type: .image, fileName: fileName, content: content)
    }

    /// 单文件 profile（M2）。与图片共用 attachment 形状：text 存文件名，
    /// dataName 就是原文件名（上游 FileProfile.ToProfileDto 的约定）。
    public static func fileEntry(fileName: String, content: Data) -> SCProfile {
        attachment(type: .file, fileName: fileName, content: content)
    }

    /// Group profile（M3）：多文件打成一个 zip 作为传输体。
    ///
    /// text = 文件名清单 `\n` 连接（上游 GetDisplayText 的形态，收件箱页直接拿它展示）；
    /// dataName = zip 名；transferDataHash = zip 字节的 SHA-256。
    /// hash 必须由调用方传入**按各文件真实字节算出的 groupHash** ——
    /// 它是跨客户端判等（「远端和我本地是不是同一批文件」）的唯一依据，
    /// Windows 端对同一批文件会算出同样的值；拿 zip 内容 hash 顶替的话，
    /// 对端每次都会当成新内容重复下载甚至回推，直接破坏互通。
    ///
    /// size 记 zip 字节数（STORE 打包下与文件总和只差 zip 头部开销）。
    /// 上游 DTO 的 Size 语义是「文件字节数之和」，接收方只用它做展示与
    /// 超限判断，两种口径在 15MB 上限下不产生行为差异 —— 已知轻微偏差。
    public static func group(zipName: String,
                            fileNames: [String],
                            content: Data,
                            groupHash hash: String) -> SCProfile {
        SCProfile(type: .group,
                  hash: hash,
                  text: fileNames.joined(separator: "\n"),
                  hasData: true,
                  dataName: zipName,
                  transferDataHash: SCCrypto.sha256Hex(content),
                  size: Int64(content.count),
                  syncedAt: nil)
    }

    // MARK: - Group hash（docs/Hash.md §3，与上游逐条对齐）

    /// GroupProfile 的 profile hash。调用方负责把 entry 准备成规范形态：
    /// path 是相对根的路径、分隔符统一 `/`、目录以 `/` 结尾。
    ///
    /// 与上游 docs/Hash.md §3 的逐条对应（上游实现在 GroupProfile.CaclHashAndSize
    /// + GroupEntry.ToEntryStringAsync，两边都核对过）：
    ///
    ///   §3.1 entry 收集：上游以输入文件的父目录为根取相对路径，分隔符统一 `/`，
    ///        目录 EntryName 以 `/` 结尾 —— 本函数不重复做这件事（引擎侧只有
    ///        扁平文件清单，天然满足；将来支持文件夹时由收集方构造好再传入）
    ///
    ///   §3.2 排序：按 EntryName 的 **UTF-8 字节数组** 字典序升序。
    ///        刻意不用 Swift String 的 `<`（那是 Unicode 规范等价比较，
    ///        组合字符的不同写法会被判相等），`utf8.lexicographicallyPrecedes`
    ///        才是逐字节比较，与上游 ByteArrayComparer 一致
    ///
    ///   §3.3 每条 entry 的 hash 输入串（`\0` = 单个 0x00 字节，UTF-8 编码后占 1 字节）：
    ///        目录：`D|{entryName}\0`
    ///        文件：`F|{entryName}|{length}|{contentHash 大写hex}\0`
    ///        文件的 contentHash 为空时上游输出空串（GroupEntry.HashTask 为 null
    ///        → string.Empty），这里照抄 `(sha256 ?? "")` 的行为
    ///
    ///   §3.4 哈希：全部 entry 输入串按序拼接 → UTF-8 → SHA-256 → 大写 hex
    ///        （SCCrypto.sha256Hex 已是大写）
    ///
    /// entry 为空时结果是 SHA256("")，与上游「无输入文件」分支一致。
    public static func groupHash(entries: [(path: String,
                                            isDirectory: Bool,
                                            size: Int64,
                                            sha256: String?)]) -> String {
        let ordered = entries.sorted {
            $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
        }
        var combined = Data()
        for e in ordered {
            let line: String
            if e.isDirectory {
                line = "D|\(e.path)\0"
            } else {
                let contentHash = (e.sha256 ?? "").uppercased()
                line = "F|\(e.path)|\(e.size)|\(contentHash)\0"
            }
            combined.append(contentsOf: line.utf8)
        }
        return SCCrypto.sha256Hex(combined)
    }

    private static func attachment(type: Kind, fileName: String, content: Data) -> SCProfile {
        SCProfile(type: type,
                  hash: fileHash(fileName: fileName, content: content),
                  text: fileName,
                  hasData: true,
                  dataName: fileName,
                  transferDataHash: SCCrypto.sha256Hex(content),
                  size: Int64(content.count),
                  syncedAt: nil)
    }

    /// 内容唯一标识（协议规定大小写不敏感比较，这里统一成大写）
    public var normalizedHash: String { hash.uppercased() }

    /// 给日志/CLI 看的短摘要
    public var summary: String {
        let preview: String
        if text.count > 60 {
            preview = String(text.prefix(60)) + "…"
        } else {
            preview = text
        }
        let escaped = preview
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "type=\(type.rawValue) hasData=\(hasData) size=\(size ?? Int64(text.utf8.count)) hash=\(hash.prefix(12))… text=\"\(escaped)\""
    }
}
