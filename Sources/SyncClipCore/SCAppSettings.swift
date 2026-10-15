import Foundation

/// App 侧设置：服务器列表 + 同步行为，序列化成 JSON 存在 App 容器里。
///
/// 为什么不放 UserDefaults：TrollStore 装的 App 容器可以用 Filza 直接看和改，
/// 存成文件意味着出问题时你能直接编辑它，而不用去刨 plist 二进制缓存。
/// 位置：<App容器>/Documents/syncclip-config.json
public struct SCAppSettings: Codable, Equatable {

    // MARK: 服务器

    /// 已保存的服务器。可以有任意多台，类型可以混着来。
    public var servers: [SCServerProfile]
    /// 当前使用哪一台（存 id 而不是下标，删掉中间一条时不会错位）
    public var activeServerID: String?

    // MARK: 同步行为

    public var pollInterval: Double
    public var startupSync: String
    public var conflictResolution: String
    public var syncEnabled: Bool
    public var keepAliveEnabled: Bool
    /// 订阅服务器的实时推送（SyncClipboard 官方服务器才有，WebDAV/S3 没 Hub）。
    /// 开着的话 PC 上一复制，手机上几乎是立刻就变；不依赖它也能靠轮询工作。
    public var pushEnabled: Bool
    public var verboseLogging: Bool

    public init(servers: [SCServerProfile] = [],
                activeServerID: String? = nil,
                pollInterval: Double = 2.0,
                startupSync: String = "pull",
                conflictResolution: String = "newest",
                syncEnabled: Bool = true,
                keepAliveEnabled: Bool = true,
                pushEnabled: Bool = true,
                verboseLogging: Bool = false) {
        self.servers = servers
        self.activeServerID = activeServerID
        self.pollInterval = pollInterval
        self.startupSync = startupSync
        self.conflictResolution = conflictResolution
        self.syncEnabled = syncEnabled
        self.keepAliveEnabled = keepAliveEnabled
        self.pushEnabled = pushEnabled
        self.verboseLogging = verboseLogging
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        servers = try c.decodeIfPresent([SCServerProfile].self, forKey: .servers) ?? []
        activeServerID = try c.decodeIfPresent(String.self, forKey: .activeServerID)
        pollInterval = try c.decodeIfPresent(Double.self, forKey: .pollInterval) ?? 2.0
        startupSync = try c.decodeIfPresent(String.self, forKey: .startupSync) ?? "pull"
        conflictResolution = try c.decodeIfPresent(String.self, forKey: .conflictResolution) ?? "newest"
        syncEnabled = try c.decodeIfPresent(Bool.self, forKey: .syncEnabled) ?? true
        keepAliveEnabled = try c.decodeIfPresent(Bool.self, forKey: .keepAliveEnabled) ?? true
        pushEnabled = try c.decodeIfPresent(Bool.self, forKey: .pushEnabled) ?? true
        verboseLogging = try c.decodeIfPresent(Bool.self, forKey: .verboseLogging) ?? false

        // ---- 老版本配置迁移 ----
        // 早期版本只有一台服务器，字段平铺在顶层（baseURL/username/password/…）。
        // 见到那种形状就自动收编成一条服务器记录，用户不必重新填一遍。
        //
        // 这几个 key 只在迁移时读一次，所以单独放一个 CodingKeys 里 ——
        // 不宜混进主 CodingKeys：合成出来的 encode 也会用到它，
        // 而它们已经没有对应属性了，两边对不上会直接编译不过。
        if servers.isEmpty {
            enum LegacyKeys: String, CodingKey {
                case baseURL, username, password, name
            }
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let legacyURL = try legacy.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
            if !legacyURL.isEmpty {
                var migrated = SCServerProfile(
                    type: .syncclipboard,
                    url: legacyURL,
                    username: try legacy.decodeIfPresent(String.self, forKey: .username) ?? "",
                    password: try legacy.decodeIfPresent(String.self, forKey: .password) ?? ""
                )
                migrated.name = try legacy.decodeIfPresent(String.self, forKey: .name) ?? ""
                servers = [migrated]
                activeServerID = migrated.id
            }
        }

        // 修正悬空的 activeServerID（手动改过 JSON、或删了服务器没更新时会发生）
        if let id = activeServerID, !servers.contains(where: { $0.id == id }) {
            activeServerID = servers.first?.id
        }
        if activeServerID == nil, let first = servers.first {
            activeServerID = first.id
        }
    }

    // MARK: - 激活的服务器

    public var activeServer: SCServerProfile? {
        if let id = activeServerID, let match = servers.first(where: { $0.id == id }) {
            return match
        }
        return servers.first
    }

    public var hasServers: Bool { !servers.isEmpty }

    public func server(withID id: String) -> SCServerProfile? {
        servers.first { $0.id == id }
    }

    public func isActive(_ profile: SCServerProfile) -> Bool {
        profile.id == activeServer?.id
    }

    // MARK: - 增删改

    /// 新增或更新（按 id 匹配）。若目前没有任何激活项，顺手把新的设为激活。
    public mutating func upsert(_ profile: SCServerProfile) {
        if let idx = servers.firstIndex(where: { $0.id == profile.id }) {
            servers[idx] = profile
        } else {
            servers.append(profile)
        }
        if activeServerID == nil || !servers.contains(where: { $0.id == activeServerID }) {
            activeServerID = profile.id
        }
    }

    public mutating func remove(id: String) {
        servers.removeAll { $0.id == id }
        if activeServerID == id {
            activeServerID = servers.first?.id
        }
    }

    public mutating func setActive(id: String) {
        guard servers.contains(where: { $0.id == id }) else { return }
        activeServerID = id
    }

    // MARK: - 落盘

    public static let fileName = "syncclip-config.json"

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
            try encoder.encode(self).write(to: url, options: .atomic)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - 转成引擎配置

    /// 当前激活服务器的引擎配置。没有激活服务器、或配置不完整时会抛错。
    public func toConfig() throws -> SCConfig {
        guard let profile = activeServer else {
            throw SCServerProfile.ValidationError.missing("任何一台服务器（先去「服务器」页加一台）")
        }
        try profile.validate()
        return SCConfig(profile: profile,
                        pollInterval: pollInterval,
                        startupSyncRaw: startupSync,
                        conflictRaw: conflictResolution)
    }

    public var isConfigured: Bool { (try? toConfig()) != nil }
}
