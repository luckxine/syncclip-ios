import Foundation
import UIKit

// 探针是一个纯粹的工具 App：不做 UI 设计，只要能在真机上把三件事看清楚。
// 用 UIKit 而不是 SwiftUI 是刻意的 —— 探针越"笨"越好，不能让它自己的框架问题
// 混进实验结果里。

exit(UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv,
                       nil, NSStringFromClass(ProbeAppDelegate.self)))

final class ProbeAppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = ProbeViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
