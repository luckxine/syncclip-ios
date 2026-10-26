import SwiftUI
import UniformTypeIdentifiers
import SyncClipCore

/// 多选上传：文档选择器多选 → 待传清单 → 一起推给服务器。
///
/// 为什么不走剪贴板：iOS 的剪贴板一次只能带一个文件引用，
/// 「把一组文件发出去」只有文档选择器这条路（设计稿 §4.3）。
struct GroupPickerView: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var picked: [PickedFile] = []
    @State private var showPicker = false
    @State private var isUploading = false

    /// 选中的文件。大小在 picker 回调里就记下来 —— 那一刻安全作用域肯定有效，
    /// 之后清单再怎么刷新都不必重新去碰文件。
    struct PickedFile: Identifiable {
        let url: URL
        let size: Int
        var id: String { url.absoluteString }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: SCToken.Space.l) {
                    if picked.isEmpty {
                        SCEmptyState(icon: "doc.badge.plus",
                                     title: "还没选文件",
                                     message: "支持多选；选文件夹会自动打成一个组",
                                     actionTitle: "选择文件") {
                            showPicker = true
                        }
                    } else {
                        pickedCard
                        SCPrimaryButton(title: "上传 \(picked.count) 个文件",
                                        icon: "arrow.up.to.line",
                                        busy: isUploading) {
                            startUpload()
                        }
                        .disabled(isUploading)
                        SCSecondaryButton(title: "重新选择", icon: "arrow.uturn.left") {
                            showPicker = true
                        }
                    }
                }
                .padding(.horizontal, SCToken.Space.page)
                .padding(.vertical, SCToken.Space.l)
            }
            .scPageBackground()
            .navigationTitle("上传文件")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showPicker) {
            DocumentPicker { urls in
                picked = Self.sizedFiles(from: urls)
            }
        }
    }

    // MARK: - 待传清单

    private var pickedCard: some View {
        SCCard("待传清单",
               footnote: "共 \(picked.count) 项 · 文件合计 \(totalText)\(overLimit ? " · ⚠️ 超上限" : "")") {
            ForEach(picked) { file in
                HStack(spacing: SCToken.Space.m) {
                    Image(systemName: file.url.hasDirectoryPath ? "folder.fill" : "doc.fill")
                        .font(.system(size: 14))
                        .foregroundColor(SCToken.Palette.secondaryLabel)
                    Text(file.url.lastPathComponent)
                        .font(SCToken.Text.rowSubtitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: SCToken.Space.s)
                    Text(sizeText(for: file))
                        .font(SCToken.Text.caption)
                        .foregroundColor(SCToken.Palette.secondaryLabel)
                }
            }

            if overLimit {
                SCCardDivider()
                HStack(alignment: .top, spacing: SCToken.Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(SCToken.Palette.warn)
                    Text(overLimitText)
                        .font(SCToken.Text.caption)
                        .foregroundColor(SCToken.Palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 上限判断
    //
    // 警示只是提示，不拦着传 —— 真正的守卫在引擎里逐个文件做（跳过的会明确通知）。
    // 门槛取「单文件上限 × 文件数」的总量口径，另外任何一个文件单独超限也算：
    // 两种情况引擎都会跳过一部分，用户应该在上传前就知道。

    private var limitBytes: Int { model.settings.maxFileMB * 1024 * 1024 }

    private var overLimit: Bool {
        guard !picked.isEmpty else { return false }
        let files = picked.filter { !$0.url.hasDirectoryPath }
        let total = files.reduce(0) { $0 + $1.size }
        return total > limitBytes * max(files.count, 1)
            || files.contains { $0.size > limitBytes }
    }

    private var overLimitText: String {
        "总量或单个文件超过上限（单文件 \(model.settings.maxFileMB) MB）。"
            + "仍然可以尝试：超限的部分会被引擎逐个跳过并通知。文件夹按打包后的大小算，同理。"
    }

    // MARK: - 上传

    private func startUpload() {
        isUploading = true
        Task {
            await model.pushFiles(urls: picked.map(\.url))
            isUploading = false
            dismiss()
        }
    }

    // MARK: - 工具

    private var totalText: String {
        let files = picked.filter { !$0.url.hasDirectoryPath }
        let total = files.reduce(0) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }

    private func sizeText(for file: PickedFile) -> String {
        file.url.hasDirectoryPath
            ? "文件夹"
            : ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
    }

    /// picker 给的是安全作用域 URL：读大小也要先拿权限，
    /// 不然从 iCloud / 其他 provider 选的文件会读出 0。
    static func sizedFiles(from urls: [URL]) -> [PickedFile] {
        urls.map { url in
            let scoped = url.startAccessingSecurityScopedResource()
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if scoped { url.stopAccessingSecurityScopedResource() }
            return PickedFile(url: url, size: size)
        }
    }
}

// MARK: - 文档选择器包装
//
// UIDocumentPickerViewController(forOpeningContentTypes:asCopy:) +
// allowsMultipleSelection 是 iOS 14+ 的 API（iOS 15 天花板内），比 SwiftUI 自带的 fileImporter
// 多一个「多选」能力 —— 而多选正是这个页存在的理由。
private struct DocumentPicker: UIViewControllerRepresentable {
    var onPicked: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item, .folder],
                                                    asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: ([URL]) -> Void
        init(onPicked: @escaping ([URL]) -> Void) { self.onPicked = onPicked }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            onPicked(urls)
        }
    }
}
