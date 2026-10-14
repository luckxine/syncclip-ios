import Foundation
import SwiftUI
import SyncClipCore

struct SettingsView: View {

    @EnvironmentObject private var model: AppModel

    // 服务器相关的字段用本地 state，按「保存并应用」才生效。
    // 不直接双向绑定：否则每敲一个字符都会重建同步循环，既费电又难排查。
    @State private var baseURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var pollInterval: Double = 2
    @State private var startupSync = "pull"
    @State private var showPassword = false
    @State private var loaded = false

    private let intervalOptions: [Double] = [1, 2, 3, 5, 10, 30]

    var body: some View {
        NavigationView {
            Form {

                // MARK: 后台常驻

                Section {
                    Toggle("后台保活", isOn: Binding(
                        get: { model.settings.keepAliveEnabled },
                        set: { model.settings.keepAliveEnabled = $0; model.settingsChanged() }
                    ))
                    Text("没有越狱就注册不了 launchd 守护进程，所以只能靠持续播放一段听不见的音频，让系统不挂起本 App。关掉的话，退到后台约 30 秒后同步就会停。代价是费电。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("常驻")
                }

                // MARK: 同步开关

                Section {
                    Toggle("启用同步", isOn: Binding(
                        get: { model.settings.syncEnabled },
                        set: { model.settings.syncEnabled = $0; model.settingsChanged() }
                    ))
                    Toggle("详细日志", isOn: Binding(
                        get: { model.settings.verboseLogging },
                        set: { model.settings.verboseLogging = $0; model.settingsChanged() }
                    ))
                } header: {
                    Text("同步")
                } footer: {
                    Text("详细日志会把每一轮同步的细节都记下来，排查完建议关掉。")
                }

                // MARK: 服务器

                Section {
                    HStack {
                        Text("地址")
                        Spacer()
                        TextField("http://192.168.1.10:5033", text: $baseURL)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                    HStack {
                        Text("用户名")
                        Spacer()
                        TextField("用户名", text: $username)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    HStack {
                        Text("密码")
                        Spacer()
                        if showPassword {
                            TextField("密码", text: $password)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("密码", text: $password)
                                .multilineTextAlignment(.trailing)
                        }
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("服务器")
                } footer: {
                    Text("就是 SyncClipboard.Server 的地址（自建 Docker 那台）。地址要带 http:// 或 https:// 前缀，端口别漏。")
                }

                // MARK: 同步行为

                Section {
                    Picker("轮询间隔", selection: $pollInterval) {
                        ForEach(intervalOptions, id: \.self) { v in
                            Text(v < 1 ? "\(Int(v * 1000)) 毫秒" : "\(Int(v)) 秒").tag(v)
                        }
                    }
                    Picker("启动时", selection: $startupSync) {
                        Text("跟随远端（拉取）").tag("pull")
                        Text("以本地为准（推送）").tag("push")
                        Text("都不做，只记录").tag("none")
                    }
                } header: {
                    Text("同步行为")
                } footer: {
                    Text("「启动时」只影响 App 冷启动后的第一次对齐方向。之后是按内容变化各走各的。")
                }

                // MARK: 应用

                Section {
                    Button {
                        apply()
                    } label: {
                        Label("保存并应用", systemImage: "checkmark.circle")
                    }
                    Button {
                        Task { await model.testConnection() }
                    } label: {
                        Label("测试连接", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }

                // MARK: 关于

                Section {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(Self.versionText).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Bundle ID")
                        Spacer()
                        Text(Bundle.main.bundleIdentifier ?? "-")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("配置文件").font(.footnote)
                        Text(SCAppSettings.defaultURL.path)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("用 Filza 可以直改这个 JSON。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } header: {
                    Text("关于")
                }
            }
            .navigationTitle("设置")
            .onAppear(perform: loadFromModel)
        }
        .navigationViewStyle(.stack)
    }

    private static var versionText: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private func loadFromModel() {
        guard !loaded else { return }
        loaded = true
        baseURL = model.settings.baseURL
        username = model.settings.username
        password = model.settings.password
        pollInterval = model.settings.pollInterval
        startupSync = model.settings.startupSync
    }

    private func apply() {
        model.settings.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        model.settings.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        model.settings.password = password
        model.settings.pollInterval = pollInterval
        model.settings.startupSync = startupSync
        model.settingsChanged()

        do {
            _ = try model.settings.toConfig()
            model.toast = "已保存并应用"
        } catch {
            model.toast = "已保存，但还不能同步：\(error)"
        }
    }
}
