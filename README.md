# syncclip — SyncClipboard 的 iOS 客户端

把 iPhone 剪贴板接到自建 [SyncClipboard](https://github.com/Jeric-X/SyncClipboard) 服务器上，
干掉「用快捷指令每次手动点一下」。**装一次，之后全自动双向同步。**

| | |
|---|---|
| 目标设备 | iPhone / iOS 15.5 / **已装 TrollStore（无越狱）** |
| 目标服务器 | 自建 SyncClipboard.Server（Docker） |
| 安装方式 | CI 打出未签名 `.ipa` → TrollStore 打开安装 |
| 当前版本 | 文本双向同步（图片/文件暂不支持，会安全跳过） |

---

## 一、为什么是「TrollStore App」这个形态

三条硬约束决定了唯一可行的做法：

**1. 无提示读写剪贴板，只能靠私有 entitlement。**
iOS 14 起读 `UIPasteboard` 会弹「允许粘贴」，公开 API 没有开关。系统对特定角色放行，
需要这四条（取自上游 [owngoal-dev/icli](https://github.com/owngoal-dev/icli) 的签名清单，
`com.apple.Pasteboard.background-access` 的官方描述就是 "Clipboard access without a foreground app"）：

```
com.apple.private.webkit.pasteboard
com.apple.private.pasteboard.check-pasteboard
com.apple.Pasteboard.background-access
com.apple.Pasteboard.paste-unchecked
```

**TrollStore 的核心能力正是「IPA 里可以塞任意 entitlement，系统照常按授权执行」**，
所以不越狱也能拿到这一组。它只对 3 个在 iOS 15/A12+ 被禁的 entitlement 报错
（`cs.debugger`、`dynamic-codesigning`、`skip-library-validation`），这批不在其中。

**2. 常驻只能靠「后台音频」。**
TrollStore 明确做不到 spawn launch daemon（那需要 `CS_PLATFORMIZED`），也不能往系统进程注入 tweak。
所以没有「重启也在」的守护进程可选，只能：声明 `UIBackgroundModes=audio`
+ 持续播放一段**听不见但非全零**的音频，让进程不被系统挂起。
（用纯数字静音会被部分系统版本判定成没在播放而照样挂起，所以波形取 16bit 的最低有效位。）

**3. 变更检测靠轮询 + 通知双保险。**
不能 hook SpringBoard，拿不到即时事件，所以以 `UIPasteboard.changeCount` 轮询为主
（默认 2 秒），`UIPasteboard.changedNotification` 能收到就提前唤醒一轮。

---

## 二、工程结构

```
Sources/SyncClipCore/        同步核心。与常驻方式解耦，App 与守护进程共用同一份
  SCAppSettings.swift        App 设置（JSON 落盘）+ 转换/校验成引擎配置
  SCConfig.swift             引擎侧的配置（plist 来源，守护进程用）
  SCClient.swift             WebDAV 兼容 API 客户端（4 条路径 + Basic Auth）
  SCProfile.swift            SyncClipboard.json 模型 + hash 算法
  SCPasteboard.swift         剪贴板读写
  SCSyncEngine.swift         双向同步状态机（变更判定、冲突仲裁、附件解析）
  SCDarwinNotify.swift       Darwin 通知订阅
  SCEntitlementInspector.swift  从自己的 Mach-O 签名段里读 entitlement（诊断页用）
  SCInAppLog.swift           环形日志缓冲，挂到 SCLog.sink 上给界面用
  SCLog.swift                os_log + stderr + UI 三路日志

Sources/SyncClipApp/         iOS App（TrollStore 安装）
  SyncClipboardApp.swift     @main + RootView（三个 Tab）+ 复用组件
  AppModel.swift             中枢：设置、同步循环、保活、诊断
  BackgroundKeeper.swift     静音音频保活
  HomeView.swift             状态 / 操作 / 预览 / 统计
  SettingsView.swift         服务器配置
  DiagnosticsView.swift      entitlement 自检 / 剪贴板实测 / 日志

Config/
  Info.plist                 含 UIBackgroundModes=audio、URL scheme、图标声明
  SyncClipboard.entitlements 四条剪贴板 entitlement（刻意的最小集）

Sources/syncclipd/           越狱守护进程（当前用不上，保留）
layout/                      守护进程的 LaunchAgent plist + entitlements

scripts/
  build-app.sh               构建 + ldid 签名 + 打 ipa + 验包
  build.sh                   同上，但产出越狱用的 .deb
  lint-swift.js              源码体检（无 Swift 工具链的机器也能跑）
  make-icons.js              生成 PNG 图标（自带 PNG 编码器 + ASCII 预览）
  make-ipa.js                打 ipa（自带 zip 写入器，零外部依赖）
  verify-ipa.js              验包：结构 + Info.plist + **从 Mach-O 读 entitlement**
  make-deb.js / verify-deb.js  守护进程那条路的打包与校验
  selftest-pipeline.js       打包/验包流水线自测（正例过、反例必须被拦下）
```

---

## 三、构建

### 有 Mac

```bash
brew install libplist          # ldid 的依赖
bash scripts/build-app.sh      # 产出 dist/SyncClipboard_1.0.0.ipa
```

### 没有 Mac（推 GitHub）

Actions 会自动跑三件事：纯 node 的静态校验 → 构建 `.ipa`（arm64 + arm64e 两份）→
构建越狱 `.deb`（备着）。打 `v*` tag 会直接发 Release。
产物在对应 workflow run 的 Artifacts 里下载。

### 本机（Windows/Linux，没有 Swift 工具链）能跑的部分

```bash
node scripts/lint-swift.js             # 源码体检
node scripts/make-icons.js --preview   # 在终端里看图标长什么样
node scripts/selftest-pipeline.js      # 验证打包/验包链路本身是对的
```

这几条已经在 Windows 上实测跑通。它们抓出过的真实缺陷：`DEBIAN/` 混进 `data.tar.gz`、
二进制权限位不是 `0755`、`async` 函数带 `inout` 参数、`switch` 多个 case 重名变量、
SDF 三角形符号写反、zip 的 external attributes 32 位溢出。

---

## 四、安装与配置

1. 把 `SyncClipboard_1.0.0.ipa` 传到 iPhone，用 **TrollStore** 打开安装。
2. 打开 App → **诊断** 页 → 点右上角「重新诊断」。
   确认第一行是绿色的「剪贴板权限就位」。这是整个方案的地基，**先确认这一步再往下走**。
3. 去 **设置** 页填服务器：
   - 地址：`http://192.168.1.10:5033`（要带 http:// 前缀，端口别漏）
   - 用户名 / 密码：SyncClipboard.Server 的账号
   - 轮询间隔：默认 2 秒
   - 点「保存并应用」
4. 回 **同步** 页，点「立即同步」看有没有正常拉/推。

配置文件在 App 容器的 `Documents/syncclip-config.json`，可以用 Filza 直接改。

### 三个页面

- **同步**：连接状态、立即同步 / 推送剪贴板 / 拉取远端、本地与远端内容预览、推送/拉取/失败计数。
- **设置**：服务器地址账号、轮询间隔、启动对齐策略、后台保活开关、详细日志开关。
- **诊断**：二进制里实际签到的 entitlement 列表、剪贴板实测（changeCount / 类型 / 内容 / 读取耗时）、实时日志。

### URL scheme（备用触发方式）

```
syncclip://sync    立即同步
syncclip://push    把当前剪贴板推到服务器
syncclip://pull    把远端内容拉到剪贴板
```

配合 `设置 → 辅助功能 → 触控 → 轻点背面 → 轻点两下 → 快捷指令 → 打开 URL`，
得到一个不打开 App 就能同步的物理手势。这是后台保活万一被系统掐掉时的兜底。

---

## 五、已知限制

| 限制 | 说明 | 后备方案 |
|---|---|---|
| 后台保活靠音频会话 | 费电；App 被系统强杀后要重新打开一次才会继续 | 轻点背面触发 URL scheme |
| 只同步文本 | `Image`/`File`/`Group` 类型会**安全跳过**（不会用空内容覆盖剪贴板） | 后续版本 |
| 轮询不是瞬时 | 默认 2 秒延迟 | 改小 `pollInterval` |
| 网络断开期间不推送 | 断开时不写状态，恢复后本地改动仍会推上去（不会静默丢） | — |

跳过逻辑是刻意写死的：如果剪贴板里是图片（`hasStrings == false` 但 `types` 非空），
或者远端 profile 不是文本，同步引擎**什么都不做**。宁可不同步，也不能把内容弄丢。

---

## 六、越狱路线（保留）

如果哪天越狱了，`Sources/syncclipd/` + `scripts/build.sh` + `layout/` 是一条完整的
launchd 常驻守护进程路线：同步核心是同一份代码，改成系统级服务后不依赖 App 存活，
也不用靠音频保活。装成 **LaunchAgent 而不是 LaunchDaemon**——因为 `pasteboardd` 是每用户的
launchd 服务，系统域的 root 进程连不上它。

详见 [`docs/research.md`](docs/research.md) 与 [`docs/verification.md`](docs/verification.md)。
