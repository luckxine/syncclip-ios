import Foundation

/// NE 可行性探针，宿主 App 与隧道 appex 共用的常量。
///
/// 两边是两个独立进程、两个独立沙盒，唯一的公共通道是 App Group 容器。
/// 常量集中在这里，避免两边字符串写歪 —— 那样表现会非常像「功能没生效」，
/// 排查起来极费时间。
public enum Probe {

    public static let appBundleID = "com.cxk.pasteprobe"
    public static let tunnelBundleID = "com.cxk.pasteprobe.tunnel"
    public static let appGroupID = "group.com.cxk.pasteprobe"

    public static let logFileName = "probe-log.json"

    /// 日志上限。心跳是每 5 秒一条，不封顶的话放一晚上就爆了。
    public static let maxRecords = 500

    // ---- 剪贴板往返协议 ----
    //
    // 探针要回答的核心问题之一是「隧道进程能不能读写剪贴板」。
    // 但隧道进程没有 UI，宿主 App 又可能已经退到后台 —— 用什么通道把答案带回来？
    // 答案就用剪贴板本身：
    //
    //   1. App 把剪贴板写成  "PasteProbe-TX-<nonce>"
    //   2. App 拉起隧道，并把 echoPasteboard 选项传进去
    //   3. 隧道路进程读剪贴板：读到啥都记进日志；若读到的正是 <nonce>，
    //      就把剪贴板回写成 "[PasteProbe-ECHO] <nonce>"
    //   4. App 轮询剪贴板，看到 echo 就说明「隧道进程真的能读也能写」
    //
    // 这条通道不依赖 App Group，所以即使 App Group 因为 entitlement 没生效而
    // 不可用，这个问题依然有答案。
    public static let txPrefix = "PasteProbe-TX-"
    public static let echoPrefix = "[PasteProbe-ECHO]"

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    public static var logURL: URL? {
        containerURL?.appendingPathComponent(logFileName)
    }
}

/// 一条日志。写成 Codable 而不是纯文本，是为了让 App 能按字段渲染，
/// 也为了将来换成真正的同步实现时能直接复用这套跨进程状态的想法。
public struct ProbeRecord: Codable {
    public var at: Double
    public var source: String      // "app" / "tunnel"
    public var kind: String        // "heartbeat" / "pasteboard.read" / ...
    public var detail: String

    public init(source: String, kind: String, detail: String) {
        self.at = Date().timeIntervalSince1970
        self.source = source
        self.kind = kind
        self.detail = detail
    }

    public var clock: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date(timeIntervalSince1970: at))
    }

    public var line: String {
        "[\(clock)] \(source)/\(kind): \(detail)"
    }
}

/// 跨进程日志。
///
/// 注意：两个进程都在读-改-写同一个文件，理论上会互相覆盖（丢一条日志）。
/// 探针阶段可以接受：我们关心的是「有没有记录」而不是「一条不漏」。
/// 真做同步实现时这里要换掉（App Group + 文件锁，或者一个本地 socket）。
public enum ProbeLog {

    public static func append(source: String, kind: String, detail: String) {
        var records = readRaw()
        records.append(ProbeRecord(source: source, kind: kind, detail: detail))
        if records.count > Probe.maxRecords {
            records.removeFirst(records.count - Probe.maxRecords)
        }
        guard let url = Probe.logURL else { return }
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: url, options: .atomic)
        }
    }

    public static func readRaw() -> [ProbeRecord] {
        guard let url = Probe.logURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ProbeRecord].self, from: data)) ?? []
    }

    /// 读日志，并附带一句「读不到的原因」。
    ///
    /// 这个说明很重要：诊断页上「没有日志」有四种完全不同的成因
    /// （App Group 不可用 / 文件还没建 / 读不动 / 解不开），
    /// 一句"无日志"会把它们混成一个谜。
    public static func read() -> (records: [ProbeRecord], note: String) {
        if Probe.containerURL == nil {
            return ([], "App Group 容器拿不到（application-groups entitlement 没生效？）")
        }
        guard let url = Probe.logURL else { return ([], "日志路径拼不出来") }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ([], "日志文件还不存在（隧道从没起来过？）")
        }
        guard let data = try? Data(contentsOf: url) else { return ([], "日志文件读不动") }
        guard let records = try? JSONDecoder().decode([ProbeRecord].self, from: data) else {
            return ([], "日志解不开（两个进程同时写坏了？）")
        }
        return (records, "\(records.count) 条")
    }

    public static func clear() {
        if let url = Probe.logURL {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
