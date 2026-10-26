import UIKit
import UniformTypeIdentifiers
import SyncClipCore
import SyncClipApp

/// 自定义键盘（Info.plist 的 NSExtensionPrincipalClass 指向本类）。
///
/// 双模式（hasFullAccess）：
///   - 未开完全访问：只读 App Group 里的共享历史文本，点击直接 insertText。
///     这是刻意保守的下限 —— 无完全访问的键盘既不能联网也不能写剪贴板，
///     与其摆一堆点不动的按钮，不如把「为什么点不动」说清楚。
///   - 开了完全访问：追加「最新」按钮（SCClient 拉服务器当前内容：文本
///     insertText，图片/文件 getFile 后写剪贴板），历史里的图片/文件条目
///     也可点击取回写剪贴板。
///
/// 布局选了 UIScrollView + UIStackView 而不是 UICollectionView：条目就 50 条、
/// 都是同一形态的文字行，集合视图的复用机制在这里只剩成本没有收益。
final class KeyboardViewController: UIInputViewController {

    // MARK: - 视图

    private let statusLabel = UILabel()
    private let scrollView = UIScrollView()
    private let stack = UIStackView()

    // MARK: - K3 存活探针

    private var heartbeatTimer: Timer?
    private var appearedAt: Date?
    private let heartbeatInterval: TimeInterval = 30

    /// 唤起即同步协调器。键盘每次弹出都静默跑一轮双向同步
    /// （拉远端图片/文件→写剪贴板 / 读剪贴板新图片/文件→推服务器）。
    /// 这是实现「像微信输入法那样」三端同步的核心，见 KeyboardSyncCoordinator 文档。
    /// statusLabel 在 viewDidLoad 后才绑（属性初始化顺序不保证它此时尚未创建）。
    private let syncCoordinator = KeyboardSyncCoordinator()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGray6

        // 协调器的状态条引用在这时绑：statusLabel 已创建完毕，下面配样式不影响它
        syncCoordinator.statusLabel = statusLabel

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(statusLabel)
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 键盘每次唤起都会走这里，hasFullAccess 的值到这时才可靠
        appearedAt = Date()
        AppGroupStore.appendKeyboardLog("appear hasFullAccess=\(hasFullAccess)")
        startHeartbeat()
        rebuildList()
        // 唤起即同步：已开完全访问才跑，静默一轮双向同步
        syncCoordinator.syncOnAppear(hasFullAccess: hasFullAccess)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        let alive = appearedAt.map { Int(Date().timeIntervalSince($0)) } ?? -1
        AppGroupStore.appendKeyboardLog("disappear alive=\(alive)s hasFullAccess=\(hasFullAccess)")
    }

    // MARK: - 心跳

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        // .common 模式：滚动列表时键盘里的 timer 也不该停摆，否则心跳数据有假空洞
        let timer = Timer(timeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            AppGroupStore.appendKeyboardLog("heartbeat hasFullAccess=\(self?.hasFullAccess ?? false)")
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    // MARK: - 列表构建

    private func rebuildList() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard AppGroupStore.isAvailable else {
            statusLabel.text = "App Group 不可用"
            addPlainLabel("键盘与主 App 的共享容器在这台设备上不可用（K1 探针项，主 App 诊断页有结论）。\n键盘面板功能受限，系统键盘不受影响。")
            return
        }

        statusLabel.text = hasFullAccess ? "完全访问已开启" : "开启完全访问以解锁图片与联网"

        let tools = UIStackView()
        tools.axis = .horizontal
        tools.spacing = 8
        if hasFullAccess {
            let latest = makeToolButton("最新") { [weak self] in self?.pullLatestTapped() }
            latest.setContentHuggingPriority(.required, for: .horizontal)
            tools.addArrangedSubview(latest)
        }
        // 逃生通道：没有它，用户装上这块键盘后可能切不回系统键盘
        let switcher = makeToolButton("切换键盘") { [weak self] in
            self?.advanceToNextInputMode()
        }
        tools.addArrangedSubview(switcher)
        let spacer = UIView()
        tools.addArrangedSubview(spacer)
        stack.addArrangedSubview(tools)

        // 未开完全访问时只列文本条目 —— 联网/写剪贴板都不可用，摆出来也只是
        // 点不动的按钮；「解锁」的提示已经写在顶部状态条里了。
        let entries = AppGroupStore.readHistory(limit: AppGroupStore.historyLimit)
        let visible = hasFullAccess ? entries : entries.filter { $0.kind == "text" }

        if visible.isEmpty {
            addPlainLabel(hasFullAccess
                          ? "暂无历史：在主 App 或分享扩展里推送过内容后，这里会出现条目。"
                          : "暂无文本历史：在主 App 或分享扩展里推送过文本后，这里会出现条目。")
        } else {
            for entry in visible {
                makeRowButton(rowTitle(for: entry)) { [weak self] in
                    self?.entryTapped(entry)
                }
            }
        }
    }

    private func rowTitle(for entry: AppGroupStore.HistoryEntry) -> String {
        switch entry.kind {
        case "image":
            return "[图] " + (entry.imageHint ?? entry.text)
        case "file":
            return "[文件] " + entry.text
        default:
            let body = entry.text.replacingOccurrences(of: "\n", with: " ")
            return body.count > 40 ? String(body.prefix(40)) + "…" : body
        }
    }

    // MARK: - 条目动作

    private func entryTapped(_ entry: AppGroupStore.HistoryEntry) {
        switch entry.kind {
        case "image", "file":
            guard hasFullAccess else {
                statusLabel.text = "开启完全访问后才能取回图片/文件"
                return
            }
            fetchAttachment(dataName: entry.text)
        default:
            textDocumentProxy.insertText(entry.text)
        }
    }

    private func pullLatestTapped() {
        statusLabel.text = "拉取最新…"
        withClient { [weak self] client in
            let profile = try await client.fetchProfile()
            if profile.type == .text && !profile.hasData {
                self?.textDocumentProxy.insertText(profile.text)
                self?.statusLabel.text = "已输入最新文本"
            } else if profile.hasData, let dataName = profile.dataName {
                let data = try await client.getFile(dataName: dataName,
                                                    expectedTransferDataHash: profile.transferDataHash)
                self?.writeToPasteboard(data)
                self?.statusLabel.text = "已复制，去粘贴"
            } else {
                self?.statusLabel.text = "服务器上是空内容"
            }
        }
    }

    private func fetchAttachment(dataName: String) {
        statusLabel.text = "取回中…"
        withClient { [weak self] client in
            let data = try await client.getFile(dataName: dataName)
            self?.writeToPasteboard(data)
            self?.statusLabel.text = "已复制，去粘贴"
        }
    }

    /// 写原始字节进剪贴板（沿用主 App 的策略：不走 UIImage，动图保帧、字节不漂移）。
    private func writeToPasteboard(_ data: Data) {
        let uti = SCImageCodec.sniff(data)?.uti ?? UTType.data.identifier
        UIPasteboard.general.setData(data, forPasteboardType: uti)
    }

    /// 「拿配置 → 建 SCClient → 跑业务」的公共壳：没有配置/网络失败统一在
    /// 状态条上给人话，不弹窗（键盘环境弹窗既难看又抢焦点）。
    private func withClient(_ body: @escaping (SCClient) async throws -> Void) {
        Task { @MainActor in
            do {
                guard let (_, settings) = AppGroupStore.loadConfig() else {
                    statusLabel.text = "没有服务器配置（打开主 App 一次以导出）"
                    return
                }
                let client = try SCClient(config: settings.toConfig())
                try await body(client)
            } catch {
                statusLabel.text = "失败：\(error)"
            }
        }
    }

    // MARK: - 小件

    private func makeToolButton(_ title: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.label, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .callout)
        button.backgroundColor = .systemBackground
        button.layer.cornerRadius = 8
        button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        button.addAction(UIAction(handler: { _ in action() }), for: .touchUpInside)
        return button
    }

    private func makeRowButton(_ title: String, action: @escaping () -> Void) {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.label, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .callout)
        button.titleLabel?.numberOfLines = 2
        button.contentHorizontalAlignment = .left
        button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        button.backgroundColor = .systemBackground
        button.layer.cornerRadius = 8
        button.addAction(UIAction(handler: { _ in action() }), for: .touchUpInside)
        stack.addArrangedSubview(button)
    }

    private func addPlainLabel(_ text: String) {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        stack.addArrangedSubview(label)
    }
}
