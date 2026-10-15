import Foundation

/// SyncClipboard 官方服务器的实时推送通道（SignalR over WebSocket）。
///
/// 为什么值得做：官方服务端本来就带 SignalR Hub，谁 PUT 了新剪贴板，
/// 服务端就把**新的 profile 内容本身**推给所有在线客户端
/// （`SyncClipboardController` 里 `_hubContext.Clients.All.RemoteProfileChanged(profileDto)`）。
/// 官方 Windows/macOS 客户端就是这么收到「另一台机器复制了东西」的。
/// 有了它，手机端不必再每 2 秒去问一次服务器，PC 上复制 → 手机上几乎是立刻就能用。
///
/// ## 协议（照官方客户端 `OfficialAdapter` 的实现对齐）
///
/// 服务器侧（`Web.cs`）：`AddAuthentication("BasicAuthentication")` + `MapHub<SyncClipboardHub>("/SyncClipboardHub")`，
/// Hub 上带 `[Authorize]`。官方客户端连的时候就是塞一个普通头：
///
/// ```csharp
/// config.Headers.Add("Authorization", "Basic " + base64(user + ":" + password));
/// ```
///
/// 所以这里也一样：握手请求带 `Authorization: Basic …`。**不需要 JWT、不需要 access_token**
/// —— 这一点是从官方实现里读出来的，不靠猜。
///
/// 连接本身用 SignalR 的 **JSON 协议**，消息之间以 `0x1e`（RS）分隔：
///   → 先发握手 `{"protocol":"json","version":1}\x1e`，服务器回 `{}\x1e`
///   ← 服务器调用客户端方法：`{"type":1,"target":"RemoteProfileChanged","arguments":[{…}]}\x1e`
///   ← 心跳：`{"type":6}\x1e`（服务器每 15 秒发一次，客户端也得发，否则 30 秒后被判超时）
///
/// 这里**跳过 negotiate**，直接连 WebSocket —— SignalR 只在 WebSockets 传输时才允许这么做，
/// 而我们就只用 WebSockets。少一次往返，也少一个要处理的响应格式。
public final class SCSignalR: @unchecked Sendable {

    // MARK: - 对外状态

    public enum State: Equatable {
        case idle
        case connecting
        case connected
        /// 断线等待重连（剩余秒数 + 原因）
        case waiting(TimeInterval, String)
        case failed(String)

        public var label: String {
            switch self {
            case .idle: return "未启动"
            case .connecting: return "连接中"
            case .connected: return "已连接"
            case .waiting(let s, _): return "\(Int(s))s 后重连"
            case .failed(let why): return "失败：\(why)"
            }
        }

        public var isConnected: Bool { self == .connected }
    }

    public enum Event {
        case state(State)
        /// 服务器推来了新的剪贴板内容
        case remoteProfile(SCProfile)
        /// 历史记录变化（本项目暂不处理，留着不浪费）
        case remoteHistory
    }

    /// 给诊断页看的一组数字
    public struct Snapshot {
        public var state: State = .idle
        public var connectCount = 0
        public var profilePushCount = 0
        public var lastEventAt: Date?
        public var lastDisconnectReason: String?
        public var hubURL: String = ""
    }

    public static let hubPath = "/SyncClipboardHub"

    /// 所有回调都在**后台队列**上调用，UI 侧自己切主线程
    public var onEvent: ((Event) -> Void)?

    // MARK: - 内部

    private let hubURL: URL
    private let authHeader: String
    private let queue = DispatchQueue(label: "com.cxk.syncclip.signalr")
    private let session: URLSession
    private let lock = NSLock()

    private var task: URLSessionWebSocketTask?
    private var ping: DispatchSourceTimer?
    private var retryWork: DispatchWorkItem?
    private var handshakeWork: DispatchWorkItem?
    private var stopped = true
    private var attempt = 0
    private var buffer = Data()

    private var state: State = .idle
    private var connectCount = 0
    private var profilePushCount = 0
    private var lastEventAt: Date?
    private var lastDisconnectReason: String?

    /// 握手之后多久没收到服务器任何消息就当成握手失败
    private static let handshakeTimeout: TimeInterval = 8
    /// 客户端心跳间隔。服务器超时是 30 秒，10 秒发一次很安全。
    private static let pingInterval: TimeInterval = 10

    // MARK: - 构造

    /// - Returns: nil 表示这台服务器不是 SyncClipboard 官方服务器（WebDAV / S3 没有 Hub）
    public init?(profile: SCServerProfile, timeout: TimeInterval = 15) {
        guard profile.type == .syncclipboard else {
            SCLog.info("服务器类型是 \(profile.type.displayName)，没有 SignalR Hub，跳过实时推送")
            return nil
        }
        let raw = profile.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: raw), let scheme = base.scheme?.lowercased(),
              base.host != nil, scheme == "http" || scheme == "https" else {
            SCLog.warn("SignalR：服务器地址不合法（\(raw)）")
            return nil
        }

        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = (scheme == "https") ? "wss" : "ws"
        // 服务器可能挂在子路径下，所以把 hub 路径接在原 path 后面而不是覆盖它
        let existing = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
        comps.path = existing + Self.hubPath
        comps.query = nil
        comps.fragment = nil
        guard let url = comps.url else { return nil }
        self.hubURL = url

        let credential = "\(profile.username):\(profile.password)"
        self.authHeader = "Basic " + Data(credential.utf8).base64EncodedString()

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.waitsForConnectivity = false
        cfg.httpShouldSetCookies = false
        self.session = URLSession(configuration: cfg)

        SCLog.info("SignalR 目标：\(url.absoluteString)（服务器 \(profile.displayTitle)）")
    }

    // MARK: - 生命周期

    public func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard self.stopped else { return }
            self.stopped = false
            self.attempt = 0
            self.connect()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.stopped = true
            self.cancelPending()
            self.teardown()
            self.setState(.idle)
        }
    }

    /// 从后台回到前台时叫一下：长连接大概已经被系统掐了，这里立刻重连而不是等退避
    public func nudge() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard !self.stopped else { return }
            guard !self.state.isConnected else { return }
            self.cancelPending()
            self.attempt = 0
            self.teardown()
            self.connect()
        }
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        var s = Snapshot()
        s.state = state
        s.connectCount = connectCount
        s.profilePushCount = profilePushCount
        s.lastEventAt = lastEventAt
        s.lastDisconnectReason = lastDisconnectReason
        s.hubURL = hubURL.absoluteString
        return s
    }

    // MARK: - 连接

    private func connect() {
        guard !stopped else { return }
        setState(.connecting)

        var request = URLRequest(url: hubURL)
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue("SyncClipboard-iOS", forHTTPHeaderField: "User-Agent")

        let wsTask = session.webSocketTask(with: request)
        task = wsTask
        buffer.removeAll()
        wsTask.resume()

        // SignalR 握手：JSON 协议、版本 1
        sendRaw("{\"protocol\":\"json\",\"version\":1}\u{1e}")

        // 握手回包没有独立的回调，所以用「收到任何一条消息」当连接成功的标志，
        // 再加一个兜底定时器：超时还没消息就判定失败并重连，
        // 免得「连上了但服务器不说话」永远停在 connecting。
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.task === wsTask, !self.state.isConnected else { return }
            self.handleDisconnect("握手超时（\(Int(Self.handshakeTimeout)) 秒内服务器没有回应）")
        }
        handshakeWork = work
        queue.asyncAfter(deadline: .now() + Self.handshakeTimeout, execute: work)

        receiveNext()
        startPing()
    }

    private func markConnected() {
        handshakeWork?.cancel()
        handshakeWork = nil
        guard !state.isConnected else { return }
        attempt = 0
        connectCount += 1
        SCLog.info("SignalR 已连接（第 \(connectCount) 次）")
        setState(.connected)
    }

    private func handleDisconnect(_ reason: String) {
        guard !stopped else { return }
        lastDisconnectReason = reason
        cancelPending()
        teardown()

        attempt += 1
        // 退避：1,2,4,8,16,30,30…（封顶 30 秒，别把电池和服务器都耗在这上面）
        let delay = min(30, pow(2, Double(min(attempt, 5))) / 2)
        SCLog.warn("SignalR 断开：\(reason)；\(Int(delay)) 秒后重连")
        setState(.waiting(delay, reason))

        let work = DispatchWorkItem { [weak self] in self?.connect() }
        retryWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func teardown() {
        ping?.cancel()
        ping = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func cancelPending() {
        retryWork?.cancel()
        retryWork = nil
        handshakeWork?.cancel()
        handshakeWork = nil
    }

    // MARK: - 收发

    private func startPing() {
        ping?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self] in
            self?.sendRaw("{\"type\":6}\u{1e}")
        }
        timer.resume()
        ping = timer
    }

    private func sendRaw(_ text: String) {
        guard let task = task else { return }
        task.send(.string(text)) { [weak self] error in
            guard let error = error else { return }
            self?.queue.async {
                self?.handleDisconnect("发送失败：\(error.localizedDescription)")
            }
        }
    }

    private func receiveNext() {
        guard let task = task else { return }
        task.receive { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                switch result {
                case .failure(let error):
                    self.handleDisconnect(Self.describe(error))
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.feed(Data(text.utf8))
                    case .data(let data):
                        self.feed(data)
                    @unknown default:
                        break
                    }
                    self.receiveNext()
                }
            }
        }
    }

    /// 攒够一条以 0x1e 结尾的记录再处理 —— WebSocket 不保证一条消息就是一条协议消息
    private func feed(_ data: Data) {
        buffer.append(data)
        let separator = UInt8(0x1e)
        while let index = buffer.firstIndex(of: separator) {
            let frame = buffer[buffer.startIndex..<index]
            buffer.removeSubrange(buffer.startIndex...index)
            if !frame.isEmpty {
                handleFrame(Data(frame))
            }
        }
        // 防御：万一对面不发分隔符，别让缓冲区无限长
        if buffer.count > 4 * 1024 * 1024 { buffer.removeAll() }
    }

    private func handleFrame(_ data: Data) {
        if !state.isConnected {
            // 服务器回的第一条（`{}`）就是握手完成
            markConnected()
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            SCLog.debug("SignalR 收到无法解析的帧（\(data.count) 字节）")
            return
        }
        let type = (object["type"] as? NSNumber)?.intValue ?? -1

        switch type {
        case 1:
            let target = object["target"] as? String ?? ""
            let args = object["arguments"] as? [Any] ?? []
            switch target {
            case "RemoteProfileChanged":
                if let first = args.first, let profile = Self.decodeProfile(first) {
                    lastEventAt = Date()
                    profilePushCount += 1
                    SCLog.info("SignalR 收到远端新剪贴板：\(profile.summary)")
                    emit(.remoteProfile(profile))
                }
            case "RemoteHistoryChanged":
                emit(.remoteHistory)
            default:
                SCLog.debug("SignalR 收到未处理的方法调用：\(target)")
            }

        case 6:
            break                                  // 服务器心跳，不用回

        case 7:
            handleDisconnect("服务器要求关闭连接")

        case 3:
            break                                  // 调用完成回执，我们没发起过调用

        default:
            SCLog.debug("SignalR 收到 type=\(type) 的帧")
        }
    }

    /// 把 arguments[0] 重新编码再解码成 SCProfile。
    /// 绕这一圈是为了复用 SCProfile 里那套容错解码（服务端会省略 null 字段）。
    static func decodeProfile(_ any: Any) -> SCProfile? {
        guard JSONSerialization.isValidJSONObject(any),
              let data = try? JSONSerialization.data(withJSONObject: any) else { return nil }
        do {
            return try JSONDecoder().decode(SCProfile.self, from: data)
        } catch {
            SCLog.warn("SignalR 推来的 profile 解不开：\(error)")
            return nil
        }
    }

    // MARK: - 状态发布

    private func setState(_ new: State) {
        lock.lock()
        let changed = (state != new)
        state = new
        lock.unlock()
        if changed { emit(.state(new)) }
    }

    private func emit(_ event: Event) {
        onEvent?(event)
    }

    static func describe(_ error: Error) -> String {
        let e = error as NSError
        // WebSocket 最常见的两种：断线（-1005/-1001）和 TLS/网络栈错误
        switch e.code {
        case -1005: return "连接被服务器断开（-1005）"
        case -1001: return "请求超时（-1001）"
        case -1003: return "找不到主机（-1003）"
        case -1004: return "连不上服务器（-1004）"
        case -1200, -1201, -1202: return "TLS 握手失败（\(e.code)），自签证书的话会这样"
        default:
            var s = "\(e.domain) \(e.code)：“\(e.localizedDescription)”"
            if let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError {
                s += " ← \(underlying.domain) \(underlying.code)"
            }
            return s
        }
    }
}
