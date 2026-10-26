import Foundation

/// 冲突解决策略：两端同时变了以谁为准
public enum SCConflictResolution: String, Codable, CaseIterable, Identifiable {
    /// 比时间戳，新的赢；拿不到可信时间戳时以远端为准（不会把服务器上的内容顶掉）
    case newest
    /// 总是本地赢
    case local
    /// 总是远端赢
    case remote

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .newest: return "以最新为准"
        case .local: return "以本地为准"
        case .remote: return "以远端为准"
        }
    }

    public var blurb: String {
        switch self {
        case .newest: return "比较两端的修改时间，新的覆盖旧的。拿不到时间戳时交给远端。"
        case .local: return "手机上复制的永远赢，会覆盖服务器上的内容。"
        case .remote: return "服务器上的永远赢。手机上的改动只在服务器没有变化时才推上去。"
        }
    }
}

/// 引擎的完整配置 = 一台服务器 + 一组同步行为。
///
/// 注意这里**只描述一台服务器**。多服务器是上层（App 的服务器列表）的事：
/// 切换服务器时用新的 profile 重建引擎，这样引擎内部始终只有一个远端状态，
/// 不会出现「两个服务器的 lastRemoteHash 混在一起」这类难查的问题。
public struct SCConfig: Equatable {

    public var profile: SCServerProfile

    /// 轮询间隔（秒）。下限 0.5，避免手抖配成 0 把服务器打爆。
    public var pollInterval: TimeInterval

    /// 启动时先做哪个方向
    public var startupSync: StartupSync

    /// 两端同时变了以谁为准
    public var conflictResolution: SCConflictResolution

    /// 图片双向同步（M1）。默认关：探针（P1）真机验证过了再开。
    public var imageSyncEnabled: Bool

    /// 单张图片的大小上限（字节）。103 隧道实测 15MB 稳定 / 21MB 必断
    /// （设计稿 §1.5），frp 修复并复测前默认 15MB。
    public var maxImageBytes: Int

    /// 单文件同步（M2）。默认开。
    public var fileSyncEnabled: Bool

    /// 多文件（Group）同步（M3）。默认开。
    public var groupSyncEnabled: Bool

    /// 拉取单文件后是否把 file-url 引用写进剪贴板（P3 探针项）。
    /// 默认关：跨 App 能不能粘出文件由探针把关（设计稿 §4.2）。
    public var fileClipboardWriteEnabled: Bool

    /// 文件 / Group 的大小上限（字节）。与图片共用 15MB 的实测安全值
    /// （设计稿 §1.5）；Group 按各文件字节总和计。
    public var maxFileBytes: Int

    public enum StartupSync: String, Codable, CaseIterable, Identifiable {
        case pull, push, none
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .pull: return "跟随远端（拉取）"
            case .push: return "以本地为准（推送）"
            case .none: return "都不做，只记录"
            }
        }
    }

    public init(profile: SCServerProfile,
                pollInterval: TimeInterval = 2,
                startupSync: StartupSync = .pull,
                conflictResolution: SCConflictResolution = .newest,
                imageSyncEnabled: Bool = false,
                maxImageBytes: Int = 15 * 1024 * 1024,
                fileSyncEnabled: Bool = true,
                groupSyncEnabled: Bool = true,
                fileClipboardWriteEnabled: Bool = false,
                maxFileBytes: Int = 15 * 1024 * 1024) {
        self.profile = profile
        self.pollInterval = max(0.5, pollInterval)
        self.startupSync = startupSync
        self.conflictResolution = conflictResolution
        self.imageSyncEnabled = imageSyncEnabled
        self.maxImageBytes = maxImageBytes
        self.fileSyncEnabled = fileSyncEnabled
        self.groupSyncEnabled = groupSyncEnabled
        self.fileClipboardWriteEnabled = fileClipboardWriteEnabled
        self.maxFileBytes = maxFileBytes
    }

    /// 从已填好的 server profile 构造（校验交给 profile）
    public init(profile: SCServerProfile,
                pollInterval: Double,
                startupSyncRaw: String,
                conflictRaw: String,
                imageSyncEnabled: Bool = false,
                maxImageBytes: Int = 15 * 1024 * 1024,
                fileSyncEnabled: Bool = true,
                groupSyncEnabled: Bool = true,
                fileClipboardWriteEnabled: Bool = false,
                maxFileBytes: Int = 15 * 1024 * 1024) {
        self.init(profile: profile,
                  pollInterval: pollInterval,
                  startupSync: StartupSync(rawValue: startupSyncRaw) ?? .pull,
                  conflictResolution: SCConflictResolution(rawValue: conflictRaw) ?? .newest,
                  imageSyncEnabled: imageSyncEnabled,
                  maxImageBytes: maxImageBytes,
                  fileSyncEnabled: fileSyncEnabled,
                  groupSyncEnabled: groupSyncEnabled,
                  fileClipboardWriteEnabled: fileClipboardWriteEnabled,
                  maxFileBytes: maxFileBytes)
    }

    // MARK: - 便捷访问

    public var serverType: SCServerType { profile.type }
    public var serverTitle: String { profile.displayTitle }
    public var serverSubtitle: String { profile.displaySubtitle }

    // MARK: - 越狱守护进程用的 plist 装载
    //
    // 守护进程的配置是给人用编辑器改的 plist，字段是平铺的（baseURL/username/…），
    // 这里把它映射成 profile。多服务器是 App 侧的概念，守护进程只挂一台。

    public static let defaultConfigPath = "/var/mobile/Library/Preferences/com.cxk.syncclip.plist"

    public static var searchPaths: [String] {
        var paths: [String] = []
        if let env = ProcessInfo.processInfo.environment["SYNCCLIP_CONFIG"], !env.isEmpty {
            paths.append(env)
        }
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            paths.append(home + "/Library/Preferences/com.cxk.syncclip.plist")
        }
        paths.append(defaultConfigPath)
        paths.append("/var/jb/etc/syncclipd.plist")
        return paths
    }

    public enum ConfigError: Error, CustomStringConvertible {
        case fileNotFound([String])
        case unreadable(String, String)
        case invalid(String)

        public var description: String {
            switch self {
            case .fileNotFound(let tried):
                return "找不到配置文件。已尝试：\n  " + tried.joined(separator: "\n  ")
                    + "\n请在上述任一位置创建配置，或用 --config <path> 指定。"
            case .unreadable(let path, let why):
                return "配置文件无法解析：\(path)（\(why)）"
            case .invalid(let why):
                return "配置有问题：\(why)"
            }
        }
    }

    public static func load(explicitPath: String? = nil) throws -> (config: SCConfig, path: String) {
        let candidates = explicitPath.map { [$0] } ?? searchPaths
        var tried: [String] = []

        for path in candidates {
            guard FileManager.default.fileExists(atPath: path) else {
                tried.append(path)
                continue
            }
            guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else {
                throw ConfigError.unreadable(path, "不是合法 plist 字典")
            }
            return (try parse(dict), path)
        }
        throw ConfigError.fileNotFound(tried)
    }

    public static func parse(_ dict: [String: Any]) throws -> SCConfig {
        func str(_ key: String) -> String? {
            (dict[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let rawType = str("type") ?? SCServerType.syncclipboard.rawValue
        let type = SCServerType(rawValue: rawType) ?? .syncclipboard

        var profile = SCServerProfile(type: type,
                                      name: str("name") ?? "",
                                      url: str("baseURL") ?? "",
                                      username: str("username") ?? "",
                                      password: str("password") ?? "",
                                      region: str("region") ?? "us-east-1",
                                      bucketName: str("bucketName") ?? "",
                                      objectPrefix: str("objectPrefix") ?? "",
                                      forcePathStyle: (dict["forcePathStyle"] as? NSNumber)?.boolValue ?? false)

        let interval: TimeInterval
        if let n = dict["pollInterval"] as? NSNumber { interval = n.doubleValue }
        else if let s = dict["pollInterval"] as? String, let d = Double(s) { interval = d }
        else { interval = 2 }

        profile.name = profile.name.isEmpty ? (str("name") ?? "") : profile.name

        do {
            try profile.validate()
        } catch {
            throw ConfigError.invalid("\(error)")
        }

        return SCConfig(profile: profile,
                        pollInterval: interval,
                        startupSyncRaw: str("startupSync") ?? "pull",
                        conflictRaw: str("conflictResolution") ?? "newest")
    }

    // MARK: - 热更新探测

    public struct Fingerprint: Equatable {
        public var path: String
        public var modified: Date?
        public var size: UInt64?
    }

    public static func fingerprint(of path: String) -> Fingerprint {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return Fingerprint(path: path,
                           modified: attrs?[.modificationDate] as? Date,
                           size: attrs?[.size] as? UInt64)
    }
}
