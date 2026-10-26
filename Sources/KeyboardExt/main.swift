import Foundation
import SyncClipApp

// 这是一份 app extension 的「假入口」，和 Sources/PasteProbeTunnel/main.swift
// 同一个套路：SwiftPM 要求 executable target 必须有 main.swift，但 Package.swift
// 里链接器被指定了 `-Xlinker -e -Xlinker _NSExtensionMain`，真正的入口是
// Foundation 的 NSExtensionMain —— 它会读 appex Info.plist 里的
// NSExtensionPrincipalClass，实例化我们的 KeyboardViewController。
// 正常的 appex 里，下面这段顶层代码一行都不会跑。
//
// 万一 `-e` 没生效（链接器行为变了），进程会真的跑进这个 main。这里照隧道
// 探针的思路留一条只有这种情况才会出现的日志：fakeEntry 行出现在
// keyboard.log 里 = 入口点配置错了。这条日志同时是 K3 探针的一部分 ——
// 它能证明"键盘进程活着且 App Group 可写"这两件事。
AppGroupStore.appendKeyboardLog("fakeEntry: main() 被执行了 —— -e _NSExtensionMain 没生效，appex 入口点不对")

// 不退出：退出会让 PlugInKit 报「扩展崩溃」，而我们要的是那条日志能被读到。
RunLoop.main.run()
