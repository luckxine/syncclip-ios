import SwiftUI
import UIKit
import SyncClipCore

struct DiagnosticsView: View {

    @EnvironmentObject private var model: AppModel
    @State private var busy = false
    /// PlugIns 目录下的 appex（P4）：装没装只看这个目录，别的都是间接信号
    @State private var appexEntries: [String] = []
    /// 键盘心跳日志（K1/K3）：进页时从 App Group 读一批
    @State private var keyboardLog: [String] = []

    private var d: AppModel.Diagnostics { model.diagnostics }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: SCToken.Space.l) {
                    foundationCard
                    checksCard
                    probeCard
                    extensionCard
                    keyboardCard
                    keepAliveCard
                    pushCard
                    pasteboardCard
                    endpointCard
                    logCard
                }
                .padding(.horizontal, SCToken.Space.page)
                .padding(.vertical, SCToken.Space.l)
            }
            .scPageBackground()
            .navigationTitle("诊断")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            Task { await runDiagnostics() }
                        } label: {
                            Label("重新诊断", systemImage: "arrow.clockwise")
                        }
                        Button {
                            model.copyLogs()
                        } label: {
                            Label("复制日志", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            model.clearLogs()
                        } label: {
                            Label("清空日志", systemImage: "trash")
                        }
                    } label: {
                        if busy { ProgressView() } else { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            refreshExtensionCards()
            if model.diagnostics.binaryPath.isEmpty {
                Task { await runDiagnostics() }
            }
        }
    }

    // MARK: - 地基

    private var foundationCard: some View {
        let ok = d.pasteboardEntitlementsPresent
        return SCCard("地基", footnote: ok
                      ? "读剪贴板不弹系统提示，这块就对了。"
                      : "没拿到关键 entitlement 的话，读剪贴板会弹「允许粘贴」，"
                        + "每次都被打断，那就白做了。") {
            HStack(alignment: .top, spacing: SCToken.Space.m) {
                Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(ok ? SCToken.Palette.ok : SCToken.Palette.warn)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ok ? "剪贴板权限就位" : "剪贴板权限可能不完整")
                        .font(SCToken.Text.rowTitle)
                    Text(d.note.isEmpty ? "还没有诊断数据，点右上角重新诊断" : d.note)
                        .font(SCToken.Text.caption)
                        .foregroundColor(SCToken.Palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if !d.entitlements.isEmpty {
                SCCardDivider()
                VStack(alignment: .leading, spacing: SCToken.Space.xs) {
                    Text("二进制里实际签到的 entitlement（\(d.entitlements.count) 条）")
                        .font(SCToken.Text.caption)
                        .foregroundColor(SCToken.Palette.secondaryLabel)
                    ForEach(d.entitlements, id: \.self) { key in
                        HStack(spacing: SCToken.Space.s) {
                            Image(systemName: key.lowercased().contains("pasteboard")
                                  ? "hand.raised.fill" : "checkmark")
                                .font(.system(size: 9))
                                .foregroundColor(key.lowercased().contains("pasteboard")
                                                 ? SCToken.Palette.ok : SCToken.Palette.tertiaryLabel)
                                .frame(width: 12)
                            Text(key)
                                .font(SCToken.Text.monoSmall)
                                .foregroundColor(SCToken.Palette.secondaryLabel)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else if let err = d.entitlementError {
                SCCardDivider()
                Text(err)
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 自检

    private var checksCard: some View {
        SCCard("算法自检", footnote: "这几项不联网、不需要凭据，能在出问题前就把「算法对不对」和"
               + "「权限有没有」分辨清楚。") {
            checkRow(title: "SigV4 签名",
                     ok: d.sigV4Passed,
                     detail: d.sigV4Detail.isEmpty ? "点右上角重新诊断" : d.sigV4Detail)
            SCCardDivider()
            checkRow(title: "Darwin 通知",
                     ok: d.darwinNotifyAvailable,
                     detail: d.darwinNotifyAvailable
                        ? "可用，剪贴板变化能立刻唤醒，比轮询更快"
                        : "不可用，退化为纯轮询。只是延迟略大，功能不受影响",
                     warnWhenFalse: true)
        }
    }

    private func checkRow(title: String, ok: Bool, detail: String, warnWhenFalse: Bool = false) -> some View {
        HStack(alignment: .top, spacing: SCToken.Space.m) {
            Image(systemName: ok ? "checkmark.circle.fill"
                                : (warnWhenFalse ? "info.circle.fill" : "xmark.circle.fill"))
                .font(.system(size: 15))
                .foregroundColor(ok ? SCToken.Palette.ok
                                    : (warnWhenFalse ? SCToken.Palette.warn : SCToken.Palette.bad))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(SCToken.Text.rowSubtitle)
                Text(detail)
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - M0 机制探针
    //
    // 图片/文件同步的三个机制风险点，真机各跑一遍；
    // 过了再去设置里打开「图片同步」。

    private var probeCard: some View {
        SCCard("机制探针（M0）", footnote: "P1/P2 的结果自动回来；P3 要去文件 App 里粘一下才算数。"
               + "跑完把结果页截图或抄回来。") {
            VStack(alignment: .leading, spacing: SCToken.Space.xs) {
                HStack {
                    Text("P1 · 后台读图（图片同步的地基）")
                        .font(SCToken.Text.rowTitle)
                    Spacer()
                    Button(model.probeP1Armed ? "解除" : "布防") {
                        model.probeP1Armed ? model.disarmP1() : model.armP1()
                    }
                    .font(SCToken.Text.caption)
                    .buttonStyle(.bordered)
                }
                if model.probeP1Armed {
                    HStack(spacing: SCToken.Space.s) {
                        Circle().fill(SCToken.Palette.warn).frame(width: 8, height: 8)
                        Text("布防中 —— 等待剪贴板变化")
                            .font(SCToken.Text.caption)
                            .foregroundColor(SCToken.Palette.secondaryLabel)
                    }
                }
                ForEach(model.probeP1Lines, id: \.self) { line in
                    probeLine(line)
                }
            }

            SCCardDivider()

            VStack(alignment: .leading, spacing: SCToken.Space.xs) {
                HStack {
                    Text("P2 · 读文件 App 拷贝的文件")
                        .font(SCToken.Text.rowTitle)
                    Spacer()
                    Button("读取") {
                        Task { await model.runP2() }
                    }
                    .font(SCToken.Text.caption)
                    .buttonStyle(.bordered)
                }
                Text("先去文件 App 长按任一文件 → 拷贝，再回这里点「读取」")
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.tertiaryLabel)
                if let lines = model.probeP2Lines {
                    ForEach(lines, id: \.self) { line in
                        probeLine(line)
                    }
                }
            }

            SCCardDivider()

            VStack(alignment: .leading, spacing: SCToken.Space.xs) {
                HStack {
                    Text("P3 · 写文件引用进剪贴板")
                        .font(SCToken.Text.rowTitle)
                    Spacer()
                    Button("写入") {
                        model.runP3()
                    }
                    .font(SCToken.Text.caption)
                    .buttonStyle(.bordered)
                }
                if let lines = model.probeP3Lines {
                    ForEach(lines, id: \.self) { line in
                        probeLine(line)
                    }
                }
            }
        }
    }

    private func probeLine(_ line: String) -> some View {
        Text(line)
            .font(SCToken.Text.monoSmall)
            .foregroundColor(line.hasPrefix("✅") ? SCToken.Palette.ok
                 : (line.hasPrefix("❌") ? SCToken.Palette.bad
                 : (line.hasPrefix("⚠️") || line.hasPrefix("⏱") ? SCToken.Palette.warn
                 : SCToken.Palette.secondaryLabel)))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - P4 扩展安装状态

    private var extensionCard: some View {
        SCCard("P4 · 分享/键盘扩展",
               footnote: "扩展是打进 ipa 的 PlugIns 目录随包安装的，装没装以这里列出的为准。") {
            if appexEntries.isEmpty {
                HStack(alignment: .top, spacing: SCToken.Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(SCToken.Palette.warn)
                    Text("没发现任何扩展 —— 需要用包含扩展的完整 ipa 重装；精简包/单独装主 App 不会有。")
                        .font(SCToken.Text.caption)
                        .foregroundColor(SCToken.Palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(appexEntries, id: \.self) { name in
                    HStack(spacing: SCToken.Space.m) {
                        Image(systemName: "puzzlepiece.fill")
                            .font(.system(size: 13))
                            .foregroundColor(SCToken.Palette.ok)
                        Text(name)
                            .font(SCToken.Text.rowSubtitle)
                            .foregroundColor(SCToken.Palette.label)
                        Spacer(minLength: SCToken.Space.s)
                        SCPill(text: "已安装", color: SCToken.Palette.ok, compact: true)
                    }
                }
            }

            SCCardDivider()

            VStack(alignment: .leading, spacing: SCToken.Space.xs) {
                Text("怎么验证能用")
                    .font(SCToken.Text.rowSubtitle)
                    .foregroundColor(SCToken.Palette.label)
                Text("分享：去任意 App 分享一张图，分享面板里选「剪贴板同步」")
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.secondaryLabel)
                Text("键盘：设置 → 通用 → 键盘 → 键盘 → 添加新键盘")
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.secondaryLabel)
            }
        }
    }

    // MARK: - K1/K3 键盘存活

    private var keyboardCard: some View {
        SCCard("K1/K3 · 键盘存活",
               footnote: "键盘扩展每次被系统拉起都往 App Group 写一行心跳，"
               + "这里就是原始记录 —— 没记录 = 键盘从没被拉起过；"
               + "相邻两行的时间差就是 K3 要量的「切走后还活多久」。") {
            if !AppGroupStore.isAvailable {
                Text("App Group 不可用：键盘读不到主 App 写的任何数据（K1 未过，或安装时没带上权限组）。"
                     + "主 App 的同步不受影响。")
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            } else if keyboardLog.isEmpty {
                Text("还没有心跳记录。先按上面 P4 的指引把键盘加进来，再去任意输入框切出键盘。")
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: SCToken.Space.xs) {
                    Text("最近 \(keyboardLog.count) 条")
                        .font(SCToken.Text.caption)
                        .foregroundColor(SCToken.Palette.secondaryLabel)
                    ForEach(keyboardLog, id: \.self) { line in
                        probeLine(line)
                    }
                }
            }
        }
    }

    private func refreshExtensionCards() {
        // appex 列表直接读主包 PlugIns 目录；键盘日志从 App Group 读，
        // App Group 不可用时留空 —— 两张卡各自有空态文案，不在这里报错
        if let plugins = Bundle.main.builtInPlugInsURL,
           let contents = try? FileManager.default.contentsOfDirectory(
               at: plugins, includingPropertiesForKeys: nil) {
            appexEntries = contents.map(\.lastPathComponent).sorted()
        } else {
            appexEntries = []
        }
        keyboardLog = AppGroupStore.isAvailable ? AppGroupStore.readKeyboardLog(30) : []
    }

    // MARK: - 后台保活

    private var keepAliveCard: some View {
        let danger = model.maxTickGap > 30
        return SCCard("后台保活实测", footnote: "验法：开着 App 回桌面，去别的 App 待 5 分钟再回来。"
                      + "最长间隔只有几秒说明后台一直在跑；是几分钟就是被挂起了。") {
            SCKeyValue(key: "轮询次数", value: "\(model.tickCount)")
            SCKeyValue(key: "上次轮询",
                       value: model.lastTickAt.map { HomeView.relative($0) } ?? "-")
            SCKeyValue(key: "最长间隔",
                       value: String(format: "%.1f 秒", model.maxTickGap),
                       mono: true,
                       tint: model.maxTickGap == 0
                            ? SCToken.Palette.secondaryLabel
                            : (danger ? SCToken.Palette.warn : SCToken.Palette.ok))
            SCKeyValue(key: "保活状态",
                       value: model.keeperHealth,
                       tint: model.keeperRestartCount == 0 ? SCToken.Palette.ok : SCToken.Palette.warn)
            if model.keeperRestartCount > 0 {
                Text("自愈过 \(model.keeperRestartCount) 次。偶发几次正常（来电、切耳机都会弄断会话），"
                     + "但如果这个数字一直在涨，说明这里的会话很不稳，去看日志里那条“后台保活自愈”。")
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let at = model.bgRefreshScheduledAt {
                SCKeyValue(key: "兜底唤醒", value: "已排期（\(HomeView.relative(at))）")
            }
            if danger, let at = model.maxTickGapAt {
                Text("最长间隔出现在 \(HomeView.relative(at))。超过 30 秒说明那段时间进程被系统挂起，"
                     + "后台保活没生效。")
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 剪贴板

    // MARK: - 实时推送

    private var pushCard: some View {
        let connected = d.pushState == "已连接"
        let unsupported = d.pushState == "此服务器类型不支持"
        let tint = connected ? SCToken.Palette.ok
                 : (unsupported ? SCToken.Palette.idle : SCToken.Palette.warn)
        return SCCard("实时推送", footnote: "服务器本来就带推送通道：谁改了剪贴板，"
                      + "服务端就把新内容直接推给在线的客户端。"
                      + "通了的话 PC 上一复制，手机上几乎是立刻就变。") {
            HStack(spacing: SCToken.Space.s) {
                Circle().fill(tint).frame(width: 9, height: 9)
                Text(d.pushState.isEmpty ? "还没测过" : d.pushState)
                    .font(SCToken.Text.rowTitle)
                    .foregroundColor(tint)
            }
            if !d.pushHub.isEmpty {
                SCKeyValue(key: "地址", value: d.pushHub, mono: true)
            }
            SCKeyValue(key: "连接成功次数", value: "\(d.pushConnectCount)", mono: true)
            SCKeyValue(key: "收到推送次数", value: "\(d.pushProfileCount)", mono: true)
            if let at = d.pushLastEventAt {
                SCKeyValue(key: "上次收到", value: HomeView.relative(at))
            }
            if let why = d.pushLastDisconnect, !why.isEmpty {
                Text("上次断开：\(why)")
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if d.pollIntervalEffective > 0 {
                SCKeyValue(key: "实际轮询间隔",
                           value: String(format: "%.1f 秒（推送连着时会退到 30 秒）", d.pollIntervalEffective),
                           mono: true)
            }
            if !connected && !unsupported {
                Text("没连上也不影响同步 —— 轮询照样在跑，只是没做到「秒级」。")
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pasteboardCard: some View {
        SCCard("剪贴板实测") {
            SCKeyValue(key: "changeCount", value: "\(d.pasteboardChangeCount)", mono: true)
            SCKeyValue(key: "读取耗时", value: String(format: "%.2f ms", d.readMillis), mono: true)
            SCKeyValue(key: "类型",
                       value: d.pasteboardTypes.isEmpty ? "（空）"
                            : d.pasteboardTypes.joined(separator: ", "),
                       mono: true)

            if !d.pasteboardItems.isEmpty {
                SCCardDivider()
                VStack(alignment: .leading, spacing: SCToken.Space.xs) {
                    Text("逐 UTI 字节数（拷贝来源不同，形态不同 —— P0 现场记录）")
                        .font(SCToken.Text.caption)
                        .foregroundColor(SCToken.Palette.secondaryLabel)
                    ForEach(Array(d.pasteboardItems.enumerated()), id: \.offset) { _, item in
                        Text("\(item.uti) · \(item.bytes >= 0 ? "\(item.bytes) 字节" : "非字节值")")
                            .font(SCToken.Text.monoSmall)
                            .foregroundColor(SCToken.Palette.secondaryLabel)
                            .textSelection(.enabled)
                    }
                }
            }

            SCCardDivider()

            VStack(alignment: .leading, spacing: SCToken.Space.xs) {
                Text("文本内容")
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.secondaryLabel)
                SCPreview(text: d.pasteboardText ?? "",
                          placeholder: "（读不到文本）",
                          lineLimit: 8)
            }
        }
    }

    // MARK: - 端点

    private var endpointCard: some View {
        SCCard("当前端点") {
            if let profile = model.settings.activeServer {
                HStack(spacing: SCToken.Space.m) {
                    SCTypeBadge(type: profile.type, large: true)
                    Text(profile.displayTitle)
                        .font(SCToken.Text.rowSubtitle)
                }
                if !d.endpointDescription.isEmpty {
                    Text(d.endpointDescription)
                        .font(SCToken.Text.monoSmall)
                        .foregroundColor(SCToken.Palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                SCCardDivider()
                SCKeyValue(key: "状态", value: model.connection.label,
                           tint: model.connection.isBad ? SCToken.Palette.bad
                               : (model.connection.isOK ? SCToken.Palette.ok
                                  : SCToken.Palette.secondaryLabel))
                SCKeyValue(key: "详情", value: model.connection.detail)
            } else {
                Text("还没配置服务器")
                    .font(SCToken.Text.rowSubtitle)
                    .foregroundColor(SCToken.Palette.secondaryLabel)
            }
        }
    }

    // MARK: - 日志

    private var logCard: some View {
        SCCard("日志", footnote: d.binaryPath.isEmpty ? nil : d.binaryPath) {
            if model.logs.isEmpty {
                Text("（暂无日志）")
                    .font(SCToken.Text.caption)
                    .foregroundColor(SCToken.Palette.tertiaryLabel)
            } else {
                let shown = Array(model.logs.suffix(60))
                VStack(alignment: .leading, spacing: SCToken.Space.s) {
                    Text("最近 \(shown.count) 条 / 共 \(model.logs.count) 条")
                        .font(SCToken.Text.caption)
                        .foregroundColor(SCToken.Palette.secondaryLabel)
                    ForEach(shown) { entry in
                        HStack(alignment: .top, spacing: SCToken.Space.s) {
                            Text(Self.timeFormatter.string(from: entry.time))
                                .font(SCToken.Text.monoSmall)
                                .foregroundColor(SCToken.Palette.tertiaryLabel)
                            Text(entry.text)
                                .font(SCToken.Text.monoSmall)
                                .foregroundColor(SCToken.Palette.secondaryLabel)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 工具

    private func runDiagnostics() async {
        busy = true
        await model.runDiagnostics()
        busy = false
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
