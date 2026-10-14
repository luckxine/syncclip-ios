import SwiftUI
import UIKit
import SyncClipCore

struct DiagnosticsView: View {

    @EnvironmentObject private var model: AppModel
    @State private var busy = false

    private var d: AppModel.Diagnostics { model.diagnostics }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: SCToken.Space.l) {
                    foundationCard
                    checksCard
                    keepAliveCard
                    pasteboardCard
                    endpointCard
                    logCard
                }
                .padding(.horizontal, SCToken.Space.page)
                .padding(.vertical, SCToken.Space.l)
            }
            .scPageBackground()
            .navigationTitle("诊断")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            Task { await runDiagnostics() }
                        } label: {
                            Label("重新诊断", systemImage: "arrow.clockwise")
                        }
                        Button {
                            model.copyLogs()
                        } label: {
                            Label("复制日志", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            model.clearLogs()
                        } label: {
                            Label("清空日志", systemImage: "trash")
                        }
                    } label: {
                        if busy { ProgressView() } else { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            if model.diagnostics.binaryPath.isEmpty {
                Task { await runDiagnostics() }
            }
        }
    }

    // MARK: - 地基

    private var foundationCard: some View {
        let ok = d.pasteboardEntitlementsPresent
        return SCCard("地基", footnote: ok
                      ? "读剪贴板不弹系统提示，这块就对了。"
                      : "没拿到关键 entitlement 的话，读剪贴板会弹「允许粘贴」，"
                        + "每次都被打断，那就白做了。") {
            HStack(alignment: .top, spacing: SCToken.Space.m) {
                Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(ok ? SCToken.Palette.ok : SCToken.Palette.warn)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ok ? "剪贴板权限就位" : "剪贴板权限可能不完整")
                        .font(SCToken.Text.rowTitle)
                    Text(d.note.isEmpty ? "还没有诊断数据，点右上角重新诊断" : d.note)
                        .font(SCToken.Text.caption)
                        .foregroundColor(SCToken.Palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if !d.entitlements.isEmpty {
                SCCardDivider()
                VStack(alignment: .leading, spacing: SCToken.Space.xs) {
                    Text("二进制里实际签到的 entitlement（\(d.entitlements.count) 条）")
                        .font(SCToken.Text.caption)
                        .foregroundColor(SCToken.Palette.secondaryLabel)
                    ForEach(d.entitlements, id: \.self) { key in
                        HStack(spacing: SCToken.Space.s) {
                            Image(systemName: key.lowercased().contains("pasteboard")
                                  ? "hand.raised.fill" : "checkmark")
                                .font(.system(size: 9))
                                .foregroundColor(key.lowercased().contains("pasteboard")
                                                 ? SCToken.Palette.ok : SCToken.Palette.tertiaryLabel)
                                .frame(width: 12)
                            Text(key)
                                .font(SCToken.Text.monoSmall)
                                .foregroundColor(SCToken.Palette.secondaryLabel)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else if let err = d.entitlementError {
                SCCardDivider()
                Text(err)
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 自检

    private var checksCard: some View {
        SCCard("算法自检", footnote: "这几项不联网、不需要凭据，能在出问题前就把「算法对不对」和"
               + "「权限有没有」分辨清楚。") {
            checkRow(title: "SigV4 签名",
                     ok: d.sigV4Passed,
                     detail: d.sigV4Detail.isEmpty ? "点右上角重新诊断" : d.sigV4Detail)
            SCCardDivider()
            checkRow(title: "Darwin 通知",
                     ok: d.darwinNotifyAvailable,
                     detail: d.darwinNotifyAvailable
                        ? "可用，剪贴板变化能立刻唤醒，比轮询更快"
                        : "不可用，退化为纯轮询。只是延迟略大，功能不受影响",
                     warnWhenFalse: true)
        }
    }

    private func checkRow(title: String, ok: Bool, detail: String, warnWhenFalse: Bool = false) -> some View {
        HStack(alignment: .top, spacing: SCToken.Space.m) {
            Image(systemName: ok ? "checkmark.circle.fill"
                                : (warnWhenFalse ? "info.circle.fill" : "xmark.circle.fill"))
                .font(.system(size: 15))
                .foregroundColor(ok ? SCToken.Palette.ok
                                    : (warnWhenFalse ? SCToken.Palette.warn : SCToken.Palette.bad))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(SCToken.Text.rowSubtitle)
                Text(detail)
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 后台保活

    private var keepAliveCard: some View {
        let danger = model.maxTickGap > 30
        return SCCard("后台保活实测", footnote: "验法：开着 App 回桌面，去别的 App 待 5 分钟再回来。"
                      + "最长间隔只有几秒说明后台一直在跑；是几分钟就是被挂起了。") {
            SCKeyValue(key: "轮询次数", value: "\(model.tickCount)")
            SCKeyValue(key: "上次轮询",
                       value: model.lastTickAt.map { HomeView.relative($0) } ?? "-")
            SCKeyValue(key: "最长间隔",
                       value: String(format: "%.1f 秒", model.maxTickGap),
                       mono: true,
                       tint: model.maxTickGap == 0
                            ? SCToken.Palette.secondaryLabel
                            : (danger ? SCToken.Palette.warn : SCToken.Palette.ok))
            if danger, let at = model.maxTickGapAt {
                Text("最长间隔出现在 \(HomeView.relative(at))。超过 30 秒说明那段时间进程被系统挂起，"
                     + "后台保活没生效。")
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 剪贴板

    private var pasteboardCard: some View {
        SCCard("剪贴板实测") {
            SCKeyValue(key: "changeCount", value: "\(d.pasteboardChangeCount)", mono: true)
            SCKeyValue(key: "读取耗时", value: String(format: "%.2f ms", d.readMillis), mono: true)
            SCKeyValue(key: "类型",
                       value: d.pasteboardTypes.isEmpty ? "（空）"
                            : d.pasteboardTypes.joined(separator: ", "),
                       mono: true)

            SCCardDivider()

            VStack(alignment: .leading, spacing: SCToken.Space.xs) {
                Text("文本内容")
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.secondaryLabel)
                SCPreview(text: d.pasteboardText ?? "",
                          placeholder: "（读不到文本）",
                          lineLimit: 8)
            }
        }
    }

    // MARK: - 端点

    private var endpointCard: some View {
        SCCard("当前端点") {
            if let profile = model.settings.activeServer {
                HStack(spacing: SCToken.Space.m) {
                    SCTypeBadge(type: profile.type, large: true)
                    Text(profile.displayTitle)
                        .font(SCToken.Text.rowSubtitle)
                }
                if !d.endpointDescription.isEmpty {
                    Text(d.endpointDescription)
                        .font(SCToken.Text.monoSmall)
                        .foregroundColor(SCToken.Palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                SCCardDivider()
                SCKeyValue(key: "状态", value: model.connection.label,
                           tint: model.connection.isBad ? SCToken.Palette.bad
                               : (model.connection.isOK ? SCToken.Palette.ok
                                  : SCToken.Palette.secondaryLabel))
                SCKeyValue(key: "详情", value: model.connection.detail)
            } else {
                Text("还没配置服务器")
                    .font(SCToken.Text.rowSubtitle)
                    .foregroundColor(SCToken.Palette.secondaryLabel)
            }
        }
    }

    // MARK: - 日志

    private var logCard: some View {
        SCCard("日志", footnote: d.binaryPath.isEmpty ? nil : d.binaryPath) {
            if model.logs.isEmpty {
                Text("（暂无日志）")
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.tertiaryLabel)
            } else {
                let shown = Array(model.logs.suffix(60))
                VStack(alignment: .leading, spacing: SCToken.Space.s) {
                    Text("最近 \(shown.count) 条 / 共 \(model.logs.count) 条")
                        .font(SCToken.Text.caption)
                        .foregroundColor(SCToken.Palette.secondaryLabel)
                    ForEach(shown) { entry in
                        HStack(alignment: .top, spacing: SCToken.Space.s) {
                            Text(Self.timeFormatter.string(from: entry.time))
                                .font(SCToken.Text.monoSmall)
                                .foregroundColor(SCToken.Palette.tertiaryLabel)
                            Text(entry.text)
                                .font(SCToken.Text.monoSmall)
                                .foregroundColor(SCToken.Palette.secondaryLabel)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 工具

    private func runDiagnostics() async {
        busy = true
        await model.runDiagnostics()
        busy = false
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
