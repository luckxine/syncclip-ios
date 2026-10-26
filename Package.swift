// swift-tools-version:5.9
// 刻意停在 5.9：强制 Swift 5 语言模式，避免 Xcode 16 自带 Swift 6 把并发检查升级成编译错误。
import PackageDescription

let package = Package(
    name: "SyncClipboardiOS",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        // iOS App（TrollStore 安装）
        .executable(name: "SyncClipboard", targets: ["SyncClipboardApp"]),
        // 常驻守护进程（越狱路线，保留；将来若越狱可直接用）
        .executable(name: "syncclipd", targets: ["syncclipd"]),
        // 同步核心，两条路线共用
        .library(name: "SyncClipCore", targets: ["SyncClipCore"]),
        // NE 可行性探针（见 docs/probe.md）：宿主 App + 隧道 appex
        .executable(name: "PasteProbe", targets: ["PasteProbe"]),
        .executable(name: "PasteProbeTunnel", targets: ["PasteProbeTunnel"]),
        // M4/M5：分享与键盘两个 appex（各自被 build-app.sh 组进 PlugIns/）
        .executable(name: "ShareExt", targets: ["ShareExt"]),
        .executable(name: "KeyboardExt", targets: ["KeyboardExt"])
    ],
    targets: [
        .target(
            name: "SyncClipCore",
            path: "Sources/SyncClipCore"
        ),
        // AppGroupStore 单独成一个库：两个 appex 要用它，而 executable target
        // 不能被别的 target 依赖。模块名刻意保持 "SyncClipApp"（与目录名一致），
        // 这样脚本 lint-swift.js 的符号索引（按 Sources/ 第一层目录名推断模块）
        // 与真实模块划分一致，扩展里的 import 不会出现假报错。
        .target(
            name: "SyncClipApp",
            dependencies: ["SyncClipCore"],
            path: "Sources/SyncClipApp",
            sources: ["AppGroupStore.swift"]
        ),
        // 主 App 的 executable。AppGroupStore.swift 归上面的库（见注释），
        // 所以这里 exclude 掉；主 App 源码用它时需要 import SyncClipApp。
        .executableTarget(
            name: "SyncClipboardApp",
            dependencies: ["SyncClipCore", "SyncClipApp"],
            path: "Sources/SyncClipApp",
            exclude: ["AppGroupStore.swift"]
        ),
        .executableTarget(
            name: "syncclipd",
            dependencies: ["SyncClipCore"],
            path: "Sources/syncclipd"
        ),

        // ---- 探针 ----
        .target(name: "PasteProbeShared", path: "Sources/PasteProbeShared"),
        .executableTarget(
            name: "PasteProbe",
            dependencies: ["PasteProbeShared"],
            path: "Sources/PasteProbe"
        ),
        // 这是一个 app extension，不是普通可执行文件。SwiftPM 没有 app-extension
        // 产品类型，所以两件 Xcode 本来会替我们做的事只能手写：
        //   1. 入口点必须指向 Foundation 的 NSExtensionMain（PlugInKit 靠它去读
        //      Info.plist 里的 NSExtensionPrincipalClass 并实例化我们的 provider）。
        //      SwiftPM 仍然要求 executable target 有个 main.swift，那个文件在正常
        //      情况下永远不会被执行（见 Sources/PasteProbeTunnel/main.swift 的注释）。
        //   2. -application-extension 让编译器替我们把「appex 里不该用的 API」拦下来。
        .executableTarget(
            name: "PasteProbeTunnel",
            dependencies: ["PasteProbeShared"],
            path: "Sources/PasteProbeTunnel",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),

        // ---- M4/M5 扩展（照 PasteProbeTunnel 的模式，见上面那段注释）----
        .executableTarget(
            name: "ShareExt",
            dependencies: ["SyncClipCore", "SyncClipApp"],
            path: "Sources/ShareExt",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .executableTarget(
            name: "KeyboardExt",
            dependencies: ["SyncClipCore", "SyncClipApp"],
            path: "Sources/KeyboardExt",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        )
    ]
)
