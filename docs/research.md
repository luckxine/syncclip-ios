# SyncClipboard iOS —— 调研结论（2026-10）

目标：把「iOS 上靠快捷指令手动点一下才同步剪贴板」换成后台自动双向同步。
环境：iPhone / iOS 15.5 / 有 TrollStore（巨魔）/ 服务器是自建 SyncClipboard.Server（Docker）。

---

## 1. 官方协议（写客户端必须对齐，来自上游源码与文档）

认证：**HTTP Basic**（`Authorization: Basic base64(user:pass)`）。

关键 API 全部是「不以 `/api/` 开头」的 **WebDAV 兼容路径**（`src/SyncClipboard.Server.Core/Controllers/SyncClipboardController.cs`）：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/SyncClipboard.json` | 读当前剪贴板（返回 `ProfileDto`） |
| PUT | `/SyncClipboard.json` | 写当前剪贴板（Body 就是 ProfileDto JSON） |
| GET | `/file/{dataName}` | 取附件字节流 |
| PUT | `/file/{dataName}` | 传附件字节流（`dataName` 不能含 `/` 或 `\`） |
| PROPFIND / MKCOL | `/`、`/file` | WebDAV 探测用，客户端可忽略 |

官方服务器额外有 `/api/time`、`/api/version`（可做探活/版本校验）、`/api/history*`、`/api/history/query`、
以及 SignalR hub（`SignalRConstants.HubPath`，用于服务端主动推送 `RemoteProfileChanged`）。
**只有官方服务器有这些**；WebDAV/S3 后端只有上表那 4 条。

### ProfileDto（字段大小写敏感）

```jsonc
{
  "type": "Text",                 // Text | Image | File | Group，必填
  "hash": "…",                    // 可选，空串等同 null
  "text": "…",                    // 必填（可能只是预览/截断内容）
  "hasData": false,               // 必填
  "dataName": "…",                // hasData=true 时必填
  "transferDataHash": "…",        // 可选，64 位大写十六进制 SHA-256
  "size": 0,                      // 可选
  "syncedAt": "2026-10-09T15:30:00+08:00"  // 可选
}
```

- Image/File/Group 的 `hasData` **恒为 true**（真正的数据在 `/file/{dataName}`）。
- Text 类型可选把完整字符串放进附件，此时 `text` 只存开头一截，接收方需拉附件拿全文。
  所以接收侧**必须**处理「Text + hasData=true」这种情况。
- `hash` 是内容唯一标识（算法见下）。有 `hash` 时接收方要校验一致性。
- `transferDataHash` 只在 `hasData=true` 时使用，放在 **`TransferDataHash` 请求/响应头**里，
  是传输文件完整字节流的 SHA-256（大写十六进制）。
- 服务器收到 PUT 时：`hash` 非空且 history 里已有该 hash → 直接把它设为当前剪贴板；否则新建记录。
- `hasData=false` 时携带 `transferDataHash` 会被 400 拒绝。

### hash 算法（`docs/Hash.md`）

```
Text        : SHA256(UTF8(text))
File/Image  : SHA256(UTF8( 文件名 + "|" + ToUpper(SHA256(文件内容)) ))
Group       : 见 docs/Hash.md（v1 不实现）
```
统一用**大写十六进制**字符串，比较时大小写不敏感。

### 版本约束

客户端版本必须 ≥ 服务器版本（3.1.1 起不兼容旧版客户端），所以别手搓基于老协议的实现。

---

## 2. 「无提示读写剪贴板」怎么拿（已确认可行）

iOS 14 起读 `UIPasteboard` 会弹「允许粘贴」，公开 API 没有开关。系统对特定角色放行，
所需的私有 entitlement（上游 [owngoal-dev/icli](https://github.com/owngoal-dev/icli) 的签名清单，iOS 15+ 实测可用）：

| entitlement | 作用（原文） |
|---|---|
| `com.apple.private.webkit.pasteboard` | Pasteboard service client profile for direct CLI clipboard access |
| `com.apple.private.pasteboard.check-pasteboard` | Pasteboard service checks |
| `com.apple.Pasteboard.background-access` | **Clipboard access without a foreground app** |
| `com.apple.Pasteboard.paste-unchecked` | CLI pasteboard access profile；接收方 App 自己的粘贴行为不受影响 |

配合 `ldid -S xxx.entitlements` 签名即可。icli 的文档明确写：「icli reads and writes the system
pasteboard without a prompt」，并且它是一个 **`spawns_processes: false` 的 CLI**，说明这件事不需要 UI 进程。

TrollStore 下同样有效：TrollStore 会保留 IPA 里的任意 entitlement，只对 3 个在 iOS 15/A12+ 被禁的
（`com.apple.private.cs.debugger`、`dynamic-codesigning`、`com.apple.private.skip-library-validation`）报错崩溃。

---

## 3. 常驻方式的选择（已定：TrollStore App，不越狱）

### 3.1 为什么没有走「launchd 守护进程」

1. **TrollStore 单独做不到「launchd 守护进程」**。上游 README 原话列了三件不可能的事：
   真正的 platformization（`TF_PLATFORM` / `CS_PLATFORMIZED`）、spawn launch daemon、
   往系统进程注入 tweak。所以要「重启也在、App 不用活着」就必须有真正的越狱环境；
   而这台 15.5 机器**并没有越狱**，所以这条当下不可行。
2. **要让 /var/jb 里的第三方二进制带 entitlement 跑起来，靠的是越狱的「dynamic trustcache」**
   （Dopamine 的 release notes 里多次出现 "load a dynamic trustcache"，rootless 越狱正是用这个
   机制让 ldid 签名 + 带 entitlement 的二进制在 /var/jb 里被 AMFI 放行）。
3. **守护进程读剪贴板有「域名」问题**：`pasteboardd` 是**每用户**（GUI 会话）里的 launchd 服务。
   系统域里以 root 跑的 LaunchDaemon 默认连不上它。所以正解是把常驻进程装成
   **`/var/jb/Library/LaunchAgents/` 里的 LaunchAgent**——它天然跑在用户域、以 mobile 身份运行，
   连 pasteboardd 就是正常路径。这也是设计里选 LaunchAgent 而不是 LaunchDaemon 的原因。

### 3.2 实际采用的形态：TrollStore App + 后台音频保活

没有越狱就无法注册系统服务，所以常驻只能用系统本来就允许的那条路：
声明 `UIBackgroundModes=audio` + 持续播放一段听不见的音频，让 App 进程不被挂起。
三个实现细节：

- **不能用纯数字静音**（全 0 采样）：部分系统版本会把「输出恒为 0」的会话判定成
  没在播放而照样挂起。这里用 16bit 的 ±1（约 -90 dBFS）：人耳听不见，但确实是有内容的信号。
- 音频会话带 `.mixWithOthers`，不抢用户的音乐。
- 被电话等打断后要自己把会话接回来，否则保活就断了。

变更检测：不能 hook SpringBoard，所以以 `UIPasteboard.changeCount` 轮询为主
（默认 2 秒），`UIPasteboard.changedNotification` 能收到就提前唤醒一轮。

### 3.3 这个形态的代价，以及怎么让它可验证

音频保活是「一直是这么做的」但不是「官方保证的」，而它是否生效完全取决于设备行为。
所以 App 里把轮询节拍本身记了下来（诊断页的「后台保活实测」）：轮询次数与**最长间隔**。
App 真被挂起的话，这个值会是分钟级而不是几秒 —— 把「我觉得它在跑」变成「这个数字说明它在跑」。

万一保活在你的机器上不生效，兜底是 URL scheme + 「轻点背面」：
`syncclip://sync` 不打开 App 就能触发一次同步。

---

## 4. 架构

```
        ┌────────────── iPhone (iOS 15.5, TrollStore) ──────────────┐
        │  SyncClipboard.app                                        │
        │   主线程: SCAppSettings / AppModel / SwiftUI              │
        │   轮询任务: SCSyncEngine.syncOnce()                        │
        │     ├─ changeCount 变了 → PUT /SyncClipboard.json          │
        │     └─ 远端 hash 变了   → 写 UIPasteboard（无 banner）      │
        │   保活: BackgroundKeeper（静音音频会话）                   │
        └──────────────────────────┬────────────────────────────────┘
                                   │ HTTP Basic
                   ┌───────────────▼───────────────┐
                   │ SyncClipboard.Server (Docker) │
                   └───────────────────────────────┘
```

同一份核心（`SCProfile` / `SCClient` / `SCPasteboard` / `SCSyncEngine`）有两个前端：

- `Sources/SyncClipApp/`：TrollStore App（**当前使用**）
- `Sources/syncclipd/`：越狱环境下的 launchd LaunchAgent 守护进程（保留备用；
  它必须装成 LaunchAgent 而不是 LaunchDaemon，因为 `pasteboardd` 是每用户的 launchd 服务，
  系统域的 root 进程连不上它）

v1 范围：**文本双向同步**。图片/文件/Group、历史记录、收藏都不做。
