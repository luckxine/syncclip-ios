# 真机验证清单

> 设备：iPhone / iOS 15.5 / 已装 TrollStore（**无越狱**）。服务器：自建 SyncClipboard.Server。
> 路线：TrollStore 装 App，后台静音音频保活 + 轮询同步。

按顺序做，每步都给了「怎么判断成功」。**第 1、2 步是这个方案的两个命门，先验这两个再往下走。**

---

## 第 0 步：不碰设备就能验的部分（已完成）

打包链路已经在本机（Windows，无 Swift 工具链）跑通并自测过：

```bash
node scripts/lint-swift.js             # 源码静态体检
node scripts/make-icons.js --selftest  # 图标几何 + PNG 编码
node scripts/selftest-pipeline.js      # 打包/验包链路：正例过、反例必须被拦下
```

最后那条尤其重要：它造一个**带真实 code signature 段结构**的合成 Mach-O，
先确认完整包能过，再逐项注入缺陷（少一条 entitlement、误加被禁的 entitlement、
缺后台 audio 声明、bundle id 写错、部署目标过高、图标分辨率与文件名不符……），
确认每一项都被拦下。只有「正例过 + 反例不过」都成立，`verify-ipa.js` 里的
entitlement 解析器才算可信——否则一个写得太宽松的校验器等于没校验。

还没验的只有两件事：**Swift 能不能编过**（需要 macOS + Xcode），
以及**设备上 entitlement 与后台保活是否真的生效**（就是下面第 1、2 步）。

---

## 第 1 步：确认 entitlement 真的生效（地基）

装完 App 先做这个，别急着配服务器。

1. 把 `dist/SyncClipboard_1.0.0.ipa` 传到手机，**用 TrollStore 打开安装**。
2. 打开 App → **诊断** 页 → 右上角 … → 「重新诊断」。

判断：

- ✅ 第一行绿色「**剪贴板权限就位**」，并且下面列表里能看到那四条 `pasteboard`；
  同时清单里**不应该**出现 `skip-library-validation` 之类被禁的——
  而「剪贴板实测」里的文本内容就是你刚才复制的东西，**手机没有弹任何提示** → 地基对了，往下走。
- ❌ 红色「剪贴板权限可能不完整」→ entitlement 没签进去，看下面的排查。
- ⚠️ 列表里有 entitlement，但读剪贴板时手机弹了「允许粘贴」→ 说明这几条对
  **App 形态**（而不是 CLI 形态）不生效。这时按「逐条加变量」往上试：
  先加 `platform-application` + `com.apple.private.security.no-sandbox`，
  改 `Config/SyncClipboard.entitlements` 重打包装一遍。

> 为什么这里强调「App 形态」：我们借鉴的 icli 是一份**纯 CLI** 的 entitlement 清单，
> 它自己也明确写了 "individual keys have **not** been tested by removing them one at a time"。
> 所以那是参考而不是保证——你这台机器上到底哪几条必需，只能自己测。

### 排查

| 现象 | 先查什么 |
|---|---|
| 诊断页说读不到签名段 | 二进制没被 ldid 签过。构建时 `build-app.sh` 会直接 fail 并打印 ldid 输出 |
| 诊断页列出的 entitlement 是空的 | 同上；另外确认装的是 CI 产出的 ipa，不是你自己随手签的 |
| entitlement 都在，但读剪贴板弹提示 | 按上面的「逐条加变量」流程；每次只加一条，记下哪一条起作用 |
| App 一装就闪退 | 大概率签了 iOS 15/A12+ 被禁的 entitlement（`cs.debugger` / `dynamic-codesigning` / `skip-library-validation`）。`verify-ipa.js` 会拦这种包，但如果你改过清单要重新确认 |

---

## 第 2 步：确认后台保活真的有用（第二个命门）

第 1 步过了只说明「能读剪贴板」，不代表「能在后台一直读」。
TrollStore 拿不到 `CS_PLATFORMIZED`，做不了 launchd 守护进程，
所以这里靠的是 `UIBackgroundModes=audio` + 一段听不见的音频。

**实验设计（照做，别省）：**

1. 打开 App，确认 **设置 → 后台保活** 是开的，回 **同步** 页确认状态是「轮询中」。
2. 按 Home 键回桌面，然后**切到别的 App**（比如备忘录），在里面待 **5 分钟**。
   - 不要从后台把 App 划掉！那是主动杀进程，跟被系统挂起是两回事。
3. 5 分钟后回到 App，进 **诊断** 页看「**后台保活实测**」：

| 看到 | 结论 |
|---|---|
| 「最长间隔」只有几秒（<30 秒） | ✅ 后台一直在跑，保活有效。可以做端到端了 |
| 「最长间隔」是分钟级 | ❌ 那段时间被系统挂起了。见下 |

4. 顺手做个真实验：让 Mac 上复制一段文字（服务器会更新），回手机
   进 **同步** 页看「拉取」计数有没有 +1，以及预览里是不是 Mac 上那段。

**如果保活没生效**，按这个顺序退：

1. 确认 `UIBackgroundModes` 真的在包里（`verify-ipa.js` 会检查这一项）。
2. 有些系统版本会把「输出恒为 0」的音频会话判定成没在播放而被挂起——
   本项目用的波形是 16bit 的最低有效位（±1，约 -90 dBFS），已经有内容了。
   如果仍然被挂起，把 `BackgroundKeeper.inaudibleWAV()` 里的幅度从 `±1` 调到 `±64`
   （依然听不见，但更像"真在放东西"）再试。
3. 关掉「后台保活」再打开一次（重新激活音频会话）。
4. 完全退而求其次：**用「轻点背面」触发**。
   `设置 → 辅助功能 → 触控 → 轻点背面 → 轻点两下 → 快捷指令 → 打开 URL → syncclip://sync`。
   这样每次你复制完东西，双击一下手机背面就同步了——比快捷指令那套少点两次，
   而且不需要 App 在后台活着。

---

## 第 3 步：端到端

1. **设置** 页填：地址（`http://192.168.1.10:5033`，注意带前缀和端口）、用户名、密码 → 「保存并应用」。
2. 点「测试连接」→ 应显示「服务器可达，版本 x.y.z」。
   - 若报 401 → 账号密码不对。
   - 若报版本低于客户端 → 服务端要升级（3.1.1 起客户端与服务器必须同版本）。
   - 若报网络错误 → 手机和服务器不在同一网段？服务器防火墙？地址写错？
3. **同步** 页点「推送剪贴板」→ 去 Mac 上的 SyncClipboard 看剪贴板变了没。
4. 在 Mac 上复制另一段 → 手机 **同步** 页点「拉取远端」→ 去备忘录里长按粘贴，看是不是那段。
5. 正常之后就不用管了：本地复制东西 2 秒内会推上去，远端变了 2 秒内会拉下来。

### 安全设计的两个预期行为（不是 bug）

- **剪贴板里是图片时，同步什么都不做。** 引擎会检测到「有内容但没文本」并整轮跳过，
  免得把图片顶掉。诊断页的「剪贴板实测」里能看到类型。
- **远端是空文本时不写本地。** 避免服务器上的一次清空把你的剪贴板也清掉。

---

## 第 4 步：配置文件直改

App 容器里有个 JSON，可以用 Filza 直接编辑（改完回 App 会自动重载）：

```
/var/mobile/Containers/Data/Application/<UUID>/Documents/syncclip-config.json
```

诊断页底部会显示完整路径，直接照着找。

```json
{
  "baseURL": "http://192.168.1.10:5033",
  "username": "youruser",
  "password": "yourpass",
  "pollInterval": 2,
  "startupSync": "pull",
  "keepAliveEnabled": true,
  "syncEnabled": true,
  "verboseLogging": false
}
```
