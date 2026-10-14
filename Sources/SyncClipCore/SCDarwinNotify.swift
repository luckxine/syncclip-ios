import Foundation

/// Darwin 通知（notifyd）。
///
/// 用途：让同步在「剪贴板刚被写」的瞬间醒来做一轮，而不是干等轮询。
/// **这是优化，不是依赖** —— 轮询是保底路径，通知只是提前唤醒。
///
/// ## 为什么用 dlsym 而不是直接调用
///
/// notify(3) 这套 API（`notify_register_dispatch` / `notify_post` / `notify_cancel`）
/// 在 <notify.h> 里，但 Swift 的 Darwin 模块**在 iOS 上不导出它们**
/// （macOS 上能直接 import Darwin 用到）。直接写会编译失败：
///     error: cannot find 'notify_register_dispatch' in scope
///
/// 而我们要么为它退化掉编译，要么拿不到这个加速项。用 dlsym 在运行时解析是更合适的做法：
///   - 编译期不依赖头文件，代码永远能过
///   - 运行期符号在就用、不在就静默降级成纯轮询
///   - `notify_client.h` 也把 `notify_register_dispatch` 标为「其他平台私有 API」，
///     所以运行时探测比编译期假设更诚实
///
/// 符号由 libSystem 提供，`dlopen(nil)` 拿到主程序句柄即可。
public enum SCDarwinNotify {

    /// 常见的剪贴板相关通知名候选。全部订阅上，谁触发都唤醒一次同步。
    /// 这类名字都是非保留前缀（不含 `com.apple.system.`），普通用户域进程即可订阅与投递。
    public static let clipboardCandidates: [String] = [
        "com.apple.pasteboard.changed",
        "com.apple.pasteboard.pasteboard.changed",
        "com.apple.UIKit.pasteboard.changed",
        "com.apple.pasteboard.notify.changed"
    ]

    // MARK: - 动态解析 notify(3)

    /// `uint32_t notify_register_dispatch(const char *name, int *out_token,
    ///                                    dispatch_queue_t queue, notify_handler_t handler);`
    /// `typedef void (^notify_handler_t)(int token);`
    private typealias RegisterDispatchFn = @convention(c) (
        UnsafePointer<CChar>,
        UnsafeMutablePointer<Int32>,
        DispatchQueue,
        @convention(block) (Int32) -> Void
    ) -> UInt32

    private typealias CancelFn = @convention(c) (Int32) -> UInt32
    private typealias PostFn = @convention(c) (UnsafePointer<CChar>) -> UInt32

    /// NOTIFY_STATUS_OK。这是 <notify.h> 里的宏，Swift 也拿不到，所以写字面量。
    private static let statusOK: UInt32 = 0

    private static let registerDispatch: RegisterDispatchFn? = {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "notify_register_dispatch") else { return nil }
        return unsafeBitCast(sym, to: RegisterDispatchFn.self)
    }()

    private static let cancelFn: CancelFn? = {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "notify_cancel") else { return nil }
        return unsafeBitCast(sym, to: CancelFn.self)
    }()

    private static let postFn: PostFn? = {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "notify_post") else { return nil }
        return unsafeBitCast(sym, to: PostFn.self)
    }()

    /// 这台设备上 notify(3) 到底能不能用。诊断页可以显示它。
    public static var isAvailable: Bool { registerDispatch != nil && cancelFn != nil }

    // MARK: - 订阅

    /// 订阅一组通知名；回调在给定队列上执行。
    /// - Returns: token 数组。空数组表示「这台设备/这个平台用不了」，调用方应安静地退回轮询。
    @discardableResult
    public static func observe(_ names: [String],
                               queue: DispatchQueue,
                               handler: @escaping (String) -> Void) -> [Int32] {
        guard isAvailable else {
            SCLog.debug("notify_register_dispatch 在当前平台不可用（Swift 的 Darwin 模块在 iOS 上不导出 notify API），退回纯轮询")
            return []
        }
        guard let register = registerDispatch else { return [] }

        var tokens: [Int32] = []
        for name in names {
            var token: Int32 = 0
            let status = name.withCString { cName in
                register(cName, &token, queue) { _ in handler(name) }
            }
            if status == statusOK {
                tokens.append(token)
            } else {
                SCLog.debug("订阅通知 \(name) 失败，status=\(status)")
            }
        }
        return tokens
    }

    public static func cancel(_ tokens: [Int32]) {
        guard let cancel = cancelFn else { return }
        for t in tokens { _ = cancel(t) }
    }

    /// 主动投递一个通知（调试用）
    public static func post(_ name: String) {
        guard let post = postFn else { return }
        _ = name.withCString { post($0) }
    }
}
