import Foundation
import SyncClipCore

// syncclipd —— SyncClipboard 的 iOS 常驻同步客户端（越狱 / LaunchAgent 形态）
//
// 子命令：
//   run                          常驻同步（默认；launchd 用这个）
//   probe [--watch <秒>]         诊断剪贴板：当前内容、changeCount、订阅 Darwin 通知
//   test                         服务器连通性
//   get                          取远端当前内容并打印
//   set <文本>                   把文本推到服务器
//   dump                         打印当前配置与引擎状态
//   selftest                     校验 SigV4 签名算法（用 AWS 官方测试向量）
//
// 全局：--config <path>  指定配置文件；--interval <秒> 覆盖轮询间隔；-v 打开 debug 日志
//
// 配置可以有两种形状，自动识别：
//   1. App 的 JSON（多服务器）：{ "servers": [...], "activeServerID": "..." , ... }
//   2. 守护进程的 plist（单服务器）：{ baseURL, username, password, ... }
// 这样 App 里配好的服务器，越狱环境下守护进程可以直接拿来用，不必重填。

signal(SIGPIPE, SIG_IGN)

// MARK: - 参数

struct Arguments {
    var command: String = "run"
    var operands: [String] = []
    var configPath: String?
    var interval: TimeInterval?
    var verbose = false
    var watchSeconds: Double?
}

func parseArguments(_ argv: [String]) -> Arguments {
    var a = Arguments()
    var rest = argv.dropFirst().map { $0 }
    if let first = rest.first, !first.hasPrefix("-") {
        a.command = first
        rest.removeFirst()
    }
    var i = 0
    while i < rest.count {
        let token = rest[i]
        switch token {
        case "--config":
            i += 1
            if i < rest.count { a.configPath = rest[i] }
        case "--interval":
            i += 1
            if i < rest.count, let d = Double(rest[i]) { a.interval = d }
        case "--watch":
            i += 1
            if i < rest.count, let d = Double(rest[i]) { a.watchSeconds = d } else { a.watchSeconds = 30 }
        case "-v", "--verbose", "--debug":
            a.verbose = true
        case "-h", "--help":
            a.command = "help"
        default:
            a.operands.append(token)
        }
        i += 1
    }
    return a
}

let helpText = """
syncclipd — SyncClipboard iOS 常驻同步客户端

用法：syncclipd [命令] [选项]

命令：
  run                  常驻同步（默认）。给 launchd 用的就是它。
  probe [--watch 秒]   诊断剪贴板：读到的内容、changeCount、Darwin 通知订阅情况
  test                 服务器连通性
  get                  取远端当前内容并打印到 stdout
  set <文本>           把文本推到服务器
  dump                 打印生效的配置与引擎状态
  selftest             用 AWS 官方测试向量校验 SigV4 签名算法

选项：
  --config <path>      指定配置文件（默认按顺序找 HOME/Library/Preferences/… 与 App 的 JSON）
  --interval <秒>      覆盖轮询间隔（默认取配置里的 pollInterval）
  -v, --verbose        输出 debug 日志
  -h, --help           显示本帮助
"""

// MARK: - 配置加载（两种形状都认）

/// 依次尝试的配置文件位置：优先 App 的 JSON，其次守护进程的 plist。
func candidateConfigPaths(_ explicit: String?) -> [String] {
    if let explicit { return [explicit] }
    var paths: [String] = []
    if let env = ProcessInfo.processInfo.environment["SYNCCLIP_CONFIG"], !env.isEmpty {
        paths.append(env)
    }
    let home = ProcessInfo.processInfo.environment["HOME"] ?? "/var/mobile"
    // App 的 JSON 在容器里，路径不固定；这里先看几个常见位置
    paths.append(home + "/Documents/syncclip-config.json")
    paths.append(home + "/Library/Preferences/com.cxk.syncclip.plist")
    paths.append(SCConfig.defaultConfigPath)
    paths.append("/var/jb/etc/syncclipd.plist")
    return paths
}

enum LoadedConfig {
    case appSettings(SCAppSettings, path: String)
    case engine(SCConfig, path: String)

    var path: String {
        switch self {
        case .appSettings(_, let p), .engine(_, let p): return p
        }
    }

    func engineConfig() throws -> SCConfig {
        switch self {
        case .appSettings(let s, _): return try s.toConfig()
        case .engine(let c, _): return c
        }
    }

    /// 显示用的服务器描述
    var serverDescription: String {
        switch self {
        case .appSettings(let s, _):
            guard let p = s.activeServer else { return "(未配置服务器)" }
            return "[\(p.type.displayName)] \(p.displaySubtitle)"
        case .engine(let c, _):
            return "[\(c.serverType.displayName)] \(c.profile.displaySubtitle)"
        }
    }
}

func loadConfig(for command: String) -> LoadedConfig? {
    guard command != "probe", command != "help", command != "selftest" else { return nil }

    var tried: [String] = []
    for path in candidateConfigPaths(arguments.configPath) {
        guard FileManager.default.fileExists(atPath: path) else {
            tried.append(path)
            continue
        }
        do {
            // 先按 App 的 JSON 试（多服务器格式）
            if let data = FileManager.default.contents(atPath: path),
               let settings = try? JSONDecoder().decode(SCAppSettings.self, from: data),
               settings.hasServers {
                return .appSettings(settings, path: path)
            }
            // 退回守护进程的 plist
            return .engine(try SCConfig.load(explicitPath: path).config, path: path)
        } catch {
            FileHandle.standardError.write(Data("配置文件 \(path) 读取失败：\(error)\n".utf8))
            exit(2)
        }
    }

    FileHandle.standardError.write(Data(
        ("找不到配置文件。已尝试：\n  " + tried.joined(separator: "\n  ")
         + "\n在 App 里配好服务器，或用 --config 指定。\n").utf8))
    exit(2)
}

// MARK: - 常驻循环

final class Daemon {

    private var config: SCConfig
    private var engine: SCSyncEngine
    private var configPath: String?
    private var configFingerprint: SCConfig.Fingerprint?
    private let intervalOverride: TimeInterval?

    /// 由 Darwin 通知置位；true 时立刻跑一轮
    private let wakeFlag = WakeFlag()

    final class WakeFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        func consume() -> Bool {
            lock.lock(); defer { lock.unlock() }
            let v = flag; flag = false; return v
        }
    }

    init(config: SCConfig, path: String?, intervalOverride: TimeInterval?) throws {
        self.config = config
        self.configPath = path
        self.engine = try SCSyncEngine(config: config)
        self.intervalOverride = intervalOverride
        self.configFingerprint = path.map { SCConfig.fingerprint(of: $0) }
    }

    private var pollInterval: TimeInterval {
        intervalOverride ?? config.pollInterval
    }

    func run() async {
        SCLog.info("syncclipd 启动 [\(config.serverType.displayName)] "
                   + "\(config.profile.displaySubtitle)，轮询 \(String(format: "%.1f", pollInterval))s，"
                   + "启动=\(config.startupSync.rawValue)，冲突=\(config.conflictResolution.rawValue)")
        if let p = configPath { SCLog.info("配置文件：\(p)") }

        // 订阅剪贴板相关 Darwin 通知（有就加速，没有也不影响）
        let queue = DispatchQueue(label: "com.cxk.syncclip.darwin")
        let tokens = SCDarwinNotify.observe(SCDarwinNotify.clipboardCandidates, queue: queue) { _ in
            self.wakeFlag.set()
        }
        if tokens.isEmpty {
            SCLog.info("未订阅到剪贴板通知，纯轮询模式")
        } else {
            SCLog.info("已订阅 \(tokens.count) 个剪贴板通知名")
        }
        defer { SCDarwinNotify.cancel(tokens) }

        while true {
            let stats = await engine.syncOnce()
            if stats.action != .idle || !stats.note.isEmpty {
                SCLog.debug("同步结果：\(stats.action.rawValue) — \(stats.note)")
            }
            reloadConfigIfChanged()
            await sleepInterruptibly(seconds: pollInterval)
        }
    }

    /// 配置变了就重建 engine（保留已对齐的远端 hash，避免整轮重来）
    private func reloadConfigIfChanged() {
        guard let path = configPath else { return }
        let now = SCConfig.fingerprint(of: path)
        guard now != configFingerprint else { return }
        configFingerprint = now

        guard let loaded = loadConfig(for: "run") else { return }
        do {
            let fresh = try loaded.engineConfig()
            let carry = engine.state
            config = fresh
            engine = try SCSyncEngine(config: fresh)
            engine.adopt(state: carry)
            SCLog.info("配置已热更新：[\(fresh.serverType.displayName)] \(fresh.profile.displaySubtitle)")
        } catch {
            SCLog.error("配置热更新失败，继续用旧配置：\(error)")
        }
    }

    /// 等一段时间，但被 wakeFlag（Darwin 通知）打断就提前返回
    private func sleepInterruptibly(seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if wakeFlag.consume() { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        _ = wakeFlag.consume()
    }
}

// MARK: - 主流程

let arguments = parseArguments(CommandLine.arguments)

if arguments.verbose { SCLog.level = .debug }
SCLog.rotateLogFileIfNeeded()

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

switch arguments.command {

case "help":
    print(helpText)
    exit(0)

case "selftest":
    let result = SCSigV4.selfTest()
    print(result.passed ? "✅ \(result.detail)" : "❌ \(result.detail)")
    exit(result.passed ? 0 : 1)

case "probe":
    print("剪贴板诊断")
    print("  hasStrings  : \(SCPasteboard.hasText)")
    print("  changeCount : \(SCPasteboard.changeCount)")
    print("  types       : \(SCPasteboard.typeIdentifiers.joined(separator: ", "))")
    print("  notify      : \(SCDarwinNotify.isAvailable ? "可用" : "不可用（走纯轮询）")")
    if let t = SCPasteboard.readText() {
        print("  text        : \(t.count) 字符 / \(t.utf8.count) 字节")
        print("  hash        : \(SCProfile.textHash(t))")
        print("  preview     : \(t.prefix(200).replacingOccurrences(of: "\n", with: "\\n"))")
    } else {
        print("  text        : (无可读文本)")
    }

    if let watch = arguments.watchSeconds {
        print("\n监听 \(Int(watch)) 秒：每 0.5s 采样一次 changeCount\n")
        let queue = DispatchQueue(label: "com.cxk.syncclip.probe")
        let tokens = SCDarwinNotify.observe(SCDarwinNotify.clipboardCandidates, queue: queue) { name in
            print("[\(ISO8601DateFormatter().string(from: Date()))] 🔔 收到通知：\(name)")
            fflush(stdout)
        }
        print("已订阅通知 \(tokens.count) 个\n")

        var last = SCPasteboard.changeCount
        let end = Date().addingTimeInterval(watch)
        while Date() < end {
            let cc = SCPasteboard.changeCount
            if cc != last {
                let t = SCPasteboard.readText() ?? "(非文本)"
                print("[\(ISO8601DateFormatter().string(from: Date()))] ✅ changeCount \(last) → \(cc)  text=\(t.prefix(60))")
                fflush(stdout)
                last = cc
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        SCDarwinNotify.cancel(tokens)
        print("\n采样结束。出现 ✅ 说明 changeCount 检测有效；出现 🔔 说明对应通知名可用。")
    }
    exit(0)

case "run":
    guard let loaded = loadConfig(for: "run") else { exit(2) }
    do {
        let daemon = try Daemon(config: try loaded.engineConfig(),
                                path: loaded.path,
                                intervalOverride: arguments.interval)
        await daemon.run()
    } catch {
        fail("无法启动：\(error)", code: 2)
    }

case "test":
    guard let loaded = loadConfig(for: "test") else { exit(2) }
    print("服务器：\(loaded.serverDescription)")
    do {
        let engine = try SCSyncEngine(config: try loaded.engineConfig())
        let info = await engine.probeServer()
        print("  可达    : \(info.reachable ? "是" : "否")")
        if let v = info.version { print("  服务端版本: \(v)") }
        print("  详情    : \(info.message)")
        exit(info.reachable ? 0 : 1)
    } catch {
        fail("配置不完整：\(error)", code: 2)
    }

case "get":
    guard let loaded = loadConfig(for: "get") else { exit(2) }
    do {
        let engine = try SCSyncEngine(config: try loaded.engineConfig())
        if let text = try await engine.manualGet() {
            print(text)
            exit(0)
        }
        fail("远端当前不是可同步的文本内容")
    } catch {
        fail("\(error)")
    }

case "set":
    guard let loaded = loadConfig(for: "set") else { exit(2) }
    let text = arguments.operands.joined(separator: " ")
    guard !text.isEmpty else { fail("用法：syncclipd set <文本>", code: 2) }
    do {
        let engine = try SCSyncEngine(config: try loaded.engineConfig())
        try await engine.manualSet(text)
        print("已推送 \(text.utf8.count) 字节")
        exit(0)
    } catch {
        fail("\(error)")
    }

case "dump":
    guard let loaded = loadConfig(for: "dump") else { exit(2) }
    print("配置文件: \(loaded.path)")
    do {
        let cfg = try loaded.engineConfig()
        let p = cfg.profile
        print("类型: \(cfg.serverType.rawValue)（\(cfg.serverType.displayName)）")
        print("名称: \(p.displayTitle)")
        print("地址: \(p.url.isEmpty ? "(留空，用 AWS 默认端点)" : p.url)")
        print("\(cfg.serverType.usernameLabel): \(p.username)")
        print("\(cfg.serverType.passwordLabel): \(p.password.isEmpty ? "(空)" : String(repeating: "*", count: min(p.password.count, 8)))")
        if cfg.serverType == .s3 {
            print("区域: \(p.region)")
            print("存储桶: \(p.bucketName)")
            print("对象前缀: \(p.objectPrefix.isEmpty ? "(无)" : p.objectPrefix)")
            print("路径风格: \(p.forcePathStyle ? "是" : "否")")
        }
        print("pollInterval: \(cfg.pollInterval)")
        print("startupSync: \(cfg.startupSync.rawValue)")
        print("conflictResolution: \(cfg.conflictResolution.rawValue)")

        if case .appSettings(let s, _) = loaded, s.servers.count > 1 {
            print("--- 其他已保存的服务器（共 \(s.servers.count) 台，App 里可切换）---")
            for server in s.servers where server.id != s.activeServer?.id {
                print("  [\(server.type.badge)] \(server.displayTitle) — \(server.displaySubtitle)")
            }
        }

        let engine = try? SCSyncEngine(config: cfg)
        print("--- 引擎状态 ---")
        print("lastLocalDigest: \(engine?.state.lastLocalDigest ?? "(nil)")")
        print("lastLocalKind  : \(engine?.state.lastLocalKind ?? .none)")
        print("lastRemoteHash: \(engine?.state.lastRemoteHash ?? "")")
        print("primed        : \(engine?.state.primed ?? false)")
        exit(0)
    } catch {
        fail("配置不完整：\(error)", code: 2)
    }

default:
    fail("未知命令：\(arguments.command)\n\n\(helpText)", code: 2)
}
