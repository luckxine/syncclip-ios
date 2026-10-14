import Foundation
import PasteProbeShared

// 这是一份 app extension 的「假入口」。
//
// SwiftPM 没有 app-extension 产品类型，executable target 必须有一个 main.swift，
// 所以这个文件存在。但链接器在 Package.swift 里被指定了
// `-Xlinker -e -Xlinker _NSExtensionMain`，真正的入口是 Foundation 的
// NSExtensionMain —— 它会去读 appex Info.plist 里的 NSExtensionPrincipalClass，
// 实例化我们的 ProbeTunnelProvider。正常的 appex 里，下面这段顶层代码一行都不会跑。
//
// 那为什么还要在这里写东西？因为万一 `-e` 没生效（比如链接器行为变了），
// 进程会真的跑进这个 main。这时最坏的结果是「appex 静默不起作用」，
// 现象是「隧道连上了但日志里什么都没有」—— 和 entitlement 没生效长得一模一样。
// 所以这里留一条只有这种情况才会出现的日志，让两种失败在日志里能区分开。

ProbeLog.append(source: "tunnel", kind: "fakeEntry",
                detail: "main() 被执行了 —— 说明 -Xlinker -e _NSExtensionMain 没生效，"
                      + "appex 的入口点不对。这条日志只在链接器入口有问题时出现。")

// 不退出：退出会让 PluginKit 报「扩展崩溃」，而我们要的是那条日志能被读到。
RunLoop.main.run()
