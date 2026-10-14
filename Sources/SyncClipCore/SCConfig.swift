import Foundation

/// 一份配置。来源是 plist 文件，不依赖 cfprefsd（守护进程以 mobile 身份跑，
/// 直接读文件更可预期，也方便用编辑器/脚本改）。
public struct SCConfig: Equatable {

    /// 服务器根地址，例如 http://192.168.1.10:5033
    public var baseURL: URL
    public var username: String
    public var password: String

    /// 轮询间隔（秒）。下限 0.5，避免手抖配成 0 把服务器打爆。
    public var pollInterval: TimeInterval

    /// 启动时先做哪个方向：pull=跟随远端 / push=把手机剪贴板推上去 / none=不动
    public var startupSync: StartupSync

    /// 只在本地和远端都一样时允许覆盖本地剪贴板（v1 固定行为，留字段备用）
    public var pullOverwritesLocal: Bool

    public enum StartupSync: String {
        case pull, push, none
    }

    public static let defaultConfigPath = "/var/mobile/Library/Preferences/com.cxk.syncclip.plist"

    /// 依次尝试的配置文件位置。第一个存在的生效。
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

    public init(baseURL: URL, username: String, password: String,
                pollInterval: TimeInterval = 2,
                startupSync: StartupSync = .pull,
                pullOverwritesLocal: Bool = true) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.pollInterval = max(0.5, pollInterval)
        self.startupSync = startupSync
        self.pullOverwritesLocal = pullOverwritesLocal
    }

    // MARK: - 读取

    public enum ConfigError: Error, CustomStringConvertible {
        case fileNotFound([String])
        case unreadable(String, String)
        case invalidBaseURL(String)
        case missingCredential(String)

        public var description: String {
            switch self {
            case .fileNotFound(let tried):
                return "找不到配置文件。已尝试：\n  " + tried.joined(separator: "\n  ")
                    + "\n请在上述任一位置创建配置，或用 --config <path> 指定。"
            case .unreadable(let path, let why):
                return "配置文件无法解析：\(path)（\(why)）"
            case .invalidBaseURL(let raw):
                return "baseURL 非法：\(raw)（需要带 scheme，例如 http://192.168.1.10:5033）"
            case .missingCredential(let key):
                return "配置缺少必填字段：\(key)"
            }
        }
    }

    /// 显式指定路径就只用那一个；否则按 searchPaths 找第一个存在的。
    public static func load(explicitPath: String? = nil) throws -> (config: SCConfig, path: String) {
        let candidates: [String]
        if let p = explicitPath {
            candidates = [p]
        } else {
            candidates = searchPaths
        }

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

        guard let rawURL = str("baseURL"), !rawURL.isEmpty else {
            throw ConfigError.missingCredential("baseURL")
        }
        guard let url = URL(string: rawURL), url.scheme != nil, url.host != nil else {
            throw ConfigError.invalidBaseURL(rawURL)
        }
        guard let user = str("username"), !user.isEmpty else {
            throw ConfigError.missingCredential("username")
        }
        guard let pass = str("password"), !pass.isEmpty else {
            throw ConfigError.missingCredential("password")
        }

        let interval: TimeInterval
        if let n = dict["pollInterval"] as? NSNumber {
            interval = n.doubleValue
        } else if let s = dict["pollInterval"] as? String, let d = Double(s) {
            interval = d
        } else {
            interval = 2
        }

        let startup: StartupSync
        if let s = str("startupSync"), let v = StartupSync(rawValue: s.lowercased()) {
            startup = v
        } else {
            startup = .pull
        }

        var pullOverwrite = true
        if let n = dict["pullOverwritesLocal"] as? NSNumber {
            pullOverwrite = n.boolValue
        }

        return SCConfig(baseURL: url, username: user, password: pass,
                        pollInterval: interval, startupSync: startup,
                        pullOverwritesLocal: pullOverwrite)
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
