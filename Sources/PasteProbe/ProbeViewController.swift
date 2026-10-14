import Foundation
import NetworkExtension
import UIKit
import PasteProbeShared

/// 探针的界面：一个状态区 + 一块日志 + 若干按钮 + 一个 URL 输入框。
///
/// 它同时充当"仪表盘"：状态区实时显示 App Group 是否可用、隧道状态、剪贴板的
/// changeCount —— 排查这类问题时，这三个数字比任何日志都直观。
final class ProbeViewController: UIViewController {

    private let runner = ProbeRunner()
    private let statusLabel = UILabel()
    private let logView = UITextView()
    private let urlField = UITextField()
    private var statusTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildUI()

        runner.onLine = { [weak self] line in
            self?.append(line)
        }

        append("就绪。四个实验分别验四件事，见下方按钮说明。")
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
        title.text = "NE 探针 v1.0.1 · 非越狱设备能不能跑网络扩展"
        title.font = .boldSystemFont(ofSize: 15)
        title.numberOfLines = 0

        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.numberOfLines = 0
        statusLabel.textColor = .secondaryLabel

        urlField.placeholder = "测试 URL（隧道联网实验用），如 http://192.168.1.10:5033/api/version"
        urlField.font = .systemFont(ofSize: 11)
        urlField.borderStyle = .roundedRect
        urlField.keyboardType = .URL
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.spellCheckingType = .no
        urlField.clearButtonMode = .whileEditing

        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.isEditable = false
        logView.layer.borderWidth = 1
        logView.layer.borderColor = UIColor.separator.cgColor
        logView.layer.cornerRadius = 6
        logView.textContainerInset = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)

        let row1 = makeRow([
            makeButton("① 运行探针\necho 往返", #selector(runTapped)),
            makeButton("② 只读剪贴板\n（不改内容）", #selector(readClipboardTapped)),
            makeButton("③ 隧道联网", #selector(fetchTapped)),
        ])
        let row2 = makeRow([
            makeButton("④ App↔隧道", #selector(pingTapped)),
            makeButton("刷新日志", #selector(dumpTapped)),
            makeButton("清空日志", #selector(clearTapped)),
        ])
        let row3 = makeRow([
            makeButton("停止隧道", #selector(stopTapped)),
            makeButton("开机自启", #selector(onDemandTapped)),
            makeButton("还原剪贴板", #selector(restoreTapped)),
        ])

        let stack = UIStackView(arrangedSubviews: [
            title, statusLabel, urlField, row1, row2, row3, logView,
        ])
        stack.axis = .vertical
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            logView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
    }

    private func makeButton(_ title: String, _ action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 12)
        button.titleLabel?.numberOfLines = 2
        button.titleLabel?.textAlignment = .center
        button.layer.borderWidth = 1
        button.layer.borderColor = UIColor.systemBlue.cgColor
        button.layer.cornerRadius = 6
        button.contentEdgeInsets = UIEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)
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

    @objc private func readClipboardTapped() { runner.readClipboardNow() }

    @objc private func fetchTapped() {
        runner.testURL = urlField.text ?? ""
        runner.fetchViaTunnel()
    }

    @objc private func pingTapped() { runner.pingTunnel() }

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
        if let session = runner.session {
            lines.append("隧道：\(ProbeRunner.statusName(session.status))"
                       + "   开机自启=\(runner.manager?.isOnDemandEnabled == true)")
        } else {
            lines.append("隧道：（还没有配置）")
        }
        statusLabel.text = lines.joined(separator: "\n")
    }
}
