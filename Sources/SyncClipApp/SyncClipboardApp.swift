import SwiftUI
import UIKit
import SyncClipCore

@main
struct SyncClipboardApp: App {

    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onOpenURL { url in model.handle(url: url) }
                .onAppear { model.bootstrap() }
        }
        .onChange(of: scenePhase) { phase in
            // 回到前台时补一轮：后台保活万一被系统掐了，回前台立刻追上进度
            if phase == .active {
                Task { await model.syncNow(silent: true) }
            }
        }
    }
}

struct RootView: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("同步", systemImage: "arrow.triangle.2.circlepath") }

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }

            DiagnosticsView()
                .tabItem { Label("诊断", systemImage: "stethoscope") }
        }
        .modifier(ToastModifier(message: $model.toast))
    }
}

/// 顶部一闪而过的提示条
struct ToastModifier: ViewModifier {

    @Binding var message: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let text = message {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.82), in: Capsule())
                    .padding(.top, 8)
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        let shown = text
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                            if message == shown { message = nil }
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.22), value: message)
    }
}

// MARK: - 复用的小组件

/// 一张卡片容器
struct Card<Content: View>: View {
    let title: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// 一段等宽预览文本
struct PreviewBlock: View {
    let text: String
    let placeholder: String
    var lines: Int = 4

    var body: some View {
        if text.isEmpty {
            Text(placeholder)
                .font(.footnote)
                .foregroundStyle(.tertiary)
        } else {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(lines)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
    }
}
