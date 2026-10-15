# NE 探针：非越狱设备上，网络扩展到底能不能用

这份文档对应 `scripts/build-probe.sh` 产出的 `PasteProbe_<版本>_<arch>.ipa`。

它不是要用的 App，是一个**问问题**的工具。问题都在公开资料里查不到确定答案 ——
只能在你的机器上跑一遍。每个问题对应界面上的一个按钮。

---

## 一、v1 和 v1.0.1 已经测到的东西

### v1.0.0：三个地基问题全过（2026-10-15，iOS 15.5 + TrollStore）

| 问题 | 结果 |
|---|---|
| TrollStore 伪造签名带进来的 `com.apple.developer.networking.networkextension`，**到运行时还算不算数**？ | ✅ **算。** `saveToPreferences` 成功，系统弹出并接受了 VPN 配置授权 |
| 隧道进程能不能真的跑起来？ | ✅ 能。`connection.status → connected`，appex 进程开始打心跳 |
| **隧道进程能不能读写剪贴板？** | ✅ **都能。** 读到 App 写进去的 nonce 并回写了 echo |

顺带测出一条**必须写进真实现的设计约束**：

> **隧道进程的主队列不会被排空。**
> v1 从 `DispatchQueue.main` 派了两个任务（一个只记日志、一个读剪贴板），
> 一个都没执行；同一时刻派到后台队列的那份正常跑完。
> 所以 appex 里**所有活儿都必须放后台队列**，别用 `DispatchQueue.main`，
> 也别依赖主 RunLoop（`Timer`、`RunLoop.main.run()` 之类）。

### v1.0.1：又测出两件很要紧的事

**① 隧道连跑了 23 分钟，中间 App 被重装过。**

把 v1.0.0 的日志按秒推回去：隧道是 `02:26:08` 被拉起的，心跳一路到 `02:49:47`
才停 —— **23 分 39 秒**，每 5 秒一条、**一条不漏**（#226 在 02:44:58，#283 在
02:49:43，57 × 5s = 285s，完全对得上）。这段时间里 App 肯定不在前台，
而且中途被**整个替换成了 v1.0.1**（证据：那条停止日志是 v1.0.0 的格式，
说明跑在内存里的还是旧 appex 的代码 —— 也就是说**替换磁盘上的 bundle 并不会
杀掉已经跑着的 appex**，它会继续从内存里跑）。

这已经是「隧道独立于 App 活着」的强证据，但还不算最终结论：需要一个干净实验
（把 App 从后台**划掉**、或**重启手机**，中间不装任何东西）。见第五节。

**② 重装 App 之后，配置会失效，之后每次启动都报 `code=2`。**

实测序列：

```
[02:49:47] tunnel/stopTunnel: 被要求停止，reason=11
...（之后每一次启动）
❌ startVPNTunnel 抛错：NEVPNErrorDomain code=2
```

这两个数字现已查明（Apple 的 `NEProviderStopReason` 是按声明顺序编号的）：

| 数字 | 名字 | 意思 |
|---|---|---|
| `reason=11` | **`superceded`** | **这条配置被另一条取代了** |
| `code=2` | **`NEVPNErrorConfigurationDisabled`** | 配置处于**禁用**状态，所以不能用来启动 |

两件事连起来就是一个完整故事：**重装 App 会让旧的 VPN 配置被顶掉（`superceded`）
并被撂成禁用状态；从那以后那条配置就永远启动不了。**

对真实现的意义很大：**你用 TrollStore 每更新一次 App，VPN 配置就可能失效一次。**
一个常驻服务必须能自己发现这件事并重建配置，否则每次更新完都得手去收拾。
所以 v1.0.2 加了：

- 启动前先 `loadFromPreferences` 重读配置，打出一行完整状态
  （`isEnabled` / 按需 / 连接状态 / provider）—— 以后这类失败一眼就能定位
- `isEnabled=false` 就**自动重新启用**
- 碰到 `code=1/2/4`（配置无效 / 被禁用 / 过期）就**删掉重建一条新的、再自动重试一次**
  （只重试一次，不循环 —— 否则错误另有原因时会把用户手建的好配置反复洗掉）
- 多一个 **「重置 VPN 配置」** 按钮，手动重建

**当时的状态**：设备上的配置已经躺了（`code=2`），v1.0.2 会点一次 ① 自动重建。

### v1.0.2 的真机结果：配置能复活了，但隧道停在 connecting

```
✅ 找到已有配置
配置状态：isEnabled=false 按需=true 连接=disconnected provider=com.cxk.pasteprobe.tunnel
⚠️ 配置处于**禁用**状态（isEnabled=false）—— 这正是 code=2 的成因。现在自动重新启用…
✅ 已重新启用
启动前状态：isEnabled=true …
✅ startVPNTunnel 已被接受
隧道状态 → connecting          ← 就停在这里，再也没有 connected
```

**「配置被禁用 → 自动复活」这部分是好了的**（`code=2` 不再出现）。但隧道卡在
`connecting`，而最关键的一条证据是：

> **隧道侧一条日志都没有。**

把 App Group 日志的时间轴拉出来：上一轮的记录停在 `02:49:47`（superceded），
之后只有 App 侧三条 `pasteboard.baseline`（`03:11` / `03:13` / `11:32`），
中间 **`tunnel/*` 零条**。而隧道进程日志的第一句话就是 `startTunnel` ——
所以结论只能是：**appex 压根没有被拉起**（不是「起来了但没写日志」）。

**最可能的机制**：`superceded` 之后，那条配置记录里指向的 appex 是**重装前的那份**。
`isEnabled = true` 只修了「开关」，修不了「它指向的东西已经不在了」。
这也解释了 ④ 为什么回 nil、③ 为什么没反应。

### v1.0.3：把这次暴露的东西全修掉

除了隧道本身卡住（要真机再验），这次失败还暴露了**三个我自己写错的地方**：

1. **在 `connecting` 时又调了一次 `startVPNTunnel`** —— 我只把 `.connected` 当「在跑」，
   于是②在①还在连的时候又启动了一次。对一个正在连接的会话重复启动，
   很可能直接把会话卡死。现在：`.connecting` / `.reasserting` 一律**不重复启动**，只挂上去等。
2. **②③④ 不等连上就发 `sendProviderMessage`** —— 没连上时它是**静默不回复**的，
   界面上只会显示「隧道没有回复（nil）」，极容易被误判成「IPC 坏了」。
   现在统一排队：没连上就先拉起来，**连上之后自动把命令发出去**。
3. **卡住时没有自救** —— `code=1/2/4` 会自动重建，但「没报错、只是永远
   connecting」这个形态没被处理。现在：**30 秒没连上过、且隧道侧零心跳/零日志
   → 自动删配置重建、再试一次**（仍只一次，不循环）。

另外新增 **「列出配置」** 按钮：把系统里每一条 VPN 配置都列出来（名字 / provider /
`isEnabled` / 按需 / 连接状态）。为什么要它：`superceded` 意味着系统里可能有
一条幽灵/重复配置在顶我们，而我只删「provider 等于本探针」的那些。
一串出来，有几条、都是谁的，一目了然。

连接状态变化（`connecting` → `connected` 等）现在也写进 App Group 日志
（source 为 `app`），这样跨进程时间轴上能看到 App 侧的观察，而不是只有 UI 上滚过去的字。

### 还没答的：②③④ 三个关键实验

到现在为止那三个最关键的问题仍没有答案 —— 因为**隧道一直没能真正起来**
（v1 那次起来过、读写剪贴板都成功，但那之后 tunnel 就再没跑过）。
v1.0.3 装上后的预期路径：

1. 点「列出配置」看有几条（若 ≥ 2 条 → 点「重置 VPN 配置」清掉）
2. 点「① 运行探针」，**等满 30 秒别点别的**
3. 若出现「没连上、隧道侧零日志 → 删配置重建」，它会自动重试一次
4. 若重建后**仍然**卡在 `connecting`、隧道侧还是零日志 → 那就不是配置记录的问题，
   而是 **appex 本身拉不起来**（注册 / 签名）。下一步试：
   - TrollStore → 设置 → **Refresh App Registrations**，然后重装探针 ipa
   - 或把探针**完全卸载**再用 TrollStore 重装（清掉 LaunchServices / 插件注册的旧记录）
   - 仍不行就能定下来：重装之后 appex 无法被重新拉起，得换注册/打包方式

---

## 二、装上去

1. 把 `PasteProbe_<版本>_arm64.ipa` 传到手机（TrollStore 里直接打开，或从文件 App 打开）
2. 用 **TrollStore 打开这个 ipa** 安装
3. 桌面上会出现一个叫「NE 探针」的 App

> 用 `arm64` 那份就行，`arm64e` 那份是备用。两份内容一样，只是目标架构不同。

## 三、四个按钮 + 一个重置 + 两个手动实验

> **顺序很重要**：先点 ① 把隧道拉起来（它会自动处理 `code=2` 那种配置失效），
> 之后再点 ②③④。②③④ 都要求隧道正在跑 —— 没跑时 `sendProviderMessage` 是**静默
> 不回复**的（发给了一个不存在的进程），容易误判成“IPC 坏了”。

### ① 运行探针（echo 往返）—— 已通过，重跑主要是为了把隧道拉起来

App 把剪贴板写成 `PasteProbe-TX-<nonce>` → 拉起隧道 → 隧道读到 nonce 后回写成
`[PasteProbe-ECHO] <nonce>` → App 看到 echo 就判定通过。

失败时看这两行：

| 日志 | 意思 |
|---|---|
| `❌ startVPNTunnel 抛错：NEVPNErrorDomain code=2` | 配置被禁用了。v1.0.2 会自动重建并重试；日志里会先打出 `配置状态：isEnabled=…` |
| `⚠️ 配置处于**禁用**状态` | 就是上面那件事，正在自动重新启用 |
| `❌ saveToPreferences 失败：… code=5` | 这个才是真的“系统不认伪造的 entitlement”，NE 路线到此为止 |

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

### ⑤ 重置 VPN 配置

删掉本探针建的所有 VPN 配置，下次点 ① 会新建一条崭新的。
什么时候用：`code=2` 自动重建也没救回来，或者你想从干净状态开始。
手动做同一件事的路径：设置 → 通用 → VPN与设备管理 → VPN → 删掉 `PasteProbe 探针`。

### ⑥ 手动实验：App 被划掉之后隧道还在不在

前提：先点「② 只读剪贴板」（或 ①）把隧道拉起来，确认状态区是 `connected`。

1. 按 Home 回桌面
2. 从后台卡片里把「NE 探针」**划掉**
3. 等 3 分钟，**重新打开** App → 点「刷新日志」

看心跳的时间戳：如果这 3 分钟里每 5 秒一条还在记，说明**隧道进程没有跟着 App 一起死**。
（探针 App 刻意没有声明任何后台保活模式，所以 App 退到后台几十秒内就会被系统挂起 ——
在这个前提下隧道还在打心跳，结论才干净。）

### ⑦ 手动实验：重启手机后它会不会自己起来

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
| ①✅ ②✅ ③✅ ④✅ + ⑥⑦ 通过 | NE 路线完整成立 | **空隧道 + 隧道里挂 SignalR WebSocket + 隧道里读写剪贴板**。不要音频保活、不要轮询。App 只当配置界面（走 ④ 的 IPC 下发设置） |
| ①✅②✅③④ 但 ⑥ 不通过（隧道随 App 死） | 隧道不能当守护进程，但能当「App 挂起期间的替身」 | 隧道里跑同步 + App 侧保留音频保活兜底。App 真被杀掉时同步暂停，重开 App 恢复 |
| `saveToPreferences` 失败（`NEVPNErrorDomain code=5`） | 系统不认伪造的 NE entitlement | NE 路线结束，回到「App 内保活」：自愈版静音音频 + `BGTaskScheduler` 兜底复活 + 轮询（见 `docs/keepalive.md`） |
| ② 里隧道读到 `nil` | 隧道碰不到剪贴板 | 隧道只负责常驻 + 挂连接；剪贴板读写留在 App 侧，靠后台唤醒去做 |
| ③ 不通 | 隧道不能联网 | 隧道只能当「让进程活着的壳」，网络请求得由 App 或从外部触发 —— 这条会让方案价值大幅缩水，需要重新设计 |
| ④ 不通（但隧道在跑、`ipc.command` 有日志） | 回复通道不通 | 配置只能靠 App Group 文件 + 隧道侧轮询文件变更来传递（能用，但没那么干净） |
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
- ② 之前不要点 ①（① 会把剪贴板改写成探针的 nonce）。如果剪贴板开头是
  `PasteProbe-TX-`，先点「还原剪贴板」或者干脆重新复制一段文字。

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
