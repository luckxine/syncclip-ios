# NE 探针：非越狱设备上，网络扩展到底能不能用

这份文档对应 `scripts/build-probe.sh` 产出的 `PasteProbe_<版本>_<arch>.ipa`。

它不是要用的 App，是一个**问问题**的工具。问题都在公开资料里查不到确定答案 ——
只能在你的机器上跑一遍。每个问题对应界面上的一个按钮。

---

## 一、v1 已经测到的东西（2026-10-15）

v1 只验了「echo 往返」这一条，结果如下。这是整个方案的**地基**，它成了：

| 问题 | 结果 |
|---|---|
| TrollStore 伪造签名带进来的 `com.apple.developer.networking.networkextension`，**到运行时还算不算数**？ | ✅ **算。** `saveToPreferences` 成功，系统弹出并接受了 VPN 配置授权 |
| 隧道进程能不能真的跑起来？ | ✅ 能。`startVPNTunnel` 后 `connection.status → connected`，appex 进程开始打心跳 |
| **隧道进程能不能读写剪贴板？** | ✅ **都能。** 读到 App 写进去的 nonce 并回写了 echo |

实证日志：

```
[02:26:00] tunnel/startTunnel: 被拉起，options=AuthMethod,ServerAddress,echoPasteboard
[02:26:00] tunnel/tunnelUp: 网络设置已生效，隧道进程开始跑
[02:26:00] tunnel/pasteboard.read: [startTunnel/后台线程] changeCount=1696 长度=22 前缀=PasteProbe-TX-15872523
[02:26:00] tunnel/pasteboard.echo: [startTunnel/后台线程] 读到了 App 的 nonce 并已回写 echo=[PasteProbe-ECHO] 15872523
[02:26:05] tunnel/heartbeat: 第 1 次心跳，隧道进程还活着
```

顺带测出一条**必须写进真实现的设计约束**：

> **隧道进程的主队列不会被排空。**
> v1 从 `DispatchQueue.main` 派了两个任务（一个只记日志、一个读剪贴板），
> 一个都没执行；同一时刻派到后台队列的那份正常跑完。
> 所以 appex 里**所有活儿都必须放后台队列**，别用 `DispatchQueue.main`，
> 也别依赖主 RunLoop（`Timer`、`RunLoop.main.run()` 之类）。
> v2 加了更精确的判定，用来区分「主队列没被排空」和「主队列活着但卡在剪贴板那一步」。

### v1 **没有**证明的那件事（v2 补）

v1 是「App 先写 nonce → 隧道读出来」。而**读自己写的内容在 iOS 上永远不弹提示**，
所以它证明不了真实现最需要的那一条：

> **隧道进程读 Safari / 微信 写进去的内容，会不会被拦、会不会弹「允许粘贴」？**

这就是 v2 的**实验②**。它没验之前，整个架构不能算数 —— 因为一个只能读到自己写的
内容的剪贴板同步器是没用的。

---

## 二、装上去

1. 把 `PasteProbe_<版本>_arm64.ipa` 传到手机（TrollStore 里直接打开，或从文件 App 打开）
2. 用 **TrollStore 打开这个 ipa** 安装
3. 桌面上会出现一个叫「NE 探针」的 App

> 用 `arm64` 那份就行，`arm64e` 那份是备用。两份内容一样，只是目标架构不同。

## 三、四个按钮 + 两个手动实验

### ① 运行探针（echo 往返）—— 已通过，可跳过

App 把剪贴板写成 `PasteProbe-TX-<nonce>` → 拉起隧道 → 隧道读到 nonce 后回写成
`[PasteProbe-ECHO] <nonce>` → App 看到 echo 就判定通过。

### ② 只读剪贴板（**v2 的关键实验，不改剪贴板内容**）

这个实验回答「隧道能不能读**别人**写的内容」。步骤：

1. **先切到 Safari（或微信、备忘录），随便复制一段文字**
2. 回到探针 App，点「② 只读剪贴板」
3. **盯着屏幕顶部** —— 如果弹出「允许粘贴」的横幅，那也是结论的一部分，请记下来
4. 点「刷新日志」，看这两行：

```
[..] app/pasteboard.baseline: changeCount=… string=…字 前缀=…
[..] tunnel/pasteboard.snapshot: [startTunnel/只读模式/后台线程] changeCount=… string=…字 types=[…] 前缀=…
```

判读：

| 现象 | 结论 |
|---|---|
| 两行的 `前缀` 都是你刚复制的那段文字 | ✅ **隧道能读别人的剪贴板，且没弹提示** → 架构成立 |
| App 那行拿到了内容，隧道那行是 `string=nil（读不到）` | ⚠️ 只有前台 App 被放行。真实现得改成「隧道只负责常驻和网络，剪贴板读写交给 App」 |
| 两行都是 `nil` | ⚠️ 连前台 App 都被拦。先看 App 那边有没有弹提示 —— 有提示说明 entitlement 没被认 |
| 弹了提示，但你点「允许」后两行都有内容 | ⚠️ 能用但每次都要手点，等于没解决问题 |

> 为什么这个实验必须单独做：`com.apple.Pasteboard.background-access` 的字面意思是
> "Clipboard access without a foreground app"，但它到底是按**进程有没有前台态**判定，
> 还是按**有没有这条 entitlement** 判定，没有公开资料。实测才知道。

### ③ 隧道联网

在输入框里填一个 URL（填你的 SyncClipboard 服务器就行，例如
`http://192.168.1.10:5033/api/version`），点「③ 隧道联网」。
隧道进程会自己 GET 一次，日志里出现：

```
tunnel/fetch.done: HTTP 200，123 字节，8 ms，正文前缀=…
```

验的是「隧道进程能不能自己发请求」。真实现里它要挂着 WebSocket 或轮询服务器，
所以这条不通的话整个「隧道里跑同步」就没意义。

### ④ App↔隧道

点「④ App↔隧道」，走的是官方 IPC：App 侧 `sendProviderMessage`，隧道侧
`handleAppMessage`。隧道会回一个 JSON（含心跳次数、当前线程、最后一次剪贴板快照）。

真实现靠这条通道下发配置、触发立即同步，所以要尽早确认它通。

### ⑤ 手动实验：App 被划掉之后隧道还在不在

前提：先点「② 只读剪贴板」（或 ①）把隧道拉起来，确认状态区是 `connected`。

1. 按 Home 回桌面
2. 从后台卡片里把「NE 探针」**划掉**
3. 等 3 分钟，**重新打开** App → 点「刷新日志」

看心跳的时间戳：如果这 3 分钟里每 5 秒一条还在记，说明**隧道进程没有跟着 App 一起死**。
（探针 App 刻意没有声明任何后台保活模式，所以 App 退到后台几十秒内就会被系统挂起 ——
在这个前提下隧道还在打心跳，结论才干净。）

### ⑥ 手动实验：重启手机后它会不会自己起来

1. 点「开机自启」→ 日志出现 `✅ 已开启 on-demand 自动连接`
2. **重启手机**
3. 重启后**不要打开这个 App**，等 2 分钟，再打开它 → 「刷新日志」

日志里如果有重启时间之后的心跳，说明隧道开机自启了 —— 那就等价于一个
**系统级常驻服务**（纯 TrollStore 环境下原本被认为做不到的事）。

> 注意：`UIBackgroundModes`（音频/位置）那套做不到开机自启，这是 NE 与它们的本质差别。

---

## 四、结果怎么读（这张表就是探针的全部产出）

| 现象 | 结论 | 最终架构 |
|---|---|---|
| ①✅ ②✅ ③✅ ④✅ + ⑤⑥ 通过 | NE 路线完整成立 | **空隧道 + 隧道里挂 SignalR WebSocket + 隧道里读写剪贴板**。不要音频保活、不要轮询。App 只当配置界面（走 ④ 的 IPC 下发设置） |
| ①✅②✅③④ 但 ⑤ 不通过（隧道随 App 死） | 隧道不能当守护进程，但能当「App 挂起期间的替身」 | 隧道里跑同步 + App 侧保留音频保活兜底。App 真被杀掉时同步暂停，重开 App 恢复 |
| `saveToPreferences` 失败（`NEVPNErrorDomain code=5 permission denied`） | 系统不认伪造的 NE entitlement | NE 路线结束，回到「App 内保活」：自愈版静音音频 + `BGTaskScheduler` 兜底复活 + 轮询（见 `docs/keepalive.md`） |
| ② 里隧道读到 `nil` | 隧道碰不到剪贴板 | 隧道只负责常驻 + 挂连接；剪贴板读写留在 App 侧，靠后台唤醒去做 |
| ③ 不通 | 隧道不能联网 | 隧道只能当「让进程活着的壳」，网络请求得由 App 或从外部触发 —— 这条会让方案价值大幅缩水，需要重新设计 |
| ④ 不通 | IPC 不通 | 配置只能靠 App Group 文件 + 隧道侧轮询文件变更来传递（能用，但没那么干净） |
| `connected` 但 App Group 日志一条都没有 | appex 没启动，或日志通道断了 | 按下面第五节逐条排查；这时 ②③④ 都无从判断 |
| 日志里出现 `tunnel/fakeEntry` | 链接器的 `-e _NSExtensionMain` 没生效 | 构建问题，不是设备问题。把这条日志发我 |

---

## 五、失败了怎么办（按代价从低到高）

1. **先确认 appex 真的被注册了。** TrollStore 的安装路径里，注册通过
   `registerPath()`（`RootHelper/uicache.m`）做，而它**会遍历 `PlugIns/`、读每个插件的
   Info.plist 和 entitlement 一起注册** —— 所以插件注册本身不是问题（这条已核实）。
   但如果以前用别的工具装过同一个 App，残注册会挡路。去 TrollStore 设置里点一次
   **「Refresh App Registrations」**，再重装。

2. **把 entitlement 和 StosVPN 对齐。** 去 App Store 装一个 StosVPN（或 LocalDevVPN），
   把它的 ipa 取下来，看它的 `com.apple.developer.networking.networkextension` 数组里
   到底列了几个值 —— 照着抄。这是唯一一个「确定能建起 VPN 隧道的、非越狱设备上的第三方实现」。

3. **加 `com.apple.private.networkextension.ne` / `no-sandbox`。**
   逐条**加一条、重装、重试**，不要一次加一堆 —— 这样哪一条起作用是已知的。
   注意 `com.apple.private.skip-library-validation` 在 iOS 15/A12+ 上一签就崩，别碰。

4. **补 `NEMachServiceName`。** 探针的 appex Info.plist 里没有这一项（StosVPN 也没有）。
   如果怀疑是这个，加 `<key>NEMachServiceName</key><string>group.com.cxk.pasteprobe</string>`
   再试。验包器不检查这一项，所以加它不会让 CI 变红。

5. **换个注册路径。** TrollStore 2 的安装有两套（`LSApplicationWorkspace installApplication:`
   建占位 + MCM 容器 + uicache 注册）。如果 appex 死活起不来，试「装完再用 TrollStore 重装一次」。

6. **接受失败。** NE 这条路本来就是「可能不行」的，所以才用探针先问，而不是直接改主程序。

---

## 六、探针本身的已知限制

- **隧道不转发任何流量。** 只声明一条包含 `10.11.0.0/24` 的路由，其余全部排除
  （`0.0.0.0/0.0.0.0` 放进 `excludedRoutes`）。这是故意的，出自 StosVPN 的手法：
  隧道是活的，但你的流量一点都不经过它，既不影响网络，也不会因为转发出错而失败。
- **日志最多 500 条**（心跳 5 秒一条，不封顶的话放一晚上就爆了）。
- **两个进程同时写同一个日志文件**，理论上会互相覆盖、丢一条。探针阶段够用；
  真做同步实现时这里要换掉。
- **App Group 用不了时**，隧道侧的日志读不到，但剪贴板往返照样能验。
- 探针**刻意不声明任何后台模式**（验包器会检查这一条），所以它不能用来测音频保活。
- 「② 只读剪贴板」实验有可能因为**你自己刚复制完**而在系统里留下"最近复制"状态，
  影响后续判断 —— 做重复实验时先复制一段别的内容再试。

---

## 七、怎么重新构建

```bash
# macOS 上（需要 Xcode + ldid）
bash scripts/setup-ldid.sh          # 准备 ldid（带功能冒烟测试）
bash scripts/build-probe.sh         # arm64
bash scripts/build-probe.sh --arch arm64e
```

CI 里是 `probe` 那个 job，两个架构各出一份，产物在 Actions 的
`ipa-probe-arm64` / `ipa-probe-arm64e` 工件里；打了 tag 会一并挂到 Release。

构建脚本里有三道自查（都在这台 Windows 上验过）：

1. **appex 入口点**：确认二进制把 `_NSExtensionMain` 当外部符号引用，且 `LC_MAIN`
   没有指向 `_main`（注意：真实二进制里入口地址上**没有**符号，那是 ld64 生成的 thunk）
2. **两组 entitlement 都签进去了**：`ldid -e` 读回来逐条对
3. **按 probe 档验包**：`verify-ipa.js --profile probe` —— 它会从 ipa 里把 appex
   二进制的 **Mach-O 签名段**抠出来复读 entitlement

第 3 条是重点：`appex` 的入口点写错时，它的表现是「静默什么都不做」，
和 entitlement 没生效一模一样。这件事在本地就验掉，不要带上真机。
