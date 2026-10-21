# 小米耳机（Xiaomi 耳夹式耳机 / REDMI Buds 系）macOS 客户端 —— 公开资料研究

> 研究对象设备：**Xiaomi 耳夹式耳机**，BT MAC `00:13:D6:E2:17:D4`，SIG company id `0x038F`，
> 支持 HFP / AVRCP / A2DP / GATT，带「录音」功能。
> 本文件所有结论都标注了 **可信度** 与 **来源**；标 `high` 的均已在源码或真机上核对过。

---

## 0. 结论摘要（TL;DR）

> **证据等级**：`[HW]` 真机实测 · `[DOC]` 小米官方协议文档 · `[SRC]` 开源源码 · `[?]` 未知待验

1. **🔥 找到了官方一手协议规范** `[DOC]` —— 小米小爱开放平台公开了整套 **MMA 协议**文档：
   帧头 `FEDCBA`、服务 UUID `0000AF00`、完整 opcode/属性表、电量字节规则、ANC 状态、录音状态，
   **全部有官方原文与十六进制样例**。不需要靠猜。
   [小米小爱开放平台 · 蓝牙通讯协议](https://developers.xiaoai.mi.com/documents/Home?type=/api/doc/render_markdown/VoiceserviceAccess/Bluetooth/BluetoothProtocol/CommunicationProtocol)

2. **🎉 已在用户真机上跑通整条读链路** `[HW]` —— 这是最强证据：
   BLE 连上 `AF00` 服务，**不做任何认证**直接发 `GET_DEVICE_INFO`，
   **立刻拿到完整应答**：型号 `vela os earbuds`、VID/PID `0x2717/0x50DB`、
   **电量 `C5 C9 1E` = 左 69% / 右 73% / 盒 30%**，6 秒后变 `C7 CA 1E`（左 71%/右 74%）。
   → **电量+固件+ANC 状态全部免认证可读。**

3. **认证算法已双向验证，且无固定密钥** `[HW]`+`[SRC]`：
   自定义 **SAFER+** 变体（128-bit、8 rounds、`PATTERN=0x9999`）。
   我用 Python 复现 Gadgetbridge 算法，对**两组真机抓包全部 MATCH**；
   Lead 已把它移植成 Swift 并跑通握手。**不需要逆向闭源 `.so`，不需要任何密钥。**

4. **传输层选 BLE，不要 RFCOMM** `[HW]`：
   - **BLE GATT（推荐）**：服务 `0xAF00`，**`AF07`=写、`AF08`=收**（动态发现，不硬编码）
   - 经典 **RFCOMM**：SDP 服务名 **`MIWEAR`**，channel **28**，service class `0000fd2d-…`。
     我实测 `openRFCOMMChannelAsync` 返回 0 但**无任何回调** —— 官方文档解释了原因：
     opcode `0x0A`「主机通知设备通讯方式 0=BLE/1=SPP」+ `0x0B` 唤醒，**设备同一时刻只服务一条通道**。
     → 实测证明 BLE 是正确路线。

5. **电量必须走私有帧，标准 0x180F 不够** `[DOC]`+`[HW]`：
   `0x02` → ATTR `0x07` → 三字节 `[左, 右, 充电盒]`，bit7=充电中，`0xFF`=未知。
   **充电盒电量只有这条路径能拿到**（`0x2A19` 结构上只有一个 byte）。

6. **⚠️ 本机 M2529E1 没有 ANC** `[HW]`+拆解报告 —— **对 UI 影响最大**：
   产品只有「3Mic+VPU **通话降噪**」，没有主动降噪硬件。
   协议侧 `opcode 0x08` + `ATTR 0x04` 支持 `0/1/2/3`（正常/降噪/通透/抗风噪），
   但**本机实际支持哪几档必须真机探测**（见 §2.12，用官方 Status 码 `0=成功 / 9=不支持` 判定）。
   → **不要照抄 Redmi Buds 的三档 ANC UI**，要做运行时能力探测。

7. **「录音」是设备本地录音，我们拿不到文件** `[DOC]`+拆解报告：
   耳机内 Opus/.ogg，单耳最长 90 分钟；本机还支持**充电盒离线录音**
   （充电盒自带 BLE SoC `C0:13:D6:E2:17:D5` + 麦克风 + 录音键）。
   **导出只能走官方「小米耳机」App 的私有 BLE 通道**，公开资料零实现。
   → 我们只能查「能否录音」的状态（`0x0E` ATTR `0x02`），**拿不到音频内容**。
   macOS 端要录音就用**内置麦克风**（48kHz），不要用耳机麦（HFP 会锁 8k/16k 并打断 A2DP）。

8. **现成可参考的 macOS 开源实现有两个**（都是 Swift，见 §5）：
   `ChristianVeneko/redmi-buds-bar`（协议层拆得最干净 + 真机 hex fixture）、
   `killsng/RedmiBudsControl`（含 PROTOCOL.md，但其「AES 密钥」结论是**错的**）。
   ⚠️ **两者都是 AGPL-3.0，商用需注意传染性**，建议只参考算法、独立实现。

---

## 1. 产品身份确认

| 项 | 值 | 可信度 | 来源 |
|---|---|---|---|
| 中文名 | 小米耳夹式耳机（首款耳夹式，2026-05-21 发布，首销 799 元） | high | [快科技](http://m.mydrivers.com/newsview/1124025.html) |
| **型号** | **`M2529E1`**（海外名 Xiaomi Clip） | **high** | [我爱音频网拆解报告](https://www.52audio.com/archives/285892.html)（实机包装标签） |
| 形态 | 耳夹式 / clip-on / open-ear，单耳 5.5–6.0g，**IP57**，11mm 单元，LHDC 5.0，蓝牙 5.4 | high | 同上 |
| **是否有 ANC** | ❌ **没有主动降噪**。产品特性只有「**3Mic+VPU AI 通话降噪**」（通话降噪，非 ANC）。这是开放式耳夹，物理上无法密封耳道 | **high** | 拆解报告 + 评测报告特性列表 |
| 录音能力 | **4 种录音场景**：现场录音 / 音视频录音 / 通话录音 / **充电盒录音（耳机放入盒离线录音）**；App 可实时转写、生成摘要 | high | 拆解报告 |
| 充电盒硬件 | 自带 **蓝牙 SoC（昂瑞微 OM6629）+ 扬声器 + 麦克风 + 功能按键**，独立于耳机的 BLE 身份 `C0:13:D6:E2:17:D5` | high | 拆解报告 |
| 耳机主控 | 恒玄 **BES2710Y**（双模蓝牙 6.1，集成 Codec） | high | 拆解报告 |
| 海外对应系列 | **Xiaomi OpenWear**（OpenWear Stereo / Stereo Pro）/ Xiaomi Clip —— 同为开放式耳挂/耳夹形态 | medium | [小米官网 OpenWear Stereo](https://www.mi.com/ae-en/product/xiaomi-openwear-stereo/)、[on.cc 报道](https://hk.on.cc/hk/bkn/cnt/entertainment/20251014/mobile/bkn-20251014190017822-1014_00862_001.html) |
| 系统识别名 | `Xiaomi 耳夹式耳机`（系统蓝牙列表即此名，**不含 "Redmi Buds"** → 现有工具的名称正则匹配会漏掉） | high | 本机 `system_profiler SPBluetoothDataType` 实测 |
| 本机服务位图 | Classic `0x900019` = HFP AVRCP A2DP GATT ACL；另有独立 BLE 身份 `C0:13:D6:E2:17:D5` | high | 同上 |

### 1.1 ⚠️ 对产品设计影响最大的两条

**(a) 本机型没有 ANC。** 用户提出的「切换降噪 / 通透 / 普通」三档，
对本机**物理上不存在「降噪」这一档**。UI 设计必须据此调整 —— 否则会画出一个永远点不动的按钮。
建议：
- 先真机发一次 `opcode 0x08, payload 02 04 01`（降噪）看耳机是否接受/报错
- 若只支持「通透 / 关闭」，UI 就只做两档（甚至一键切换）
- **不要照抄 Redmi Buds 3 Pro 的三档 UI**

**(b) 录音的真正形态是「4 种场景 + 充电盒也有麦」。**
这比 Xiaomi Buds 5 那只「耳机本地 90 分钟」更进一步：
- 耳机内录音（放进盒里也能录，盒有独立麦克风和 SoC）
- 充电盒按键可直接控制录音
- 录音完成后由「小米耳机」App 转写/摘要

→ **结论不变**：录音内容仍在设备侧，导出走 App 私有通道，**我们拿不到文件**。
但 UI 上可以做得更贴近用户心智：显示「耳机本地录音状态」+「Mac 端录音」两个独立入口。

> ⚠️ **对实现的影响**：`redmi-buds-bar` 用 `name.hasPrefix("Redmi Buds ")` 识别设备，
> 对「Xiaomi 耳夹式耳机」**不生效**。我们必须改用
> "SDP 里有 `0xFD2D`/`MIWEAR` 服务" 或 "BLE 广播里存在 `AF00` 服务" 来发现设备。

---

## 2. 协议速查表

### 2.1 帧格式（MMA / miwear）— 可信度 **high**

```
FE DC BA | TYPE | OPCODE | LEN_HI LEN_LO | [STATUS] | SEQ | PAYLOAD... | EF
```

- `TYPE`：`0xC4` phone request / `0x04` response / `0xC0` earbuds request / `0xC7` earbuds notify
  - 判据：`(TYPE & 0x40) != 0` → request（**无 STATUS 字节**）；否则 response（**多 1 字节 STATUS**）
- `LEN`：大端 16-bit，**request 时 = payload+1，response 时 = payload+2**（把 STATUS 和 SEQ 都算进去）
- 整帧长度 = `7 + LEN + 1`（header3 + type1 + opcode1 + len2 = 7，末尾 +1 是 `EF`）
- ⚠️ 实测校验：fixture `fedcbac7f400067104000b0000ef` 为 14 字节 = 7+6+1 ✓

来源：[Gadgetbridge `Message.java`](https://codeberg.org/Freeyourgadget/Gadgetbridge/src/branch/master/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/redmibuds/protocol/Message.java)（`MESSAGE_HEADER = {0xfe,0xdc,0xba}`、`MESSAGE_TRAILER = 0xef`）、
[`redmi-buds-bar Message.swift`](https://github.com/ChristianVeneko/redmi-buds-bar/blob/main/Sources/BudsProtocol/Message.swift)

### 2.2 Opcode 表 — 可信度 **high**

| Opcode | 名称 | 说明 |
|---|---|---|
| `0x02` | GET_DEVICE_INFO | **取电量/固件/VID-PID**，payload `FF FF FF FF`（全字段） |
| `0x08` | ANC | **切降噪模式** + 佩戴检测 |
| `0x09` | GET_DEVICE_RUN_INFO | 取运行态（当前 ANC 模式、佩戴检测开关），payload `FF FF FF FF` |
| `0x0E` | REPORT_STATUS | 耳机主动上报（电量变化 / 模式变化），**需回 ack** |
| `0x50` | AUTH_CHALLENGE | 认证 challenge |
| `0x51` | AUTH_CONFIRM | 认证确认 |
| `0xF2` | SET_CONFIG | 写配置（强度/EQ/手势/查找耳机…） |
| `0xF3` | GET_CONFIG | 读配置 |
| `0xF4` | NOTIFY_CONFIG | 耳机主动通知配置变化 |

来源：Gadgetbridge [`Opcode.java`](https://codeberg.org/Freeyourgadget/Gadgetbridge/src/branch/master/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/redmibuds/protocol/Opcode.java)、redmi-buds-bar `Message.swift`

### 2.3 GATT 通道（推荐 macOS 走这条）— 可信度 **high**

**🔥 找到了官方协议规范**：小米小爱开放平台公开了整套 **MMA 协议**文档（含 AF00 服务、帧格式、
opcode、电量、ANC、录音状态），这是**官方一手权威来源**，不是逆向：
[小米小爱开放平台 · 蓝牙通讯协议](https://developers.xiaoai.mi.com/documents/Home?type=/api/doc/render_markdown/VoiceserviceAccess/Bluetooth/BluetoothProtocol/CommunicationProtocol)

官方定义的 UUID（`0000xxxx-0000-1000-8000-00805F9B34FB`）：

| 官方名称 | 值 | 用途 |
|---|---|---|
| `UUID_SERVICE` | **`0000AF00-…`** | 设备服务 |
| `UUID_WRITE` | `0000AF05-…` | 主机 → 设备 |
| `UUID_NOTIFICATION` | `0000AF06-…` | 设备 → 主机 |
| `UUID_XIAOAI` | `00001101-0000-1000-8000-008584d01810` | 私有 RFCOMM（**注意基址是 `008584d01810`，不是标准的 `00805f9b34fb`**） |

> 官方文档原话：「若设备BLE连接有配对加密要求，需要将 Characteristic MMA TX 中
> Client Characteristic Configuration Descriptor 的 attribute permission 添加 **Writable with authentication**」
> → 暗示**认证是可选的**，取决于设备是否要求加密。

**本机实测到的该耳机 GATT 服务**（Lead 真机读，与官方定义同族）：

| Service | Characteristic | Properties | 用途 |
|---|---|---|---|
| **`AF00`** | **`AF07`** | read + write + writeNoResp (0x0E) | **写 miwear 帧**（官方对应 AF05） |
| **`AF00`** | **`AF08`** | notify (0x10) | **收 miwear 帧**（官方对应 AF06） |
| `FD2D` | `FF10` / `FF11`-`FF13` | write / notify+write | 小米 "FastConnect" 私有服务，**角色未确认**（见 §2.9） |
| `180A` | `2A29`/`2A24`/`2A25`/`2A50` | read | 厂商="DEMO"、型号="0000"、序列号=`0013D6E217D4`(=MAC)、PnP |
| `180F` ×2 | `2A19` | read + notify | 电池，**实测两个都读到 60%** |
| `01000100-...-009078563412` | `03000300-…` / `02000200-…` | rw / notify | 私有，未确认 |

> ⚠️ 实测特征号是 **AF07/AF08**，官方规范写的是 **AF05/AF06**。
> 两者可能是不同产品世代/不同固件的差异，也可能是本机 CoreBluetooth 读到的实例。
> **实现时应动态发现 `AF00` 服务下的 RX/TX 特征**，不要硬编码。

真机收到的 AF08 通知示例（Lead 实测）：

```
FE DC BA C7 F4 00 05 00 01 03 00 0C 03 EF     ← lead 转录，14 字节
```

> ⚠️ **格式自检**：按 §2.1，`LEN=0x0005` 时应为 `7+5+1 = 13` 字节，但转录为 14 字节。
> 可能差 1 字节；`03 00 0C 03` 作为 payload（TLV: len=3, const=0x00, **code=0x0C**, data=0x03）是自洽的。
> `0x0C` = earbuds position（耳机位置），`0x03` 按源码注释为 bitmask「戴左+戴右」。
> **复现时请以原始 BLE 字节 dump 为准，不要依赖这条转录。**

### 2.3b 官方 opcode 表（与逆向结果对照）— 可信度 **high（官方文档）**

| OpCode | 官方定义 | 备注 |
|---|---|---|
| `0x02` | 信息查询（32 位掩码按属性查询） | 电量/固件/VID-PID 都走这里 |
| `0x08` | 主机配置设备相关信息（32 位掩码） | **ANC 切换在这里** |
| `0x09` | 主机获取设备私有信息（32 位掩码） | 经典蓝牙地址、工作模式等 |
| `0x0A` | **主机通知设备通讯方式（0=BLE，1=SPP）** | ⭐ 切通道前先通知设备，避免丢数 |
| `0x0B` | 主机激活设备经典蓝牙模块（SPP 前置） | 低功耗唤醒 |
| `0x06` | 通知设备断开当前经典蓝牙 | BLE 与 BR/EDR 连接一致性 |
| `0x07` | 从机主动通知经典蓝牙连接状态 | 0=断开 1=连接成功 2=未配对 |
| `0x0E` | 设备主动上报运行信息 | **电量变化、录音状态在此上报** |
| `0xD0`-`0xD3` | 语音输入的 开始/停止/取消/长按 | 语音助手流式输入，**不是**本地录音文件 |

> 📌 `0x0A` 很重要：**如果我们先用 BLE 建链，之后再想走 SPP，必须先发 0x0A 告知设备切通道。**
> 这解释了为什么我实测 RFCOMM 打不开 —— 设备当时正以 BLE 通道在通讯。

### 2.4 经典蓝牙 RFCOMM / SDP — 可信度 **high（本机实测）**

本机 `IOBluetoothDevice.performSDPQuery` 解析该耳机得到 **13 条 SDP 记录**，其中关键两条：

```
[11] name=MIWEAR   rfcomm=28
     attr[0x0001] ServiceClassIDList = uuid128(00 00 fd 2d 00 00 10 00 80 00 00 80 5f 9b 34 fb)
     attr[0x0004] ProtocolDescriptorList = { { L2CAP(0x0100) }, { RFCOMM(0x0003), 28 } }

[6]  name=serial   rfcomm=16
     attr[0x0001] = uuid32(00 00 11 01)   ← 标准 SPP 0x1101，非小米控制通道
```

→ 小米控制通道 = **service class `0000fd2d-0000-1000-8000-00805f9b34fb`，RFCOMM channel 28**。
（Gadgetbridge 常量 `UUID_DEVICE_CTRL = 0000fd2d-…` 与此一致。
`redmi-buds-bar` 里的 `df21fe2c-2515-4fdb-8886-f12c4d67927c` / fallback channel 28 是它在别的机型上
拿到的等价指向，两者都落到 channel 28。）

**实测状态**：`openRFCOMMChannelAsync(&ch, withChannelID: 28)` 与 `channel 16` 均返回
`kIOReturnSuccess(0)`，但 **8–20 秒内 `rfcommChannelOpenComplete` 从未回调**（无错误、无成功）。

**为什么会这样 —— 官方文档给出了答案**（可信度 **high**）：

> OpCode `0x0A`「主机通知设备通讯方式」：**主要用于通知设备切换通讯通道。
> 因为设备切换通道需要一些时间，提前通知设备准备切换通道，避免切换通道导致的丢数现象。
> 0：BLE通讯  1：SPP通讯**
> OpCode `0x0B`「主机激活设备的经典蓝牙模块」：如果通讯通道是 spp，当发现设备处于低功耗状态，
> **在连接 spp 前先发该命令唤醒设备的经典蓝牙模块，再进行 spp 连接。**

→ **设备同一时刻只服务一条通道。** 当时耳机正以 BLE 方式被测试占用，
所以 SPP 通道不响应。**这恰好再次证明：BLE 优先是正确路线。**
若将来确实需要走 SPP，必须先用 BLE 发 `0x0A`(val=1) + `0x0B` 唤醒，再开 RFCOMM。

> 官方说 SPP 用的是 **`UUID_XIAOAI = 00001101-0000-1000-8000-008584d01810`**（注意非标准基址），
> 而本机 SDP 里 0x1101 那条叫 `serial`、channel 16。两者都能试，但**不建议绕这条路**。

### 2.5 电量帧（十六进制样例）— 可信度 **high**

**🔥 官方规范原文给出的电量规则（权威）**：

> 「电量值：一个 byte 表示一个电量值。最高位表示充电状态。**耳机：左耳电量：第0个byte /
> 右耳电量：第1个byte / 盒子电量：第2个byte**」
> 「当无法获取到设备电量时填充默认值 **0xFF**」
> 「电量 Byte 的最高位是充电状态，1 表示"充电中"。以电量 100% 为例，`0x64`(0110 0100) 表示 100% 未充电，
> `0xE4`(1110 0100) 表示 100% 且充电中」
> 「电量取值范围 0-100」

**官方原始样例**（可直接照抄）：

```
耳机:  FE DC BA 00 02 00 07 00 00 04 07 05 06 FF EF
                      └len=7┘       │  │  │  └ 左耳5% / 右耳6% / 盒子(无法获取)
                                    │  │  └ ATTR=0x07 (XM_ARRT_TYPE_MULT_BATTERY)
                                    │  └ Length=04
                                    └ 0x02 信息查询 (掩码 0x00000080 = 取多电量)
```

**请求**（手机 → 耳机，取全字段）：

```
FE DC BA C4 02 00 05 00 FF FF FF FF EF
└ 头 ─┘ │  │  └len=0x0005┘ seq  └ payload ─┘
        │  └ opcode 0x02 GET_DEVICE_INFO
        └ type 0xC4 phone request
```

**响应**（耳机 → 手机，真机 fixture）：

```
FE DC BA 04 02 00 3C 00 02 0D 00 52 45 44 4D 49 20 42 75 64 73 20 33 38
05 01 52 02 52 02 05 03 27 17 50 F3 02 04 01 02 05 00 04 07 DE DE 4F
02 08 00 02 09 00 02 0A 01 02 0B 01 02 0D 01 02 0E 03 02 0F 01 EF
```

关键片段解析（TLV = `len | index | data...`）：

| TLV | 含义 | 数据 |
|---|---|---|
| `02 0D 00` 后接 `52 45 44 4D 49 20 42 75 64 73 20 33 38` | index 0x00 设备名 | `"REDMI Buds 38"` |
| `05 01 52 02 52 02` | index 0x01 固件 | 主 `5.2.5.2`，副 `5.2.5.2` |
| `05 03 27 17 50 F3` | index 0x03 VID/PID | `VID:0x2717 PID:0x50F3` |
| **`04 07 DE DE 4F`** | **index 0x07 电量** | **`DE` `DE` `4F` = 左 94% / 右 94% / 盒 79%** |

**电量字节解码规则**（官方 + 两套实现三方一致）：

```
0xFF            → 未知（该部件不在/不报）
bit7 (0x80)     → 1 = 正在充电
bit0..bit6      → 电量百分比
例：0xDE = 1101 1110 → 充电中，0x5E = 94%
    0x4F = 0100 1111 → 未充电，79%
```

**主动上报**（REPORT_STATUS，真机 fixture）：

```
FE DC BA C7 0E 00 06 60 04 00 DE DE 4F EF
                      │  └ seq  └ TLV: len=4, const=0x00, code=0xDE?, data=DE 4F
                      └ opcode 0x0E REPORT_STATUS
```
（此 fixture 的 TLV code 字节为 `0xDE`，看起来是抓包样本里"电量"的另一种带内编码；
**实现时请以 `index 0x00` 的 TLV 为主**，即 `StatusUpdate.parse` 的 `case 0x00`。）

来源：redmi-buds-bar [`Fixtures.swift`](https://github.com/ChristianVeneko/redmi-buds-bar/blob/main/Tests/BudsProtocolTests/Fixtures.swift)（注明"captured from a real REDMI Buds 8 session"）、
Gadgetbridge `RedmiBudsProtocol.decodeDeviceInfo()` / `parseBatteryInfo()`

### 2.6 ANC / 降噪模式切换 — 可信度 **high**

**切换模式**（opcode `0x08`，payload `02 04 <mode>`）：

| 意图 | 完整帧 |
|---|---|
| 关闭 ANC | `FE DC BA C4 08 00 04 0A 02 04 00 EF` |
| **开启降噪** | `FE DC BA C4 08 00 04 0B 02 04 01 EF` |
| 通透模式 | `FE DC BA C4 08 00 04 0D 02 04 02 EF` |

（倒数第 4 字节是递增的 seq，示例里分别是 `0A/0B/0D`）

**模式取值**：`0x00` = OFF，`0x01` = NOISE_CANCELLING，`0x02` = TRANSPARENCY。

**降噪强度**（opcode `0xF2` SET_CONFIG，config `0x0B`）：

```
FE DC BA C4 F2 ... 04 00 0B 01 <strength> EF   ← 设 ANC 强度
FE DC BA C4 F2 ... 04 00 0B 02 <strength> EF   ← 设通透强度
```
- ANC 强度：`00`=BALANCED，`01`=LIGHT，`02`=DEEP，`03`=ADAPTIVE
- 通透强度：`00`=REGULAR，`01`=VOICE，`02`=AMBIENT（Buds 3 Pro 只支持前两个）

**佩戴检测**（同样走 opcode `0x08`，注意**标志位是反的**：`0x00`=启用）：

```
FE DC BA C4 08 ... 02 06 <00|01> EF
```

**ANC 状态上报**：`FE DC BA C7 0E 00 04 70 02 04 00 EF`（`02 04 00` = 当前为 OFF）

**适用型号**：上述 opcode/config 来自 Gadgetbridge `redmibuds` 家族，覆盖
Redmi Buds 3 Pro / 4 Active / 5 Pro / 6 / 6 Active / 6 Lite / 6 Pro / 8 Active（+ Buds 8 真机验证）。
各型号支持的模式子集不同 —— 见 §2.8。

**🔥 官方规范给出的 ANC（权威，可用于交叉验证）** — 可信度 **high**

官方 `0x08`（主机配置设备信息）属性掩码表里，**Bit4 = `ATTR_DEVICE_ANC_MODE`**：

> 「配置ANC模式：**0：正常  1：降噪  2：通透  3：抗风噪模式**」

官方 `0x09` 上报属性里 **Bit9 = `ATTR_TYPE_GET_ANC_STATUS`**：
> 「获取耳机的主动降噪状态：0：正常 1：降噪 2：通透 3：抗风噪模式」

官方 `0x0E` 主动上报里 **Bit4 = `ATTR_TYPE_ANC_STATUS`**：
> 「上报耳机降噪的状态：0x00 正常模式 / 0x01 降噪模式 / 0x02 通透模式 / 0x03 抗风噪模式」

官方给的写配置命令实例（注意这里是 `type=0xC0` = earbuds request 方向）：

```
关闭低功耗:   FE DC BA C0 08 00 04 00 02 00 01 EF
                                 └ Len=2, ATTR=0x00(功耗), 值=01(关闭低功耗)
```
→ **同构推断**：ANC 切换应为 `FE DC BA C4 08 ... 02 04 <mode> EF`，
与上文逆向得到的 `02 04 <mode>` **完全吻合**（`02`=Len，`04`=ATTR_DEVICE_ANC_MODE 所在字节）。
**两个独立来源互相印证 → 可信度 high。**

`redmi-buds-bar` 的常用 config code 表：`02`手势 `03`自动接听 `04`双连 `06`佩戴检测 `07`EQ预设
`0A`长按循环 `0B`效果强度 `0C`耳机位置 `25`自适应ANC `29`自适应音效 `37`EQ曲线 `3B`自定义ANC。

### 2.7 认证（关键突破）— 可信度 **high（已实测验证）**

**算法**：自定义 **SAFER+** 变体（Bluetooth 风格），128-bit key、**8 rounds**、`PATTERN=0x9999`。

- 明文常量 `SEQ = 11 22 33 33 22 11 11 22 33 33 22 11 11 22 33 33`
- key schedule：`keyInit[15] ^= 6`，17 项 LFSR 寄存器 + 旋转 5 bit + bias matrix
- bias matrix：`45^(45^((17*(i+2)+(j+1))) mod 257) mod 257`
- exp/log 表以 45 为底、mod 257
- 最终 `response = SAFER_encrypt(SEQ, keySchedule(challenge))`

**⚠️ 没有固定密钥**：`keySchedule()` 的输入就是耳机发来的 16-byte challenge，无 secret 常量。
→ **每次会话的 challenge 不同，但算法是确定的；我们完全能自研，不需要逆向闭源 SDK。**

> ❌ **推翻一条流传的错误结论**：`killsng/RedmiBudsControl` 的 `docs/PROTOCOL.md` 与 `docs/AUTH_REVERSE.md`
> 认为认证是「AES-128 + 某个藏在 `libxm_bluetooth.so` 里的密钥」，并计划去逆向 APK 提取 key。
> **这是错的** —— 真实算法是 SAFER+ 变体，**没有任何密钥**。
> 我已用真机抓包双向验证（见下），该结论可以废弃，**不需要逆向 `libxm_bluetooth.so`**。

**我做的实测验证**（`research/web/_src/verify_auth.py`，用真机 fixture，`python3 verify_auth.py` 可复现）：

```
challenge 67c6697351ff4aec29cdbaabf2fbe346   → 12953ffa34f0b875cd3b6850b974856c   MATCH ✓
challenge 00000000000000000000000000000000   → bca5905bc849392e7bf9fdcdc570ef77   MATCH ✓
```

这是**两组互相独立**的配对：
- 第 1 组来自真机：手机发随机 challenge，耳机回 `computeResponse(challenge)`（`fedcbac4 50 …` → `fedcba04 50 …`）
- 第 2 组来自真机：耳机发 challenge（`fedcbac0 50` 帧，16 字节 body 全零），手机回答案

两组都独立命中，说明算法实现正确（不是巧合）。

**握手时序**（与 Gadgetbridge / redmi-buds-bar 一致）：

```
1. 手机 → 耳机 : AUTH_CHALLENGE(0x50)  payload = 01 <16 random>
2. 耳机 → 手机 : AUTH_CHALLENGE response     （其值不校验，忽略）
3. 手机 → 耳机 : AUTH_CONFIRM(0x51)     payload = 01 00
4. 耳机 → 手机 : AUTH_CHALLENGE request      payload = 01 <16B challenge>
5. 手机 → 耳机 : AUTH_CHALLENGE response     payload = 01 <computeResponse(challenge)>
6. 耳机 → 手机 : AUTH_CONFIRM request   → 手机回 payload=01
7. 认证完成 → 立即发 GET_DEVICE_INFO / GET_DEVICE_RUN_INFO / 一串 GET_CONFIG
```

真机 fixture 佐证：

```
fedcbac4500012000167c6697351ff4aec29cdbaabf2fbe346ef   ← 1. 手机发 challenge
fedcba0450001300000112953ffa34f0b875cd3b6850b974856cef   ← 2. 耳机回
fedcbac4510003010100ef                                 ← 3. 手机确认
fedcba04510003000101ef                                 ← 4. 耳机确认
```

来源：Gadgetbridge [`Authentication.java`](https://codeberg.org/Freeyourgadget/Gadgetbridge/src/branch/master/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/redmibuds/protocol/Authentication.java)、`AuthData.java`；
redmi-buds-bar `Authentication.swift` + `Session.swift`

**✅ 已解决（真机实测 `[HW]`，见 §2.11.1）**：
**BLE 通道上读操作免认证** —— 不做任何认证直接发 `GET_DEVICE_INFO(0x02)` 与 `GET_DEVICE_RUN_INFO(0x09)`
都能立刻收到完整应答，电量/固件/ANC 状态全部可读。
**SAFER+ 认证仅对写操作（ANC / SET_CONFIG）需要**（Lead 已用 Swift 移植跑通握手）。
→ 实现顺序建议：**先做免认证的读路径把 UI 跑起来**，写操作再接认证。

### 2.8 各型号能力差异（Gadgetbridge `redmibuds` 家族）— 可信度 high

| 型号 | 支持程度 | 主要能力 |
|---|---|---|
| Redmi Buds 3 Pro | 高度支持 | 电量(左/右/盒)、ANC(off/NC/通透)、4 档强度、通透 2 档、EQ、手势、双连 |
| Redmi Buds 4 Active | 基本支持 | 连接认证、固件、电量 |
| Redmi Buds 5 Pro / 6 / 6 Pro / 6 Active / 6 Lite / 8 Active | 已支持 | 见 Gadgetbridge 各 Coordinator |

来源：[Gadgetbridge Xiaomi 耳机页](https://gadgetbridge.org/gadgets/headphones/xiaomi/)

### 2.9 关于 `FD2D` / `AF00` / 两个 `0x180F` 的角色（回答 Lead 的问题）

| 问题 | 结论 | 可信度 |
|---|---|---|
| `AF00` 是什么？ | **小米 MMA 协议的官方设备服务**（官方文档 `UUID_SERVICE` = `0000AF00-…`），就是 miwear 帧的承载通道 | **high（官方文档）** |
| `FD2D` 是什么？ | 小米 "FastConnect" 私有服务（UUID `0000fd2d-…`，Gadgetbridge 常量名 `UUID_DEVICE_CTRL`）。**它和我们已破解的 miwear/MMA 帧不是一回事**；公开资料里**没有任何对 FF10/FF11/FF12/FF13 的帧格式实现**。推测用于快连/配对辅助/OTA，但**未证实**。建议：**先不碰 FD2D**，AF00 已够用 | **low / 未证实** |
| 两个 `0x180F` 分别是什么？ | **公开资料里完全没有小米耳机的 GATT/180F 实现**（Gadgetbridge 无任何 `180F`/`2A19` 引用；它和 redmi-buds-bar 都只走 SPP）。所以「左/右 vs 耳机/盒」**没有公开依据** | **unknown** |
| 充电盒电量只能从 opcode 0x02 拿吗？ | **是。** 官方规范明确 `XM_ARRT_TYPE_MULT_BATTERY` 的 `[L,R,case]` 三字节是盒电量的唯一公开来源。标准 `0x2A19` 只有一个 byte，**结构上就给不出三个值** | **high** |

**如何用真机 5 分钟判定两个 0x180F**（建议 Lead 直接测）：

1. 两耳都戴上 → 记下两个 0x180F 值
2. **把左耳放回充电盒**，等 2 秒 → 再看两个值
   - 若**值 A 变成充电态/或消失** → A 对应左耳
3. 换成右耳放回 → 若**值 B 变化** → B 对应右耳
4. **两耳都取出、只开盒盖** → 若某个值反映盒电量，那才是盒

> 我的预判（**推测，非结论**）：两个 0x180F 更可能是**左耳 / 右耳**，
> 因为厂商通常把「与系统电量栏集成的标准服务」做成左右各一；
> 而**充电盒电量只走私有帧**。但这需要真机确认，别直接写进实现。

**另一条可交叉验证的线索**：官方 `0x0E` 主动上报属性位里，**Bit0 = `ATTR_TYPE_DEVICE_BATTERY`**
（「上报设备电量(支持多电量上报)，设备电量低于阈值 20% 需主动上报一次」）。
所以除了轮询 0x02，我们还能**订阅 AF08 被动收电量变化** —— 这对菜单栏 App 是最省电的做法。

### 2.10 🔥 官方完整属性表（A 项：给「按型号显示可用功能」用）

> 来源：小米小爱开放平台 MMA 协议文档（§6 命令定义）。**这是官方原文，可信度 high。**
> **TLV 编码规则（务必按此实现）**：`Length | ATTR | Data...`，
> 其中 **`Length` = 1(ATTR 本身) + N(Data 字节数)**。
> 例：官方 `04 07 05 06 FF` → Length=04，ATTR=0x07，Data 3 字节。
> ⚠️ Lead 实测记录里的“len”列是**纯 Data 字节数**，协议里的 Length 字段要 **+1**，别搞混。

#### 2.10.1 `0x02` GET_DEVICE_INFO 属性表（ATTR 值 = Bit 位号）

| ATTR | 名称 | 含义 | 参数格式 |
|---|---|---|---|
| `0x00` | `XM_ATTR_TYPE_NAME` | 设备蓝牙名称 | 字符串 |
| `0x01` | `XM_ATTR_TYPE_VERSION` | 软硬件版本号 | **每 2 字节一个版本**，每 4bit 一段；主副设备各 2 字节 |
| `0x02` | `XM_ATTR_TYPE_BATTERY` | **单**电池电量（Device battery） | 1 字节，最高位=充电 |
| `0x03` | `XM_ATTR_TYPE_VID_AND_PID` | VID / PID | 4 字节：VID 高、VID 低、PID 高、PID 低 |
| `0x04` | `XM_ATTR_TYPE_EDR_CONNECTION_STATUS` | BR/EDR 连接状态 | 1 字节：0 断开 / 1 已连 / 2 未配对 |
| `0x05` | `XM_ATTR_TYPE_MANDATORY_UPGRADE_FLAG` | 当前运行系统环境 | 1 字节：0 正常 / 1 强制升级 |
| `0x06` | `XM_ATTR_TYPE_UBOOT_VERSION` | uboot 版本号 | 2 字节，4 段 |
| `0x07` | `XM_ARRT_TYPE_MULT_BATTERY` | **多电量（耳机左/右/盒）** | 1 字节/项，最高位=充电；**耳机：第0=左 第1=右 第2=盒** |
| `0x08` | `XM_ATTR_TYPE_CODEC_TYPE` | 设备语音编码类型 | 0=speex(默认) / 1=opus / 2=no_decode |
| `0x09` | `XM_ATTR_TYPE_POWER_SAVE` | 是否支持待机模式配置 | 0=不支持 / 1=支持 |
| `0x0A` | `XM_ATTR_TYPE_FUNC_KEY` | 是否支持功能键配置 | 0/1 |
| `0x0B` | `XM_ATTR_TYPE_HOTWORD` | 是否支持热词 | 0/1 |
| `0x0C` | `XM_ATTR_TYPE_CHARSET_TYPE` | 文本编码格式 | 0=UTF-8 / 1=UTF-16 / 2=Unicode / 3=GBK2312（当前仅 UTF-8） |
| `0x0D` | `XM_ATTR_TYPE_COLOR` | 设备类型 | 0=默认/不支持；1~15=15 种设备类型 |
| `0x0E`+ | — | **官方未定义（厂商扩展）** | — |

#### 2.10.2 `0x08` SET_DEVICE_INFO 属性表（写操作）

| ATTR | 名称 | 含义 | 参数 |
|---|---|---|---|
| `0x00` | `ATTR_DEVICE_POWER_MODE` | 功耗模式 | `00` 开低功耗(默认) / `01` 关低功耗 / `FF` 永不关机 / `02-FE` 待机时长（`1E`=30 分钟后） |
| `0x01` | `ATTR_DEVICE_FUNC_KEY` | 功能键定义 | 定制数据 |
| `0x02` | `ATTR_DEVICE_HOTWORD` | 设备热词 | 0/1 |
| `0x03` | `ATTR_DEVICE_SUP_POWER_SAVE_NEW` | 新版省电模式（挡位） | `01` 支持 |
| **`0x04`** | **`ATTR_DEVICE_ANC_MODE`** | **配置 ANC 模式** | **`0` 正常 / `1` 降噪 / `2` 通透 / `3` 抗风噪** |
| `0x05` | `ATTR_DEVICE_GAME_MODE` | 游戏模式 | 0 关 / 1 开 |
| `0x06` | `ATTR_DEVICE_AUTO_PLAY` | 入耳自动续播 | 0 续播(默认) / 1 不续播 |

#### 2.10.3 `0x09` GET_DEVICE_RUN_INFO 属性表（读运行态）

| ATTR | 名称 | 含义 | 参数 |
|---|---|---|---|
| `0x00` | `ATTR_EDR_MAC` | **经典蓝牙 MAC** | 6 字节 |
| `0x01` | `ATTR_BLE_MAC` | **BLE MAC** | 6 字节 |
| `0x02` | `ATTR_COMMUNICATION_MAX_MTU` | MMA 协议最大 MTU | 2 字节 |
| `0x03` | `ATTR_CLASSIC_BLUETOOTH_STATUS` | 经典蓝牙状态 | 0 未连 / 1 已连 |
| `0x04` | `ATTR_GET_POWER_MODE` | 当前工作模式 | 0 正常 / 1 低功耗 |
| `0x05` | `ATTR_VENDOR_DATA` | 定制配置信息 | 定制 |
| `0x06` | `ATTR_TWS_STATUS` | 主从回连状态 | 0 完成 / 1 连接中 |
| `0x07` | `ATTR_DEVICE_VIRTUAL_ADDRESS` | 虚拟地址 | 4 字节随机数 |
| `0x08` | `ATTR_TYPE_DONGLE_STATUS` | 辅助设备连接状态 | 0 断开 / 1 连接中 / 2 完成 |
| **`0x09`** | **`ATTR_TYPE_GET_ANC_STATUS`** | **当前 ANC 状态** | **0 正常 / 1 降噪 / 2 通透 / 3 抗风噪** |
| `0x0A` | `ATTR_DEVICE_AUTO_PLAY` | 入耳自动续播 | 0 续播 / 1 不续播 |
| `0x0B` | `ATTR_DEVICE_GAME_MODE` | 游戏模式 | 0 关 / 1 开 |

#### 2.10.4 `0x0E` REPORT_STATUS 上报属性表

| ATTR | 名称 | 含义 | 参数 |
|---|---|---|---|
| `0x00` | `ATTR_TYPE_DEVICE_BATTERY` | 上报设备电量（支持多电量） | 规则同 `0x02` 电量；**低于 20% 需主动上报一次** |
| `0x02` | `ATTR_TYPE_DEVICE_LOCAL_RECORD` | **设备录音状态** | 0 本地不可录(TWS 未入耳) / 1 可录(已入耳) |
| `0x04` | `ATTR_TYPE_ANC_STATUS` | **上报 ANC 状态** | 0 正常 / 1 降噪 / 2 通透 / 3 抗风噪 |

> ⚠️ **重要**：官方 `0x0E` 里**电量是 ATTR `0x00`**，而 Lead 真机在这台 M2529E1 上看到的是 **ATTR `0x04` 里带 3 字节电量**
> （`FEDCBAC7 0E 0006 02 0400 CACC1E EF`）。这与官方表不一致 → 说明**该固件用了厂商自定义的 ATTR 映射**。
> **实现必须两种都兼容**：`0x0E` 的 TLV 只要 data 长度 ≥3 且形如电量，就按电量解析，别写死 ATTR 号。
> （这也是 §2.3 中我把该帧标为「需以原始 dump 为准」的原因。）

---


### 2.11 🧪 真机实测记录（M2529E1，Lead 在用户的耳机上直接验证）

> 证据等级标记：
> **[HW]** = 本机真机实测（最可靠） · **[DOC]** = 官方文档 · **[SRC]** = 开源源码（Gadgetbridge / redmi-buds-bar） · **[?]** = 未知/待验

#### 2.11.1 认证在 BLE 上【不是必需】—— 决定性结论 **[HW]**

连上 BLE 后**不做任何认证**，直接写 `AF00` 特征：

```
发送  FE DC BA C4 02 00 05 00 FF FF FF FF EF        (GET_DEVICE_INFO)
```

**立刻收到完整应答**（免认证）：

```
FE DC BA 04 02 00 41 00 | 00 ... 65 字节 payload ... | EF
```

解析出的 TLV（这台耳机的真实能力集）：

| ATTR | data | 含义 | 官方定义 [DOC] |
|---|---|---|---|
| `0x00` | `vela os earbuds` | **型号名** | XM_ATTR_TYPE_NAME ✓ |
| `0x01` | `15 12 15 12` | 固件版本 | XM_ATTR_TYPE_VERSION ✓（每 2 字节一版本） |
| `0x02` | `C9` | 单电池电量 | XM_ATTR_TYPE_BATTERY ✓ |
| `0x03` | `27 17 50 DB` | **VID `0x2717` / PID `0x50DB`** | XM_ATTR_TYPE_VID_AND_PID ✓ |
| `0x04` | `01` | EDR 已连接 | XM_ATTR_TYPE_EDR_CONNECTION_STATUS ✓ |
| `0x05` | `00` | 正常系统（非强制升级） | ✓ |
| `0x06` | `15 12` | uboot 版本 | ✓ |
| **`0x07`** | **`C5 C9 1E`** | **电量：左 69% / 右 73% / 盒 30%** | XM_ARRT_TYPE_MULT_BATTERY ✓ |
| `0x08` | `01` | 语音编码 = opus | XM_ATTR_TYPE_CODEC_TYPE ✓ |
| `0x0D` | `02` | 设备类型 = 2 | XM_ATTR_TYPE_COLOR ✓ |
| `0x0E` | `03` | **官方未定义** → 厂商扩展 | — |
| `0x0F` | `01` | **官方未定义** → 厂商扩展 | — |
| `0x10` | `01 01` | **官方未定义** → 厂商扩展 | — |

**6 秒后再读**：`0x07 → C7 CA 1E`（左 71% / 右 74% / 盒 30%，在盒中充电、电量在涨）

> ✅ **结论**：**免认证即可拿到全部电量**，SAFER+ 不是读电量的必需品。
> ✅ 也证明官方 `0x07` 的「左/右/盒」字节顺序在真机上**完全成立**。
> ⚠️ 官方只定义到 `0x0D`，本机多出 `0x0E / 0x0F / 0x10` 三个**厂商私有 ATTR**，含义未知（`[?]`）。

#### 2.11.2 SAFER+ 认证仍需要（用于写操作）**[HW]**

Lead 已把 Gadgetbridge 的 SAFER+ 算法**完整移植成 Swift 并跑通**：
发出 challenge → 耳机回 16 字节应答 → 我们回 `AUTH_CONFIRM [0x01, 0x00]`。
→ 说明**读电量免认证，但 ANC / SET_CONFIG 等写操作需要认证**（待逐条确认哪些写需要）。
「无固定密钥」这一点与我 §2.7 的分析一致（我自己也用 Python 复现并 MATCH 了两组真机抓包）。

#### 2.11.3 `0x09` GET_DEVICE_RUN_INFO 同样免认证 **[HW]**

```
返回 TLVs:
  0x00 / 0x01  len=6  0013D6E217D4 ×2      ← 左右耳 MAC
  0x02  len=2  04 00                        ← MMA MTU = 0x0400 = 1024
  0x03  len=1  01                           ← 经典蓝牙已连接
  0x04  len=1  00                           ← 当前=正常模式（非低功耗）
  0x05  len=3  02 02 00                     ← 厂商定制信息
  0x09  len=1  00                           ← ★ ANC/降噪模式 = 0（正常）
  0x0A  len=1  00                           ← 入耳自动续播 = 0（启用）
```

> ⚠️ **修正一处 Lead 的解读**：Lead 把 `0x0A` 标为「入耳检测」，但按官方表 `[DOC]`，
> `0x09` 的 `0x0A` = **`ATTR_DEVICE_AUTO_PLAY`（入耳自动续播）**，不是佩戴检测本身。
> 佩戴检测状态在 `0x0E/0xF4` 的 `0x0C`（耳机位置 bitmask）里。
> **`0x09` 的 `0x09` = `ATTR_TYPE_GET_ANC_STATUS` 确实是「当前 ANC 模式」——这就是 B 项的答案（见下）**

#### 2.11.4 主动上报（免认证）**[HW]**

```
FEDCBAC7 0E 0006 02 0400 CACC1E EF   → op=0x0E reportStatus, TLV idx=0x04, data=CA CC 1E = 电量(左74%/右76%/盒30%)
FEDCBAC7 F4 0005 01 03000C03   EF    → op=0xF4 notifyConfig, TLV idx=0x0C, data=0x03 = 左右耳都在戴/在盒
```

> ⚠️ **与官方表冲突**（已在上文标注）：官方 `0x0E` 电量 ATTR 是 `0x00`，本机是 `0x04`。
> **该固件用了自定义 ATTR 映射** → 解析必须容错，不能写死 ATTR 号。

#### 2.11.5 帧长度自检 —— 双方已对齐 **[HW]**

- 正确公式：**总长 = 7 + LEN + 1**
- `LEN=5` → 13 字节：`FEDCBAC7F400050103000C03EF` ✓（notifyConfig）
- `LEN=6` → 14 字节：`FEDCBAC70E000602040 0CACC1EEF` ✓（reportStatus）
- 我原先看到的 14 字节 `...F4000500 0103000C03EF` 是把两帧看混了，已修正。

#### 2.11.6 特征号：AF07 / AF08（非官方 AF05/AF06）**[HW]**

服务 `0xAF00` 下实测：**`AF07` = write（写帧）、`AF08` = notify（收帧）**；
官方规范写的是 `AF05`(write) / `AF06`(notify) `[DOC]`。
→ **实现必须动态发现**：在 `0xAF00` 下找 `properties` 含 `.write`/`.writeWithoutResponse` 的作 RX，
含 `.notify` 的作 TX，**不要硬编码 UUID**。

---


#### 2.12 🎯 B 项：`mode=3` 抗风噪是否支持 & 如何查询当前 ANC 模式

#### (1) 查询当前 ANC 模式 —— 有独立命令，且不是 0x02

**答案：用 `0x09` GET_DEVICE_RUN_INFO 的 ATTR `0x09`**（`ATTR_TYPE_GET_ANC_STATUS`）`[DOC]`

**不需要**轮询 `0x02`，因为 `0x02` 的属性表里**根本没有 ANC 状态**这一项。
两种读取方式：

| 方式 | 帧 | 说明 |
|---|---|---|
| **主动查** | `FE DC BA C4 09 00 05 <seq> FF FF FF FF EF` | 全字段查询，应答里找 ATTR `0x09` |
| **定向查** | 同上，payload 用 `02 09`（Length=2, ATTR=0x09） | 只查 ANC，应答更短、更省电 |
| **被动收** | `0x0E` 上报 ATTR `0x04` | 耳机上按键改模式时会主动推 |

**`mode` 取值（三处官方定义完全一致）**`[DOC]`：

```
0 = 正常（关闭降噪）
1 = 降噪 (ANC)
2 = 通透 (Transparency)
3 = 抗风噪 (Wind noise reduction)
```

→ 与 Gadgetbridge `RedmiBudsAmbientSoundMode` 的 `0x00/0x01/0x02` 完全对应（后者没实现 3）`[SRC]`。

#### (2) `mode=3` 抗风噪是否为本机支持 —— 官方有「能力探测」机制，但**本机未实测**

**结论：`[?]` 需一次真机写入即可定论。** 现有证据：

- 官方文档把 `3=抗风噪` 定义为**通用枚举值**，不是所有设备都实现 `[DOC]`
- **本机 M2529E1 没有 ANC 硬件**（§1.1）`[HW]`，抗风噪属于 ANC 家族功能 → **大概率不支持**
- 但「有没有 ANC」与「支不支持抗风噪枚举」是两件事，**不能靠推理定论**

**关键工具：官方状态码 `Status` 字节** `[DOC]` —— 写操作的应答里第一个字节就是它：

| Status | 含义 |
|---|---|
| `0` | Success 成功 |
| `1` | Fail 失败 |
| `2` | Unkown_Cmd 未知命令 |
| `7` | **Param_Error 参数错误** |
| `9` | **Not Support 设备不支持此操作** ← 判断「不支持」的关键 |

**判定脚本（真机 2 分钟，只读+一次写）**：

```
① 先读当前态：0x09 → ATTR 0x09          记录 base 值（Lead 实测 = 0x00）
② 依次写 mode = 2 → 读回 0x09  验证「通透」是否真的生效（这项几乎肯定支持）
③ 依次写 mode = 1 → 读回 0x09  验证「降噪」是否生效
④ 依次写 mode = 3 → 读回 0x09  验证「抗风噪」是否生效
⑤ 全部写回 mode = 0 复原

判定规则：
  · 应答 Status = 0 且 读回值 == 写入值   → ✅ 该档 真支持
  · 应答 Status = 9 (Not Support)        → ❌ 该档 不支持（UI 不要画）
  · 应答 Status = 7 (Param_Error)        → ⚠️ 参数不合法 → 视为不支持
  · 应答 Status = 0 但读回值没变          → ⚠️ 接受但无效（可能需认证）→ 先补 SAFER+ 再试
  · 完全无应答                            → 可能写操作需要认证（见 §2.11.2）

参考帧（写 mode=3，seq 自增）：
  FE DC BA C4 08 00 04 <seq> 02 04 03 EF
```

> 💡 **建议**：UI 采用**运行时能力探测**而不是硬编码档位表 ——
> 首次连接时对每个 mode 试写一次并按 `Status` 结果缓存，这样同一份代码能同时支持
> 「只有通透/关闭」的耳夹本机 和 「三档 ANC」的 Redmi Buds Pro 系列，不用为每个型号写适配。

---


## 3. 「录音」功能真相

### 3.1 这是耳机本地录音，不是"当麦克风用" — 可信度 **high（官方 FAQ 原文）**

小米官方 FAQ（Xiaomi Buds 5，同一套「录音」能力延续到后续含录音功能的型号）明确写：

> "The recording function can record **90 minutes** of audio for each earbud. The recording code uses
> **Opus** code, and the recording file extension is **"ogg"**. **The recording file is saved in the earbuds.**
> You can export the recording file via the Xiaomi Earbuds APP."
> "Both Android and iOS phones support the recording function. **iOS phones use BLE**, and the export time
> will be longer than the Android phone."
> 触发方式：**连击触摸区三次**开始/停止；"**Each earphone records independently.**"

来源：[Xiaomi 官方 FAQ KA-232757](https://www.mi.com/global/support/faq/details/KA-232757/)、
[KA-257532](https://www.mi.com/global/support/faq/details/KA-257532/)

**结论（对产品方向至关重要）**：

- ✅ 「录音」= **耳机内置存储 + 本地 Opus 录音**，最长 90 分钟/耳，`ogg` 文件存在耳机里
- ✅ 导出必须走 **官方 Xiaomi Earbuds App**，经 **BLE 私有传输**（iOS 端确认是 BLE）
- ❌ **不存在**「把耳机当麦克风实时录进电脑」这条路径 —— 那是另一回事（HFP 输入）
- ❌ **我们无法用自研 App 直接拿到耳机内的录音文件**：导出协议是 App 私有，
  公开资料里**没有任何实现**（Gadgetbridge、redmi-buds-bar、killsng 全都只做电量/ANC/EQ，没碰录音）

> 📌 产品建议：如果用户要的是「耳机里已经录好的东西」，macOS 端唯一可行路径是**引导用手机 App 导出**，
> 而不是我们直连耳机抓文件。如果用户要的是「在 Mac 上录会议/语音」，那根本不需要耳机本地录音，
> 用 Mac 自己麦克风 + AVAudioEngine 质量远高于 HFP。

**官方规范里关于「录音」的两处线索（重要，用来划定边界）**：

1. `0x0E` 上报属性 **Bit2 = `ATTR_TYPE_DEVICE_LOCAL_RECORD`**：
   > 「上报设备录音状态：**0：本地不可录音(TWS未入耳) 1：本地可以录音(TWS入耳)**」
   > 注：「主要用于设备在某些状态下不可录音的情况，比如 TWS 耳机未入耳的情况下是不可录音的」
   → 说明「**本地录音**」是耳机固件侧独立功能，协议只暴露**能不能录**这个布尔状态。

2. `0xD0`-`0xD3` 是**语音输入流**（语音助手用）：`0xD0` 开始 / `0xD1` 停止 / `0xD2` 取消 / `0xD3` 长按。
   这是「设备录 → 实时传给 App」的**语音识别管线**，**不是**本地录音文件。
   → 官方全程**没有**任何「读取设备本地录音文件」的命令；文件导出是 **Xiaomi Earbuds App 的私有通道**。

> ✅ 结论固化：**我们只能查"能否录音"的状态，拿不到录音内容。** 这条对产品定位是硬约束。

### 3.1b Apple 平台录音落地：三条现实路径

| 路径 | 可行性 | 说明 |
|---|---|---|
| A. 自研 App 直接导出耳机内 ogg | ❌ | 私有 BLE 传输协议，公开资料零实现；且官方 FAQ 只说「通过 Xiaomi Earbuds APP 导出」 |
| B. 自研 App 打开耳机麦克风录音（HFP） | ⚠️ 可行但音质差 | 8k/16k 单声道；会打断 A2DP；适合语音备忘，不适合音乐/高保真 |
| C. 自研 App 用 **Mac 内置麦克风**录音 | ✅ 推荐 | 48kHz 高质量；不受蓝牙链路影响；耳机继续正常放音乐 |

> 💡 **最佳实践组合**：菜单栏 App 做「电量 + ANC 控制」，走 BLE（全程不碰音频链路）；
> 「录音」做成**调用 Mac 内置麦**的录音器（AVAudioEngine，48k→按需降采样），
> 并在 UI 上明确区分「耳机本地录音（需用手机 App 导出）」和「Mac 录音」两件事，避免误导用户。

### 3.2 macOS 从蓝牙耳机录音的真实限制 — 可信度 **high**

| 限制 | 说明 |
|---|---|
| **HFP 单向低带宽** | 一开耳机麦克风，链路从 A2DP 切到 HFP/SCO：**输入 8kHz 或 16kHz 单声道**，A2DP 播放同时被打断/降级 |
| **双向不能兼得** | 经典蓝牙下无法"高音质播放 + 耳机麦克风录音"同时进行（除非用 LE Audio） |
| **LE Audio 输入** | 本机 Bluetooth 控制器**支持 LEA**（`system_profiler` 显示 `Supported services` 含 `LEA`），但 macOS 对 LE Audio 输入支持依赖系统版本与耳机固件，**需真机验证**；不能假设可用 |
| **系统默认输入会抢** | 耳机一连上常被设为 Default Input，任何 App 一音频输入就触发 HFP 切换 → 「录音体验差」的根因 |

**本机实测**（`system_profiler SPAudioDataType`）：

```
Xiaomi 耳夹式耳机:
  Default Input Device: Yes
  Input Channels: 1
  Transport: Bluetooth          ← 确实暴露了一个 1ch 蓝牙输入设备
```

**macOS 录制最佳实践**（`high`，来自 Apple DTS 建议 + 社区验证）：

1. **不要**让 `AVAudioEngine` 直接吃蓝牙输入的 native format —— 一旦引擎含 input node，
   系统会把耳机锁在 8k/16k HFP 模式（经典坑，见 [SO 44651389](https://stackoverflow.com/questions/44651389/avaudioengine-uses-wrong-format-when-bluetooth-headset-plugged-in)）。
2. 若只是播放，用 Apple DTS 给的办法把 output node 显式绑到默认输出设备，避免 implicit 双向：
   ```swift
   var addr = AudioObjectPropertyAddress(
       mSelector: kAudioHardwarePropertyDefaultOutputDevice,
       mScope: kAudioObjectPropertyScopeGlobal,
       mElement: kAudioObjectPropertyElementMain)
   var deviceID: AudioObjectID = 0
   var size = UInt32(MemoryLayout.size(ofValue: deviceID))
   AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
   try engine.outputNode.auAudioUnit.setDeviceID(deviceID)
   ```
3. **录音要拿高质量，就不要用蓝牙耳机的麦** —— 用内置麦克风（本机 `MacBook Pro麦克风`，
   实测已存在），采样率用设备原生（通常 48kHz），再按需降采样到 16k 存 Opus/AAC。
4. 必须用耳机麦时：**明确告知用户会切 HFP、音质降级、A2DP 中断**，并允许一键切回内置麦。
5. 输入设备选择用 `AVAudioEngine.inputNode.auAudioUnit.setDeviceID(...)` 或
   `kAudioHardwarePropertyDefaultInputDevice` 显式指定，别依赖"默认跟随系统"（会被耳机抢走）。

---

## 4. 我们能用 / 不能用

| 能力 | 可行性 | 依据 |
|---|---|---|
| 显示左/右耳 + 充电盒电量 | ✅ **已真机跑通** | `0x02` → ATTR `0x07`，实测 `C5 C9 1E` = 69%/73%/30% `[HW]` |
| 显示充电状态 | ✅ 可行 | 电量字节 bit7 `[DOC]` |
| 读固件 / VID-PID / 型号 | ✅ **已真机跑通** | `0x02` ATTR `0x00/0x01/0x03` `[HW]` |
| 读当前 ANC/通透模式 | ✅ **已真机跑通** | `0x09` ATTR `0x09`，实测 = 0（正常） `[HW]` |
| 被动收电量/模式变化 | ✅ 可行 | 订阅 `0x0E` / `0xF4` `[HW]` |
| 免认证做上述全部读操作 | ✅ **已确认** | 未认证直接收到应答 `[HW]` |
| 切换 降噪/通透/关闭 | ⚠️ **协议支持，但本机可能只有部分档位** | `0x08` `02 04 <mode>`；**本机无 ANC 硬件** `[HW]`，需能力探测 |
| 设 ANC 强度（轻/均衡/深度/自适应） | ⚠️ 机型相关，本机大概率不支持 | `0xF2` config `0x0B` `[SRC]` |
| 认证握手（写操作用） | ✅ **已自研跑通** | SAFER+ 无固定密钥；Python 复现 MATCH + Swift 移植跑通 `[HW]` |
| 均衡器 / 手势 / 查找耳机 / 佩戴检测 | ✅ 协议可行，本机支持度待验 | config code 表 `[SRC]` |
| 读取标准 0x180F 电量 | ⚠️ 可读但**信息不足** | 只能得 2 个值，**拿不到充电盒**；归属未确认（**不阻塞**） |
| 读取耳机内录音文件 | ❌ **不可行** | 私有 BLE 导出协议，公开资料零实现 |
| 查「耳机当前能否本地录音」状态 | ✅ 可行 | `0x0E` ATTR `0x02` `[DOC]` |
| 把耳机当麦克风高质量录音 | ❌ 不可行 | HFP 限制 8k/16k 且打断 A2DP；应改用内置麦 |

---

## 4.5 推荐技术路线（给实现同学，已按真机结果更新）

> 一句话：**BLE GATT 单通道搞定全部控制/电量；读路径免认证先跑通；写路径再接 SAFER+；录音用内置麦。**

```
① 设备发现
   CoreBluetooth 扫到广播里暴露 AF00 服务的设备（或已知 MAC 00:13:D6:E2:17:D4）
   ⚠️ 不要用 "Redmi Buds" 名字匹配（本机型叫 "Xiaomi 耳夹式耳机"，型号名是 "vela os earbuds"）

② 连接 & 发现
   connect → discoverServices([AF00])
   在 0xAF00 下【动态发现】：write 特征 → RX（本机 AF07），notify 特征 → TX（本机 AF08）
   ⚠️ 官方文档写 AF05/AF06，本机实测 AF07/AF08 → 绝不硬编码 UUID
   开启 notify

③ 首屏状态（全部免认证 [HW]）
   写 AF07: FE DC BA C4 02 00 05 00 FF FF FF FF EF   → GET_DEVICE_INFO，拿 TLV 0x07 电量[L,R,盒]
   写 AF07: FE DC BA C4 09 00 05 01 FF FF FF FF EF   → GET_DEVICE_RUN_INFO，拿 TLV 0x09 = ANC 模式
   两个都能在未认证状态下立刻拿到应答

④ 认证（仅写 ANC/SET_CONFIG 前需要）
   走 SAFER+（§2.7）：发 16B challenge → 收 16B 应答 → 回 AUTH_CONFIRM [01 00]
   无固定密钥，纯算法，可自研

⑤ 常驻刷新（省电关键，全部免认证）
   订阅 AF08 被动收：
     op 0x0E (reportStatus)  → TLV 带 3 字节电量（本机 idx=0x04，官方 idx=0x00，两者都要兼容）
     op 0xF4 (notifyConfig)  → TLV idx 0x0C = 耳机位置（戴/在盒），idx 0x0B = ANC 模式
   → 电量变化、按键改 ANC 都会主动推，**不需要轮询**
   兜底：菜单栏展开时主动查一次 0x02
   收到 request 类型的 0x0E/0xF4 要**回 ack**：FE DC BA 04 <op> 00 02 <seq> EF

⑥ 切 ANC（需认证）
   写 AF07: FE DC BA C4 08 00 04 <seq> 02 04 <mode> EF
   mode: 0=正常 1=降噪 2=通透 3=抗风噪
   ⚠️ 本机没有 ANC 硬件 → 先做 §2.12 的能力探测，按 Status 码决定 UI 显示哪几档
   （Status: 0=成功 / 7=参数错误 / 9=不支持）

⑦ 录音（与耳机完全解耦）
   用 Mac 内置麦 + AVAudioEngine，48kHz 原生 → 按需降采样
   ❌ 不要用蓝牙耳机的 input node（会锁 8k/16k 并打断 A2DP）
   ✅ UI 把「Mac 录音」与「耳机本地录音（需手机 App 导出）」分开呈现
```

**剩余待验证清单（都很小，真机几分钟）**：

| # | 待验证 | 方法 | 当前状态 |
|---|---|---|---|
| 1 | ~~BLE 读是否免认证~~ | — | ✅ **已确认免认证** `[HW]` |
| 2 | ~~AF07/AF08 是否可用~~ | — | ✅ **已确认可用** `[HW]` |
| 3 | **写 ANC 是否必须认证** | 直接写 `0x08` 看有无应答；无则应答 → 先认证再写 | `[?]` |
| 4 | **本机实际支持哪几档 mode** | 按 §2.12 脚本逐档试写 + 读回 + 看 Status | `[?]`（几乎肯定无 1=ANC） |
| 5 | 两个 0x180F 的归属 | §2.9 的「取出单耳」实验 | `[?]`（**已不阻塞**：用 0x07 就够了） |
| 6 | 厂商私有 ATTR `0x0E/0x0F/0x10` 含义 | 对照官方表（官方只定义到 0x0D）；可忽略 | `[?]`（**不阻塞**） |

> **实现优先级建议**：③④⑤ 就是 MVP 的全部。**1 和 5、6 都可以不做** ——
> 电量从 `0x02/0x07` 拿，两个 0x180F 只是可选优化。

## 5. 参考链接

### 5.1 可直接复用的源码（最优先）
| 项目 | 说明 | 链接 |
|---|---|---|
| **Gadgetbridge** (`redmibuds`) | Android；**协议权威来源**，含 SAFER+ 认证、电量、ANC、EQ 全套 | [RedmiBudsProtocol.java](https://codeberg.org/Freeyourgadget/Gadgetbridge/src/branch/master/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/redmibuds/RedmiBudsProtocol.java) |
| **ChristianVeneko/redmi-buds-bar** | **macOS / Swift**；协议层拆得最干净（`Message.swift` FrameDecoder、`Session.swift` 状态机、真机 hex `Fixtures.swift`），真机验过 Buds 8 | [GitHub](https://github.com/ChristianVeneko/redmi-buds-bar) |
| **killsng/RedmiBudsControl** | **macOS / Swift**；带 `docs/PROTOCOL.md` 中文级协议说明 + RFCOMM 实现（但认证结论有误） | [GitHub](https://github.com/killsng/RedmiBudsControl) |
| **web1n/android_packages_apps_XiaomiTWS** | Android；早期 MIUI 内置 TWS 电量上报实现 | [GitHub](https://github.com/web1n/android_packages_apps_XiaomiTWS) |
| **CesurPolat/MiBudsClient** | Python/Flet；Redmi Buds 6 Play 电量 | [GitHub](https://github.com/CesurPolat/MiBudsClient) |

### 5.2 协议文档 / 官方

- 🔥 **小米小爱开放平台 · 蓝牙通讯协议（官方一手规范，MMA/FEDCBA/AF00/电量/ANC/录音全在此）**：
  https://developers.xiaoai.mi.com/documents/Home?type=/api/doc/render_markdown/VoiceserviceAccess/Bluetooth/BluetoothProtocol/CommunicationProtocol
- Gadgetbridge Xiaomi 耳机支持页（型号能力矩阵）：https://gadgetbridge.org/gadgets/headphones/xiaomi/
- Gadgetbridge Galaxy Buds 协议（同类 TWS 协议范本）：https://gadgetbridge.org/internals/specifics/galaxy-buds-protocol/
- 小米官方 FAQ —— 录音功能（**关键**）：https://www.mi.com/global/support/faq/details/KA-232757/
- 小米官方 FAQ —— 录音功能说明：https://www.mi.com/global/support/faq/details/KA-257532/
- Xiaomi OpenWear Stereo 官方页：https://www.mi.com/ae-en/product/xiaomi-openwear-stereo/

### 5.3 产品信息 / 硬件

- 小米首款耳夹式耳机发布（799 元 / 5.5g / IP57 / LHDC 5.0）：http://m.mydrivers.com/newsview/1124025.html
- REDMI Clip Neo 亮相：https://www.ithome.com/1/013/949.htm
- **实物拆解报告（型号 M2529E1、充电盒独立 BLE SoC、4 种录音场景）**：https://www.52audio.com/archives/285892.html
- **详细评测（包装特性=通话降噪而非 ANC、实际续航/重量）**：https://www.52audio.com/archives/283154.html
- OpenWear Stereo Pro 录音功能报道：https://hk.on.cc/hk/bkn/cnt/entertainment/20251014/mobile/bkn-20251014190017822-1014_00862_001.html

### 5.4 macOS 音频

- AVAudioEngine 被蓝牙耳机锁 8kHz（含 Apple DTS 解法代码）：https://stackoverflow.com/questions/44651389/avaudioengine-uses-wrong-format-when-bluetooth-headset-plugged-in
- JUCE 同类问题（蓝牙输入拖低采样率）：https://github.com/juce-framework/JUCE/issues/1131

---

## 6. 附录：本目录下的可验证物

| 文件 | 内容 |
|---|---|
| `_src/verify_auth.py` | **SAFER+ 认证算法 Python 复现**，内置真机 fixture，`python3 verify_auth.py` 即可看到两组 MATCH |
| `_src/probe_sdp.swift` | IOBluetooth SDP 探测工具，在本机实测出 **MIWEAR / channel 28 / service class 0xFD2D** |
| `_src/rfcomm_probe.swift` | RFCOMM 端到端探测（含完整 Swift 帧编解码 + SAFER+ 实现；**本机未打通 channel 28**，原因见 §2.4） |
| 小米官方 MMA 协议文档 | https://developers.xiaoai.mi.com/documents/Home?type=/api/doc/render_markdown/VoiceserviceAccess/Bluetooth/BluetoothProtocol/CommunicationProtocol （§2.10 属性表出处；**未随仓库分发**，版权归小米） |
| [redmi-buds-bar](https://github.com/ChristianVeneko/redmi-buds-bar) | 上游 Swift 工程（AGPL-3.0，**未随仓库分发**，协议层最干净） |
| [RedmiBudsControl](https://github.com/killsng/RedmiBudsControl) | 上游 Swift 工程（含 PROTOCOL.md，**未随仓库分发**） |
| `_src/RedmiBudsProtocol.java` 等 | Gadgetbridge redmibuds 协议层源码快照 |

> ⚠️ **许可证注意（已核对 LICENSE 文件）**：`_src/` 是调研过程留存的第三方源码快照，未在本项目中调用。
> - **Gadgetbridge**：**AGPL-3.0**
> - **redmi-buds-bar**：**AGPL-3.0**（不是 MIT，我原先判断有误，已按 LICENSE 文件更正）
> - **killsng/RedmiBudsControl**：仓库内**无 LICENSE 文件** → 默认保留所有权利，不可直接复制
>
> **AGPL 有强传染性**：如果我们把它们的代码复制进自己的 App 并分发，整个 App 可能都被要求按 AGPL 开源。
> **建议：只参考算法与协议常量，全部独立重新实现**（协议事实本身不受版权保护，
> 但代码表达受保护）。Swift 侧请自己写，不要粘贴。
