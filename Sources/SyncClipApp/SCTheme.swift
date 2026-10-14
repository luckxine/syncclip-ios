import SwiftUI
import UIKit
import SyncClipCore

/// 设计 token 层。
///
/// 所有间距、圆角、颜色、字号都在这里定义一次，界面层只用 token，不写字面量。
/// 这样改一处就能整体调整，也不会出现「这个卡片 14 那个卡片 15」这类磨损。
///
/// 颜色一律建在 iOS 的语义色之上（systemBackground / label / …），
/// 于是深色模式、增强对比度、灰度滤镜都是系统帮我们处理的，不必自己维护两套。
enum SCToken {

    // MARK: - 间距（4 的倍数，越往上越少用）

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
        /// 页面左右统一留白
        static let page: CGFloat = 16
    }

    enum Radius {
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 22
        static let pill: CGFloat = 999
    }

    // MARK: - 字号

    enum Text {
        /// 大号状态标题
        static let hero = Font.system(size: 26, weight: .semibold)
        static let sectionTitle = Font.system(size: 13, weight: .semibold)
        static let rowTitle = Font.system(size: 16, weight: .medium)
        static let rowSubtitle = Font.system(size: 13)
        static let caption = Font.system(size: 12)
        static let metricValue = Font.system(size: 22, weight: .semibold)
        static let metricLabel = Font.system(size: 11, weight: .medium)
        static let mono = Font.system(size: 12, design: .monospaced)
        static let monoSmall = Font.system(size: 11, design: .monospaced)
        static let badge = Font.system(size: 10, weight: .heavy)
    }

    // MARK: - 颜色

    enum Palette {
        static var surface: Color { Color(uiColor: .secondarySystemGroupedBackground) }
        static var raised: Color { Color(uiColor: .systemBackground) }
        static var pageBackground: Color { Color(uiColor: .systemGroupedBackground) }
        static var separator: Color { Color(uiColor: .separator) }
        static var label: Color { Color(uiColor: .label) }
        static var secondaryLabel: Color { Color(uiColor: .secondaryLabel) }
        static var tertiaryLabel: Color { Color(uiColor: .tertiaryLabel) }

        static let ok = Color.green
        static let warn = Color.orange
        static let bad = Color.red
        static let idle = Color.secondary
    }

    /// 每种服务器类型一个固定的识别色。
    /// 深色模式下要调亮，否则在深背景上分辨不出，所以用 trait-aware 的颜色。
    static func accent(for type: SCServerType) -> Color {
        switch type {
        case .syncclipboard:
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.40, green: 0.62, blue: 1.00, alpha: 1)
                    : UIColor(red: 0.16, green: 0.40, blue: 0.92, alpha: 1)
            })
        case .webdav:
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.30, green: 0.82, blue: 0.55, alpha: 1)
                    : UIColor(red: 0.05, green: 0.55, blue: 0.32, alpha: 1)
            })
        case .s3:
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 1.00, green: 0.66, blue: 0.28, alpha: 1)
                    : UIColor(red: 0.82, green: 0.44, blue: 0.05, alpha: 1)
            })
        }
    }

    static func tint(for status: SCSyncEngine.Action) -> Color {
        switch status {
        case .pulled, .pushed: return Palette.ok
        case .failed: return Palette.bad
        case .skipped: return Palette.warn
        case .idle: return Palette.idle
        }
    }

    // MARK: - 动效

    /// 统一的展开/收起曲线。系统默认的 easeInOut 在卡片出现时略显生硬。
    static let reveal = Animation.spring(response: 0.38, dampingFraction: 0.86)
    static let quick = Animation.easeOut(duration: 0.18)
}

// MARK: - 便捷修饰符

extension View {
    /// 页面级背景
    func scPageBackground() -> some View {
        background(SCToken.Palette.pageBackground.ignoresSafeArea())
    }

    /// 卡片外观：圆角 + 背景，不用阴影（iOS 的 grouped 背景上阴影会显脏）
    func scCardSurface(radius: CGFloat = SCToken.Radius.l) -> some View {
        background(SCToken.Palette.surface,
                   in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
