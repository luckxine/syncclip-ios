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
        .executable(name: "SyncClipboard", targets: ["SyncClipApp"]),
        // 常驻守护进程（越狱路线，保留；将来若越狱可直接用）
        .executable(name: "syncclipd", targets: ["syncclipd"]),
        // 同步核心，两条路线共用
        .library(name: "SyncClipCore", targets: ["SyncClipCore"]),
        // NE 可行性探针（见 docs/probe.md）：宿主 App + 隧道 appex
        .executable(name: "PasteProbe", targets: ["PasteProbe"]),
        .executable(name: "PasteProbeTunnel", targets: ["PasteProbeTunnel"])
    ],
    targets: [
        .target(
            name: "SyncClipCore",
            path: "Sources/SyncClipCore"
        ),
        .executableTarget(
            name: "SyncClipApp",
            dependencies: ["SyncClipCore"],
            path: "Sources/SyncClipApp"
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
        )
    ]
)
