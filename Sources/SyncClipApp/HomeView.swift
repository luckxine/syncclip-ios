import SwiftUI
import UIKit
import SyncClipCore

struct HomeView: View {

    @EnvironmentObject private var model: AppModel

    private var connectionColor: Color {
        switch model.connection {
        case .ok: return .green
        case .failed: return .red
        case .checking: return .orange
        case .unknown: return .gray
        }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {

                    // ---- 状态 ----
                    Card {
                        HStack(spacing: 10) {
                            StatusDot(color: connectionColor)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.connection.label).font(.headline)
                                Text(model.connection.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                            Spacer()
                            if model.connection == .checking {
                                ProgressView()
                            }
                        }

                        Divider().padding(.vertical, 2)

                        HStack {
                            Label(model.isLoopRunning ? "轮询中" : "未运行",
                                  systemImage: model.isLoopRunning ? "play.circle.fill" : "pause.circle")
                                .font(.caption)
                                .foregroundStyle(model.isLoopRunning ? .green : .secondary)
                            Spacer()
                            if let t = model.lastSyncAt {
                                Text("上次同步 \(Self.relative(t))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text(model.lastAction)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // ---- 操作 ----
                    Card("操作") {
                        HStack(spacing: 10) {
                            Button {
                                Task { await model.syncNow() }
                            } label: {
                                Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }

                        HStack(spacing: 10) {
                            Button {
                                Task { await model.pushCurrentClipboard() }
                            } label: {
                                Label("推送剪贴板", systemImage: "arrow.up.to.line")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)

                            Button {
                                Task { await model.pullRemote() }
                            } label: {
                                Label("拉取远端", systemImage: "arrow.down.to.line")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }
                    }

                    // ---- 预览 ----
                    Card("本地剪贴板") {
                        PreviewBlock(text: model.localPreview,
                                     placeholder: "剪贴板里没有文本（或者读到的是图片）")
                    }

                    Card("远端内容") {
                        PreviewBlock(text: model.remotePreview,
                                     placeholder: "还没从服务器取到内容")
                    }

                    // ---- 统计 ----
                    Card("统计") {
                        HStack {
                            statItem("推送", "\(model.pushCount)", "arrow.up")
                            Divider().frame(height: 28)
                            statItem("拉取", "\(model.pullCount)", "arrow.down")
                            Divider().frame(height: 28)
                            statItem("失败", "\(model.failureCount)", "exclamationmark.triangle")
                        }
                    }

                    if let err = model.keepAliveError {
                        Card("后台保活异常") {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                            Text("同步仍在跑，但 App 退到后台约 30 秒后可能被系统挂起。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("剪贴板同步")
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .navigationViewStyle(.stack)
    }

    private func statItem(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3).bold()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
