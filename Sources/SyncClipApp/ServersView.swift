import SwiftUI
import SyncClipCore
struct ServersView: View {

    @EnvironmentObject private var model: AppModel

    @State private var editing: SCServerProfile?
    @State private var creatingNew = false
    @State private var pendingDelete: SCServerProfile?

    var body: some View {
        NavigationView {
            Group {
                if model.settings.servers.isEmpty {
                    ScrollView {
                        SCEmptyState(icon: "server.rack",
                                     title: "还没有服务器",
                                     message: "支持三种后端，用的是同一套同步协议，随时可以换。",
                                     actionTitle: "添加第一台") {
                            creatingNew = true
                        }
                        typeGallery
                            .padding(.horizontal, SCToken.Space.page)
                    }
                    .scPageBackground()
                } else {
                    List {
                        Section {
                            ForEach(model.settings.servers) { profile in
                                Button {
                                    editing = profile
                                } label: {
                                    serverRow(profile)
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        pendingDelete = profile
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                    if !model.settings.isActive(profile) {
                                        Button {
                                            model.selectServer(id: profile.id)
                                        } label: {
                                            Label("使用", systemImage: "checkmark.circle")
                                        }
                                        .tint(SCToken.accent(for: profile.type))
                                    }
                                }
                            }
                        } header: {
                            Text("已保存的服务器")
                        } footer: {
                            Text("点任意一行编辑。左滑可以删除或切换为当前使用。"
                                 + "同步时只会用当前那一台，切换会重置这一轮的对齐状态。")
                        }

                        Section {
                            ForEach(SCServerType.allCases) { type in
                                HStack(alignment: .top, spacing: SCToken.Space.m) {
                                    Image(systemName: type.iconName)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(SCToken.accent(for: type))
                                        .frame(width: 22)
                                        .padding(.top, 1)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(type.displayName)
                                            .font(SCToken.Text.rowSubtitle)
                                            .foregroundColor(SCToken.Palette.label)
                                        Text(type.blurb)
                                            .font(SCToken.Text.caption)
                                            .foregroundColor(SCToken.Palette.secondaryLabel)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        } header: {
                            Text("可以用的后端类型")
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("服务器")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        creatingNew = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $creatingNew) {
                ServerEditorView(profile: nil) { profile in
                    model.saveServer(profile)
                }
            }
            .sheet(item: $editing) { profile in
                ServerEditorView(profile: profile) { updated in
                    model.saveServer(updated)
                }
            }
            .alert(item: $pendingDelete) { profile in
                Alert(
                    title: Text("删除「\(profile.displayTitle)」？"),
                    message: Text(model.settings.isActive(profile)
                                  ? "这是当前正在使用的服务器。删除后会切到列表里的第一台。"
                                  : "只影响这台设备的配置，服务器上的内容不会被删。"),
                    primaryButton: .destructive(Text("删除")) {
                        model.deleteServer(id: profile.id)
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 行

    private func serverRow(_ profile: SCServerProfile) -> some View {
        let isActive = model.settings.isActive(profile)
        let status = model.serverStatus[profile.id]

        return HStack(spacing: SCToken.Space.m) {
            SCTypeBadge(type: profile.type, large: true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: SCToken.Space.xs) {
                    Text(profile.displayTitle)
                        .font(SCToken.Text.rowTitle)
                        .foregroundColor(SCToken.Palette.label)
                        .lineLimit(1)
                    if isActive {
                        SCPill(text: "使用中", color: SCToken.accent(for: profile.type), compact: true)
                    }
                }
                Text(profile.displaySubtitle)
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.secondaryLabel)
                    .lineLimit(1)
                if let status, status.isBad {
                    Text(status.detail)
                        .font(SCToken.Text.caption)
                        .foregroundColor(SCToken.Palette.bad)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: SCToken.Space.s)

            if let status {
                switch status {
                case .checking:
                    ProgressView().scaleEffect(0.7)
                case .ok:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(SCToken.Palette.ok)
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(SCToken.Palette.bad)
                case .unknown:
                    EmptyView()
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    // MARK: - 空状态下的类型介绍

    private var typeGallery: some View {
        VStack(spacing: SCToken.Space.m) {
            ForEach(SCServerType.allCases) { type in
                HStack(alignment: .top, spacing: SCToken.Space.m) {
                    SCTypeBadge(type: type, large: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(type.displayName)
                            .font(SCToken.Text.rowTitle)
                        Text(type.blurb)
                            .font(SCToken.Text.caption)
                            .foregroundColor(SCToken.Palette.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SCToken.Space.m)
                .scCardSurface(radius: SCToken.Radius.m)
            }
        }
    }
}
