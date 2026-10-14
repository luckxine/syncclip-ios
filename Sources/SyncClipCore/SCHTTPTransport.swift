import Foundation

/// HTTP 传输层：同时服务 SyncClipboard 官方服务器与 WebDAV。
///
/// 两者**路径完全一致**（这也是上游桌面端的约定）：
///   GET/PUT  {base}/SyncClipboard.json
///   GET/PUT  {base}/file/{name}
///
/// 差别只有两处，都在这个类里消化：
///   1. WebDAV 写文件前要先确认 `file/` 目录存在（MKCOL，已存在会回 405/301，忽略）
///   2. 连通性探测：WebDAV 用 PROPFIND Depth:1；官方服务器用 GET /api/version
public final class SCHTTPTransport: SCTransport {

    public static let clipboardFileName = "SyncClipboard.json"
    public static let dataDirectory = "file"
    public static let transferDataHashHeader = "TransferDataHash"

    private let session: URLSession
    private let type: SCServerType
    private let baseURL: URL
    private let authHeader: String
    private let username: String

    /// 目录是否已经确认过（WebDAV 每进程只 MKCOL 一次）
    private var dataDirectoryChecked = false
    private let dirLock = NSLock()

    public init(profile: SCServerProfile, timeout: TimeInterval = 20) throws {
        guard let url = URL(string: profile.url.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme != nil, url.host != nil else {
            throw SCTransportError.notConfigured("服务器地址不合法")
        }
        self.type = profile.type
        self.baseURL = url
        self.username = profile.username

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 6
        cfg.waitsForConnectivity = false
        cfg.httpShouldSetCookies = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: cfg)

        let raw = "\(profile.username):\(profile.password)"
        self.authHeader = "Basic " + Data(raw.utf8).base64EncodedString()
    }

    // MARK: - 协议实现

    public func fetchProfile() async throws -> SCProfile {
        let (data, response) = try await send("GET", path: Self.clipboardFileName)
        guard let http = response as? HTTPURLResponse else { throw SCTransportError.badResponse }

        // 对象还不存在 = 第一次用，不是错误
        if http.statusCode == 404 {
            SCLog.debug("远端还没有 \(Self.clipboardFileName)，按空内容处理")
            return SCProfile()
        }
        try ensureOK(http, data: data)

        do {
            return try JSONDecoder().decode(SCProfile.self, from: data)
        } catch {
            throw SCTransportError.badResponse
        }
    }

    public func putProfile(_ profile: SCProfile) async throws {
        var request = try makeRequest("PUT", path: Self.clipboardFileName)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("SyncClipboard-iOS", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(profile)

        let (data, response) = try await perform(request)
        try ensureOK(response, data: data)
    }

    public func getFile(dataName: String, expectedTransferDataHash: String?) async throws -> Data {
        try scValidateDataName(dataName)

        let (data, response) = try await send("GET", path: filePath(dataName))
        try ensureOK(response, data: data)

        if let expected = expectedTransferDataHash, !expected.isEmpty {
            let actual = SCCrypto.sha256Hex(data)
            if actual.caseInsensitiveCompare(expected) != .orderedSame {
                throw SCTransportError.hashMismatch(expected: expected, actual: actual)
            }
        }
        return data
    }

    public func putFile(dataName: String, data: Data) async throws {
        try scValidateDataName(dataName)

        if type == .webdav {
            await ensureDataDirectoryExists()
        }

        var request = try makeRequest("PUT", path: filePath(dataName))
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("SyncClipboard-iOS", forHTTPHeaderField: "User-Agent")
        request.setValue(SCCrypto.sha256Hex(data),
                         forHTTPHeaderField: Self.transferDataHashHeader)
        request.httpBody = data

        let (body, response) = try await perform(request)
        try ensureOK(response, data: body)
    }

    public func probe() async -> SCProbeResult {
        // 官方服务器：顺便把版本取回来看一眼（3.1.1 起客户端必须不低于服务端）
        if type == .syncclipboard {
            if let version = try? await fetchVersion() {
                return SCProbeResult(reachable: true, version: version,
                                     message: "服务器可达，版本 \(version)")
            }
        }

        do {
            let profile = try await fetchProfile()
            switch type {
            case .webdav:
                // 真按 WebDAV 的方式探一次：PROPFIND 比 GET 更能说明「这是一个可用的 WebDAV 空间」
                try await propfind()
                return SCProbeResult(reachable: true,
                                     message: "WebDAV 可达。远端内容：\(profile.summary)")
            default:
                return SCProbeResult(reachable: true, message: "服务器可达。远端内容：\(profile.summary)")
            }
        } catch {
            return SCProbeResult(reachable: false, message: "\(error)")
        }
    }

    // MARK: - 官方服务器专有

    /// GET /api/version（仅 SyncClipboard 官方服务器）
    public func fetchVersion() async throws -> String {
        let (data, response) = try await send("GET", path: "api/version")
        guard let http = response as? HTTPURLResponse else { throw SCTransportError.badResponse }
        try ensureOK(http, data: data)
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\r")) ?? ""
    }

    // MARK: - WebDAV 专有

    /// PROPFIND Depth:1，用来确认这地址确实是个可读的 WebDAV 空间
    private func propfind() async throws {
        var request = try makeRequest("PROPFIND", path: "")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // Depth:1 的响应体可能不小，但只要状态码
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw SCTransportError.badResponse }
        // 207 Multi-Status 是 PROPFIND 的正常响应
        guard http.statusCode == 207 || (200..<300).contains(http.statusCode) else {
            throw SCTransportError.http(code: http.statusCode,
                                        body: String(data: data, encoding: .utf8),
                                        hint: SCTransportError.hint(forHTTP: http.statusCode))
        }
    }

    /// 确保 `file/` 目录存在。已存在时 WebDAV 服务器回 405 或 301，都算正常。
    private func ensureDataDirectoryExists() async {
        dirLock.lock()
        let already = dataDirectoryChecked
        dirLock.unlock()
        if already { return }

        do {
            var request = try makeRequest("MKCOL", path: Self.dataDirectory)
            request.setValue("SyncClipboard-iOS", forHTTPHeaderField: "User-Agent")
            let (_, response) = try await perform(request)
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 201: SCLog.info("已在远端创建 \(Self.dataDirectory)/ 目录")
                case 405, 301, 302, 200: break     // 已存在，正常
                default: SCLog.warn("MKCOL \(Self.dataDirectory)/ 返回 \(http.statusCode)，继续尝试上传")
                }
            }
        } catch {
            // MKCOL 失败不阻断：有些服务端不允许建目录但允许直接写文件
            SCLog.warn("MKCOL \(Self.dataDirectory)/ 失败：\(error)，仍继续尝试上传")
        }

        dirLock.lock()
        dataDirectoryChecked = true
        dirLock.unlock()
    }

    // MARK: - 内部

    private func filePath(_ dataName: String) -> String {
        // 服务端约定 dataName 不含 / \，但仍要编码空格等字符
        let allowed = CharacterSet.urlPathAllowed
            .subtracting(CharacterSet(charactersIn: "/\\?#"))
        let encoded = dataName.addingPercentEncoding(withAllowedCharacters: allowed) ?? dataName
        return Self.dataDirectory + "/" + encoded
    }

    private func makeRequest(_ method: String, path: String) throws -> URLRequest {
        // baseURL 可能带子路径（WebDAV 常挂在 /dav/xxx），逐段拼接以保留子路径
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
        try await perform(try makeRequest(method, path: path))
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw SCTransportError.transport(error.localizedDescription)
        }
    }

    private func ensureOK(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw SCTransportError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw SCTransportError.http(code: http.statusCode,
                                        body: String(data: data, encoding: .utf8),
                                        hint: SCTransportError.hint(forHTTP: http.statusCode))
        }
    }

    /// 给 UI 用：当前挂在哪台服务器上
    public var endpointDescription: String {
        "\(type.displayName) · \(baseURL.absoluteString) · \(username)"
    }
}
