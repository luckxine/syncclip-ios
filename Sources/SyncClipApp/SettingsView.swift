import SwiftUI
import SyncClipCore

struct SettingsView: View {

    @EnvironmentObject private var model: AppModel

    private static let intervalOptions: [Double] = [1, 2, 3, 5, 10, 30]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: SCToken.Space.l) {
                    syncCard
                    behaviorCard
                    keepAliveCard
                    aboutCard
                }
                .padding(.horizontal, SCToken.Space.page)
                .padding(.vertical, SCToken.Space.l)
            }
            .scPageBackground()
            .navigationTitle("设置")
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 同步

    private var syncCard: some View {
        SCCard("同步", footnote: model.settings.syncEnabled
               ? nil
               : "关掉之后不轮询、不读写剪贴板。这个开关在后台也生效。") {
            toggleRow(icon: "arrow.triangle.2.circlepath",
                      tint: SCToken.accent(for: model.settings.activeServer?.type ?? .syncclipboard),
                      title: "启用同步",
                      subtitle: model.settings.hasServers
                          ? nil
                          : "还没有服务器，开了也不会同步",
                      isOn: Binding(
                        get: { model.settings.syncEnabled },
                        set: { model.settings.syncEnabled = $0; model.settingsChanged() }))

            SCCardDivider()

            VStack(alignment: .leading, spacing: SCToken.Space.s) {
                Text("轮询间隔")
                    .font(SCToken.Text.rowSubtitle)
                    .foregroundColor(SCToken.Palette.label)
                Text("每 \(Int(model.settings.pollInterval)) 秒检查一次两端有没有变化。"
                     + "调小更及时但更费电。")
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("轮询间隔", selection: Binding(
                    get: { model.settings.pollInterval },
                    set: { model.settings.pollInterval = $0; model.settingsChanged() })) {
                    ForEach(Self.intervalOptions, id: \.self) { v in
                        Text("\(Int(v)) 秒").tag(v)
                    }
                }
                .pickerStyle(.segmented)
            }

            SCCardDivider()

            toggleRow(icon: "text.alignleft",
                      tint: SCToken.Palette.secondaryLabel,
                      title: "详细日志",
                      subtitle: "把每一轮同步的细节都记下来，排查完建议关掉",
                      isOn: Binding(
                        get: { model.settings.verboseLogging },
                        set: { model.settings.verboseLogging = $0; model.settingsChanged() }))
        }
    }

    // MARK: - 行为

    private var behaviorCard: some View {
        SCCard("行为", footnote: "「启动时」只在冷启动后的第一次对齐生效，之后各走各的。") {
            VStack(alignment: .leading, spacing: SCToken.Space.s) {
                Text("启动时先做哪个方向")
                    .font(SCToken.Text.rowSubtitle)
                    .foregroundColor(SCToken.Palette.label)
                Picker("启动时", selection: Binding(
                    get: { model.settings.startupSync },
                    set: { model.settings.startupSync = $0; model.settingsChanged() })) {
                    ForEach(SCConfig.StartupSync.allCases) { s in
                        Text(s.displayName).tag(s.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            SCCardDivider()

            VStack(alignment: .leading, spacing: SCToken.Space.s) {
                Text("两端同时变了以谁为准")
                    .font(SCToken.Text.rowSubtitle)
                    .foregroundColor(SCToken.Palette.label)

                ForEach(SCConflictResolution.allCases) { option in
                    conflictOption(option)
                }
            }
        }
    }

    private func conflictOption(_ option: SCConflictResolution) -> some View {
        let selected = model.settings.conflictResolution == option.rawValue
        return Button {
            guard !selected else { return }
            model.settings.conflictResolution = option.rawValue
            model.settingsChanged()
        } label: {
            HStack(alignment: .top, spacing: SCToken.Space.s) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundColor(selected ? .accentColor : SCToken.Palette.tertiaryLabel)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.displayName)
                        .font(SCToken.Text.rowSubtitle)
                        .foregroundColor(SCToken.Palette.label)
                    Text(option.blurb)
                        .font(SCToken.Text.caption)
                        .foregroundColor(SCToken.Palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 常驻

    private var keepAliveCard: some View {
        SCCard("常驻", footnote: "没有越狱就注册不了系统服务，所以只能这样让进程活着。"
               + "关掉的话退到后台约 30 秒后同步就会停。") {
            toggleRow(icon: "waveform",
                      tint: SCToken.Palette.warn,
                      title: "后台保活",
                      subtitle: "持续播放一段听不见的音频，系统就不会挂起本 App。代价是费电。",
                      isOn: Binding(
                        get: { model.settings.keepAliveEnabled },
                        set: { model.settings.keepAliveEnabled = $0; model.settingsChanged() }))

            if let err = model.keepAliveError {
                SCCardDivider()
                HStack(alignment: .top, spacing: SCToken.Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(SCToken.Palette.bad)
                    Text(err)
                        .font(SCToken.Text.caption)
                        .foregroundColor(SCToken.Palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 关于

    private var aboutCard: some View {
        SCCard("关于") {
            SCKeyValue(key: "版本", value: Self.versionText)
            SCKeyValue(key: "Bundle ID", value: Bundle.main.bundleIdentifier ?? "-", mono: true)

            SCCardDivider()

            VStack(alignment: .leading, spacing: SCToken.Space.xs) {
                Text("配置文件")
                    .font(SCToken.Text.rowSubtitle)
                Text(SCAppSettings.defaultURL.path)
                    .font(SCToken.Text.monoSmall)
                    .foregroundColor(SCToken.Palette.secondaryLabel)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("是个 JSON，可以用 Filza 直改。改完回 App 会自动生效。")
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.tertiaryLabel)
            }

            SCCardDivider()

            VStack(alignment: .leading, spacing: SCToken.Space.xs) {
                Text("URL 快捷动作")
                    .font(SCToken.Text.rowSubtitle)
                Text("syncclip://sync   立即同步\n"
                     + "syncclip://push   推送当前剪贴板\n"
                     + "syncclip://pull   拉取远端内容")
                    .font(SCToken.Text.monoSmall)
                    .foregroundColor(SCToken.Palette.secondaryLabel)
                    .textSelection(.enabled)
                Text("配合「设置 → 辅助功能 → 触控 → 轻点背面 → 快捷指令 → 打开 URL」，"
                     + "就能双击手机背面同步一次，不用打开 App。")
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.tertiaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 组件

    private func toggleRow(icon: String, tint: Color, title: String,
                           subtitle: String?, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: SCToken.Space.m) {
            SCIconLabel(icon: icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SCToken.Text.rowTitle)
                if let subtitle {
                    Text(subtitle)
                        .font(SCToken.Text.caption)
                        .foregroundColor(SCToken.Palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: SCToken.Space.s)
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
    }

    private static var versionText: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
