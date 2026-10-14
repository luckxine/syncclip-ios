# NE 探针：非越狱设备上，网络扩展到底能不能用

这份文档对应 `scripts/build-probe.sh` 产出的 `PasteProbe_<版本>_<arch>.ipa`。

它不是要用的 App，是一个**问问题**的工具。问题只有三个，但三个都没法从公开资料里
查到确定答案 —— 只能在你的机器上跑一次：

| # | 问题 | 为什么查不到 |
|---|---|---|
| 1 | TrollStore 伪造签名带进来的 `com.apple.developer.networking.networkextension`，**到运行时还算不算数**？ | TrollStore 官方 README 只说「arbitrary entitlements」，没有任何一句提到过网络扩展这个词；`com.apple.developer.networking.vpn.api` 更是完全没有任何资料。有第三方项目声称可行（EasyTier、CB Pro Proxy），但都没有官方背书 |
| 2 | 隧道进程是不是**真的独立于宿主 App 活着**？（App 退到后台、被划掉、甚至手机重启后它还在不在） | 这是 NE 的文档语义（由 `nesessionmanager` 托管），但「TrollStore 装的 App 里塞 appex」这条路上没人验过 |
| 3 | **隧道进程能不能读写 `UIPasteboard`？** | 没有任何先例。EasyTier / StosVPN 的隧道进程只用网络框架，`otool -L` 里连 UIKit 都没有。这一条决定了「把同步逻辑整个搬进隧道」这条路走不走得通 |

问题 3 是重点：如果它成立，那最终形态就是「一条空隧道 + 隧道里跑同步」，
**不需要音频保活、不需要轮询、App 被杀也照常同步** —— 这是非越狱设备上能做到的
最接近守护进程的东西。如果不成立，就退回到「App 内保活 + 定时轮询」。

---

## 一、装上去

1. 把 `PasteProbe_<版本>_arm64.ipa` 传到手机上（AirDrop / 文件 App / 局域网传都行）
2. 用 **TrollStore 打开这个 ipa** 安装
3. 桌面上会出现一个叫「NE 探针」的 App

> 用 `arm64` 那份就行，`arm64e` 那份是备用。两份内容一样，只是目标架构不同。

## 二、跑一次（大约 1 分钟）

打开 App，界面上有六格按钮。按顺序做：

1. **点「运行探针」** → 系统会弹「"NE 探针" 想要添加 VPN 配置」，点**允许**，验证面容/密码
2. 然后就等着，屏幕上会一行一行滚出日志：
   - `✅ saveToPreferences 成功` = 系统接受了这个（伪造签名的）VPN 配置
   - `隧道状态 → connecting` → `connected` = 隧道进程起来了
   - `✅✅ 剪贴板里出现 echo：[PasteProbe-ECHO] xxxxxxxx` = **隧道进程读到了 App 写进剪贴板的内容，并成功回写了剪贴板**
3. 底部会自动贴出 App Group 里的隧道日志（那是隧道进程自己写的）

最后一步如果看到两个 ✅✅，那么三个问题**全是通过**。

### 界面上的状态区是干什么的

```
App Group：可用 / ❌ 不可用
跨进程日志：N 条
最后一条：13:04:12  tunnel/heartbeat
剪贴板：changeCount=42  长度=27  前缀=[PasteProbe-ECHO] ab12cd34
隧道：connected   开机自启=False
```

- **App Group 是否可用**必须先看这一项：它为「不可用」时，隧道进程的日志读不到，
  但**剪贴板往返那条通道不依赖它**，问题 3 照样有答案
- **changeCount** 是最直接的证据：App 写一次它 +1，隧道回写一次它再 +1
- **最后一条** 的时间戳配合心跳，能看出隧道是不是还在跑

---

## 三、两个更强的实验（建议都做，各 2 分钟）

问题 2 说「独立于 App 活着」，上面那次跑只证明了「隧道起来了」。要做实它，得让
App 真的不在：

### 实验 A：App 被划掉

1. 探针跑成功后，按 Home 回桌面
2. 从后台卡片里把「NE 探针」**划掉**
3. 等 3 分钟，**重新打开** App

看状态区的「最后一条」：如果时间戳是刚才这 3 分钟里的（心跳每 5 秒一条），
说明**隧道进程根本没有跟着 App 一起死** —— 这就是我们要的那个性质。

（探针 App 刻意**没有**声明任何后台保活模式，所以 App 退到后台几十秒内就会被系统挂起。
在这个前提下隧道还能打心跳，结论才干净。）

### 实验 B：重启手机后自动起来

1. 点「开机自启」→ 日志里出现 `✅ 已开启 on-demand 自动连接`
2. **重启手机**
3. 重启后**不要打开这个 App**，等 2 分钟，再打开它

隧道日志里如果有重启时间之后的心跳，说明它开机自启了 —— 那就等价于一个
**系统级常驻服务**（这是纯 TrollStore 环境下原本被认为做不到的事）。

> 注意：`UIBackgroundModes` 那套（音频/位置）是做不到开机自启的，
> 这是 NE 与它们的本质差别。

---

## 四、结果怎么读（这张表就是这次探针的全部产出）

| 现象 | 结论 | 最终架构 |
|---|---|---|
| 三个 ✅ 全绿 + 实验 A 通过 | NE 路线成立，且隧道能独立存活 | **空隧道 + 隧道里挂 SignalR WebSocket + 隧道里读写剪贴板**。不要音频保活、不要轮询。App 只当一个配置界面 |
| `saveToPreferences` 失败（`NEVPNErrorDomain code=5 permission denied`） | 系统不认伪造的 NE entitlement | NE 路线结束。回到「App 内保活」：自愈版静音音频 + `BGTaskScheduler` 兜底复活 + 轮询（或 App 活着时的 WebSocket） |
| 配置存下了、隧道也 `connected`，但**没有 echo**、日志里却有 `pasteboard.read` 报错或读到空 | 隧道能跑，但**碰不到剪贴板** | 隧道只负责常驻 + 挂着连接；剪贴板读写留在 App 侧（App 被挂起时靠后台唤醒去做）。仍然比纯音频保活强 |
| `connected` 但 App Group 日志**一条都没有**（连 `fakeEntry` 都没有） | appex 没被真正启动，或者进程起来但日志通道断了 | 先按下面第五节逐条排查。这时问题 3 无从判断 |
| 日志里出现 `tunnel/fakeEntry` | 链接器的 `-e _NSExtensionMain` 没生效 | 构建问题，不是设备问题。把这条日志发我 |
| 隧道起不来，`startVPNTunnel` 抛 `NEVPNErrorDomain code=1` | appex 没通过注册/校验 | 见第五节 |

---

## 五、失败了怎么办（按代价从低到高）

1. **先确认 appex 真的被注册了。** TrollStore 的安装路径里，注册是通过
   `registerPath()`（`RootHelper/uicache.m`）做的，而它**会遍历 `PlugIns/`、
   读每个插件的 Info.plist 和 entitlement 一起注册** —— 所以插件注册本身不是问题。
   但如果你以前用别的工具装过同一个 App，残注册会挡路。去 TrollStore 设置里点一次
   **「Refresh App Registrations」**，再重装一次探针。

2. **把 entitlement 和 StosVPN 对齐。** 去 App Store 装一个 StosVPN（或 LocalDevVPN），
   用 `frida-ios-dump` / TrollDecrypt 之类把它的 ipa 取下来，看它的
   `com.apple.developer.networking.networkextension` 数组里到底列了几个值 —— 照着抄。
   这是唯一一个「确定能建起 VPN 隧道的、非越狱设备上的第三方实现」。

3. **加 `com.apple.private.networkextension.ne` / `no-sandbox`。**
   有些 NE 相关的私有 entitlement 可能被 `neagent` 检查。逐条**加一条、重装、重试**，
   不要一次加一堆 —— 这样哪一条起作用是已知的。
   注意 `com.apple.private.skip-library-validation` 在 iOS 15/A12+ 上一签就崩，别碰。

4. **补 `NEMachServiceName`。** 探针的 appex Info.plist 里**没有**这一项
   （StosVPN 也没有，它在 App Store 上跑得好好的）。但如果你怀疑是这个，
   加 `<key>NEMachServiceName</key><string>group.com.cxk.pasteprobe</string>` 再试。
   我们的验包器不检查这一项，所以加它不会让 CI 变红。

5. **换个注册路径。** TrollStore 2 的安装有两套：先用
   `LSApplicationWorkspace installApplication:` 建占位、再用 MCM 容器 + uicache 注册。
   如果 appex 死活起不来，可以试「装完再用 TrollStore 重装一次」或换个安装工具。

6. **接受失败。** NE 这条路本来就是「可能不行」的，所以才用探针先问，而不是直接改
   主程序。走不了就走回音频/位置保活，`docs/keepalive.md` 里有全部备选。

---

## 六、探针本身的已知限制

- **隧道不转发任何流量。** 它只声明了一条包含 `10.11.0.0/24` 的路由，其余全部排除
  （`NEIPv4Route.default()` 放进 `excludedRoutes`）。这是故意的，出自 StosVPN 的手法：
  隧道是活的，但你的流量一点都不经过它，所以既不影响网络，也不会因为转发出错而失败。
- **日志最多 500 条**（心跳 5 秒一条，不封顶的话放一晚上就爆了）。
- **两个进程同时写同一个日志文件**，理论上会互相覆盖、丢一条。探针阶段够用；
  真做同步实现时这里要换掉。
- **App Group 用不了时**，隧道侧的日志读不到，但剪贴板往返照样能验。
- 探针**刻意不声明任何后台模式**（验包器会检查这一条），所以它不能用来测音频保活。

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

1. **appex 入口点**：`otool -l` 读 `LC_MAIN`，再确认二进制引用了 `_NSExtensionMain`
2. **两组 entitlement 都签进去了**：`ldid -e` 读回来逐条对
3. **按 probe 档验包**：`verify-ipa.js --profile probe` —— 它会从 ipa 里把 appex
   二进制的 **Mach-O 签名段**抠出来复读 entitlement，并从符号表里确认
   `LC_MAIN` 真的指向 `_NSExtensionMain`

第 3 条是重点：`appex` 的入口点写错时，它的表现是「静默什么都不做」，
和 entitlement 没生效一模一样。这件事在本地就验掉，不要带上真机。
