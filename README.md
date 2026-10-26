# syncclip — SyncClipboard 的 iOS 客户端

把 iPhone 剪贴板接到自建 [SyncClipboard](https://github.com/Jeric-X/SyncClipboard) 服务器上，
干掉「用快捷指令每次手动点一下」。**装一次，之后全自动双向同步。**

| | |
|---|---|
| 目标设备 | iPhone / iOS 15.5 / **已装 TrollStore（无越狱）** |
| 服务器 | **SyncClipboard 服务器 / WebDAV / S3 兼容存储**，可同时存多台、随时切换 |
| 安装方式 | CI 打出未签名 `.ipa` → TrollStore 打开安装 |
| 当前版本 | 文本双向同步（图片/文件暂不支持，会安全跳过） |

---

## 一、支持哪三种后端

三种类型**用的是同一套对象布局**（`SyncClipboard.json` + `file/`），所以协议层完全复用，
只在传输层分叉 —— 这也是上游桌面端与 [syncclipboard-xposed](https://github.com/shaklow/syncclipboard-xposed)
的做法。

| 类型 | 需要一个 | 寻址 | 连接测试 |
|---|---|---|---|
| **SyncClipboard 服务器** | 自建 SyncClipboard.Server，或桌面客户端里开的内置服务器 | `{base}/SyncClipboard.json`、`{base}/file/{name}` | `GET /api/version` |
| **WebDAV** | 任何标准 WebDAV 空间（坚果云 / Nextcloud / 群晖 / 自建） | 同上 | `PROPFIND Depth:1`；写文件前 `MKCOL file/`（405 = 已存在） |
| **S3 兼容存储** | AWS S3 / MinIO / Cloudflare R2 / 阿里云 OSS 等 | `{prefix}/SyncClipboard.json`、`{prefix}/file/{name}` | `ListObjectsV2`（`max-keys=1`） |

S3 那一档自己实现了 **AWS Signature V4**（`UNSIGNED-PAYLOAD`，与上游一致，大文件不必二次读取）。
自定义端点默认走路径风格寻址（MinIO、R2 只认这个），AWS 官方端点走虚拟主机风格。

**服务器列表**：可以存任意多台、类型混着来，左滑删除 / 设为当前使用，或直接点一行编辑。
切换服务器会重建同步引擎 —— 旧引擎的「上次看到的远端 hash」属于另一台服务器，
带过去会让第一次比对就出错。

---

## 二、为什么是「TrollStore App」这个形态

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

**2. 常驻：音频只是当前实现，不是唯一选项 —— NE 探针已经在做。**
TrollStore 明确做不到 spawn launch daemon（那需要 `CS_PLATFORMIZED`）、不能往系统进程注入 tweak，
`posix_spawn` 出来的子进程还会跟着 App 一起被回收。但有一条例外：

> **Network Extension（VPN 隧道 appex）由 `nesessionmanager` 托管，不受 App 挂起管辖，
> App 被杀也不退出，还能开机自启。**

也就是说，非越狱设备上它已经是「守护进程」能做到的全部。它靠 `com.apple.developer.networking.networkextension`
授权 —— 免费证书拿不到（Apple capability 表里免费列为空），但 **TrollStore 伪造签名可以**
（TrollStore README 的「arbitrary entitlements」+「Signs all MachO files」；实证见 EasyTier 官方
credential-free 的 TrollStore nightly IPA、CB Pro Proxy 文档）。

两条还没人验过、而决定整个架构的东西，所以先做了 `Sources/PasteProbe*` 这个探针去问：
**伪造签名的 NE entitlement 到运行时还算不算数？隧道进程能不能读写剪贴板？**
结果决定最终形态 —— 见 [`docs/probe.md`](docs/probe.md)。

当前的保活实现是音频（`UIBackgroundModes=audio` + 一段听不见但非全零的音频）。
它的真实上限与全部备选写在 [`docs/keepalive.md`](docs/keepalive.md)：
**音频会被系统大约 3 小时后静默节流**（“quietly throttles the process until the audio queue starves”），
所以它只是 Tier 1，不是地基。

**3. 变更检测靠轮询 + 通知双保险。**
不能 hook SpringBoard，拿不到即时事件，所以以 `UIPasteboard.changeCount` 轮询为主
（默认 2 秒），`UIPasteboard.changedNotification` 能收到就提前唤醒一轮。

---

## 三、界面

四个页签。大幅借鉴了 base-ui 的「原语 + 组合」和 tdesign 的 token 化思路，
但落到 iOS 15 原生的语义色上，于是深色模式、增强对比度都由系统处理。

- **同步** —— 状态卡（渐变色随连接状态走，带呼吸点）；一张「本机 → 服务器」**方向示意图**
  直接告诉你上一次数据往哪走了；三个操作按钮；两端内容预览（可一键复制）；本次运行统计。
- **服务器** —— 列表带类型徽章与逐台连接状态，左滑删除 / 切为当前使用；
  表单里可随时换后端类型，换类型**保留**已填的公共字段。
- **设置** —— 同步开关、轮询间隔、启动对齐策略、**冲突解决策略**（最新 / 本地 / 远端）、后台保活、日志。
- **诊断** —— 地基地基（entitlement 自检）+ 算法自检 + 后台保活实测 + 剪贴板实测 + 当前端点 + 实时日志。

### 诊断页里两个不需要联网、不需要凭据的自检

这两项是刻意做的 —— 同步出问题时，最难判断的就是「是算法错了、是权限没有、还是网络不通」。
把前两个变成本地可验证的，排查范围立刻就小了：

- **SigV4 签名**：拿 AWS 官方测试向量跑一遍签名密钥派生。算错的话在用 S3 之前就看得见。
  而那个测试向量本身又由 CI 用 node 的 crypto 独立校对（见 `scripts/selftest-pipeline.js`）——
  形成「CI 验向量 → 向量验 Swift 实现」的完整链。
- **后台保活**：记录轮询节拍与**最长间隔**。App 真被系统挂起的话，这个值会是分钟级而不是几秒。
  把「我觉得它在跑」变成一个能读的数字。

---

## 四、工程结构

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

Sources/PasteProbeShared/    NE 探针：宿主 App 与隧道进程共用（常量 + 跨进程日志）
Sources/PasteProbe/          NE 探针：宿主 App（流程控制 + 日志界面）
Sources/PasteProbeTunnel/    NE 探针：NEPacketTunnelProvider（什么都不转发，只验机制）
Config/PasteProbe*.plist     探针的两份 Info.plist（appex 那份带 NSExtension 段）
Config/PasteProbe*.entitlements  探针的两组 entitlement（networkextension + app group + 剪贴板）
docs/probe.md                探针的使用说明与结果解读

scripts/
  build-app.sh               构建 + ldid 签名 + 打 ipa + 验包
  build-probe.sh             同上，但产出 NE 探针包（含 appex 入口点与双重 entitlement 校验）
  build.sh                   同上，但产出越狱用的 .deb
  lint-swift.js              源码体检（无 Swift 工具链的机器也能跑）
  make-icons.js              生成 PNG 图标（自带 PNG 编码器 + ASCII 预览）
  make-ipa.js                打 ipa（自带 zip 写入器，零外部依赖）
  verify-ipa.js              验包：结构 + Info.plist + **从 Mach-O 读 entitlement**
  make-deb.js / verify-deb.js  守护进程那条路的打包与校验
  selftest-pipeline.js       打包/验包流水线自测（正例过、反例必须被拦下）
```

---

## 五、构建

### 有 Mac

```bash
brew install libplist          # ldid 的依赖
bash scripts/build-app.sh      # 产出 dist/SyncClipboard_1.0.0.ipa
```

### 没有 Mac（推 GitHub）

Actions 会自动跑：纯 node 静态校验 → 工具链冒烟测试 → 构建 `.ipa`（arm64 + arm64e）
→ 构建 NE 探针 `.ipa`（arm64 + arm64e）→ 构建越狱 `.deb`（备着）→ 如果是 tag 就发 Release。

当前状态：**全绿**。三个 job 的分工是刻意的——
`selftest`（几秒）抳代码结构问题，`toolchain`（十几秒）抳环境问题
（SwiftPM 能不能交叉编译到 iOS、ldid 能不能写 entitlement 并读回），
两个都绿了才开始真正构建 App。这样“环境不对”和“代码写错”不会混成一个含糊的失败。

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

## 六、安装与配置

### 直接下载

最新 ipa 在 Releases 里：**https://github.com/luckxine/syncclip-ios/releases/latest**

- `SyncClipboard_1.1.0_arm64.ipa` —— 用这个（arm64 在 arm64e 机型上也能跑）
- `SyncClipboard_1.1.0_arm64e.ipa` —— 备用

1. 把 ipa 传到 iPhone（AirDrop / 自建网盘 / iCloud 都行），**用 TrollStore 打开安装**。
2. 打开 App → **诊断** 页 → 右上角 … → 「重新诊断」。
   确认第一行是绿色的「剪贴板权限就位」。这是整个方案的地基，**先确认这一步再往下走**。
3. 去 **服务器** 页 → 右上角 `+` → 选后端类型 → 填字段 → 「测试连接」→ 保存。
4. 回 **同步** 页，点「立即同步」看有没有正常拉/推。

配置文件在 App 容器的 `Documents/syncclip-config.json`，可以用 Filza 直接改。

#### 各类型填什么

| 类型 | 地址 | 账号 | 其他 |
|---|---|---|---|
| SyncClipboard | `http://192.168.1.10:5033`（带前缀和端口） | 服务器账号 | — |
| WebDAV | `https://dav.jianguoyun.com/dav/我的同步目录`（要指到具体目录） | WebDAV 账号 | — |
| S3 | 留空用 AWS 默认端点；自建填 `https://minio.example.com` | Access Key ID | 区域、存储桶、对象前缀 |

### 自己构建

见上面第五节。

### 服务器页怎么用

- 点右上角 `+` 新增。先选后端类型，再填字段；换类型会保留已填的地址和账号。
- 点任意一行编辑；左滑可以删除，或把不常用的那台「设为当前使用」。
- 保存后如果它是当前使用的服务器，会自动测试一次连接。
- S3 编辑页里多一个 **SigV4 自检**，它不联网、不需要凭据，填之前就能确认签名算法是对。

### URL scheme（备用触发方式）

```
syncclip://sync    立即同步
syncclip://push    把当前剪贴板推到服务器
syncclip://pull    把远端内容拉到剪贴板
```

配合 `设置 → 辅助功能 → 触控 → 轻点背面 → 轻点两下 → 快捷指令 → 打开 URL`，
得到一个不打开 App 就能同步的物理手势。这是后台保活万一被系统掐掉时的兜底。

---

## 七、已知限制

| 限制 | 说明 | 后备方案 |
|---|---|---|
| 后台保活靠音频会话 | **会被系统大约 3 小时后静默节流**；App 被强杀后要重新打开一次才会继续。全部备选手段见 [`docs/keepalive.md`](docs/keepalive.md)，正在验的 NE 路线见 [`docs/probe.md`](docs/probe.md) | 轻点背面触发 URL scheme；或等 NE 探针结论 |
| 图片/文件类型需手动开启 | 图片同步默认关（先跑诊断页 M0 探针）；`File`/`Group` 尚未实现，会明确跳过 | M2/M3（见「七点五」） |
| 轮询不是瞬时 | 默认 2 秒延迟 | 改小 `pollInterval` |
| 网络断开期间不推送 | 断开时不写状态，恢复后本地改动仍会推上去（不会静默丢） | — |

跳过逻辑是刻意写死的：如果剪贴板里是图片（`hasStrings == false` 但 `types` 非空）,
或者远端 profile 不是文本，同步引擎**什么都不做**。宁可不同步，也不能把内容弄丢。

---

## 七点五、v2：全类型同步（进行中，2026-10 起）

v1 的「只同步文本」是三处刻意跳过（引擎首轮、拉取分派、推送构造），协议层什么都不缺。
v2 把它泛化为全类型，分阶段落地，设计全稿见 `D:/poxian/syncclip-ios-redesign.md`（M0-M6）。

**已落地（v1.3.0，M0 + M1）：**

- **引擎泛化**（`SCSyncEngine`）：本地分类 文本→图片→文件引用，changeCount 门控
  （剪贴板没变就不重读/重哈希）；digest 前缀 `T:`/`I:` 区分类型；文本路径行为与 v1 一致
- **图片双向同步**（默认关，设置里开）：推送 原字节直传（PNG/JPEG/GIF 保真、GIF 保动图），
  HEIC 转 JPEG 0.85 对齐上游；拉取 sniff 真实格式后 `setData` 原始字节进剪贴板，不走 UIImage；
  单张上限默认 15MB（103 frp 隧道实测 21MB 必断，修复前安全值），超限明确跳过+通知
- **M0 机制探针**（诊断页）：P1 后台读图（挂在同步循环上测生产路径）、
  P2 读文件 App 拷贝（iOS 15 无 `itemProviders`，三级兑底：file-url+NSFileCoordinator →
  file-url 直接读 → iOS16+ itemProviders，哪级通用 via 字段回传）、P3 写 file-url 引用；
  另有逐 UTI 字节数 dump（P0）
- **本地通知**：provisional 授权（不弹窗、静默进通知中心），后台拉到图片/超限跳过可见
- **手动物理按钮泛化**：推送/拉取按钮对图片同样生效

**待做：** M2 单文件+收件箱 → M3 Group(zip) → M4 分享菜单（依赖 TrollStore appex 探针 P4）→
M5 键盘取用面板（双模式）→ M6 历史记录。frp 服务器端修复（frpc poolCount=10）待执行。

---

## 八、越狱路线（保留）

如果哪天越狱了，`Sources/syncclipd/` + `scripts/build.sh` + `layout/` 是一条完整的
launchd 常驻守护进程路线：同步核心是同一份代码，改成系统级服务后不依赖 App 存活，
也不用靠音频保活。装成 **LaunchAgent 而不是 LaunchDaemon**——因为 `pasteboardd` 是每用户的
launchd 服务，系统域的 root 进程连不上它。

详见 [`docs/research.md`](docs/research.md) 与 [`docs/verification.md`](docs/verification.md)。
