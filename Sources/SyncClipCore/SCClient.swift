import Foundation

/// 协议层的门面：按服务器类型挑一个传输层，再向上提供统一接口。
///
/// 上层（同步引擎、UI）只认这四个动作，完全不需要知道自己挂的是
/// SyncClipboard 服务器、WebDAV 还是 S3。
public final class SCClient {

    public typealias ClientError = SCTransportError

    private let transport: SCTransport
    public let config: SCConfig

    /// 按配置里的服务器类型创建对应的传输层。配置不完整会直接抛错，
    /// 而不是等到发请求才失败 —— 报错点越早，排查越省事。
    public init(config: SCConfig) throws {
        self.config = config
        let profile = config.profile
        try profile.validate()

        switch profile.type {
        case .syncclipboard, .webdav:
            self.transport = try SCHTTPTransport(profile: profile)
        case .s3:
            self.transport = try SCS3Transport(profile: profile)
        }
    }

    // MARK: - 当前剪贴板

    public func fetchProfile() async throws -> SCProfile {
        try await transport.fetchProfile()
    }

    public func putProfile(_ profile: SCProfile) async throws {
        try await transport.putProfile(profile)
    }

    // MARK: - 附件

    public func putFile(dataName: String, content: Data) async throws {
        try await transport.putFile(dataName: dataName, data: content)
    }

    public func getFile(dataName: String, expectedTransferDataHash: String? = nil) async throws -> Data {
        try await transport.getFile(dataName: dataName,
                                    expectedTransferDataHash: expectedTransferDataHash)
    }

    // MARK: - 探活

    public func probeServer() async -> SCProbeResult {
        await transport.probe()
    }

    /// 只有 SyncClipboard 官方服务器才有版本接口；其余类型返回 nil。
    public func fetchVersion() async -> String? {
        guard let http = transport as? SCHTTPTransport else { return nil }
        return try? await http.fetchVersion()
    }

    /// 诊断/show 用的：当前实际在用什么端点
    public var endpointDescription: String {
        if let http = transport as? SCHTTPTransport { return http.endpointDescription }
        if let s3 = transport as? SCS3Transport { return s3.endpointDescription }
        return config.serverSubtitle
    }

    // MARK: - 版本比较
    //
    // SyncClipboard 从 3.1.1 起不兼容旧版客户端，所以服务端版本高于客户端时要提醒。

    /// 返回 true 表示服务端版本**高于**客户端已知可兼容的版本
    public static func serverIsNewer(than clientVersion: String, serverVersion: String) -> Bool {
        compare(serverVersion, clientVersion) == .orderedDescending
    }

    /// 宽松的点分版本比较：只比数字段，缺的按 0 算
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = lhs.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
