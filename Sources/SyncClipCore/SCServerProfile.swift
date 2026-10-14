import Foundation

/// 服务器类型。
///
/// 三种后端**用的是同一套对象布局**（`SyncClipboard.json` + `file/` 目录），
/// 所以协议层（JSON 模型、hash 算法、双向状态机）可以完全复用，
/// 只在传输层分叉。这也正是上游 SyncClipboard 桌面端与 Xposed 模块的做法。
public enum SCServerType: String, Codable, CaseIterable, Identifiable {
    /// SyncClipboard 官方 HTTP 服务器（自建 SyncClipboard.Server / 桌面端内置服务器）
    case syncclipboard
    /// WebDAV 存储（坚果云、Nextcloud、群晖、自建 WebDAV 等）
    case webdav
    /// S3 兼容对象存储（AWS S3、MinIO、Cloudflare R2、阿里云 OSS 的 S3 兼容模式等）
    case s3

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .syncclipboard: return "SyncClipboard 服务器"
        case .webdav: return "WebDAV"
        case .s3: return "S3 兼容存储"
        }
    }

    /// 列表里那个小徽章上的短标签
    public var badge: String {
        switch self {
        case .syncclipboard: return "SC"
        case .webdav: return "DAV"
        case .s3: return "S3"
        }
    }

    public var iconName: String {
        switch self {
        case .syncclipboard: return "server.rack"
        case .webdav: return "externaldrive.connected.to.line.below"
        case .s3: return "shippingbox"
        }
    }

    public var blurb: String {
        switch self {
        case .syncclipboard:
            return "自建 SyncClipboard.Server，或桌面客户端里开的内置服务器。支持历史记录与版本查询。"
        case .webdav:
            return "任何标准 WebDAV 空间。上手最快，坚果云、Nextcloud、群晖都行。"
        case .s3:
            return "S3 兼容对象存储。适合已经有对象存储或想走云厂商的人。"
        }
    }

    /// 连接地址该填什么样的例子，直接用作输入框的占位符
    public var urlPlaceholder: String {
        switch self {
        case .syncclipboard: return "http://192.168.1.10:5033"
        case .webdav: return "https://dav.jianguoyun.com/dav/我的同步目录"
        case .s3: return "https://s3.us-east-1.amazonaws.com（留空用 AWS 默认）"
        }
    }

    /// 用户名这一栏的语义（S3 里它是 Access Key ID）
    public var usernameLabel: String {
        switch self {
        case .syncclipboard: return "用户名"
        case .webdav: return "用户名"
        case .s3: return "Access Key ID"
        }
    }

    public var passwordLabel: String {
        switch self {
        case .syncclipboard: return "密码"
        case .webdav: return "密码"
        case .s3: return "Secret Access Key"
        }
    }

    /// 该类型下 url 这个字段是不是必填
    public var urlIsRequired: Bool {
        // S3 可以留空走 AWS 默认端点（https://s3.<region>.amazonaws.com）
        self != .s3
    }
}

/// 一条服务器配置。
///
/// 刻意做成 `Codable` 且字段可缺省：配置文件是给人用 Filza 改的，
/// 老版本写的文件缺新字段是常态，不能因为多了个字段就读不出来。
public struct SCServerProfile: Codable, Hashable, Identifiable {

    public var id: String
    public var type: SCServerType
    /// 显示名称。留空时界面上用 host 兜底显示。
    public var name: String
    public var url: String
    public var username: String
    public var password: String

    // ---- 仅 S3 用 ----
    public var region: String
    public var bucketName: String
    public var objectPrefix: String
    /// 路径风格寻址。自建 MinIO 之类通常需要打开。
    public var forcePathStyle: Bool

    public init(id: String = UUID().uuidString,
                type: SCServerType = .syncclipboard,
                name: String = "",
                url: String = "",
                username: String = "",
                password: String = "",
                region: String = "us-east-1",
                bucketName: String = "",
                objectPrefix: String = "",
                forcePathStyle: Bool = false) {
        self.id = id
        self.type = type
        self.name = name
        self.url = url
        self.username = username
        self.password = password
        self.region = region
        self.bucketName = bucketName
        self.objectPrefix = objectPrefix
        self.forcePathStyle = forcePathStyle
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        let rawType = try c.decodeIfPresent(String.self, forKey: .type) ?? SCServerType.syncclipboard.rawValue
        type = SCServerType(rawValue: rawType) ?? .syncclipboard
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        region = try c.decodeIfPresent(String.self, forKey: .region) ?? "us-east-1"
        bucketName = try c.decodeIfPresent(String.self, forKey: .bucketName) ?? ""
        objectPrefix = try c.decodeIfPresent(String.self, forKey: .objectPrefix) ?? ""
        forcePathStyle = try c.decodeIfPresent(Bool.self, forKey: .forcePathStyle) ?? false
    }

    // MARK: - 显示

    /// 列表里显示的标题：优先自定义名称，其次 host，再其次类型名
    public var displayTitle: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { return n }
        if let host = hostString { return host }
        return type.displayName
    }

    /// 列表里显示的副标题：类型 + 位置
    public var displaySubtitle: String {
        switch type {
        case .s3:
            let bucket = bucketName.trimmingCharacters(in: .whitespacesAndNewlines)
            let endpoint = hostString ?? "AWS 默认端点"
            return bucket.isEmpty ? endpoint : "\(bucket) · \(endpoint)"
        default:
            return hostString ?? url
        }
    }

    public var hostString: String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let u = URL(string: trimmed), let h = u.host {
            if let port = u.port { return "\(h):\(port)" }
            return h
        }
        return trimmed
    }

    // MARK: - 校验

    public enum ValidationError: Error, CustomStringConvertible, Equatable {
        case missingURL
        case badURL(String)
        case missing(String)

        public var description: String {
            switch self {
            case .missingURL:
                return "还没填服务器地址"
            case .badURL(let raw):
                return "地址不合法：\(raw)（要带 http:// 或 https:// 前缀）"
            case .missing(let what):
                return "还没填 \(what)"
            }
        }
    }

    /// 逐项校验。返回第一个问题，没有则抛 nil。
    public func validate() throws {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)

        if type.urlIsRequired {
            guard !u.isEmpty else { throw ValidationError.missingURL }
            guard let parsed = URL(string: u), parsed.scheme != nil, parsed.host != nil else {
                throw ValidationError.badURL(u)
            }
        } else if !u.isEmpty {
            // S3 允许留空（走 AWS 默认端点），但填了就必须合法
            guard let parsed = URL(string: u), parsed.scheme != nil, parsed.host != nil else {
                throw ValidationError.badURL(u)
            }
        }

        switch type {
        case .syncclipboard, .webdav:
            guard !username.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ValidationError.missing(type.usernameLabel)
            }
            guard !password.isEmpty else {
                throw ValidationError.missing(type.passwordLabel)
            }
        case .s3:
            guard !bucketName.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ValidationError.missing("存储桶名称")
            }
            guard !username.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ValidationError.missing(type.usernameLabel)
            }
            guard !password.isEmpty else {
                throw ValidationError.missing(type.passwordLabel)
            }
        }
    }

    public var isComplete: Bool { (try? validate()) != nil }

    /// 转成传输层要的配置
    public func toConfig() throws -> SCConfig {
        try validate()
        return SCConfig(profile: self)
    }
}
