import Foundation

/// SyncClipboard 的 WebDAV 兼容 API 客户端。
///
/// 只用这四条路径（官方服务器与 WebDAV/S3 后端都支持）：
///   GET  /SyncClipboard.json         读远端当前剪贴板
///   PUT  /SyncClipboard.json         写远端当前剪贴板
///   GET  /file/{dataName}            取附件字节流
///   PUT  /file/{dataName}            传附件字节流
///
/// HTTP Basic 认证；`TransferDataHash` 头用于附件完整性校验。
public final class SCClient {

    public enum ClientError: Error, CustomStringConvertible {
        case badStatus(code: Int, body: String?)
        case badResponse
        case badDataName(String)
        case hashMismatch(expected: String, actual: String)
        case transport(String)

        public var description: String {
            switch self {
            case .badStatus(let code, let body):
                let detail = (body?.isEmpty == false) ? " 响应体: \(body!)" : ""
                return "服务器返回 HTTP \(code)\(detail)"
            case .badResponse:
                return "服务器返回了无法解析的响应"
            case .badDataName(let name):
                return "非法 dataName：\(name)（不能包含 / 或 \\）"
            case .hashMismatch(let e, let a):
                return "附件校验失败：期望 \(e.prefix(16))…，实际 \(a.prefix(16))…"
            case .transport(let why):
                return "网络错误：\(why)"
            }
        }
    }

    private let session: URLSession
    private let baseURL: URL
    private let authHeader: String

    public init(config: SCConfig, timeout: TimeInterval = 15) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 4
        cfg.waitsForConnectivity = false
        cfg.httpShouldSetCookies = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: cfg)

        self.baseURL = config.baseURL
        let raw = "\(config.username):\(config.password)"
        self.authHeader = "Basic " + Data(raw.utf8).base64EncodedString()
    }

    // MARK: - 当前剪贴板

    /// GET /SyncClipboard.json
    public func fetchProfile() async throws -> SCProfile {
        let (data, response) = try await send("GET", path: "SyncClipboard.json")
        try ensureOK(response, data: data)
        do {
            return try JSONDecoder().decode(SCProfile.self, from: data)
        } catch {
            throw ClientError.badResponse
        }
    }

    /// PUT /SyncClipboard.json
    public func putProfile(_ profile: SCProfile) async throws {
        var request = try makeRequest("PUT", path: "SyncClipboard.json")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("SyncClipboard", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(profile)

        let (data, response) = try await session.data(for: request)
        try ensureOK(response, data: data)
    }

    // MARK: - 附件

    /// PUT /file/{dataName}
    public func putFile(dataName: String, content: Data) async throws {
        try validate(dataName: dataName)

        var request = try makeRequest("PUT", path: filePath(dataName))
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("SyncClipboard", forHTTPHeaderField: "User-Agent")
        request.setValue(SCCrypto.sha256Hex(content),
                         forHTTPHeaderField: SCClient.transferDataHashHeader)
        request.httpBody = content

        let (data, response) = try await session.data(for: request)
        try ensureOK(response, data: data)
    }

    /// GET /file/{dataName}，并（在有 transferDataHash 时）校验字节流完整性。
    public func getFile(dataName: String, expectedTransferDataHash: String? = nil) async throws -> Data {
        try validate(dataName: dataName)

        let (data, response) = try await send("GET", path: filePath(dataName))
        try ensureOK(response, data: data)

        if let expected = expectedTransferDataHash, !expected.isEmpty {
            let actual = SCCrypto.sha256Hex(data)
            if actual.caseInsensitiveCompare(expected) != .orderedSame {
                throw ClientError.hashMismatch(expected: expected, actual: actual)
            }
        }
        return data
    }

    // MARK: - 探活

    public struct ServerInfo: Equatable {
        public var reachable: Bool
        /// 官方服务器才有 /api/version；WebDAV/S3 后端为 nil
        public var version: String?
        public var message: String
    }

    public func probeServer() async -> ServerInfo {
        // 先用 liveness 端点确认服务在跑（WebDAV 兼容路径同样足以证明）
        do {
            let profile = try await fetchProfile()
            let version = try? await fetchVersion()
            return ServerInfo(reachable: true, version: version,
                              message: "连接正常，远端内容：\(profile.summary)")
        } catch {
            return ServerInfo(reachable: false, version: nil, message: "\(error)")
        }
    }

    /// GET /api/version（仅官方服务器）
    public func fetchVersion() async throws -> String {
        let (data, response) = try await send("GET", path: "api/version")
        try ensureOK(response, data: data)
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\r")) ?? ""
    }

    // MARK: - 内部

    public static let transferDataHashHeader = "TransferDataHash"

    private func filePath(_ dataName: String) -> String {
        // dataName 允许有空格等字符；不能含 / \（服务端会 400）
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/\\"))
        let encoded = dataName.addingPercentEncoding(withAllowedCharacters: allowed) ?? dataName
        return "file/" + encoded
    }

    private func validate(dataName: String) throws {
        if dataName.isEmpty || dataName.contains("/") || dataName.contains("\\") {
            throw ClientError.badDataName(dataName)
        }
    }

    private func makeRequest(_ method: String, path: String) throws -> URLRequest {
        // baseURL 可能带子路径（例如 WebDAV 挂载到 /sync/），逐个组件拼接以保留子路径
        var url = baseURL
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ method: String, path: String) async throws -> (Data, URLResponse) {
        let request = try makeRequest(method, path: path)
        do {
            return try await session.data(for: request)
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }
    }

    private func ensureOK(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.badStatus(code: http.statusCode,
                                        body: String(data: data, encoding: .utf8))
        }
    }
}
