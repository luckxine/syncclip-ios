import Foundation
import NetworkExtension
import UIKit
import PasteProbeShared

/// 探针的界面：一个状态区 + 一块日志 + 六个按钮。
///
/// 它同时充当"仪表盘"：状态区实时显示 App Group 是否可用、隧道状态、剪贴板
/// 的 changeCount —— 排查这类问题时，这三个数字比任何日志都直观。
final class ProbeViewController: UIViewController {

    private let runner = ProbeRunner()
    private let statusLabel = UILabel()
    private let logView = UITextView()
    private var statusTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildUI()

        runner.onLine = { [weak self] line in
            self?.append(line)
        }

        append("就绪。按「运行探针」开始。")
        append("App bundle id  ：\(Probe.appBundleID)")
        append("appex bundle id：\(Probe.tunnelBundleID)")
        append("App Group      ：\(Probe.appGroupID)")

        refreshStatus()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    deinit {
        statusTimer?.invalidate()
    }

    // MARK: - UI

    private func buildUI() {
        let title = UILabel()
        title.text = "NE 探针：非越狱设备能不能跑网络扩展"
        title.font = .boldSystemFont(ofSize: 16)
        title.numberOfLines = 0

        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.numberOfLines = 0
        statusLabel.textColor = .secondaryLabel

        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.isEditable = false
        logView.layer.borderWidth = 1
        logView.layer.borderColor = UIColor.separator.cgColor
        logView.layer.cornerRadius = 6
        logView.textContainerInset = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        logView.setContentHuggingPriority(.defaultLow, for: .vertical)
        logView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let row1 = makeRow([
            makeButton("运行探针", #selector(runTapped)),
            makeButton("停止隧道", #selector(stopTapped)),
            makeButton("刷新日志", #selector(dumpTapped)),
        ])
        let row2 = makeRow([
            makeButton("开机自启", #selector(onDemandTapped)),
            makeButton("还原剪贴板", #selector(restoreTapped)),
            makeButton("清空日志", #selector(clearTapped)),
        ])

        let stack = UIStackView(arrangedSubviews: [title, statusLabel, logView, row1, row2])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
        ])
    }

    private func makeButton(_ title: String, _ action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 13)
        button.titleLabel?.numberOfLines = 2
        button.titleLabel?.textAlignment = .center
        button.layer.borderWidth = 1
        button.layer.borderColor = UIColor.systemBlue.cgColor
        button.layer.cornerRadius = 6
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func makeRow(_ buttons: [UIButton]) -> UIStackView {
        let row = UIStackView(arrangedSubviews: buttons)
        row.axis = .horizontal
        row.spacing = 6
        row.distribution = .fillEqually
        return row
    }

    // MARK: - 按钮

    @objc private func runTapped() { runner.run() }

    @objc private func stopTapped() { runner.stopTunnel() }

    @objc private func dumpTapped() { runner.dumpTunnelLog() }

    @objc private func onDemandTapped() { runner.enableOnDemand() }

    @objc private func restoreTapped() { runner.restoreClipboard() }

    @objc private func clearTapped() {
        ProbeLog.clear()
        append("已清空 App Group 日志")
        refreshStatus()
    }

    // MARK: - 渲染

    private func append(_ line: String) {
        logView.text = (logView.text ?? "") + line + "\n"
        let end = NSRange(location: (logView.text as NSString).length, length: 0)
        logView.scrollRangeToVisible(end)
    }

    private func refreshStatus() {
        let board = UIPasteboard.general
        let clip = board.string ?? ""
        let (records, note) = ProbeLog.read()

        var lines: [String] = []
        lines.append("App Group：\(Probe.containerURL != nil ? "可用" : "❌ 不可用")")
        lines.append("跨进程日志：\(note)")
        if let last = records.last {
            lines.append("最后一条：\(last.clock)  \(last.source)/\(last.kind)")
        }
        lines.append("剪贴板：changeCount=\(board.changeCount)  长度=\(clip.count)  "
                   + "前缀=\(String(clip.prefix(24)))")
        if let manager = runner.manager {
            lines.append("隧道：\(ProbeRunner.statusName(manager.connection.status))"
                       + "   开机自启=\(manager.isOnDemandEnabled)")
        } else {
            lines.append("隧道：（还没有配置）")
        }
        statusLabel.text = lines.joined(separator: "\n")
    }
}
