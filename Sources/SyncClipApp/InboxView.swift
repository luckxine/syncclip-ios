import SwiftUI
import UIKit
import SyncClipCore

/// 收件箱页：远端拉下来的文件/目录都落在 Inbox 目录，这里列出、转存、删除、清理。
///
/// 文件本体对「文件」App 也可见（Info.plist 开了 UIFileSharingEnabled，
/// 两边看到的是同一个 Documents 目录），这个页只是更顺手的入口 ——
/// 在这里删除，文件 App 里的那一份也同步消失。
struct InboxView: View {

    @EnvironmentObject private var model: AppModel

    /// 非 nil 时弹系统 Share Sheet 转存。存 URL 而不是 InboxItem，
    /// 免得依赖引擎侧类型给不给 Identifiable。
    @State private var shareURL: URL?
    /// 待删除项：目录删除不可逆，先确认一下再动手
    @State private var pendingDelete: InboxItem?
    @State private var showCleanConfirm = false

    var body: some View {
        NavigationView {
            Group {
                if model.inboxItems.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .scPageBackground()
            .navigationTitle("收件箱")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showCleanConfirm = true
                    } label: {
                        Text("清理\(model.settings.inboxKeepDays)天前")
                            .font(SCToken.Text.caption)
                    }
                    .disabled(model.inboxItems.isEmpty)
                }
            }
            .onAppear { model.refreshInbox() }
            .sheet(isPresented: Binding(
                get: { shareURL != nil },
                set: { if !$0 { shareURL = nil } })) {
                if let url = shareURL {
                    ShareSheet(items: [url])
                }
            }
            .confirmationDialog("删除「\(pendingDelete?.name ?? "")」？",
                                isPresented: Binding(
                                    get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let item = pendingDelete {
                        SCInbox.shared.remove(item)
                        model.refreshInbox()
                    }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("目录会连同里面所有内容一起删掉；文件 App 里的同一份也没了。")
            }
            .confirmationDialog("清理 \(model.settings.inboxKeepDays) 天前的收件箱内容？",
                                isPresented: $showCleanConfirm,
                                titleVisibility: .visible) {
                Button("清理", role: .destructive) { cleanUp() }
                Button("取消", role: .cancel) {}
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 列表

    private var list: some View {
        List {
            Section {
                ForEach(model.inboxItems, id: \.url) { item in
                    row(item)
                }
            } header: {
                Text("文件 App → 我的 iPhone → 剪贴板同步 → Inbox")
                    .font(SCToken.Text.caption)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { model.refreshInbox() }
    }

    private func row(_ item: InboxItem) -> some View {
        HStack(spacing: SCToken.Space.m) {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 15))
                .foregroundColor(item.isDirectory
                                 ? .accentColor
                                 : SCToken.Palette.secondaryLabel)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(SCToken.Text.rowTitle)
                    .foregroundColor(SCToken.Palette.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle(for: item))
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.secondaryLabel)
            }
            Spacer(minLength: SCToken.Space.s)
            Button {
                shareURL = item.url
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
            Button {
                pendingDelete = item
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .foregroundColor(SCToken.Palette.bad.opacity(0.8))
        }
        .padding(.vertical, SCToken.Space.xxs)
    }

    /// 目录显示子项数（InboxItem 只带自身属性，子项数现场数一下），文件显示大小。
    private func subtitle(for item: InboxItem) -> String {
        if item.isDirectory {
            let n = (try? FileManager.default.contentsOfDirectory(atPath: item.url.path))?.count ?? 0
            return "\(n) 项 · \(HomeView.relative(item.addedAt))"
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)
        return "\(size) · \(HomeView.relative(item.addedAt))"
    }

    // MARK: - 空态

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: SCToken.Space.l) {
                SCEmptyState(icon: "tray",
                             title: "收件箱是空的",
                             message: "Windows/其他端复制文件后，这里会收到")
                Text("也可以直接在系统里看：文件 App → 我的 iPhone → 剪贴板同步 → Inbox")
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.tertiaryLabel)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, SCToken.Space.page)
            .padding(.top, SCToken.Space.xxl)
        }
    }

    // MARK: - 操作

    private func cleanUp() {
        let removed = SCInbox.shared.cleanup(olderThanDays: model.settings.inboxKeepDays)
        model.refreshInbox()
        model.toast = removed > 0
            ? "已清理 \(removed) 项"
            : "没有 \(model.settings.inboxKeepDays) 天前的内容"
    }
}

// MARK: - 系统 Share Sheet 包装
//
// iOS 15 没有 ShareLink（那是 16 的），转存只能走 UIActivityViewController。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
