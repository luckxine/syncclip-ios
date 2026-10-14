import Foundation
import SwiftUI
import UIKit
import SyncClipCore

struct DiagnosticsView: View {

    @EnvironmentObject private var model: AppModel
    @State private var busy = false

    var body: some View {
        NavigationView {
            List {

                // MARK: 剪贴板权限地基

                Section {
                    HStack(spacing: 10) {
                        Image(systemName: model.diagnostics.pasteboardEntitlementsPresent
                              ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(model.diagnostics.pasteboardEntitlementsPresent ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.diagnostics.pasteboardEntitlementsPresent
                                 ? "剪贴板权限就位" : "剪贴板权限可能不完整")
                                .font(.subheadline).bold()
                            Text(model.diagnostics.note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("地基")
                } footer: {
                    Text("读剪贴板如果不弹系统提示，这块就是对的。弹了提示说明 entitlement 没签上——「允许粘贴」每次都会打断你，那就白做了。")
                }

                // MARK: entitlement 明细

                Section {
                    if let err = model.diagnostics.entitlementError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    } else if model.diagnostics.entitlements.isEmpty {
                        Text("（没有诊断数据，点上面的「重新诊断」）")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(model.diagnostics.entitlements, id: \.self) { key in
                            HStack(spacing: 8) {
                                Image(systemName: key.hasPrefix("com.apple.Pasteboard")
                                      || key.contains("pasteboard")
                                      ? "hand.raised.fill" : "checkmark")
                                    .font(.caption2)
                                    .foregroundStyle(key.contains("pasteboard") ? .blue : .secondary)
                                Text(key)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                } header: {
                    Text("二进制内嵌的 entitlement（\(model.diagnostics.entitlements.count) 条）")
                } footer: {
                    if !model.diagnostics.binaryPath.isEmpty {
                        Text(model.diagnostics.binaryPath)
                            .font(.system(.caption2, design: .monospaced))
                    }
                }

                // MARK: 后台保活实测

                Section {
                    HStack {
                        Text("轮询次数")
                        Spacer()
                        Text("\(model.tickCount)").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("上次轮询")
                        Spacer()
                        Text(model.lastTickAt.map { Self.relative($0) } ?? "-")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("最长间隔")
                        Spacer()
                        Text(String(format: "%.1f 秒", model.maxTickGap))
                            .foregroundStyle(model.maxTickGap > 30 ? .orange : .green)
                    }
                    if let at = model.maxTickGapAt, model.maxTickGap > 30 {
                        Text("最长间隔出现在 \(Self.relative(at))。超过 30 秒就说明那段时间进程被系统挂起了，后台保活没生效。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("后台保活实测")
                } footer: {
                    Text("验法：开着 App 后按 Home 键回桌面，去别的 App 待 5 分钟再回来看这个数字。如果最长间隔只有几秒，说明后台一直在跑；如果是几分钟，就是被挂起了。")
                }

                // MARK: 剪贴板实测

                Section {
                    HStack {
                        Text("changeCount")
                        Spacer()
                        Text("\(model.diagnostics.pasteboardChangeCount)")
                            .foregroundStyle(.secondary)
                            .font(.system(.caption, design: .monospaced))
                    }
                    HStack {
                        Text("读取耗时")
                        Spacer()
                        Text(String(format: "%.2f ms", model.diagnostics.readMillis))
                            .foregroundStyle(.secondary)
                            .font(.system(.caption, design: .monospaced))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("类型").font(.caption).foregroundStyle(.secondary)
                        Text(model.diagnostics.pasteboardTypes.isEmpty
                             ? "（空）" : model.diagnostics.pasteboardTypes.joined(separator: ", "))
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("文本内容").font(.caption).foregroundStyle(.secondary)
                        Text(model.diagnostics.pasteboardText ?? "（读不到文本）")
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(6)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("剪贴板实测")
                }

                // MARK: 日志

                Section {
                    ForEach(model.logs.suffix(60)) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(Self.timeFormatter.string(from: entry.time))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(entry.text)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    if model.logs.isEmpty {
                        Text("（暂无日志）").font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text("日志（最近 \(min(model.logs.count, 60)) 条 / 共 \(model.logs.count) 条）")
                    }
                }
            }
            .listStyle(.insetGrouped)
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
            .refreshable {
                await runDiagnostics()
            }
        }
        .navigationViewStyle(.stack)
    }

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

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
