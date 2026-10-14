import SwiftUI
import UIKit
import SyncClipCore

/// 服务器编辑器。新建和编辑共用：传 nil 就是新建。
///
/// 三种类型的字段差别很大，所以类型选择放在最上面且随时可换；
/// 换类型时**保留**已经填过的公共字段（地址、账号），不必重新敲一遍。
struct ServerEditorView: View {

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    private let original: SCServerProfile?
    private let onSave: (SCServerProfile) -> Void

    @State private var draft: SCServerProfile
    @State private var testState: AppModel.Connection = .unknown
    @State private var testing = false

    init(profile: SCServerProfile?, onSave: @escaping (SCServerProfile) -> Void) {
        self.original = profile
        self.onSave = onSave
        _draft = State(initialValue: profile ?? SCServerProfile())
    }

    private var isNew: Bool { original == nil }
    private var type: SCServerType { draft.type }

    private var validationError: String? {
        do {
            try draft.validate()
            return nil
        } catch {
            return "\(error)"
        }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: SCToken.Space.l) {
                    typePicker
                    identityCard
                    fieldsCard
                    testCard
                }
                .padding(.horizontal, SCToken.Space.page)
                .padding(.vertical, SCToken.Space.l)
            }
            .scPageBackground()
            .navigationTitle(isNew ? "添加服务器" : "编辑服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { save() }
                        .disabled(validationError != nil)
                        .fontWeight(.semibold)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 类型选择

    private var typePicker: some View {
        VStack(alignment: .leading, spacing: SCToken.Space.s) {
            Text("后端类型")
                .font(SCToken.Text.sectionTitle)
                .foregroundColor(SCToken.Palette.secondaryLabel)
                .padding(.leading, SCToken.Space.xs)

            VStack(spacing: SCToken.Space.s) {
                ForEach(SCServerType.allCases) { candidate in
                    typeOption(candidate)
                }
            }
        }
    }

    private func typeOption(_ candidate: SCServerType) -> some View {
        let selected = candidate == type
        let tint = SCToken.accent(for: candidate)

        return Button {
            guard !selected else { return }
            withAnimation(SCToken.reveal) {
                draft.type = candidate
                // 换类型后旧类型独有的字段就不适用了，清掉免得误导
                if candidate != .s3 {
                    // 这些字段只对 S3 有意义；保留用户填的地址与账号
                }
                testState = .unknown
            }
        } label: {
            HStack(alignment: .top, spacing: SCToken.Space.m) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 17))
                    .foregroundColor(selected ? tint : SCToken.Palette.tertiaryLabel)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: SCToken.Space.s) {
                        SCTypeBadge(type: candidate)
                        Text(candidate.displayName)
                            .font(SCToken.Text.rowSubtitle)
                            .foregroundColor(SCToken.Palette.label)
                    }
                    Text(candidate.blurb)
                        .font(SCToken.Text.caption)
                        .foregroundColor(SCToken.Palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SCToken.Space.m)
            .background(
                RoundedRectangle(cornerRadius: SCToken.Radius.m, style: .continuous)
                    .fill(selected ? tint.opacity(0.10) : SCToken.Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SCToken.Radius.m, style: .continuous)
                    .strokeBorder(selected ? tint.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 名称

    private var identityCard: some View {
        SCCard("名称", footnote: "留空就用主机名代替，纯给自己看的。") {
            SCField(label: "备注名",
                    placeholder: type == .s3 ? "例如 家里的 MinIO" : "例如 家里的服务器",
                    text: $draft.name,
                    autocapitalize: true)
        }
    }

    // MARK: - 各类型字段

    private var fieldsCard: some View {
        SCCard(type == .s3 ? "S3 连接" : "连接信息", footnote: footnote) {
            SCField(label: "地址",
                    placeholder: type.urlPlaceholder,
                    text: $draft.url,
                    keyboard: .URL,
                    footnote: type == .s3 ? "留空则用 AWS 默认端点" : urlFootnote)

            if type == .s3 {
                SCField(label: "区域",
                        placeholder: "us-east-1",
                        text: $draft.region)
                SCField(label: "存储桶",
                        placeholder: "my-bucket",
                        text: $draft.bucketName)
                SCField(label: "对象前缀",
                        placeholder: "syncclip（可留空）",
                        text: $draft.objectPrefix,
                        footnote: "对象会存在 <前缀>/SyncClipboard.json 与 <前缀>/file/ 下")

                SCCardDivider()

                Toggle(isOn: $draft.forcePathStyle) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("强制路径风格寻址")
                            .font(SCToken.Text.rowSubtitle)
                        Text("对象地址形如 host/bucket/key。自定义端点默认就是开的，"
                             + "AWS 官方端点一般不用开。")
                            .font(SCToken.Text.caption)
                            .foregroundColor(SCToken.Palette.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            SCCardDivider()

            SCField(label: type.usernameLabel,
                    placeholder: type == .s3 ? "AKIA…" : "用户名",
                    text: $draft.username)
            SCField(label: type.passwordLabel,
                    placeholder: type == .s3 ? "Secret Access Key" : "密码",
                    text: $draft.password,
                    secure: true)
        }
    }

    private var urlFootnote: String? {
        switch type {
        case .webdav:
            return "要指到具体目录，例如 https://dav.jianguoyun.com/dav/我的同步目录"
        case .syncclipboard:
            return "自建服务器的地址，带端口，例如 http://192.168.1.10:5033"
        default:
            return nil
        }
    }

    private var footnote: String? {
        switch type {
        case .s3:
            return "凭据是本机保存的，只会用来对请求签名。"
        default:
            return "同步的对象放在这个地址下的 SyncClipboard.json 与 file/ 里。"
        }
    }

    // MARK: - 测试

    private var testCard: some View {
        SCCard("测试") {
            HStack(spacing: SCToken.Space.s) {
                Button {
                    Task { await runTest() }
                } label: {
                    HStack(spacing: SCToken.Space.xs) {
                        if testing {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        Text("测试连接").font(.system(size: 14, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SCToken.Space.s + 2)
                    .foregroundColor(validationError == nil ? .accentColor : SCToken.Palette.tertiaryLabel)
                    .background(
                        RoundedRectangle(cornerRadius: SCToken.Radius.m, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(validationError == nil ? 0.35 : 0.1),
                                          lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(validationError != nil || testing)
            }

            // 测试前先本地校验，别把明显填错的东西发出去等服务器报错
            if let error = validationError {
                testResultRow(icon: "info.circle.fill",
                              tint: SCToken.Palette.secondaryLabel,
                              text: error)
            } else {
                switch testState {
                case .unknown:
                    Text("保存后如果这是当前使用的服务器，会自动测一次。")
                        .font(SCToken.Text.caption)
                        .foregroundColor(SCToken.Palette.tertiaryLabel)
                case .checking:
                    testResultRow(icon: "clock", tint: SCToken.Palette.warn, text: "正在请求服务器…")
                case .ok(let detail):
                    testResultRow(icon: "checkmark.circle.fill", tint: SCToken.Palette.ok, text: detail)
                case .failed(let detail):
                    testResultRow(icon: "exclamationmark.triangle.fill",
                                  tint: SCToken.Palette.bad, text: detail)
                }
            }

            if type == .s3 {
                SCCardDivider()
                sigV4Row
            }
        }
    }

    /// S3 能不能用，先看签名算法对不对。这个自检用的是 AWS 官方测试向量，
    /// 不需要联网也不需要凭据，所以在填完之前就能知道问题出在哪一层。
    private var sigV4Row: some View {
        let result = SCSigV4.selfTest()
        return testResultRow(icon: result.passed ? "checkmark.seal.fill" : "xmark.seal.fill",
                             tint: result.passed ? SCToken.Palette.ok : SCToken.Palette.bad,
                             text: result.passed
                                ? "SigV4 签名算法自检通过（AWS 官方测试向量）"
                                : result.detail)
    }

    private func testResultRow(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: SCToken.Space.s) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(tint)
            Text(text)
                .font(SCToken.Text.caption)
                .foregroundColor(SCToken.Palette.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 动作

    private func runTest() async {
        testing = true
        testState = .checking

        let config = SCConfig(profile: draft,
                              pollInterval: model.settings.pollInterval,
                              startupSyncRaw: model.settings.startupSync,
                              conflictRaw: model.settings.conflictResolution)
        guard let engine = try? SCSyncEngine(config: config) else {
            testState = .failed("无法创建同步引擎，检查上面的字段")
            testing = false
            return
        }

        let info = await engine.probeServer()
        if info.reachable {
            var detail = "连接成功"
            if let v = info.version, !v.isEmpty { detail += "，服务端版本 \(v)" }
            testState = .ok(detail)
        } else {
            testState = .failed(info.message)
        }
        testing = false
    }

    private func save() {
        guard validationError == nil else { return }
        onSave(draft)
        dismiss()
    }
}
