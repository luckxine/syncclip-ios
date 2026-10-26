import Foundation
import SyncClipCore

/// 主 App 与扩展（分享 / 键盘）之间的共享存储，落在 App Group 容器里。
///
/// 为什么是一份手写的文件读写而不是 UserDefaults(suiteName:)：
/// suiteName 在 App Group 不可用的机器上会静默回落到进程私有存储，读写都
/// "成功"但两边看到的是不同文件 —— 失败被藏起来，K1/P4 探针的结论就不可信。
/// 直接落文件的话，拿不到容器 URL 就是拿不到，每一步都能明确降级。
///
/// 所有方法都不抛错：扩展进程里一次未捕获异常就是整个面板白屏/闪退，
/// 失败一律返回 nil / false / 空数组，由调用方走降级文案。
public enum AppGroupStore {

    /// 全项目统一的 App Group ID，主 App 与两个 appex 的 entitlements 里写的都是它。
    public static let groupID = "group.com.cxk.syncclip"

    // MARK: - 容器可用性

    /// 容器根目录。拿不到（entitlement 没签上 / 组不存在）返回 nil。
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    /// 写探针结果的进程内缓存（探针只做一次，免得每次 isAvailable 都落一次盘）。
    private static var probedWritable: Bool?

    /// 容器真的可写吗。
    ///
    /// containerURL 非 nil 不等于可用：TrollStore 伪造签名下 App Group 是否被
    /// 系统承认，本身就是 K1/P4 探针要回答的问题。所以这里做一次真实写探针
    /// （写一个探针文件再删掉），探针失败就当不可用，UI 按降级路径走。
    public static var isAvailable: Bool {
        if let known = probedWritable { return known }
        guard let dir = containerURL else {
            probedWritable = false
            return false
        }
        let probe = dir.appendingPathComponent("probe-\(ProcessInfo.processInfo.processIdentifier)")
        let ok = (try? Data("ok".utf8).write(to: probe, options: .atomic)) != nil
        try? FileManager.default.removeItem(at: probe)
        probedWritable = ok
        return ok
    }

    // MARK: - 服务器配置导出 / 读回

    /// config.json 的形状。导出时间戳是给「配置是什么时候导出的」这类
    /// 排障文案用的；扩展端解析时字段可缺省，老版本写的文件不至于读不开。
    private struct ExportedConfig: Codable {
        var settings: SCAppSettings
        var exportedAt: Date?
    }

    private static let configFileName = "config.json"

    /// 主 App 侧：把当前设置整份导出到容器，供扩展读取。
    ///
    /// 写的是整份 SCAppSettings（全部服务器 + 激活项），loadConfig 时再挑出
    /// 激活的那台 —— 换激活服务器只需重新导出一次，扩展端的读法永远不变。
    /// 密码明文落盘：私有设备上的私有同步服务，可接受，换来 Filza 直接可查。
    @discardableResult
    public static func exportServerConfig(_ settings: SCAppSettings) -> Bool {
        guard let dir = containerURL else { return false }
        let payload = ExportedConfig(settings: settings, exportedAt: Date())
        guard let data = try? JSONEncoder().encode(payload) else { return false }
        do {
            try data.write(to: dir.appendingPathComponent(configFileName), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 扩展侧：读回激活的服务器与设置。
    ///
    /// 任何一步不成立（容器不可用 / 没导出过 / 没有完整的服务器配置）都返回
    /// nil，UI 统一走「打开主 App 一次以导出配置」的降级文案。
    public static func loadConfig() -> (profile: SCServerProfile, settings: SCAppSettings)? {
        guard let dir = containerURL,
              let data = try? Data(contentsOf: dir.appendingPathComponent(configFileName)),
              let exported = try? JSONDecoder().decode(ExportedConfig.self, from: data)
        else { return nil }
        guard let profile = exported.settings.activeServer,
              (try? profile.validate()) != nil
        else { return nil }
        return (profile, exported.settings)
    }

    // MARK: - 共享历史（键盘扩展的取用面板）

    /// 一条共享历史。
    ///
    /// kind/text 的约定（键盘扩展靠它决定点击行为）：
    ///   - text  ：text = 正文本身，点击直接 insertText
    ///   - image ：text = 服务器上的 dataName（文件名），点击后 getFile 写剪贴板
    ///   - file  ：同 image
    public struct HistoryEntry: Codable, Equatable {
        public var kind: String
        public var text: String
        public var at: Date
        /// 图片/文件的附加描述（格式、字节数），纯展示用，可为空。
        public var imageHint: String?

        public init(kind: String, text: String, at: Date = Date(), imageHint: String? = nil) {
            self.kind = kind
            self.text = text
            self.at = at
            self.imageHint = imageHint
        }
    }

    /// 上限 50 条：够键盘面板翻，jsonl 全量重排的成本也可以忽略。
    public static let historyLimit = 50
    private static let historyFileName = "history.jsonl"

    private static var historyFileURL: URL? {
        containerURL?.appendingPathComponent(historyFileName)
    }

    /// 追加一条历史，超过上限环形覆盖（最老的被挤掉）。
    ///
    /// 写入方是主 App 和分享扩展（键盘扩展只读），都是低频动作，所以用
    /// "读全量 → append → 裁剪 → 原子重写"，不搞追加写加偏移截断那套：
    /// 文件永远规整，坏行整行丢弃也不影响其余条目。
    public static func appendHistory(kind: String, text: String, imageHint: String?) {
        guard let url = historyFileURL else { return }
        var entries = loadLines(HistoryEntry.self, from: url)
        entries.append(HistoryEntry(kind: kind, text: text, imageHint: imageHint))
        if entries.count > historyLimit {
            entries.removeFirst(entries.count - historyLimit)
        }
        writeLines(entries, to: url)
    }

    /// 读历史，最新在前。容器不可用 / 文件不存在 / 全是坏行都返回空数组。
    public static func readHistory(limit: Int) -> [HistoryEntry] {
        guard let url = historyFileURL else { return [] }
        let all = loadLines(HistoryEntry.self, from: url)
        return Array(all.suffix(limit).reversed())
    }

    // MARK: - 键盘存活日志（K3 探针）

    private static let keyboardLogLimit = 200
    private static let keyboardLogFileName = "keyboard.log"

    private static var keyboardLogURL: URL? {
        containerURL?.appendingPathComponent(keyboardLogFileName)
    }

    private struct KeyboardLogLine: Codable {
        var at: Date
        var line: String
    }

    /// 追加一行键盘日志，时间戳自动带上（存结构化字段，读出时格式化成前缀）。
    ///
    /// 心跳行是 K3 探针的核心数据：系统把键盘扩展冻结/回收时写不出任何东西，
    /// 心跳的"断流"本身就是被冻结的证据。写失败静默 —— 日志写不进去不该
    /// 影响打字。
    public static func appendKeyboardLog(_ line: String) {
        guard let url = keyboardLogURL else { return }
        var lines = loadLines(KeyboardLogLine.self, from: url)
        lines.append(KeyboardLogLine(at: Date(), line: line))
        if lines.count > keyboardLogLimit {
            lines.removeFirst(lines.count - keyboardLogLimit)
        }
        writeLines(lines, to: url)
    }

    /// 读键盘日志，最新在前，每行形如 "2026-10-26T09:00:00Z heartbeat"。
    public static func readKeyboardLog(limit: Int) -> [String] {
        guard let url = keyboardLogURL else { return [] }
        let formatter = ISO8601DateFormatter()
        return loadLines(KeyboardLogLine.self, from: url)
            .suffix(limit)
            .reversed()
            .map { formatter.string(from: $0.at) + " " + $0.line }
    }

    // MARK: - jsonl 小工具

    /// 逐行解码，坏行直接跳过：一条手改坏的记录不值得拖垮整个面板。
    private static func loadLines<T: Decodable>(_ type: T.Type, from url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        let decoder = JSONDecoder()
        var out: [T] = []
        for line in text.split(separator: "\n") {
            if let item = try? decoder.decode(T.self, from: Data(line.utf8)) {
                out.append(item)
            }
        }
        return out
    }

    private static func writeLines<T: Encodable>(_ items: [T], to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var chunks: [String] = []
        for item in items {
            guard let data = try? encoder.encode(item),
                  let line = String(data: data, encoding: .utf8)
            else { continue }
            chunks.append(line)
        }
        try? chunks.joined(separator: "\n").appending("\n").data(using: .utf8)?
            .write(to: url, options: .atomic)
    }
}
