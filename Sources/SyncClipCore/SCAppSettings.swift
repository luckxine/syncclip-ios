import Foundation

/// App 侧设置：直接对应设置页上的每一项，序列化成 JSON 存在 App 容器里。
///
/// 为什么不放 UserDefaults：TrollStore 装的 App 容器可以用 Filza 直接看和改，
/// 存成文件意味着出问题时你能直接编辑它，而不用去刨 plist 二进制缓存。
/// 存的位置：<App容器>/Documents/syncclip-config.json
public struct SCAppSettings: Codable, Equatable {

    // MARK: 服务器

    public var baseURL: String
    public var username: String
    public var password: String

    // MARK: 同步行为

    /// 轮询间隔（秒）
    public var pollInterval: Double
    /// 启动时先做哪个方向：pull / push / none
    public var startupSync: String
    /// 总开关：关掉就不轮询，也不读写剪贴板
    public var syncEnabled: Bool
    /// 后台保活：用静音音频会话让进程不被挂起
    public var keepAliveEnabled: Bool
    /// 调试日志
    public var verboseLogging: Bool

    public init(baseURL: String = "",
                username: String = "",
                password: String = "",
                pollInterval: Double = 2.0,
                startupSync: String = "pull",
                syncEnabled: Bool = true,
                keepAliveEnabled: Bool = true,
                verboseLogging: Bool = false) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.pollInterval = pollInterval
        self.startupSync = startupSync
        self.syncEnabled = syncEnabled
        self.keepAliveEnabled = keepAliveEnabled
        self.verboseLogging = verboseLogging
    }

    /// 解码时对缺字段宽容（老版本写的配置文件缺新字段是常态）
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        pollInterval = try c.decodeIfPresent(Double.self, forKey: .pollInterval) ?? 2.0
        startupSync = try c.decodeIfPresent(String.self, forKey: .startupSync) ?? "pull"
        syncEnabled = try c.decodeIfPresent(Bool.self, forKey: .syncEnabled) ?? true
        keepAliveEnabled = try c.decodeIfPresent(Bool.self, forKey: .keepAliveEnabled) ?? true
        verboseLogging = try c.decodeIfPresent(Bool.self, forKey: .verboseLogging) ?? false
    }

    // MARK: - 落盘

    public static let fileName = "syncclip-config.json"

    /// App 容器里的 Documents 目录。取不到就回落到来 caches（极不可能发生）
    public static var defaultDirectory: URL {
        let fm = FileManager.default
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            return docs
        }
        return fm.temporaryDirectory
    }

    public static var defaultURL: URL {
        defaultDirectory.appendingPathComponent(fileName)
    }

    public static func load(from url: URL = SCAppSettings.defaultURL) -> SCAppSettings {
        guard let data = try? Data(contentsOf: url) else { return SCAppSettings() }
        return (try? JSONDecoder().decode(SCAppSettings.self, from: data)) ?? SCAppSettings()
    }

    @discardableResult
    public func save(to url: URL = SCAppSettings.defaultURL) -> Error? {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self)
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - 转成同步引擎要的配置

    public enum SettingsError: Error, CustomStringConvertible {
        case missingURL
        case badURL(String)
        case missingCredential(String)

        public var description: String {
            switch self {
            case .missingURL:
                return "还没填服务器地址"
            case .badURL(let raw):
                return "服务器地址不合法：\(raw)（要带 http:// 或 https:// 前缀）"
            case .missingCredential(let key):
                return "还没填\(key)"
            }
        }
    }

    public var isConfigured: Bool {
        (try? toConfig()) != nil
    }

    public func toConfig() throws -> SCConfig {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SettingsError.missingURL }
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            throw SettingsError.badURL(trimmed)
        }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else { throw SettingsError.missingCredential("用户名") }
        guard !password.isEmpty else { throw SettingsError.missingCredential("密码") }

        let startup = SCConfig.StartupSync(rawValue: startupSync.lowercased()) ?? .pull
        return SCConfig(baseURL: url,
                        username: user,
                        password: password,
                        pollInterval: pollInterval,
                        startupSync: startup)
    }

    /// 给「测试连接」用：不要求填完整，缺什么就报什么
    public func toConfigForTest() throws -> SCConfig { try toConfig() }
}
