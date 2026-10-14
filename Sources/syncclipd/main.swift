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
//
// 全局：--config <path>  指定配置文件；--interval <秒> 覆盖轮询间隔；-v 打开 debug 日志

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
            if i < rest.count, let d = Double(rest[i]) {
                a.watchSeconds = d
            } else {
                a.watchSeconds = 30
            }
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
  test                 服务器连通性与版本
  get                  取远端当前内容并打印到 stdout
  set <文本>           把文本推到服务器
  dump                 打印生效的配置与引擎状态

选项：
  --config <path>      指定配置文件（默认按顺序找 HOME/Library/Preferences/com.cxk.syncclip.plist 等）
  --interval <秒>      覆盖轮询间隔（默认取配置里的 pollInterval）
  -v, --verbose        输出 debug 日志
  -h, --help           显示本帮助
"""

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

    init(config: SCConfig, path: String?, intervalOverride: TimeInterval?) {
        self.config = config
        self.configPath = path
        self.engine = SCSyncEngine(config: config)
        self.intervalOverride = intervalOverride
        self.configFingerprint = path.map { SCConfig.fingerprint(of: $0) }
    }

    private var pollInterval: TimeInterval {
        intervalOverride ?? config.pollInterval
    }

    func run() async {
        SCLog.info("syncclipd 启动：服务器 \(config.baseURL.absoluteString)，轮询 \(String(format: "%.1f", pollInterval))s，启动策略=\(config.startupSync.rawValue)")
        if let p = configPath { SCLog.info("配置文件：\(p)") }

        // 订阅剪贴板相关 Darwin 通知（有就加速，没有也不影响）
        let queue = DispatchQueue(label: "com.cxk.syncclip.darwin")
        let tokens = SCDarwinNotify.observe(SCDarwinNotify.clipboardCandidates,
                                            queue: queue) { name in
            SCLog.debug("收到通知 \(name)，提前唤醒同步")
            self.wakeFlag.set()
        }
        if tokens.isEmpty {
            SCLog.info("未订阅到任何剪贴板通知，纯轮询模式")
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

        do {
            let loaded = try SCConfig.load(explicitPath: path)
            let carry = engine.state
            config = loaded.config
            engine = SCSyncEngine(config: config)
            engine.adopt(state: carry)
            SCLog.info("配置已热更新：轮询 \(String(format: "%.1f", pollInterval))s")
        } catch {
            SCLog.error("配置热更新失败，继续用旧配置：\(error)")
        }
    }

    /// 等一段时间，但被 wakeFlag（Darwin 通知）或 SIGTERM 打断就提前返回。
    private func sleepInterruptibly(seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if wakeFlag.consume() { return }
            try? await Task.sleep(nanoseconds: 150_000_000)   // 150ms 粒度
        }
        _ = wakeFlag.consume()
    }
}

// MARK: - 主流程

let args = parseArguments(CommandLine.arguments)

if args.verbose { SCLog.level = .debug }
SCLog.rotateLogFileIfNeeded()

func loadConfig(for command: String) -> (SCConfig, String?)? {
    // probe 不需要配置
    guard command != "probe", command != "help" else { return nil }
    do {
        let (cfg, path) = try SCConfig.load(explicitPath: args.configPath)
        return (cfg, path)
    } catch {
        FileHandle.standardError.write(Data("错误：\(error)\n".utf8))
        exit(2)
    }
}

switch args.command {

case "help":
    print(helpText)
    exit(0)

case "probe":
    // 诊断：不碰服务器，只做剪贴板体检
    print("剪贴板诊断")
    print("  hasStrings  : \(SCPasteboard.hasText)")
    print("  changeCount : \(SCPasteboard.changeCount)")
    print("  types       : \(SCPasteboard.typeIdentifiers.joined(separator: ", "))")
    if let t = SCPasteboard.readText() {
        print("  text        : \(t.count) 字符 / \(t.utf8.count) 字节")
        print("  hash        : \(SCProfile.textHash(t))")
        print("  preview     : \(t.prefix(200).replacingOccurrences(of: "\n", with: "\\n"))")
    } else {
        print("  text        : (无可读文本)")
    }

    if let watch = args.watchSeconds {
        print("\n监听 \(Int(watch)) 秒：每 0.5s 采样一次 changeCount，并订阅 Darwin 通知\n")
        let queue = DispatchQueue(label: "com.cxk.syncclip.probe")
        let tokens = SCDarwinNotify.observe(SCDarwinNotify.clipboardCandidates,
                                            queue: queue) { name in
            let stamp = ISO8601DateFormatter().string(from: Date())
            print("[\(stamp)] 🔔 收到通知：\(name)")
            fflush(stdout)
        }
        print("已订阅通知 \(tokens.count) 个：\(SCDarwinNotify.clipboardCandidates.joined(separator: ", "))\n")

        var last = SCPasteboard.changeCount
        let end = Date().addingTimeInterval(watch)
        var ticks = 0
        while Date() < end {
            let cc = SCPasteboard.changeCount
            if cc != last {
                let stamp = ISO8601DateFormatter().string(from: Date())
                let t = SCPasteboard.readText() ?? "(非文本)"
                print("[\(stamp)] ✅ changeCount \(last) → \(cc)  text=\(t.prefix(60))")
                fflush(stdout)
                last = cc
            }
            ticks += 1
            Thread.sleep(forTimeInterval: 0.5)
        }
        SCDarwinNotify.cancel(tokens)
        print("\n采样结束（\(ticks) 次）。若你在期间复制过内容，上面出现 ✅ 说明 changeCount 检测有效；")
        print("出现 🔔 说明对应的通知名可用（可用来把同步降级成事件驱动）。")
    }
    exit(0)

case "run":
    guard let (cfg, path) = loadConfig(for: "run") else { exit(2) }
    let daemon = Daemon(config: cfg, path: path, intervalOverride: args.interval)
    await daemon.run()

case "test":
    guard let (cfg, _) = loadConfig(for: "test") else { exit(2) }
    print("服务器：\(cfg.baseURL.absoluteString)")
    // 注意：switch 各 case 的变量名不要重复，一律用带前缀的名字
    let testEngine = SCSyncEngine(config: cfg)
    let info = await testEngine.probeServer()
    print("  可达    : \(info.reachable ? "是" : "否")")
    if let v = info.version { print("  服务端版本: \(v)") }
    print("  详情    : \(info.message)")
    exit(info.reachable ? 0 : 1)

case "get":
    guard let (cfg, _) = loadConfig(for: "get") else { exit(2) }
    let getEngine = SCSyncEngine(config: cfg)
    do {
        if let text = try await getEngine.manualGet() {
            print(text)
            exit(0)
        } else {
            FileHandle.standardError.write(Data("远端当前不是可同步的文本内容\n".utf8))
            exit(1)
        }
    } catch {
        FileHandle.standardError.write(Data("错误：\(error)\n".utf8))
        exit(1)
    }

case "set":
    guard let (cfg, _) = loadConfig(for: "set") else { exit(2) }
    let text = args.operands.joined(separator: " ")
    guard !text.isEmpty else {
        FileHandle.standardError.write(Data("用法：syncclipd set <文本>\n".utf8))
        exit(2)
    }
    let setEngine = SCSyncEngine(config: cfg)
    do {
        try await setEngine.manualSet(text)
        print("已推送 \(text.utf8.count) 字节")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("错误：\(error)\n".utf8))
        exit(1)
    }

case "dump":
    guard let (cfg, path) = loadConfig(for: "dump") else { exit(2) }
    print("配置文件: \(path ?? "(内置)")")
    print("baseURL: \(cfg.baseURL.absoluteString)")
    print("username: \(cfg.username)")
    print("password: \(cfg.password.isEmpty ? "(空)" : String(repeating: "*", count: min(cfg.password.count, 8)))")
    print("pollInterval: \(cfg.pollInterval)")
    print("startupSync: \(cfg.startupSync.rawValue)")
    print("pullOverwritesLocal: \(cfg.pullOverwritesLocal)")
    let dumpEngine = SCSyncEngine(config: cfg)
    print("--- 引擎状态 ---")
    print("lastLocalHash : \(dumpEngine.state.lastLocalHash ?? "(nil)")")
    print("lastRemoteHash: \(dumpEngine.state.lastRemoteHash)")
    print("primed        : \(dumpEngine.state.primed)")
    exit(0)

default:
    FileHandle.standardError.write(Data("未知命令：\(args.command)\n\n\(helpText)\n".utf8))
    exit(2)
}
