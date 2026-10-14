import SwiftUI
import UIKit
import SyncClipCore

// 基础组件。原则：每个组件只做一件事、能被组合，样式全部来自 SCToken。
// 界面文件里不出现魔法数字，也就不容易出现「这里圆角 12 那里 14」的磨损。

// MARK: - 卡片与分节

/// 一张卡片。标题可选，内容自由组合。
struct SCCard<Content: View>: View {
    private let title: String?
    private let footnote: String?
    private let content: Content

    init(_ title: String? = nil,
         footnote: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SCToken.Space.s) {
            if let title {
                Text(title.uppercased())
                    .font(SCToken.Text.sectionTitle)
                    .foregroundColor(SCToken.Palette.secondaryLabel)
                    .padding(.leading, SCToken.Space.xs)
            }
            VStack(alignment: .leading, spacing: SCToken.Space.m) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SCToken.Space.l)
            .scCardSurface()

            if let footnote {
                Text(footnote)
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.tertiaryLabel)
                    .padding(.horizontal, SCToken.Space.xs)
            }
        }
    }
}

/// 卡片内的一条分割线（比 Divider 的留白更贴合卡片的间距体系）
struct SCCardDivider: View {
    var body: some View {
        Rectangle()
            .fill(SCToken.Palette.separator.opacity(0.35))
            .frame(height: 1)
            .padding(.vertical, SCToken.Space.xxs)
    }
}

// MARK: - 状态

/// 圆点 + 文字的状态胶囊
struct SCPill: View {
    let text: String
    let color: Color
    var icon: String?
    var compact = false

    var body: some View {
        HStack(spacing: SCToken.Space.xs) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: compact ? 9 : 10, weight: .bold))
            } else {
                Circle()
                    .fill(color)
                    .frame(width: compact ? 5 : 6, height: compact ? 5 : 6)
            }
            Text(text)
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 4)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// 服务器类型徽章：SC / DAV / S3
struct SCTypeBadge: View {
    let type: SCServerType
    var large = false

    var body: some View {
        Text(type.badge)
            .font(.system(size: large ? 12 : 10, weight: .heavy))
            .foregroundColor(.white)
            .padding(.horizontal, large ? 8 : 6)
            .padding(.vertical, large ? 4 : 3)
            .background(SCToken.accent(for: type), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .fixedSize()
    }
}

// MARK: - 行

/// 带图标的设置行（用于设置页那些开关的左侧）
struct SCIconLabel: View {
    let icon: String
    var tint: Color = .accentColor

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 26, height: 26)
            .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

// MARK: - 指标

/// 一个数字 + 一个标签的小方块
struct SCMetric: View {
    let value: String
    let label: String
    let icon: String
    var tint: Color = SCToken.Palette.secondaryLabel

    var body: some View {
        VStack(spacing: SCToken.Space.xs) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tint)
            Text(value)
                .font(SCToken.Text.metricValue)
                .foregroundColor(SCToken.Palette.label)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(SCToken.Text.metricLabel)
                .foregroundColor(SCToken.Palette.tertiaryLabel)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 文本字段

/// 表单里的一个输入行。左侧固定宽度的标签，右侧输入框。
struct SCField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var secure = false
    var keyboard: UIKeyboardType = .default
    var autocapitalize = false
    var footnote: String?

    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: SCToken.Space.xs) {
            HStack(spacing: SCToken.Space.s) {
                Text(label)
                    .font(SCToken.Text.rowSubtitle)
                    .foregroundColor(SCToken.Palette.secondaryLabel)
                    .frame(width: 92, alignment: .leading)

                Group {
                    if secure && !revealed {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .font(SCToken.Text.rowTitle)
                .textInputAutocapitalization(autocapitalize ? .sentences : .never)
                .autocorrectionDisabled()
                .keyboardType(keyboard)

                if secure {
                    Button {
                        revealed.toggle()
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                            .font(.system(size: 13))
                            .foregroundColor(SCToken.Palette.tertiaryLabel)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let footnote {
                Text(footnote)
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.tertiaryLabel)
                    .padding(.leading, 92 + SCToken.Space.s)
            }
        }
    }
}

// MARK: - 预览

/// 等宽预览块。空的时候显示占位说明，非空时给个复制按钮和字数。
struct SCPreview: View {
    let text: String
    let placeholder: String
    var lineLimit = 5
    var onCopy: (() -> Void)?

    private var isEmpty: Bool { text.isEmpty }

    private var charCount: String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return "\(text.count) 字符 · \(lines) 行"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SCToken.Space.s) {
            if isEmpty {
                Text(placeholder)
                    .font(SCToken.Text.rowSubtitle)
                    .foregroundColor(SCToken.Palette.tertiaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(text)
                    .font(SCToken.Text.mono)
                    .foregroundColor(SCToken.Palette.label)
                    .lineLimit(lineLimit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                HStack(spacing: SCToken.Space.m) {
                    Text(charCount)
                        .font(SCToken.Text.caption)
                        .foregroundColor(SCToken.Palette.tertiaryLabel)
                    Spacer()
                    if let onCopy {
                        Button(action: onCopy) {
                            Label("复制", systemImage: "doc.on.doc")
                                .font(SCToken.Text.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    }
                }
            }
        }
    }
}

// MARK: - 空状态

struct SCEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: SCToken.Space.m) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundColor(SCToken.Palette.tertiaryLabel)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(SCToken.Palette.label)
            Text(message)
                .font(SCToken.Text.rowSubtitle)
                .foregroundColor(SCToken.Palette.secondaryLabel)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .padding(.top, SCToken.Space.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SCToken.Space.xxl)
        .padding(.horizontal, SCToken.Space.l)
    }
}

// MARK: - 按钮

/// 主操作按钮（大、满宽）
struct SCPrimaryButton: View {
    let title: String
    let icon: String
    var tint: Color = .accentColor
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SCToken.Space.s) {
                if busy {
                    ProgressView().progressViewStyle(.circular).tint(.white)
                } else {
                    Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                }
                Text(title).font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, SCToken.Space.m)
            .foregroundColor(.white)
            .background(tint, in: RoundedRectangle(cornerRadius: SCToken.Radius.m, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.7 : 1)
    }
}

/// 次要操作按钮（描边）
struct SCSecondaryButton: View {
    let title: String
    let icon: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SCToken.Space.xs) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 14, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, SCToken.Space.s + 2)
            .foregroundColor(.accentColor)
            .background(
                RoundedRectangle(cornerRadius: SCToken.Radius.m, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 键值行

struct SCKeyValue: View {
    let key: String
    let value: String
    var mono = false
    var tint: Color?

    var body: some View {
        HStack(alignment: .top, spacing: SCToken.Space.m) {
            Text(key)
                .font(SCToken.Text.rowSubtitle)
                .foregroundColor(SCToken.Palette.secondaryLabel)
            Spacer(minLength: SCToken.Space.s)
            Text(value)
                .font(mono ? SCToken.Text.mono : SCToken.Text.rowSubtitle)
                .foregroundColor(tint ?? SCToken.Palette.label)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
