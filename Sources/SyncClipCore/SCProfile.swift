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
        let rawType = try c.decodeIfPresent(String.self, forKey: .type) ?? "Text"
        self.type = Kind(rawValue: rawType) ?? .text
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
