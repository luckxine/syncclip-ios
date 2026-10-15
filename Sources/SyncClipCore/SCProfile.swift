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
