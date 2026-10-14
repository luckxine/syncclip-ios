import Foundation
import Darwin

/// Darwin 通知（notifyd）。
///
/// 用途：让守护进程在「剪贴板刚被写」的瞬间醒来做一轮同步，而不是干等轮询。
/// 注意：这是**优化，不是依赖**。系统有没有为剪贴板变更发通知因版本而异，
/// 所以轮询是保底路径，通知只是加速。用 `syncclipd probe --watch` 可以实测哪些名字会触发。
public enum SCDarwinNotify {

    /// 常见的剪贴板相关通知名候选。全部订阅上，谁触发都唤醒一次同步。
    /// 这类名字都是非保留前缀（不含 `com.apple.system.`），普通用户域进程即可订阅与投递。
    public static let clipboardCandidates: [String] = [
        "com.apple.pasteboard.changed",
        "com.apple.pasteboard.pasteboard.changed",
        "com.apple.UIKit.pasteboard.changed",
        "com.apple.pasteboard.notify.changed"
    ]

    /// 订阅一组通知名；回调在给定队列上执行。
    /// - Returns: token 数组，调用方保留它们即可（取消订阅用 `cancel`）。
    @discardableResult
    public static func observe(_ names: [String],
                               queue: DispatchQueue,
                               handler: @escaping (String) -> Void) -> [Int32] {
        var tokens: [Int32] = []
        for name in names {
            var token: Int32 = 0
            let status = notify_register_dispatch(name, &token, queue) { _ in
                handler(name)
            }
            if status == NOTIFY_STATUS_OK {
                tokens.append(token)
            } else {
                SCLog.debug("订阅通知 \(name) 失败，status=\(status)")
            }
        }
        return tokens
    }

    public static func cancel(_ tokens: [Int32]) {
        for t in tokens { _ = notify_cancel(t) }
    }

    /// 主动投递一个通知（调试用）
    public static func post(_ name: String) {
        _ = notify_post(name)
    }
}
