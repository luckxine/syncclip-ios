import Foundation

// 这是一份 app extension 的「假入口」，和 Sources/PasteProbeTunnel/main.swift
// 同一个套路：SwiftPM 要求 executable target 必须有 main.swift，但 Package.swift
// 里链接器被指定了 `-Xlinker -e -Xlinker _NSExtensionMain`，真正的入口是
// Foundation 的 NSExtensionMain —— 它会读 appex Info.plist 里的
// NSExtensionPrincipalClass，实例化我们的 ShareViewController。
// 正常的 appex 里，下面这段顶层代码一行都不会跑。
//
// 万一 `-e` 没生效（链接器行为变了），进程会真的跑进这个 main。这里不像隧道
// 探针那样写日志：分享扩展此刻没有任何可靠的日志通道（App Group 可能正好
// 不可用，写不进去的日志只会制造"已经排障过"的错觉），所以只留RunLoop 兜底，
// 不让进程退出 —— 退出会让 PlugInKit 报「扩展崩溃」，把现象搞混。

RunLoop.main.run()
