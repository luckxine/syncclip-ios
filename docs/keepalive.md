# iOS 后台保活：可行手段盘点（TrollStore / 无越狱 / iOS 15.5）

> 结论先行：**「静音音频」确实能保活，而且不是我拍脑袋想的——但它是「软保活」，我第一版实现有三处会导致它在几小时到几天后静默失效的真缺陷。真正的「硬保活」在非越狱设备上只有一条路：Network Extension（PacketTunnelProvider），而它恰好只有 TrollStore 拿得到 entitlement。**

本文所有判断都附了来源；未经验证的项明确标注 **待实测**。

---

## 0. 版本与环境

| 项 | 值 |
|---|---|
| 设备 | iOS 15.5，TrollStore，无越狱 |
| TrollStore | 支持范围 14.0 beta 2 – 16.6.1 / 16.7 RC / 17.0；15.5 走 CVE-2023-41991（TrollStore 2.0 起） |
| 参考实现 | StikDebug（iOS 17+，TrollStore/侧载双形态，真实项目）、StosVPN / EasyTier（Network Extension） |

---

## 1. 先纠正一个前提：音频保活的机制不是「播放了音频」，而是「后台模式 + 真的在渲染」

`UIBackgroundModes` 是 **Info.plist 键，不是 entitlement**。它在 Apple 的
[Supported capabilities (iOS)](https://developer.apple.com/help/account/reference/supported-capabilities-ios)
表里，**免费账号（Apple Developer / Personal Team）那一列是 ✓**。

所以：

- 音频保活、位置保活、后台 fetch 这三条 **对签名方式零门槛**：TrollStore、伪造签名、免费证书都一样能声明。
- 真正被 `TF_PLATFORM` 拦住的是 **Network Extension**（见第 4 节）。

系统不挂起这个进程的理由是：它声明了 `audio` 后台模式，**且 `AVAudioSession` 处于激活状态、音频引擎在持续渲染**。一旦渲染停下来（会话被抢、媒体服务被重置），系统下一轮就会把它当普通 App 挂起。

### 1.1 我第一版实现的三个真缺陷

对照 StikDebug 的
[`Services/BackgroundAudioManager.swift`](https://github.com/StephenDev0/StikDebug/blob/main/StikDebug/Services/BackgroundAudioManager.swift)：

| # | 我原来的写法 | StikDebug 的写法 | 后果 |
|---|---|---|---|
| 1 | 只监听 `interruptionNotification`，且只在 `.ended` 时 `player.play()` | 同时监听 **`AVAudioSession.mediaServicesWereResetNotification`**，收到后**重建整个 `AVAudioEngine` + `AVAudioPlayerNode`** | `mediaserverd` 重启/媒体服务重置后，`AVAudioPlayer` 会永久哑掉，我的代码无任何恢复路径 → 保活静默失效 |
| 2 | 无健康检查 | **每 2 秒的 `Timer` 检查 `engine.isRunning && player.isPlaying`**，不满足就 `setActive(true)` + `engine.start()` + `player.play()` 抢回会话 | 被持续播放音频的 App（游戏/音乐）抢占会话后，保活断掉且不自知 |
| 3 | `AVAudioPlayer` 播 1 LSB 方波（怕「全零=静音被判定没在播」） | `AVAudioEngine` + `AVAudioPlayerNode`，**全零 PCM buffer**（`frameLength` 已设、`.loops` 循环） | 两者都可用；StikDebug 说明「全零」并不一定会被判成没播——这至少说明 8kHz 方波不是必需的。更重要的是 AVAudioEngine 可按需重建，恢复能力更强 |

**所以用户那句"怎么可能靠音频来保活"——怀疑对了一半：靠音频保活是业界通行做法（App Store 上大量闹钟/录音/定位类 App 都这么干，
[SO 上的经典讨论](https://stackoverflow.com/questions/3762200/how-to-keep-an-iphone-app-running-on-background-fully-operational)，
App Store 审核有 2.5.4 条款专门拦它：[background audio rejected](https://stackoverflow.com/questions/24415616/background-audio-play-app-rejected)——审核拦得住，设备端拦不住），
但**「能保活」和「稳定保活」之间差的就是上面那三个自愈机制**。**

### 1.2 音频保活的钱与电

- 音频持续渲染会让系统处于较高功耗状态（无法深睡）。实测口径因机型差异大，粗略量级是每小时几个百分点。
- 它的隐藏风险不是耗电，而是**被抢占**：任何"更高优先级"的音频（通话、音乐、导航语音）都可能把会话拿走。

---

## 2. 分级清单

### Tier 0 — 唯一的「真常驻」：Network Extension（PacketTunnelProvider）

**机制**：App 内嵌一个 `PlugIns/TunnelProv.appex`，`Info.plist` 声明

```xml
<key>NSExtension</key>
<dict>
  <key>NSExtensionPointIdentifier</key>
  <string>com.apple.networkextension.packet-tunnel</string>
  <key>NSExtensionPrincipalClass</key>
  <string>$(PRODUCT_MODULE_NAME).PacketTunnelProvider</string>
</dict>
```

隧道进程由 `nesessionmanager` 托管，**不是 App 进程，不参与 App 挂起机制**：隧道在，它就在。
Apple 的定位就是「purpose-built mechanism for VPN/tunnel apps to run persistently in the background」
（[fosrl 讨论](https://github.com/orgs/fosrl/discussions/2350)：
"The system manages the VPN extension lifecycle—it launches when the tunnel starts and terminates when disconnected"）。

更关键的三点：

1. **App 被杀不影响隧道**。参考 [onlyapps.org](https://onlyapps.org/blog/free-vpn-session-timer-ios)：
   "The app goes to the background and iOS suspends it within seconds… The tunnel keeps running, the timer is gone.
   The tunnel can start without the app at all: from the VPN switch in Settings or by **Connect On Demand** rules."
2. **可以开机自启**：`isOnDemandEnabled = true` + `NEOnDemandRuleConnect` → 这就是非越狱设备上「守护进程」的等价物。
3. **TrollStore 能拿到这个 entitlement**（详见 2.1）。

不需要 VPN 是"真的 VPN"：可以照抄 StosVPN 的做法
（[`PacketTunnelProvider.swift`](https://github.com/SideStore/StosVPN/blob/main/TunnelProv/PacketTunnelProvider.swift)）：
只声明一条 `includedRoutes` 指向一个假 IP、`excludedRoutes = [.default()]`，然后 `packetFlow.readPackets` 起来什么都不改地写回去。
不承担任何实际流量，但进程是活的。

#### 2.1 entitlement 与它的门槛（重要）

```
com.apple.developer.networking.networkextension = [packet-tunnel-provider]   # appex 与宿主 App 都要有
com.apple.developer.networking.vpn.api          = [allow-vpn]
```

| 签名方式 | 能否拿到 | 证据 |
|---|---|---|
| 付费开发者 / App Store | ✅ | Apple 自 2016-11 起自助开通，无需申请；NE app push provider / Hotspot Helper 除外 |
| **免费 Apple ID / AltStore / SideStore** | ❌ | Apple capability 表里 Network extensions / Personal VPN 免费列**空白**；StosVPN [#16](https://github.com/SideStore/StosVPN/issues/16) 原话："You can't sideload StosVPN to use it, sideloaded apps under free accounts don't get the vpn entitlement." |
| **TrollStore（伪造签名）** | ✅（有实证） | TrollStore README：any IPA + "arbitrary entitlements" + "preserve the entitlements when resigning them with the fake root certificate"；且它是「Signs **all** MachO files」→ bundle 里的 appex 一起被 bypass 签名 |

TrollStore 路线的一手/二手证据：

- **[EasyTier-iOS](https://github.com/EasyTier/EasyTier-iOS)**（真实的 Network Extension VPN 客户端）官方 README：
  > "Nightly TrollStore build — On every push to `main`, the repository updates a **credentials-free** nightly Release IPA for TrollStore.
  > The app and its extensions are **ad-hoc signed with their required Network Extension and App Group entitlements**."
- [CB Pro Proxy](https://github.com/coolbirdzik/CB-Pro-Proxy/blob/main/docs/TROLLSTORE_INSTALLATION.md)：
  > "✅ **TrollStore** is the ONLY method that works without a paid Apple Developer account!"
- TrollStore [#763](https://github.com/opa334/TrollStore/issues/763) 安装日志里可见
  `"com.apple.developer.networking.networkextension" = ("packet-tunnel-provider")` 被完整保留，
  且 `[/…/Stash.app/PlugIns/StashTunnel.appex/StashTunnel] Applied CoreTrust bypass!`
- TrollStore [#629](https://github.com/opa334/TrollStore/issues/629)：有人报「TS2 下 VPN 类 App 能用」，最终结论是不相关原因，issue 已关闭。

#### 2.2 代价与未知

| 项 | 内容 |
|---|---|
| 用户操作 | 首次 `saveToPreferences` 会弹「允许添加 VPN 配置」→ Face ID/密码确认，**一次性** |
| 可见性 | 状态栏出现 VPN 标记；设置 → VPN 里多一条配置（无法隐藏） |
| 打包复杂度 | 多一个 `.appex`、两套 entitlements、CI 要 `ldid` 签两个二进制；现有 `make-ipa.js` 需要扩展 |
| **待实测** | ① 运行时 `neagent` 是否真认可伪造的 entitlement（EasyTier/CB Pro 是强证据，但没有官方文档）；② **appex 进程能不能读写 `UIPasteboard`——没有公开先例**；③ iOS 15.5 上 `NEIPv4Route(.default())` 排除后的隧道是否稳定常驻 |

> 已知的**反向**证据（免费证书）：`NEVPNErrorDomain Code=5 "permission denied"`（`ConfigurationReadWriteFailed`）就是没权限时的典型报错——它出现在免费证书场景。TrollStore 场景没有这类报告。

因此第 6 节把「探针实验」放在第一位。

### Tier 1 — 软保活（零门槛，一定能用）

| 手段 | 关键参数 | 代价 |
|---|---|---|
| **静音音频**（自愈版） | `UIBackgroundModes: [audio]`；`AVAudioEngine` + 全零 buffer `.loops`；`.playback` + `.mixWithOthers`；**2 秒看门狗 + interruption + mediaServicesWereReset 重建** | 耗电；会被音频会话抢占（有自愈就不致命） |
| **位置更新** | `UIBackgroundModes: [location]`；`allowsBackgroundLocationUpdates = true`；`pausesLocationUpdatesAutomatically = false`；`desiredAccuracy = kCLLocationAccuracyThreeKilometers`；`distanceFilter = CLLocationDistanceMax`；需「始终允许」 | 权限弹窗 + 定位箭头常显 + 耗电；但**比音频硬**（没有"会话被抢"这种事） |
| PiP 画中画 | `AVPlayerLayer` + `startPictureInPicture()` | **屏幕上会常驻一个画中画小窗**，比音频难看；仅备选 |

StikDebug 的组合策略（值得照抄）：**位置为主、音频为辅；位置被拒就自动回落到音频并弹窗引导去设置**（见其
[`BackgroundLocationManager.swift`](https://github.com/StephenDev0/StikDebug/blob/main/StikDebug/Services/BackgroundLocationManager.swift)），
`UIBackgroundModes` 三个都声明：`audio`、`location`、`fetch`。

### Tier 2 — 复活兜底（不指望常驻，指望被系统叫回来）

| 手段 | 行为 | 备注 |
|---|---|---|
| `BGTaskScheduler`（`BGAppRefreshTask` / `BGProcessingTask`）+ `Info.plist` 的 `fetch`/`processing` | 系统定期唤醒，15 分钟～数小时不等，**不保证**；被系统杀掉的 App 也会被唤起 | 每次约 30s 执行窗口；只能当兜底 |
| `startMonitoringSignificantLocationChanges()` / 区域监听 | 位置明显变化时**由系统重新拉起 App**（用户手动划掉的除外） | 可做"被杀后自动复活"的钩子 |
| 后台 `URLSession` | 下载/上传**完成**时系统会拉起 App（`handleEventsForBackgroundURLSession`） | 可做土办法"长轮询当推送"，但频率不可控，且需服务端配合 |

### Tier 3 — 真 daemon（你没有）

越狱 launchd（palera1n / Dopamine）。TrollStore README 明确列为不可能：

> ### Things that are not possible using TrollStore
> - Getting proper platformization (`TF_PLATFORM` / `CS_PLATFORMIZED`)
> - **Spawning a launch daemon (Would need `CS_PLATFORMIZED`)**
> - Injecting a tweak into a system process

### 试也不用试的（省时间）

| 想法 | 为什么不行 |
|---|---|
| `posix_spawn` 一个子进程当 daemon | 不越狱时确实能 spawn（`com.apple.private.security.no-sandbox` + `platform-application`，或 TrollStore 的 `spawnRoot`），但**子进程随 App 的 job 一起被回收**：r/jailbreak 实测帖标题就是 *"posix_spawn child dies after app exit"*。反证：如果这条可行，越狱界根本不需要 launchd 钩子 |
| APNs 推送唤醒 | 伪造签名没有 Apple 签发的 provisioning profile，`aps-environment` 过不了 → 拿不到 device token |
| 只靠 `beginBackgroundTask` | 单次 ~30s，续不完，系统还会警告并终止 |

---

## 3. 顺带一个更大的发现：服务端本来就支持「推送」，不该再轮询

用户的 SyncClipboard 服务端（**3.3.1**）自带 **SignalR Hub**：

```csharp
// src/SyncClipboard.Server.Core/Constants/SignalRConstants.cs
public const string HubPath = "/SyncClipboardHub";

// src/SyncClipboard.Server.Core/Web.cs:73
app.MapHub<SyncClipboardHub>(Constants.SignalRConstants.HubPath);

// src/SyncClipboard.Server.Core/Controllers/SyncClipboardController.cs:266
private async Task SaveAndNotifyCurrentProfile(Profile profile, CancellationToken token)
{
    ...
    await _hubContext.Clients.All.RemoteProfileChanged(profileDto);   // ← 谁 PUT 就推给所有在线客户端
}

// Hubs/SyncClipboardHub.cs —— 接口定义（[Authorize]，走同一套 Basic Auth）
public interface ISyncClipboardClient
{
    Task RemoteProfileChanged(ProfileDto profile);
    Task RemoteHistoryChanged(HistoryRecordDto historyRecordDto);
}
```

官方 Windows/macOS 客户端就是这么订阅的（`OfficialAdapter.cs` 用 `HubConnectionBuilder` 连 `¥{serverUrl}/SyncClipboardHub`，
`_hubConnection.On<ProfileDto>(nameof(ISyncClipboardClient.RemoteProfileChanged), …)`）。

**对 iOS 端的含义**：15 秒轮询是浪费。常驻时挂一条 WebSocket（`URLSessionWebSocketTask` + SignalR JSON 协议握手，
手写约 150 行，不引第三方库）→ PC 复制 → 手机**秒级**写剪贴板。轮询降级为兜底。
这也让 Tier 0 的性价比彻底不一样：隧道进程挂一条 WebSocket，就是**零轮询的真时同步**。

---

## 4. 省电对比：省不省电不取决于「技巧」，取决于你持有什么硬件

保活的开销只有一个来源：**为了「让进程活着」，你必须持有哪种硬件**。

| 手段 | 电耗量级 | 它持有什么 | 依据 |
|---|---|---|---|
| **NE 隧道（空闲）** | **≈0**（只剩一段内存 + 一条 socket） | 什么都不持有，CPU 可正常深睡 | 机制推导 + HN 上的对照观察：「It is not caused by an always-on VPN, but by Tailscale. Having e.g. plain WireGuard enabled 24/7 doesn't cause the battery drain」——耗电的是 Tailscale 自己的保活逻辑，不是隧道本身。我们正好可以把自己那条逻辑调得很省 |
| `BGTaskScheduler` | 极低 | 平时进程根本不在 | 系统调度，每次 ~30s |
| **静音音频** | **约 1%/小时** | **音频输出通路**（编解码器 + 功放） | **Apple 官方规格反推**：iPhone 15 Pro Max「音频播放最长 **95 小时**」→ 100/95 ≈ **1.05%/小时**（新机、50% 音量、无线电关闭）。独立旁证：睡眠类 App 实测「一晚 5–15%」「8–22%」（8 小时 → 1–2%/小时） |
| **位置（3km 精度 + 长间隔）** | **约 1–2%/小时**（估计） | 定位射频（蜂窝/WiFi 扫描，非 GPS） | Apple [Energy Guide 位置最佳实践](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/LocationBestPractices.html)：降精度、缩短时长。**量级估计，标注为估计值** |
| PiP 画中画 | 高于音频 | 音频通路 + 视频解码 + 屏幕合成 | 机制推导 |

两个容易被误导的点：

1. **iOS 电池统计会把所有流经隧道的流量记在 VPN App 头上**，所以「VPN 好费电」经常是错觉（[r/Adguard 讨论](https://www.reddit.com/r/Adguard/comments/181rh3w/ios_battery_drain_with_adguard_pro_dns/)）。我们的隧道不转发任何流量，不存在这一项。
2. **音频那 1%/小时并没有想象中贵**——真正的代价不是电，而是**可靠性**（见下）。

### 4.1 可靠性要单独看，而且音频的可靠性有实测反例

| 手段 | 会不会被系统掐掉 |
|---|---|
| 音频 | **会。** [SleepTrace 的现场笔记](https://dev.to/sleeptrace/field-notes-why-background-audio-on-ios-fails-silently-at-3am-1l2j) 写得很直白：「If you have ever wondered why your overnight audio app \"just stops\" after three hours, you have met the iOS background execution budget. The phone does not kill rogue audio apps with an alert. **It quietly throttles the process until the audio queue starves**」——即**大约 3 小时后被静默节流**。再叠加音频会话被抢占、`mediaServicesWereReset` → **不能作为唯一手段** |
| 位置 | 在 iOS 15.5 上稳。Apple 论坛原话：「Before iOS 16.4, we could reliably start CLLocationManager in the background … and keep it running **indefinitely**」（[thread 726945](https://developer.apple.com/forums/thread/726945)）——**16.4 之后才收紧，而我们正好在好的一侧** |
| NE 隧道 | **不会**。它不参与 App 的后台执行预算，系统按隧道生命周期管理 |

## 5. 「一般都是怎么保活的」——行业做法

| 需求 | 正统做法 | 我们能否用 |
|---|---|---|
| 服务器 → 设备 的实时推送 | **APNs 静默推送**（`content-available: 1`），App 完全不需要常驻 | ❌ 伪造签名没有 Apple 签发的 profile，`aps-environment` 拿不到 token |
| 设备 → 服务器的持续上报 | **位置后台模式**（运动/定位类：Strava、Life360、Find My） | ✅ |
| 需要一条常驻的网络连接 | **Network Extension**（WireGuard、Tailscale、AdGuard、NextDNS 全是这一条） | ✅ 仅 TrollStore 形态可行 |
| 闹钟/睡眠这类「必须一直醒着」 | **静音音频**（接受耗电与不稳定，或干脆要求插电） | ✅ 但有 3 小时节流 |
| 剪贴板同步 | **没有行业标准解**——Apple 自己的「通用剪贴板」走 Handoff/Continuity，不给第三方 API | 所以我们是在自造一个系统不打算给的东西 |

一句话总结行业现实：**「保活」在 iOS 上从来不是正规解法，正规解法是「不保活 + 推送」；保活是灰色做法，按场景三选一：音频（闹钟/睡眠）、位置（运动/定位）、NE（网络类）。** 我们的场景（剪贴板同步）本该走推送，而推送这条路被伪造签名堵死了——所以要么走 NE（等价于「自己当那个常驻服务」），要么接受「只有 App 活着时才同步」。

## 6. 结论与建议的落地顺序

1. **先做一个最小「探针 IPA」**（成本极低，收益是决定架构）：
   空 App + 一个什么都不转发的 `PacketTunnelProvider` + 两组 entitlements，TrollStore 装上点连接。要看三件事：
   - ① `saveToPreferences` 会不会返回 `permission denied`（entitlement 是否真被认可）
   - ② VPN 连上后 appex 进程是否在跑（`ps` 看不到，用 appex 写文件到 App Group 里、宿主 App 读出来验证）
   - ③ **appex 里 `UIPasteboard.general.string` 能不能读到当前剪贴板**（决定"隧道进程自己干活"是否可行）
2. 不管探针结果如何，**Tier 1 都要做扎实**：音频自愈（看门狗 + interruption + mediaServicesWereReset + 重建 engine）、
   可选位置保活、`BGTaskScheduler` 兜底复活。
3. **轮询换 SignalR**。
4. 探针成功 → 同步核心（`SyncClipCore`，一行不用改）搬进 appex，宿主 App 只做 UI/配置，两者用 App Group 共享配置与状态。
   这就是「真常驻」形态。
