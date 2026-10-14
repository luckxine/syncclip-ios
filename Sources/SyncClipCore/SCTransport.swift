import Foundation

/// 连通性探测结果
public struct SCProbeResult: Equatable {
    public var reachable: Bool
    /// 只有 SyncClipboard 官方服务器有版本接口；其余类型为 nil
    public var version: String?
    public var message: String

    public init(reachable: Bool, version: String? = nil, message: String) {
        self.reachable = reachable
        self.version = version
        self.message = message
    }
}

/// 传输层。
///
/// 三种服务器类型共用同一套对象布局（`SyncClipboard.json` + `file/`），
/// 所以上层（模型、hash、双向状态机）完全不必知道自己挂在什么后端上 ——
/// 分叉只发生在这里。
public protocol SCTransport: AnyObject {

    /// 读远端当前剪贴板。对象还不存在（首次使用）应返回一个空 profile 而不是抛错。
    func fetchProfile() async throws -> SCProfile

    /// 写远端当前剪贴板
    func putProfile(_ profile: SCProfile) async throws

    /// 取附件字节流
    func getFile(dataName: String, expectedTransferDataHash: String?) async throws -> Data

    /// 传附件字节流
    func putFile(dataName: String, data: Data) async throws

    /// 连通性探测
    func probe() async -> SCProbeResult
}

/// 传输层的统一错误类型
public enum SCTransportError: Error, CustomStringConvertible {

    case http(code: Int, body: String?, hint: String?)
    case transport(String)
    case badResponse
    case badDataName(String)
    case hashMismatch(expected: String, actual: String)
    case notConfigured(String)

    public var description: String {
        switch self {
        case .http(let code, let body, let hint):
            var text = "服务器返回 HTTP \(code)"
            if let hint { text += "（\(hint)）" }
            if let body, !body.isEmpty {
                let trimmed = body.count > 300 ? String(body.prefix(300)) + "…" : body
                text += "：\(trimmed)"
            }
            return text
        case .transport(let why):
            return "网络错误：\(why)"
        case .badResponse:
            return "服务器返回了无法解析的响应"
        case .badDataName(let name):
            return "非法文件名：\(name)（不能包含 / 或 \\）"
        case .hashMismatch(let e, let a):
            return "附件校验失败：期望 \(e.prefix(16))…，实际 \(a.prefix(16))…"
        case .notConfigured(let what):
            return "配置不完整：\(what)"
        }
    }

    /// 给常见状态码配一句人话，省得用户对着 401 猜
    public static func hint(forHTTP code: Int) -> String? {
        switch code {
        case 400: return "请求被拒，通常是对象名里含非法字符"
        case 401: return "认证失败，检查用户名和密码"
        case 403: return "没有权限。WebDAV 注意目录要可写；S3 检查密钥权限与存储桶策略"
        case 404: return "路径不存在。WebDAV 地址通常要带具体目录；S3 检查存储桶名与前缀"
        case 405: return "方法不被允许，地址可能指向了不支持写入的位置"
        case 409: return "冲突，通常是同名对象正在被写"
        case 423: return "资源被锁定"
        case 507: return "存储空间不足"
        default: return nil
        }
    }
}

/// 校验 dataName：服务端约定不能含路径分隔符
func scValidateDataName(_ dataName: String) throws {
    if dataName.isEmpty || dataName.contains("/") || dataName.contains("\\") {
        throw SCTransportError.badDataName(dataName)
    }
}
