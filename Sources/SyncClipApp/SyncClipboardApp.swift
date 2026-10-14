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
    /// 让首页的「切换服务器」能直接跳到服务器页
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(selectedTab: $selectedTab)
                .tabItem { Label("同步", systemImage: "arrow.triangle.2.circlepath") }
                .tag(0)

            ServersView()
                .tabItem { Label("服务器", systemImage: "server.rack") }
                .tag(1)

            SettingsView()
                .tabItem { Label("设置", systemImage: "slider.horizontal.3") }
                .tag(2)

            DiagnosticsView()
                .tabItem { Label("诊断", systemImage: "stethoscope") }
                .tag(3)
        }
        .modifier(ToastModifier(message: $model.toast))
    }
}

/// 顶部一闪而过的提示条。
/// 不用系统 Alert：同步是低注意力场景，弹窗会打断手里的操作。
struct ToastModifier: ViewModifier {

    @Binding var message: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let text = message {
                HStack(spacing: SCToken.Space.s) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 13))
                    Text(text)
                        .font(SCToken.Text.rowSubtitle)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                .foregroundColor(.white)
                .padding(.horizontal, SCToken.Space.l)
                .padding(.vertical, SCToken.Space.m)
                .background(Color.black.opacity(0.84),
                            in: RoundedRectangle(cornerRadius: SCToken.Radius.m, style: .continuous))
                .padding(.horizontal, SCToken.Space.page)
                .padding(.top, SCToken.Space.s)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { message = nil }
                .onAppear {
                    let shown = text
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        if message == shown { message = nil }
                    }
                }
            }
        }
        .animation(SCToken.reveal, value: message)
    }
}
