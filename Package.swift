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
        .library(name: "SyncClipCore", targets: ["SyncClipCore"])
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
        )
    ]
)
