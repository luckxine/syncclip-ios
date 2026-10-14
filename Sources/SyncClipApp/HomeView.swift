import SwiftUI
import UIKit
import SyncClipCore

struct HomeView: View {

    @EnvironmentObject private var model: AppModel
    /// 用来从「切换服务器」跳到服务器页
    @Binding var selectedTab: Int

    private var activeProfile: SCServerProfile? { model.settings.activeServer }

    private var statusColor: Color {
        if !model.isLoopRunning { return SCToken.Palette.idle }
        switch model.connection {
        case .ok: return SCToken.Palette.ok
        case .failed: return SCToken.Palette.bad
        case .checking: return SCToken.Palette.warn
        case .unknown: return SCToken.Palette.idle
        }
    }

    /// 顶部状态卡上的那句话
    private var headline: String {
        guard model.settings.hasServers else { return "还没有服务器" }
        guard model.settings.syncEnabled else { return "同步已关闭" }
        guard model.isLoopRunning else { return "未运行" }
        switch model.connection {
        case .failed: return "连接失败"
        case .checking: return "正在连接"
        default: return "自动同步中"
        }
    }

    private var subheadline: String {
        guard model.settings.hasServers else {
            return "先去「服务器」页添加一台，三种类型都支持"
        }
        guard model.settings.syncEnabled else {
            return "在「设置」里打开总开关才会轮询"
        }
        guard model.isLoopRunning else {
            return "当前服务器的配置还不完整"
        }
        if let t = model.lastSyncAt {
            return "上次同步 \(Self.relative(t))"
        }
        return "即将开始第一轮同步"
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: SCToken.Space.l) {
                    statusHero
                    flowDiagram
                    quickActions
                    if let err = model.keepAliveError { keepAliveWarning(err) }
                    serverCard
                    previews
                    metrics
                }
                .padding(.horizontal, SCToken.Space.page)
                .padding(.vertical, SCToken.Space.l)
            }
            .scPageBackground()
            .navigationTitle("剪贴板同步")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task {
                            model.refreshPreviews()
                            await model.syncNow()
                        }
                    } label: {
                        if model.isSyncing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(model.isSyncing)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 状态卡

    private var statusHero: some View {
        VStack(alignment: .leading, spacing: SCToken.Space.m) {

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: SCToken.Space.xs) {
                    Text(headline)
                        .font(SCToken.Text.hero)
                        .foregroundColor(SCToken.Palette.label)
                    Text(subheadline)
                        .font(SCToken.Text.rowSubtitle)
                        .foregroundColor(SCToken.Palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: SCToken.Space.s)
                LiveDot(color: statusColor, animating: model.isLoopRunning && !model.connection.isBad)
            }

            HStack(spacing: SCToken.Space.s) {
                SCPill(text: model.settings.syncEnabled ? "同步开启" : "同步关闭",
                       color: model.settings.syncEnabled ? SCToken.Palette.ok : SCToken.Palette.idle)
                SCPill(text: "\(String(format: "%.0f", model.settings.pollInterval)) 秒轮询",
                       color: SCToken.Palette.secondaryLabel)
                if !model.keepAliveError.isNil {
                    SCPill(text: "保活异常", color: SCToken.Palette.warn, icon: "exclamationmark.triangle.fill")
                }
            }

            if !model.lastAction.isEmpty {
                Text(model.lastAction)
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.tertiaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SCToken.Space.l)
        .background(
            ZStack {
                SCToken.Palette.surface
                LinearGradient(
                    colors: [statusColor.opacity(0.20), statusColor.opacity(0.03)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: SCToken.Radius.l, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SCToken.Radius.l, style: .continuous)
                .strokeBorder(statusColor.opacity(0.28), lineWidth: 1)
        )
    }

    // MARK: - 方向示意
    //
    // 一眼看出「上一次数据往哪走了」，比堆文字直觉得多。

    private var flowDiagram: some View {
        let kind = model.lastActionKind
        let leftActive = kind == .pulled
        let rightActive = kind == .pushed

        return HStack(spacing: SCToken.Space.s) {
            flowNode(icon: "doc.on.clipboard",
                     title: "本机剪贴板",
                     active: leftActive,
                     tint: SCToken.accent(for: activeProfile?.type ?? .syncclipboard))

            Image(systemName: kind == .pulled ? "arrow.left" : "arrow.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(kind == .idle || kind == .failed
                                 ? SCToken.Palette.tertiaryLabel
                                 : SCToken.tint(for: kind))
                .frame(width: 26)

            flowNode(icon: activeProfile?.type.iconName ?? "server.rack",
                     title: activeProfile?.displayTitle ?? "服务器",
                     active: rightActive,
                     tint: SCToken.accent(for: activeProfile?.type ?? .syncclipboard))
        }
    }

    private func flowNode(icon: String, title: String, active: Bool, tint: Color) -> some View {
        HStack(spacing: SCToken.Space.s) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(active ? .white : SCToken.Palette.secondaryLabel)
            Text(title)
                .font(SCToken.Text.caption)
                .foregroundColor(SCToken.Palette.label)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, SCToken.Space.m)
        .padding(.vertical, SCToken.Space.s)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: SCToken.Radius.m, style: .continuous)
                .fill(active ? tint : SCToken.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SCToken.Radius.m, style: .continuous)
                .strokeBorder(active ? Color.clear : SCToken.Palette.separator.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - 操作

    private var quickActions: some View {
        VStack(spacing: SCToken.Space.s) {
            SCPrimaryButton(title: "立即同步",
                            icon: "arrow.triangle.2.circlepath",
                            tint: SCToken.accent(for: activeProfile?.type ?? .syncclipboard),
                            busy: model.isSyncing) {
                Task { await model.syncNow() }
            }
            .disabled(!model.isLoopRunning)

            HStack(spacing: SCToken.Space.s) {
                SCSecondaryButton(title: "推送剪贴板", icon: "arrow.up.to.line") {
                    Task { await model.pushCurrentClipboard() }
                }
                SCSecondaryButton(title: "拉取远端", icon: "arrow.down.to.line") {
                    Task { await model.pullRemote() }
                }
            }
        }
    }

    private func keepAliveWarning(_ message: String) -> some View {
        HStack(alignment: .top, spacing: SCToken.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(SCToken.Palette.warn)
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 2) {
                Text("后台保活没起来")
                    .font(SCToken.Text.rowSubtitle)
                    .foregroundColor(SCToken.Palette.label)
                Text(message + "。同步仍会跑，但退到后台约 30 秒后可能被系统挂起。")
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SCToken.Space.m)
        .background(SCToken.Palette.warn.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: SCToken.Radius.m, style: .continuous))
    }

    // MARK: - 服务器

    private var serverCard: some View {
        SCCard("当前服务器") {
            if let profile = activeProfile {
                HStack(spacing: SCToken.Space.m) {
                    SCTypeBadge(type: profile.type, large: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.displayTitle)
                            .font(SCToken.Text.rowTitle)
                            .lineLimit(1)
                        Text(profile.displaySubtitle)
                            .font(SCToken.Text.caption)
                            .foregroundColor(SCToken.Palette.secondaryLabel)
                            .lineLimit(1)
                    }
                    Spacer(minLength: SCToken.Space.s)
                    SCPill(text: model.connection.label,
                           color: statusColor,
                           compact: true)
                }

                SCCardDivider()

                HStack {
                    Button {
                        selectedTab = 1
                    } label: {
                        Label(model.settings.servers.count > 1 ? "切换服务器（\(model.settings.servers.count)）" : "管理服务器",
                              systemImage: "arrow.left.arrow.right")
                            .font(SCToken.Text.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)

                    Spacer()

                    Button {
                        Task { await model.testActiveConnection() }
                    } label: {
                        Label("测试连接", systemImage: "antenna.radiowaves.left.and.right")
                            .font(SCToken.Text.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
            } else {
                SCEmptyState(icon: "server.rack",
                             title: "还没有服务器",
                             message: "SyncClipboard 服务器、WebDAV、S3 兼容存储都支持。",
                             actionTitle: "去添加") {
                    selectedTab = 1
                }
            }
        }
    }

    // MARK: - 两端预览

    private var previews: some View {
        VStack(spacing: SCToken.Space.l) {
            SCCard("本机剪贴板", footnote: localHint) {
                SCPreview(text: model.localPreview,
                          placeholder: "剪贴板里没有文本（可能复制的是图片或文件）",
                          lineLimit: 5) {
                    model.copyToClipboard(model.localPreview)
                }
            }

            SCCard("远端内容") {
                SCPreview(text: model.remotePreview,
                          placeholder: "还没从服务器取到内容",
                          lineLimit: 5) {
                    model.copyToClipboard(model.remotePreview)
                }
            }
        }
    }

    private var localHint: String? {
        guard !model.localPreview.isEmpty else { return nil }
        return "改动会在 \(Int(model.settings.pollInterval)) 秒内推上去"
    }

    // MARK: - 统计

    private var metrics: some View {
        SCCard("本次运行") {
            HStack(spacing: 0) {
                SCMetric(value: "\(model.pushCount)", label: "推送", icon: "arrow.up",
                         tint: SCToken.Palette.ok)
                divider
                SCMetric(value: "\(model.pullCount)", label: "拉取", icon: "arrow.down",
                         tint: SCToken.accent(for: activeProfile?.type ?? .syncclipboard))
                divider
                SCMetric(value: "\(model.failureCount)", label: "失败", icon: "exclamationmark.triangle",
                         tint: model.failureCount > 0 ? SCToken.Palette.bad : SCToken.Palette.tertiaryLabel)
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(SCToken.Palette.separator.opacity(0.35))
            .frame(width: 1, height: 34)
    }

    // MARK: - 工具

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// 会呼吸的状态点。同步在跑的时候它是活的，一眼能看出程序还在工作。
struct LiveDot: View {
    let color: Color
    var animating: Bool

    @State private var expanded = false

    var body: some View {
        ZStack {
            if animating {
                Circle()
                    .fill(color.opacity(0.28))
                    .frame(width: expanded ? 26 : 12, height: expanded ? 26 : 12)
                    .opacity(expanded ? 0 : 1)
                    .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false),
                               value: expanded)
            }
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
        }
        .frame(width: 26, height: 26)
        .onAppear { if animating { expanded = true } }
    }
}

extension Optional {
    /// 方便读：`if foo.isNil`
    var isNil: Bool { self == nil }
}
