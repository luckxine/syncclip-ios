import Foundation
import UIKit
import UniformTypeIdentifiers
import SyncClipCore
import SyncClipApp

/// 分享扩展的根视图（Info.plist 的 NSExtensionPrincipalClass 指向本类）。
///
/// 为什么不用 SLComposeServiceViewController：我们要的形态是「类型/大小预览 +
/// 上传按钮 + 状态文本」，跟系统分享面板的"文本框 + 发送"对不上。
/// 为什么用纯 UIKit 而不是 SwiftUI：主 App 的主题 token 里有一个内部枚举
/// 叫 Text（SCToken.Text），SwiftUI 的 Text 与它撞名会让 lint-swift.js 的
/// 跨模块检查误报；顺带 appex 不链 SwiftUI，二进制更小、内存配额更省。
@MainActor
final class ShareViewController: UIViewController {

    // MARK: - 视图

    private let summaryLabel = UILabel()
    private let hintLabel = UILabel()
    private let statusLabel = UILabel()
    private let uploadButton = UIButton(type: .system)
    private let openMainAppButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)

    /// 预读完成后的分享内容；上传按钮拿它干活。
    private var pending: SharePayload?
    /// 主 App 导出的设置；nil = 还不能上传。
    private var exportedSettings: SCAppSettings?
    /// 预读发现内容超过大小上限（appex 内存配额远低于主 App，大文件会把扩展
    /// 直接杀掉，所以宁可在这里明确拒绝）。
    private var tooLarge = false
    private var busy = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildLayout()
        refreshConfigState()
        beginReading()
    }

    private func buildLayout() {
        let titleLabel = UILabel()
        titleLabel.text = "推送到剪贴板服务器"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center

        summaryLabel.font = .preferredFont(forTextStyle: .subheadline)
        summaryLabel.textColor = .secondaryLabel
        summaryLabel.textAlignment = .center
        summaryLabel.numberOfLines = 0
        summaryLabel.text = "读取分享内容…"

        hintLabel.font = .preferredFont(forTextStyle: .footnote)
        hintLabel.textColor = .secondaryLabel
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        uploadButton.setTitle("上传", for: .normal)
        uploadButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        uploadButton.isEnabled = false
        uploadButton.addAction(UIAction(handler: { [weak self] _ in
            self?.uploadTapped()
        }), for: .touchUpInside)

        openMainAppButton.setTitle("打开主 App 导出配置", for: .normal)
        openMainAppButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        openMainAppButton.addAction(UIAction(handler: { [weak self] _ in
            self?.openMainAppTapped()
        }), for: .touchUpInside)

        cancelButton.setTitle("取消", for: .normal)
        cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        cancelButton.addAction(UIAction(handler: { [weak self] _ in
            self?.finish()
        }), for: .touchUpInside)

        let auxRow = UIStackView(arrangedSubviews: [openMainAppButton, cancelButton])
        auxRow.axis = .horizontal
        auxRow.spacing = 24
        auxRow.distribution = .equalCentering

        let root = UIStackView(arrangedSubviews: [
            titleLabel, summaryLabel, hintLabel, uploadButton, auxRow, statusLabel,
        ])
        root.axis = .vertical
        root.spacing = 14
        root.alignment = .center
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            root.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            root.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            root.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            summaryLabel.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor),
        ])
    }

    // MARK: - 配置与预读

    private func refreshConfigState() {
        if AppGroupStore.isAvailable, let (profile, settings) = AppGroupStore.loadConfig() {
            exportedSettings = settings
            hintLabel.text = "服务器：\(profile.displayTitle)"
            openMainAppButton.isHidden = true
        } else if !AppGroupStore.isAvailable {
            // 设备级问题：打开主 App 也导不出配置，提示去主 App 诊断页看 K1 结论
            exportedSettings = nil
            hintLabel.text = "App Group 容器不可用：扩展读不到服务器配置（主 App 诊断页可查探针结论）"
            openMainAppButton.isHidden = true
        } else {
            exportedSettings = nil
            hintLabel.text = "还没导出配置"
            openMainAppButton.isHidden = false
        }
        refreshUploadAllowed()
    }

    private func beginReading() {
        guard let provider = firstProvider() else {
            summaryLabel.text = "（没有可读取的分享内容）"
            statusLabel.text = "这个分享来源没有给出可读取的内容"
            return
        }

        let textID = UTType.text.identifier
        let imageID = UTType.image.identifier

        // 判定顺序 文本 → 图片 → 文件：分享一个网页 URL 时系统往往同时注册
        // 多种类型，按这个顺序总能拿到对用户最直观的那份内容。
        if provider.hasItemConformingToTypeIdentifier(textID) {
            provider.loadItem(forTypeIdentifier: textID, options: nil) { item, _ in
                let body: String?
                switch item {
                case let s as String: body = s
                case let a as NSAttributedString: body = a.string
                case let u as URL: body = try? String(contentsOf: u, encoding: .utf8)
                default: body = nil
                }
                DispatchQueue.main.async {
                    if let body, !body.isEmpty {
                        self.accept(.text(body))
                    } else {
                        self.readImage(provider, imageID: imageID)
                    }
                }
            }
        } else if provider.hasItemConformingToTypeIdentifier(imageID) {
            readImage(provider, imageID: imageID)
        } else {
            readFile(provider)
        }
    }

    /// 文本兜底与图片共用：文本读不出来（系统只给了文件形态之类）就退去读图片。
    private func readImage(_ provider: NSItemProvider, imageID: String) {
        guard provider.hasItemConformingToTypeIdentifier(imageID) else {
            readFile(provider)
            return
        }
        provider.loadItem(forTypeIdentifier: imageID, options: nil) { item, _ in
            let data: Data?
            switch item {
            case let d as Data: data = d
            case let u as URL: data = try? Data(contentsOf: u)
            case let img as UIImage:
                // 位图兜底：只有来源死活只肯给 UIImage 对象时才走，动图到这里就丢帧了
                data = img.pngData()
            default: data = nil
            }
            DispatchQueue.main.async {
                if let data, !data.isEmpty {
                    self.accept(.image(data))
                } else {
                    self.readFile(provider)
                }
            }
        }
    }

    private func readFile(_ provider: NSItemProvider) {
        // 挑"是数据但不是文本/图片"的注册类型当文件类型；挑不出就退到 public.data
        let fileTypes = provider.registeredTypeIdentifiers.filter { id in
            guard let t = UTType(id) else { return false }
            return t.conforms(to: .data) && !t.conforms(to: .text) && !t.conforms(to: .image)
        }
        let typeID = fileTypes.first ?? UTType.data.identifier

        provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
            guard let url else {
                DispatchQueue.main.async {
                    self.summaryLabel.text = "（文件内容读取失败）"
                    self.statusLabel.text = "这个来源不肯给出文件内容"
                }
                return
            }
            // 回调给的 URL 归系统管，出了回调就可能失效 —— 先拷进自己的临时目录再读
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                let fileBytes = try Data(contentsOf: dest)
                DispatchQueue.main.async {
                    self.accept(.file(name: url.lastPathComponent, data: fileBytes))
                }
            } catch {
                DispatchQueue.main.async {
                    self.summaryLabel.text = "（文件拷贝失败）"
                    self.statusLabel.text = error.localizedDescription
                }
            }
        }
    }

    private func firstProvider() -> NSItemProvider? {
        for case let item as NSExtensionItem in (extensionContext?.inputItems ?? []) {
            if let provider = item.attachments?.first { return provider }
        }
        return nil
    }

    // MARK: - 预读结果落地

    private func accept(_ payload: SharePayload) {
        pending = payload
        tooLarge = false
        // 上限对齐主 App 设置；没导出配置时用同一个默认值（15MB）做预读拦截
        let maxBytes = (exportedSettings?.maxImageMB ?? 15) * 1024 * 1024

        switch payload {
        case .text(let body):
            let byteCount = body.utf8.count
            summaryLabel.text = "文本 · \(body.count) 字 · \(byteCount) 字节"
            if byteCount > maxBytes { tooLarge = true }
        case .image(let raw):
            summaryLabel.text = "图片 · \(raw.count) 字节"
            if raw.count > maxBytes { tooLarge = true }
        case .file(let fileName, let fileBytes):
            summaryLabel.text = "文件 · \(fileName) · \(fileBytes.count) 字节"
            if fileBytes.count > maxBytes { tooLarge = true }
        }

        if tooLarge {
            statusLabel.text = "超过 \(maxBytes / 1024 / 1024) MB 上限，不上传（appex 内存配额有限，大文件在主 App 里处理）"
        }
        refreshUploadAllowed()
    }

    private func refreshUploadAllowed() {
        uploadButton.isEnabled = pending != nil && exportedSettings != nil && !tooLarge && !busy
    }

    // MARK: - 动作

    private func uploadTapped() {
        guard let payload = pending, let settings = exportedSettings, !busy else { return }
        busy = true
        uploadButton.isEnabled = false
        uploadButton.setTitle("上传中…", for: .normal)
        statusLabel.text = "上传中…"
        Task {
            let outcome = await ShareUploadFlow.upload(payload, settings: settings)
            busy = false
            uploadButton.setTitle("上传", for: .normal)
            refreshUploadAllowed()
            switch outcome {
            case .ok(let message):
                statusLabel.text = message
                // 停半秒让用户看清结果，然后收起分享面板
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.finish()
                }
            case .failed(let message):
                statusLabel.text = message
            }
        }
    }

    private func openMainAppTapped() {
        // 分享扩展里 open() 常被系统拒绝（返回 false 不跳转）—— 这不是 bug，
        // 是分享面板的既定行为。降级路径就是提示用户手动切到主 App 打开一次。
        guard let url = URL(string: "syncclip://sync") else { return }
        extensionContext?.open(url) { [weak self] success in
            DispatchQueue.main.async {
                if !success {
                    self?.statusLabel.text = "此环境不允许扩展拉起 App：请手动打开主 App 一次，再回来重试"
                }
            }
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
