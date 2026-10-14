#if canImport(UIKit)
import Foundation
import UIKit

/// 系统剪贴板封装。
///
/// 无提示读写依赖二进制上的这组 entitlement（见 syncclipd.entitlements）：
///   com.apple.private.webkit.pasteboard
///   com.apple.private.pasteboard.check-pasteboard
///   com.apple.Pasteboard.background-access
///   com.apple.Pasteboard.paste-unchecked
///
/// 重要：**必须以 mobile（用户域）身份运行**。pasteboardd 是每用户的 launchd 服务，
/// root 的系统域进程连不上它，会表现为「读到空」。所以守护进程走 LaunchAgent。
public enum SCPasteboard {

    /// 当前剪贴板文本。读不到（非文本内容等）返回 nil。
    public static func readText() -> String? {
        let pb = UIPasteboard.general
        // 用 string 而不是 strings：空剪贴板/非文本内容时 strings 可能给出空数组
        guard let s = pb.string, !s.isEmpty else { return nil }
        return s
    }

    /// 写入文本。
    @discardableResult
    public static func writeText(_ text: String) -> Bool {
        let pb = UIPasteboard.general
        pb.string = text
        return true
    }

    /// 剪贴板变更计数。**这是变更检测的首选手段**：它由 pasteboardd 维护，
    /// 每次写入都会 +1，读它不需要额外权限，也不受内容类型影响。
    /// 比「读内容再比字符串」更可靠，而且不会因为系统弹「允许粘贴」而失败。
    public static var changeCount: Int {
        UIPasteboard.general.changeCount
    }

    /// 剪贴板里是否含有文本
    public static var hasText: Bool {
        UIPasteboard.general.hasStrings
    }

    /// 剪贴板里有哪些 UTI（用于 CLI 诊断，不参与同步逻辑）
    public static var typeIdentifiers: [String] {
        UIPasteboard.general.types
    }
}
#endif
