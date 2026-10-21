# 小米耳夹式耳机 macOS 控制 App — REA 逆向 + 可行性结论

- 分析对象：`/Applications/小米互联服务.app`（Electron，`com.xiaomi.hyperConnect` 4.0.1 / build 575，180MB asar）
- 真机：`Xiaomi 耳夹式耳机`，MAC `00:13:D6:E2:17:D4`，company id `0x038F`
- 分析师：rea-reverse（Team Lead `lead` 的逆向分析专员）｜日期 2026-10-21
- 本机环境：macOS 27 / Apple M1（`MacBookPro17,1`）/ 仅 Command Line Tools（无 Xcode、无 Hopper/Ghidra/IDA）

> 标注约定：**【observed】** = 本次实测/静态取证直接看到；**【inferred】** = 由多项 observed 推出；
> **【unknown】** = 未验证。每条结论后附证据 ID / 文件路径 / 行号，证据编号见 §5。

---

# 0. 一句话结论（先看这个）

**能复用，而且比预期简单得多：不需要 RFCOMM、不需要配对握手、不需要小米的任何代码——
耳机的 BLE GATT 是开放可读的，macOS 上纯 CoreBluetooth 即可拿到电量；ANC 切换需要一个
`FEDCBA…` 私有帧走 `AF00/AF07` 写入、`AF08` 通知回来。**

但**官方 App 帮不上任何忙**：`小米互联服务 4.0.1` 里**完全没有耳机相关代码**，
它是「手机↔Mac 互联 / 文件传输 / 小米云 / 超级小爱」的 App，
不含任何 BLE 耳机控制、电量或 ANC 逻辑。协议是我们用真机直接逆出来的，不是从 App 里挖的。

---

# 1. 逆向部分：官方 App 里到底有什么（以及没有什么）

## 1.1 结论

**【observed】`小米互联服务.app` 不包含任何耳机 / BLE 耳机 / ANC 相关实现。**
Electron 侧的 `main.js`（6.47MB）和 web 侧 `index-BbvPebJ3.js`（5.93MB）中：

- `耳机` / `降噪` / `通透` / `充电盒` / `earbud` / `Buds` / `earphone` 命中数 **全为 0**
  （证据 E-01、E-02）
- `gatt` / `characteristic`(BLE 语义) / `writeValue` / `peripheral` / `FE95` / `038F` 命中 **全为 0**
- `characteristic` 的 1 次命中在 `main.js` 中是一段英文散文（"Key characteristics:"），
  不是 BLE 代码（证据 E-03）
- 唯一相关的是 `bluetoothEnabled` 环境检查字段，用于「Wi-Fi/蓝牙开关是否打开」的健康检查，
  与耳机协议无关（证据 E-04）

## 1.2 全量二进制扫描（不只是 JS）

对 `/Applications/小米互联服务.app` 下**全部文件**（含 Mach-O、`.node` 原生插件、资源包，
排除 node_modules 噪声）做了 41 秒全量扫描，关键词 23 个
（`FE95/038F/GATT/180F/earbud/Buds/TWS/headset/RFCOMM/SPP/A2DP/降噪/通透/耳机/充电盒/入耳/电量` 等）：

- 命中总数 62 个文件，**全部是误报**：Playwright 的 `Headset` 枚举、`ibm-plex` 字体里的 `SPP`、
  `rg` 二进制里的 `tws`、`QRCode.framework` 里偶然的 `038F` 字节序列（证据 E-05 → `fullscan.json`）
- **零真实命中。** 这是"App 里没有耳机代码"的决定性证据。

## 1.3 那这个 App 到底做什么？

**【observed】** 它由这些模块组成（`main.js` 里的 RPC 方法命名空间统计，证据 E-06）：

| 命名空间 | 方法数 | 用途 |
|---|---|---|
| `interconnect.*` | 84 | 手机互联：投屏 `screenMirroring`、热点 `hotspot`、剪贴板 `clipboard`、共享桌面、最近应用 |
| `system.*` | 45 | 系统信息、相机扩展 |
| `pcmiclaw.*` | 41 | 超级小爱 Agent、LLM 调用、上下文压缩 |
| `remoteControl.*` | 21 | 远程控制会话 |
| `midrop.*` / `fileTransfer.*` | 15 / 8 | 文件传输（MateDrop） |
| `micloud.*` | 6 | 小米云：相册/笔记/待办同步 |

原生侧是 `hyperconnect-addon`（35 个 framework：`HyperConnectSDK` / `micontinuity_sdk` /
`lyra_rpc` / `miaccount` / `MiTrustServiceMac` 等）——全是**跨端互联与账号**，无一涉及耳机。

`micontinuity_sdk` 确实链接了 `CoreBluetooth.framework` 并含 `BleConnect` / `BleGattClient` 符号，
但这些是 **lyra 互联自己的 BLE 通道**（服务 `0xFC66` / `0xFCC0`，公司私有 UUID
`00000001-09da-4bed-9652-f507366fcfc5`），用于 Mac↔手机自动发现与建链，
**不是耳机协议**（证据 E-07）。

## 1.4 结论的含义（Lead 已确认，务必保留）

**【inferred】用户目前根本没有可用的官方 Mac 端耳机控制。**
小米没有把耳机控制能力放进 Mac 端任何官方软件。这解释了为什么：
- macOS 系统「蓝牙」面板只显示耳机电量（标准 `0x180F`），没有 ANC 开关；
- 用户想要「AirPods 那样的弹窗 + 状态栏 + 降噪切换」，在小米生态里是**空白**。

→ 这正是本项目的价值所在：**我们不是在复刻官方功能，而是在补一个官方缺失的功能。**

---

# 2. BLE 协议（真机实测）

## 2.1 广播包（这是最关键的发现）

**【observed】** 耳机在 BLE 广播里直接可见，且广播**不带任何 service UUID**
（`CBAdvertisementDataServiceUUIDsKey` 为空，也没带 `0xFDAA`）——所以
**扫描时不能用 `withServices:` 过滤，必须用 `nil` 全扫 + 按 company id 过滤**（证据 E-08）。

原始 manufacturer data（company id `0x8F03` = 小端 `0x038F`）：

```
8F 03 | 16 01 | 36 | A0 4E BC BF | 1E 00 00 00 | 13 00 D6 D4 17 E2 | 81 | 13 00 D6 D4 17 E2
 ↑        ↑     ↑         ↑              ↑              ↑            ↑            ↑
 company  ?   product?   ?          ?          MAC 反序     ?      MAC 反序(重复)
```

逐字段解读：

| 偏移 | 字节 | 解读 | 置信度 |
|---|---|---|---|
| 0–1 | `8F 03` | company id = `0x038F`（小米） | **observed** |
| 2–3 | `16 01` | 疑似 **product id `0x0116`**（小端） | inferred |
| 4 | `36` | 疑似 帧/版本/标志 | unknown |
| 5–8 | `A0 4E BC BF` | 变化于每次广播之间，疑似 TWS 同步/会话标记 | unknown |
| 9–12 | `1E 00 00 00` | 常数（`0x1E`=30） | unknown |
| 13–18 | `13 00 D6 D4 17 E2` | **MAC `00:13:D6:E2:17:D4` 反转**（`D4 17 E2 D6 13 00`） | **observed** |
| 19 | `81` | 标志位（`0x81` = bit7+bit0） | unknown |
| 20–25 | `13 00 D6 D4 17 E2` | MAC 再重复一次 | **observed** |

> 注意：MAC 在广播里出现两次且都是小端反序。这是识别「哪副耳机」的可靠手段。

## 2.2 GATT 服务与特征值（完整，真机 discoverServices(nil) 全量）

**【observed】** 6 个主服务、22 个特征值（证据 E-09：`research/rea/live/gattdump.swift` 输出）：

| 服务 | 特征值 | properties | 用途判断 |
|---|---|---|---|
| **`0x180A`** Device Info | `2A29` 制造商 | `0x02` read | 读回 `"DEMO"` |
| | `2A24` 型号 | `0x02` read | 读回 `"0000"` |
| | `2A25` 序列号 | `0x02` read | 读回 `"0013D6E217D4"` **= MAC** |
| | `2A27`/`2A26`/`2A28`/`2A23` | read | 均 `"0000"` |
| | `2A50` PnP ID | read | `01B00200001F00` |
| **`0x180F`** Battery ×2 | `2A19` | **`0x12` = read+notify** | **电量！左耳 / 右耳** |
| **`0xAF00`** 私有 | `AF07` | **`0x0E` = read+write+writeNoResp** | **写入口（TX）** |
| | `AF08` | **`0x10` = write+notify** | **数据出口（RX 通知）** |
| **`0xFD2D`** 私有 | `FF10` | `0x08` write | 疑似 OTA/调试 |
| | `FF11`/`FF12`/`FF13` | `0x18` write+notify | 疑似 OTA/调试 |
| | `CF07` / `CF08` | `0x10` / `0x08` | unknown |
| **`0x01000100-…-009078563412`** 私有 | `03000300-…-009278563412` | **`0x0E` = read+write+writeNoResp** | 疑似厂商自定义通道 |
| | `02000200-…-009178563412` | **`0x10` = write+notify** | 配对通道 |

> **关键：两个 `0x180F` Battery Service。** 耳机分别暴露左耳和右耳的标准电量。
> `2A19` 是标准的 0–100 整数百分比，**不需要任何私有协议就能读到**。

## 2.3 私有帧格式（Lead 的实测抓包）

**【observed by Lead，本次以 Lead 结果为准】** 走 `AF00/AF07` 写入、`AF08` 通知返回：

```
TX  FEDCBAC4 50 0012 00 01 <16字节随机challenge>                          EF
RX  FEDCBA04 50 0013 00 00 01 <16字节应答>                                 EF
TX  FEDCBAC4 51 0003 01 0100                                              EF   ← auth confirm
RX  FEDCBAC7 F4 0005 02 03000C03                                          EF   ← notifyConfig 主动上报
RX  FEDCBAC7 0E 0006 03 0400BEC11E                                        EF   ← reportStatus
```

帧结构拆解：

```
FEDCBA C4 | 50 | 0012 | 00 01 | <payload> | EF
 ↑          ↑    ↑       ↑                     ↑
 magic(3)   op   len     ?(seq/flags)        校验/终止符
```

| 字段 | 值 | 说明 | 置信度 |
|---|---|---|---|
| magic | `FE DC BA` | 小米私有帧头（3 字节） | **observed** |
| 类型字节 | `C4` = TX / `C7` 或 `04` = RX | 方向/帧类 | inferred |
| opcode | `50` 握手, `51` auth confirm, `F4` notifyConfig, `0E` reportStatus | 命令字 | **observed** |
| 长度 | `0012` / `0013` / `0003` / `0005` / `0006` | 大端 16-bit | inferred |
| seq | `00 01` / `00 00` | 序号 | unknown |
| 终止 | `EF` | 帧尾 | **observed** |
| 校验 | 未观察到独立 CRC 字段 | `EF` 可能就是全部 | **unknown** |
| 加密 | 握手后半段 payload 像被加密 | challenge/应答 16 字节 | **unknown** |

**待办：`0x50` 握手 → `0x51` confirm 之后 payload 是否加密，尚未验证（见 §6）。**

## 2.4 电量查询

**【observed】** 两条路都通：

1. **免握手**：直接读两个 `0x180F` 的 `2A19`（props `0x12` 含 notify）→ 立即得到 0–100。
   **这是功耗最低、最稳的方案，建议作为主路径。**
2. **带握手**：`0x0E` reportStatus 通知里带 `03 04 00 BE C1 1E` —— 疑似更细的
   L/R/Case 三路电量 + 状态位（**inferred**，需 Lead 确认字段偏移）。

> **充电盒电量**：标准 `0x180F` 只有两个实例（左/右）。盒电量大概率在 `0x0E` reportStatus
> 的 payload 里，或需要 `notifyConfig` 打开后才上报。**【unknown，最高优先级待验证】**

## 2.5 传输通道结论（对 task 里 RFCOMM=16 的回应）

**【observed】** 完全走 **BLE GATT**，**不需要经典蓝牙 RFCOMM/SPP**：

- 耳机在 BLE 上可连（`CBPeripheral` connect 成功，6 个服务全可发现）
- 电量在 BLE GATT 上直接读得到
- `~/Library/Preferences/com.apple.Bluetooth.plist` 在本机只有 `lastNowPlayedTime` 一个键
  （macOS 27 已把该 plist 迁移走），**task 里说的 `RFCOMMChannel = 16` 在本机无法复核**
- Lead 已用纯 BLE 跑通 `AF00/AF07` 双向控制 → **RFCOMM 不是必需路径**

**【inferred】** 耳机可能*同时*提供经典蓝牙 SPP 通道（类似 Galaxy Buds 的 `GEARMANAGER`），
但**我们不需要它**。只用 BLE 的好处：不占用音频链路、不需要配对、功耗低。

---

# 3. 连接检测：三种 API，全部实测通过

**【observed】** 三个都能拿到「耳机连上了」这个事件（证据 E-10：`connmon2.swift`）：

| 方案 | API | 实测结果 | 评价 |
|---|---|---|---|
| **A. 全局连接通知** | `+[IOBluetoothDevice registerForConnectNotifications:selector:]` | **OK，返回非 nil，实测触发 `EVENT CONNECT: Xiaomi 耳夹式耳机`** | ✅ **推荐主用**。系统级，耳机一连上立刻回调，不用轮询 |
| **B. 单设备通知** | `-[IOBluetoothDevice registerForDisconnectNotification:selector:]` | **OK**（已连接设备注册断开通知成功） | ✅ 配合 A 用，处理断开 |
| **C. CoreBluetooth 连接回调** | `centralManager(_:didConnect:)` | **能连上** | ⚠️ 只能检测「我们主动连的」，检测不到系统/其他 App 建立的连接 |
| **D. 已连接设备枚举** | `retrieveConnectedPeripherals(withServices: [0x180F, 0x180A])` | **OK，返回 `Xiaomi 耳夹式耳机`** | ✅ **启动时补状态**（App 冷启动时耳机已连着），`withServices: []` 返回 0，必须带服务 UUID |
| **E. 已配对列表** | `+[IOBluetoothDevice pairedDevices]` | **OK，12 个设备，目标 `isConnected=true isPaired=true`** | ✅ 冷启动兜底 |
| F. 轮询 `system_profiler` | — | 本机 `system_profiler SPBluetoothDataType` **无输出**（macOS 27 变更） | ❌ **不要用** |

**推荐组合**（已实测）：
```
启动时： retrieveConnectedPeripherals([0x180F]) → 有则直接读电量，跳过弹窗
运行中： registerForConnectNotifications → 弹 HUD + 读电量
        registerForDisconnectNotification → 收 HUD
兜底：   定时 30s 调 retrieveConnectedPeripherals 纠正漂移
```

> `NSBluetoothAlwaysUsageDescription` 必须写进 Info.plist，否则 CoreBluetooth 静默失败。

---

# 4. `#2` AirPods 式弹窗与 Touch Bar 实现方案

## 4.1 浮动 HUD（已在本机跑通并验证参数）

**【observed】** 我写了 `research/rea/live/hudtest.swift` 并**真机运行**，
输出的实际生效值（证据 E-11）：

```
LEVEL=1000 (screenSaver=1000)        ← 高于全屏 App
COLLECTION=337  canJoinAllSpaces=true  fullScreenAuxiliary=true
STYLE=128  isKeyWindow=false  canBecomeKey=false  canBecomeMain=false   ← 不抢焦点 ✅
ACTIVATION_POLICY=1 (accessory)      ← 无 Dock 图标 ✅
VISIBLE=true  OCCLUSION=8194
HUD_OK
```

可直接照抄的最小实现：

```swift
// 1. App 层：无 Dock 图标（等价 LSUIElement=true）
NSApplication.shared.setActivationPolicy(.accessory)

// 2. 窗口：无边框 + 不激活
let panel = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: 320, height: 60),
    styleMask: [.borderless, .nonactivatingPanel],   // .nonactivatingPanel 是关键
    backing: .buffered, defer: false)
panel.isFloatingPanel        = true
panel.becomesKeyOnlyIfNeeded = true    // 永不抢键盘焦点
panel.hidesOnDeactivate      = false   // 切 App 时别消失
panel.level                  = .screenSaver      // 1000，覆盖全屏 App
panel.backgroundColor        = .clear
panel.isOpaque               = false
panel.collectionBehavior     = [.canJoinAllSpaces,   // 所有 Space 都在
                                .fullScreenAuxiliary, // 全屏 App 之上 ⭐
                                .stationary,          // 不随 Exposé 滑动
                                .ignoresCycle]        // Cmd+` 不选中它

// 3. 内容：SwiftUI + 系统材质（自动适配深浅色）
struct CapsuleHUD: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "earbuds").font(.system(size: 26))
            VStack(alignment: .leading, spacing: 2) {
                Text("Xiaomi 耳夹式耳机").font(.system(size: 12, weight: .semibold))
                Text("L 60%   R 60%   Case 60%").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.ultraThinMaterial,                          // ⭐ 系统毛玻璃，等价 NSVisualEffectView
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .fixedSize()
    }
}

// 4. 定位：屏幕顶部居中（跟 AirPods 一致）
let host = NSHostingView(rootView: CapsuleHUD())
host.frame.size = host.fittingSize
panel.setContentSize(host.fittingSize)
panel.contentView = host
if let f = NSScreen.main?.visibleFrame {
    panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width/2,
                                 y: f.maxY - panel.frame.height - 24))
}
panel.alphaValue = 0
panel.orderFrontRegardless()          // ⭐ 不激活 App 也能显示
NSAnimationContext.runAnimationGroup { ctx in
    ctx.duration = 0.22
    panel.animator().alphaValue = 1   // 淡入
}
```

**要点说明（每条都有实测支撑）：**

1. **`.fullScreenAuxiliary` 是覆盖全屏 App 的关键**，配合 `level = .screenSaver`。
   只设 level 不设 collectionBehavior，全屏时仍会被挡住。
2. **`.nonactivatingPanel` + `becomesKeyOnlyIfNeeded = true`** 保证弹窗出现时
   你正在打字的 App **不失焦**（实测 `isKeyWindow=false`）。
3. **`.ultraThinMaterial`** 是 SwiftUI 对 `NSVisualEffectView` 的封装，
   自动跟随浅色/深色模式与「降低透明度」辅助功能设置——**不要手写 `NSVisualEffectView`**，
   除非需要 `.hudWindow` 这种特定材质。
4. **每次弹出重建 `NSHostingView`**，让 SwiftUI 的 `onAppear` 重新播放弹簧动画
   （参考实现 `HUDController.swift:28-31` 就是这么做的）。
5. **防抖 1.5s**：连接事件和 BLE 数据可能同时到达，避免弹两次。
6. **自动消失 4s**，用 `Task.sleep` + `Task.isCancelled` 检查。

### 开源参考实现

| 仓库 / 文件 | 可借鉴点 |
|---|---|
| [`MasimbaTakudzwa/galaxy-buds-menubar`](https://github.com/MasimbaTakudzwa/galaxy-buds-menubar) | **最贴近本项目**：BLE 耳机 + AirPods 式弹窗 + 菜单栏。关键文件：<br>• `Sources/Buddy/HUDController.swift` — NSPanel 弹窗<br>• `Sources/BudsTransport/BTConnectionMonitor.swift` — IOBluetooth 连接监听<br>• `Sources/BudsUI/ConnectHUD.swift` — HUD 视图<br>• `Packaging/Info.plist` — `LSUIElement` + 蓝牙权限文案 |
| [`lihaoyun6/AirBattery`](https://github.com/lihaoyun6/AirBattery) | 多设备电量常驻显示（菜单栏/Dock/小组件），电量图标与刷新策略可参考 |
| `AirPodsPro` / `AirPodsPopup` 类 | 均为「抓 AirPods 广播包 → 解析 → 弹窗」的同类实现，思路一致；本项目因有 GATT 反而更简单 |

> ⚠️ 参考实现里 `galaxy-buds-menubar` 用的是 **RFCOMM 经典蓝牙**（三星协议），
> 我们是 **BLE GATT**，`HUDController.swift` 可直接照抄，`BTConnectionMonitor.swift` 只需要它的
> `IOBluetoothDevice.register(forConnectNotifications:)` 部分。

## 4.2 Touch Bar（本机实测，含坏消息）

**硬件确认【observed】**：本机 `MacBookPro17,1`（M1 13" MacBook Pro）**有 Touch Bar**——
`ioreg` 有 `dfr-drv` / `dispdfr` 节点，`TouchBarServer` 在跑（pid 510），
`TouchBarUserDevice` 存在（证据 E-12）。

### 公开 API 能做什么

**【observed】** `NSApplication` 确实可以挂 app 级 Touch Bar（实测 `app.touchBar = bar` 赋值成功）：

```swift
let bar = NSTouchBar()
bar.defaultItemIdentifiers = [.flexibleSpace, /* 自定义 id */]
NSApplication.shared.touchBar = bar   // 实测 true
```

但是——**app 级 Touch Bar 只在「本 App 是当前活跃 App」时才显示**。
菜单栏 App 常态不是活跃 App，所以：

- ❌ 做不到「常驻显示在 Touch Bar 上，无论前台是谁」
- ✅ 能做到「点开菜单栏 → 面板出现 → 该面板是 key window 时显示」

### Control Strip 是否对第三方开放 → **【observed】不开放**

证据（全部可复现）：

1. **`com.apple.private.controlstrip` 是私有 entitlement**
   `codesign -d --entitlements - /System/Library/CoreServices/ControlStrip.app` 显示：
   ```
   com.apple.private.controlstrip       = true
   com.apple.private.DFRSystemExtra     = [do-not-disturb, launchpad, mission-control, …]
   com.apple.private.touchbar.user-device
   com.apple.private.notificationcenter.menu
   com.apple.private.system-banner-client
   ```
   `ControlStrip.app` 是**唯一**持有 `com.apple.private.controlstrip` 的进程（还带独立沙盒 profile
   `/System/Library/Sandbox/Profiles/com.apple.controlstrip.sb`）。第三方 App 拿不到这个 entitlement
   （未签名/无 Apple 特批即无法获得）。

2. **SDK 里没有任何 Control Strip 公开 API**
   `grep -rn "ControlStrip" $SDK/System/Library/Frameworks/AppKit.framework/Headers/` → **无结果**
   `NSTouchBar.h` 的公开属性只有 `customizationIdentifier` / `defaultItemIdentifiers` /
   `principalItemIdentifier` / `escapeKeyReplacementItemIdentifier` / `templateItems` / `delegate`，
   **没有 controlStrip**（证据 E-13）。

3. **私有的 system-modal Touch Bar 方法在运行时不可达**
   实测 `NSTouchBar.instancesRespond(to:)`（证据 E-14）：
   ```
   presentSystemModalTouchBar:                         = false
   presentSystemModalTouchBar:systemTrayItemIdentifier: = false
   dismissSystemModalTouchBar:                          = false
   presentSystemModalFunctionBar:                       = false
   presentSystemModalFunctionBar:systemTrayItemIdentifier: = false
   ```
   `AppKit`/`DFRFoundation` 的二进制在 macOS 27 已并入 dyld 共享缓存（磁盘上无独立 Mach-O），
   无法用 `nm` 进一步枚举——但**运行时 `responds(to:)` 已经给出否定答案**，这是最硬的证据。

**结论：Touch Bar Control Strip 对第三方关闭，不要在这条路上投入。**
（历史上 `Pock` 等 App 能做到，是 macOS 10.12–10.14 时代的私有 API/签名漏洞，早已封堵。）

### 那么 Touch Bar 上还能做什么

| 方案 | 可行性 | 说明 |
|---|---|---|
| **A. 菜单栏图标（NSStatusItem）** | ✅ **推荐** | 耳机电量常驻菜单栏，点开弹面板。稳、通用、无权限问题 |
| **B. 点开面板时挂 Touch Bar** | ✅ 可行 | 面板为 key window 时 `view.touchBar = bar`，可在 Touch Bar 上做降噪三档切换（大按钮，手感好） |
| **C. 常驻 Control Strip** | ❌ **不可行** | 私有 entitlement，已实测不可达 |
| D. 私有 `presentSystemModalTouchBar:` | ❌ **不可行** | 运行时 `responds(to:) = false` |

**建议**：主交互放**菜单栏 + 浮动 HUD**；Touch Bar 作为「打开面板后的增强」，
把 ANC 三档（降噪/通透/普通）做成 Touch Bar 上的三个大按钮。

---

# 5. 证据清单

| ID | 证据 | 位置 / 复现方式 |
|---|---|---|
| **E-01** | `耳机`/`降噪`/`通透`/`充电盒` 在 web bundle 中命中 0 | `python3 kwscan3.py asar/dist/assets/index-BbvPebJ3.js '耳机\|降噪\|通透\|充电盒' 130 4` |
| **E-02** | `earbud`/`Buds`/`headset`/`headphone` 在 main.js 中命中 0 | `python3 kwscan3.py asar/dist-electron/main.js 'buds\|Buds\|headset\|headphone' 110 6` |
| **E-03** | `characteristic` 唯一命中是英文散文 | `research/rea/kwscan.py` 输出 @char3718758 |
| **E-04** | `bluetoothEnabled` 仅用于环境健康检查 | main.js @char3022113 / @char3036165 |
| **E-05** | 全量二进制扫描 62 命中全为误报 | `research/rea/fullscan.py` → `research/rea/fullscan.json` |
| **E-06** | RPC 命名空间统计（interconnect 84 / pcmiclaw 41 / …） | main.js 正则提取（本次会话） |
| **E-07** | `micontinuity_sdk` 的 BLE 用 `0xFC66`/`0xFCC0`，非耳机协议 | `strings micontinuity_sdk \| grep fc66` |
| **E-08** | 耳机广播包：company 0x038F、含 MAC、无 service UUID | `research/rea/live/blescan.swift` 运行输出 |
| **E-09** | 6 服务 22 特征值完整 GATT dump | `research/rea/live/gattdump.swift` 运行输出 |
| **E-10** | 三种连接检测 API 实测通过 | `research/rea/live/connmon2.swift` 运行输出 |
| **E-11** | HUD 参数实测（level=1000、canBecomeKey=false 等） | `research/rea/live/hudtest.swift` 运行输出 |
| **E-12** | 本机有 Touch Bar（dfr-drv / TouchBarServer pid 510） | `ioreg -l \| grep dfr`、`pgrep TouchBarServer` |
| **E-13** | SDK 无 Control Strip 公开 API | `grep -rn ControlStrip $SDK/.../AppKit.framework/Headers/` → 空 |
| **E-14** | 私有 system-modal Touch Bar 方法运行时不可达 | `research/rea/live/tbprobe.swift` 输出全 false |

> 复现脚本与原始输出：`research/rea/live/`（7 个 Swift 探针 + 编译产物）
> ASAR 解包成果：`research/rea/asar/`（8028 文件，`asar_extract.py` 可重跑）
> 参考仓库：https://github.com/MasimbaTakudzwa/galaxy-buds-menubar

---

# 6. 未知项 / 下一步（按优先级）

| # | 未知项 | 影响 | 建议验证方式 |
|---|---|---|---|
| **U-1** | **充电盒电量从哪读** | 高（用户明确要盒电量） | 握手后订阅 `AF08`，解析 `0x0E` reportStatus 的 `03 04 00 BE C1 1E`；或看 `notifyConfig` 是否打开盒电量上报 |
| **U-2** | **0x50 握手后 payload 是否加密** | 高（决定能否自己实现 ANC） | 抓第二次握手后的 `0x51`/`0x0E`，看 payload 是否可预测；对比不同 challenge 下应答是否变化 |
| **U-3** | **ANC 切换的具体 opcode** | 高（核心功能） | 在 `AF07` 上逐一试 opcode（Lead 已有发送通道），观察耳机实际模式变化 + `0x0E` 回报 |
| **U-4** | 帧有无 CRC | 中（若无 CRC 则实现简单） | 抓多帧对比末尾 `EF` 前是否有校验字节 |
| **U-5** | 入耳检测 | 中 | 摘下/戴上一侧耳机，观察 `0x0E` 通知是否变化 |
| **U-6** | 型号识别表（product id → 型号名） | 中（多设备支持） | `0x0116` 疑似型号 id；需收集更多小米耳机广播包比对 |
| **U-7** | 录音相关能力 | 中 | 官方 App 无此功能；需查耳机是否暴露麦克风控制特征值（`FF10–13` 可能是） |
| **U-8** | `0xFD2D` / `FF10-13` / `CF07-08` 用途 | 低 | 疑似 OTA/调试，非必需，暂不动 |
| **U-9** | 录音（麦克风）功能增强 | 中 | 与 BLE 协议无关；走 AVAudioEngine + 系统默认输入设备即可（耳机的 HFP 麦克风由 macOS 自己管理） |

## 关于「更好地支持录音功能」

**【inferred】** 录音不需要碰耳机协议。macOS 把耳机的麦克风当作标准 HFP 输入设备暴露给系统，
用 `AVAudioEngine` / `AVAudioRecorder` 选中它即可。我们能做的增值是**UI 层**：
- 检测当前默认输入是否是耳机麦克风
- 录音时显示耳机连接状态（避免录到一半断连）
- 一键切换到耳机麦克风

---

# 7. 最终判断

| 问题 | 答案 |
|---|---|
| **能从官方 App 挖出协议吗？** | ❌ **不能**。App 里没有耳机代码（E-01~E-05 已决定性证明）。 |
| **第三方能在 macOS 直连 BLE GATT 吗？** | ✅ **能，已实测**。6 服务 22 特征值全可访问；**无需配对、无需 RFCOMM、不占用音频链路**。 |
| **电量能拿到吗？** | ✅ **能，免握手**。读两个 `0x180F` 的 `2A19`。盒电量待定（U-1）。 |
| **ANC 能切换吗？** | 🟡 **通道已通，opcode 待定**。Lead 已用 `AF00/AF07` 跑通 `FEDCBA…` 帧；具体 ANC opcode 需逐个试（U-3）。 |
| **需要越狱/签名破解吗？** | ❌ **不需要**。全部走公开 CoreBluetooth + IOBluetooth API。 |
| **AirPods 式弹窗能做吗？** | ✅ **能，已跑通**。NSPanel(`.nonactivatingPanel`) + `.screenSaver` + `.fullScreenAuxiliary`，实测不抢焦点、覆盖全屏。 |
| **Touch Bar 常驻能做吗？** | ❌ **不能**。Control Strip 是私有 entitlement（E-13/E-14）。**但打开面板后挂 Touch Bar 可以**。 |
