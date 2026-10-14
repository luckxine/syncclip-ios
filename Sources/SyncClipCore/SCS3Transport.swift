import Foundation

/// S3 兼容对象存储的传输层。
///
/// 对象布局与 HTTP 那两种**完全一致**，只是访问方式换成 SigV4 签名：
///   {prefix}/SyncClipboard.json
///   {prefix}/file/{name}
///
/// 寻址方式：
///   - 自定义端点（MinIO、R2、自建）→ 一律路径风格 `https://host/bucket/key`
///   - AWS 默认端点 → 虚拟主机风格 `https://bucket.s3.<region>.amazonaws.com/key`
///   - 用户也可以强制打开路径风格（有些 S3 兼容实现只认这个）
public final class SCS3Transport: SCTransport {

    public static let clipboardKey = "SyncClipboard.json"
    public static let dataDirectory = "file"

    private let scheme: String
    private let host: String
    private let port: Int?
    private let region: String
    private let bucket: String
    private let objectPrefix: String
    private let pathStyle: Bool
    private let accessKeyID: String
    private let secretAccessKey: String

    private let session: URLSession

    public init(profile: SCServerProfile, timeout: TimeInterval = 25) throws {
        let region = profile.region.trimmingCharacters(in: .whitespacesAndNewlines)
        let bucket = profile.bucketName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bucket.isEmpty else { throw SCTransportError.notConfigured("存储桶名称") }
        guard !profile.username.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw SCTransportError.notConfigured("Access Key ID")
        }
        guard !profile.password.isEmpty else {
            throw SCTransportError.notConfigured("Secret Access Key")
        }

        let effectiveRegion = region.isEmpty ? "us-east-1" : region
        let rawEndpoint = profile.url.trimmingCharacters(in: .whitespacesAndNewlines)

        let endpointString = rawEndpoint.isEmpty
            ? "https://s3.\(effectiveRegion).amazonaws.com"
            : rawEndpoint
        guard let endpoint = URL(string: endpointString),
              let scheme = endpoint.scheme,
              let host = endpoint.host else {
            throw SCTransportError.notConfigured("S3 端点地址不合法：\(endpointString)")
        }

        self.scheme = scheme
        self.host = host
        self.port = endpoint.port
        self.region = effectiveRegion
        self.bucket = bucket
        self.objectPrefix = profile.objectPrefix
        // 自定义端点默认走路径风格：绝大多数 S3 兼容实现不支持虚拟主机风格
        self.pathStyle = profile.forcePathStyle || !rawEndpoint.isEmpty
        self.accessKeyID = profile.username.trimmingCharacters(in: .whitespaces)
        self.secretAccessKey = profile.password

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 8
        cfg.waitsForConnectivity = false
        cfg.httpShouldSetCookies = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - 协议实现

    public func fetchProfile() async throws -> SCProfile {
        let (data, status) = try await send(method: "GET", objectKey: Self.clipboardKey)

        if status == 404 {
            SCLog.debug("远端还没有 \(Self.clipboardKey)，按空内容处理")
            return SCProfile()
        }
        guard (200..<300).contains(status) else {
            throw SCTransportError.http(code: status,
                                        body: String(data: data, encoding: .utf8),
                                        hint: SCTransportError.hint(forHTTP: status))
        }
        do {
            return try JSONDecoder().decode(SCProfile.self, from: data)
        } catch {
            throw SCTransportError.badResponse
        }
    }

    public func putProfile(_ profile: SCProfile) async throws {
        let body = try JSONEncoder().encode(profile)
        let (data, status) = try await send(method: "PUT",
                                            objectKey: Self.clipboardKey,
                                            body: body,
                                            contentType: "application/json; charset=utf-8")
        guard (200..<300).contains(status) else {
            throw SCTransportError.http(code: status,
                                        body: String(data: data, encoding: .utf8),
                                        hint: SCTransportError.hint(forHTTP: status))
        }
    }

    public func getFile(dataName: String, expectedTransferDataHash: String?) async throws -> Data {
        try scValidateDataName(dataName)

        let (data, status) = try await send(method: "GET",
                                            objectKey: "\(Self.dataDirectory)/\(dataName)")
        guard (200..<300).contains(status) else {
            throw SCTransportError.http(code: status,
                                        body: String(data: data, encoding: .utf8),
                                        hint: SCTransportError.hint(forHTTP: status))
        }

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

        let (body, status) = try await send(method: "PUT",
                                            objectKey: "\(Self.dataDirectory)/\(dataName)",
                                            body: data,
                                            contentType: "application/octet-stream")
        guard (200..<300).contains(status) else {
            throw SCTransportError.http(code: status,
                                        body: String(data: body, encoding: .utf8),
                                        hint: SCTransportError.hint(forHTTP: status))
        }
    }

    public func probe() async -> SCProbeResult {
        // 与上游一致：用 ListObjectsV2 列一个 key，既能验证凭据也能验证桶名与区域
        let prefix = buildObjectKey("") + "/"
        do {
            let (body, status) = try await send(method: "GET",
                                                objectKey: "",
                                                query: [("list-type", "2"),
                                                        ("prefix", prefix),
                                                        ("max-keys", "1")])
            if (200..<300).contains(status) {
                let count = SCS3Transport.keyCount(in: body)
                return SCProbeResult(reachable: true,
                                     message: "S3 可达，存储桶 \(bucket) 可读"
                                        + (count > 0 ? "（该前缀下已有 \(count) 个对象）" : "（该前缀下暂无对象）"))
            }
            return SCProbeResult(reachable: false,
                                 message: SCTransportError.http(
                                    code: status,
                                    body: String(data: body, encoding: .utf8),
                                    hint: SCTransportError.hint(forHTTP: status)).description)
        } catch {
            return SCProbeResult(reachable: false, message: "\(error)")
        }
    }

    /// 从 ListObjectsV2 的 XML 里数一下 Key 的数量（不引入 XML 解析器，够用）
    static func keyCount(in xml: Data) -> Int {
        guard let text = String(data: xml, encoding: .utf8) else { return 0 }
        return text.components(separatedBy: "<Key>").count - 1
    }

    // MARK: - 对象 key

    /// 与上游 BuildObjectKey 一致：`prefix/relativePath`，两侧斜杠都规整掉
    func buildObjectKey(_ relativePath: String) -> String {
        let path = relativePath.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = objectPrefix.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if prefix.isEmpty { return path }
        if path.isEmpty { return prefix }
        return "\(prefix)/\(path)"
    }

    // MARK: - 请求与签名

    private func hostHeader(usingBucket: Bool) -> String {
        let h = usingBucket ? "\(bucket).\(host)" : host
        if let port { return "\(h):\(port)" }
        return h
    }

    /// - Returns: (响应体, HTTP 状态码)
    private func send(method: String,
                      objectKey: String,
                      query: [(String, String)] = [],
                      body: Data? = nil,
                      contentType: String? = nil) async throws -> (Data, Int) {

        let fullKey = buildObjectKey(objectKey)
        let encodedKey = SCSigV4.uriEncode(fullKey, encodeSlash: false)

        let usePathStyle = pathStyle
        let requestHost = hostHeader(usingBucket: !usePathStyle)

        let canonicalPath: String
        if usePathStyle {
            canonicalPath = encodedKey.isEmpty ? "/\(bucket)" : "/\(bucket)/\(encodedKey)"
        } else {
            canonicalPath = encodedKey.isEmpty ? "/" : "/\(encodedKey)"
        }

        let canonicalQuery = SCSigV4.canonicalQueryString(query)

        var urlString = "\(scheme)://\(requestHost)\(canonicalPath)"
        if !canonicalQuery.isEmpty { urlString += "?\(canonicalQuery)" }
        guard let url = URL(string: urlString) else {
            throw SCTransportError.notConfigured("拼出的 S3 地址不合法：\(urlString)")
        }

        // ---- 签名 ----
        let now = Date()
        let amzDate = SCSigV4.amzDate(now)
        let dateStamp = SCSigV4.dateStamp(now)

        var headers: [String: String] = [
            "host": requestHost,
            "x-amz-content-sha256": SCSigV4.unsignedPayload,
            "x-amz-date": amzDate,
        ]
        if let contentType { headers["content-type"] = contentType }

        let (canonicalHeaders, signedHeaders) = SCSigV4.canonicalHeaders(headers)

        let canonicalRequest = SCSigV4.canonicalRequest(method: method,
                                                        canonicalPath: canonicalPath,
                                                        query: canonicalQuery,
                                                        canonicalHeaders: canonicalHeaders,
                                                        signedHeaders: signedHeaders,
                                                        payloadHash: SCSigV4.unsignedPayload)

        let scope = SCSigV4.credentialScope(dateStamp: dateStamp, region: region)
        let sts = SCSigV4.stringToSign(amzDate: amzDate,
                                       credentialScope: scope,
                                       canonicalRequestHash: SCSigV4.sha256Hex(Data(canonicalRequest.utf8)))

        let signingKey = SCSigV4.deriveSigningKey(secretAccessKey: secretAccessKey,
                                                  dateStamp: dateStamp,
                                                  region: region)
        let signature = SCSigV4.hmacSHA256Hex(key: signingKey, sts)

        let authorization = SCSigV4.authorizationHeader(accessKeyID: accessKeyID,
                                                        credentialScope: scope,
                                                        signedHeaders: signedHeaders,
                                                        signature: signature)

        // ---- 发请求 ----
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(SCSigV4.unsignedPayload, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("SyncClipboard-iOS", forHTTPHeaderField: "User-Agent")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.httpBody = body

        SCLog.debug("S3 \(method) \(canonicalPath)\(canonicalQuery.isEmpty ? "" : "?…")")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SCTransportError.badResponse }
            return (data, http.statusCode)
        } catch {
            throw SCTransportError.transport(error.localizedDescription)
        }
    }

    /// 给 UI / 诊断页展示当前实际使用的端点
    public var endpointDescription: String {
        let style = pathStyle ? "路径风格" : "虚拟主机风格"
        return "\(scheme)://\(host)\(port.map { ":\($0)" } ?? "") · 桶 \(bucket) · \(region) · \(style)"
    }
}
