import Foundation
import os

/// 日志：同时写 os_log（unified log，可用 Console.app / `log stream` 看，自动轮转）
/// 和 stderr（launchd 的 StandardErrorPath 会把它落到文件里）。
public enum SCLog {

    public enum Level: Int, Comparable {
        case off = 0, error = 1, warn = 2, info = 3, debug = 4

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        public static func parse(_ s: String) -> Level {
            switch s.lowercased() {
            case "off", "none", "silent": return .off
            case "error": return .error
            case "warn", "warning": return .warn
            case "debug", "trace", "verbose": return .debug
            default: return .info
            }
        }
    }

    public static let subsystem = "com.cxk.syncclip"

    private static let log = Logger(subsystem: subsystem, category: "daemon")
    private static let queue = DispatchQueue(label: subsystem + ".log")

    /// 由 daemon 启动时设置
    public static var level: Level = .info

    /// 日志文件路径（仅用于启动时做一次体积轮转）
    public static var logFilePath: String? = "/var/mobile/Library/Logs/syncclipd.log"
    private static let maxLogBytes: UInt64 = 2 * 1024 * 1024

    /// UI 侧的日志接管口。App 里挂上它，日志就能直接显示在界面上。
    /// 实现必须自己保证线程安全（emit 会从任意线程调用）。
    public static var sink: ((String) -> Void)?

    // MARK: - 写日志

    public static func error(_ msg: @autoclosure () -> String) { emit(.error, msg()) }
    public static func warn(_ msg: @autoclosure () -> String) { emit(.warn, msg()) }
    public static func info(_ msg: @autoclosure () -> String) { emit(.info, msg()) }
    public static func debug(_ msg: @autoclosure () -> String) { emit(.debug, msg()) }

    private static func emit(_ lvl: Level, _ msg: String) {
        guard lvl <= level else { return }

        let stamp = ISO8601DateFormatter.sclogFormatter.string(from: Date())
        let tag: String
        switch lvl {
        case .error: tag = "ERROR"
        case .warn:  tag = "WARN "
        case .info:  tag = "INFO "
        default:     tag = "DEBUG"
        }
        let line = "[\(stamp)] \(tag) \(msg)\n"

        switch lvl {
        case .error: log.error("\(msg, privacy: .public)")
        case .warn:  log.warning("\(msg, privacy: .public)")
        case .info:  log.info("\(msg, privacy: .public)")
        default:     log.debug("\(msg, privacy: .public)")
        }

        // UI 日志（App 里用）
        sink?(line.trimmingCharacters(in: .newlines))

        // stderr：不加锁也无所谓（单行 write 是原子的），但串行队列更整齐
        queue.async {
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    // MARK: - 启动时的日志轮转

    /// 如果日志文件超过 2MB，改名成 .1（旧的 .1 被覆盖）。只保留一代。
    public static func rotateLogFileIfNeeded() {
        guard let path = logFilePath else { return }
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64,
              size > maxLogBytes else { return }

        let old = path + ".1"
        try? fm.removeItem(atPath: old)
        try? fm.moveItem(atPath: path, toPath: old)
    }
}

extension ISO8601DateFormatter {
    fileprivate static let sclogFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current
        return f
    }()
}
