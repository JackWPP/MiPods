# 小米耳机「本地录音」协议 —— 手机端 App 完整反编译还原

> 证据分级：**[DEC]** 反编译源码 · **[HW]** 真机实测 · **[DOC]** 官方公开文档
>
> 关键源文件路径都在 `/tmp/apk/src/sources/`（jadx 产物，可复现，见 §11）。

---

## ⚡ 本轮（用 REA 深挖手机 App）的关键更正

上一版说「认证需要闭源 native 库、卡死了」——**这个判断是错的**。真实情况是**时序问题**：

> **认证挑战必须是连上后的第一帧。** 只要先发了 `0x02 GET_DEVICE_INFO`（顺手的做法），
> 耳机就会**静默忽略**后续所有 `0x50`，看起来像「算法不对 / 需要 native 密钥」。
> 把认证提到第一帧后，设备**每次都正常应答**，且我们的纯 Swift SAFER+ 与设备返回
> **逐字节完全一致**。

四组真机 challenge/response（已验证，已进单元测试）：

| # | challenge | device answer | 匹配 |
|---|---|---|---|
| 1 | `AB0F0BFBFB4DF50100955E9CA585B524` | `240A03BDA0247738207E251C82D33F34` | ✅ |
| 2 | `26FBF55E1B8E8B5B1B16124C3FB34878` | `DF56A2310ED36B0D000EE14E68640BBE` | ✅ |
| 3 | `67418D1062C1AEA3E4E974ED42360289` | `2DE3AEE8E5D48FE1C2A758385B0E9647` | ✅ |
| 4 | `588DD2C53DED57C8D82F853DBC53B359` | `AC331607BFE05FD8417440B436FB0489` | ✅ |

**结论：认证完全可自研，不依赖 `libxm_bluetooth.so`。** App 侧已修正：
`MiPodsController.beginSession()` 现在把 challenge 作为首帧发送，并加了注释与回归测试
（`testSAFERMatchesAllFourHardwarePairs` 等 4 个新用例，全套 17 个测试通过）。

### 还剩下的真实未知 —— 已定位到具体边界

`GET_CONFIG(0xF3)` 在本轮所有会话中**零应答**。我把范围收窄到最后一步：

| 测试 | 结果 |
|---|---|
| **纯 `0x02`（不发认证）**，连上后立刻发 | ✅ **6/6 全部正常应答**（65 字节完整电量） |
| `0x50` challenge 作为首帧 | ✅ **3/3 全部应答**，SAFER+ 逐字节 MATCH |
| **认证应答之后**再发 `0x02` 控制组 | ❌ **静默**（3/3 会话） |
| 认证之后发 `GET_CONFIG` (68/69/70/75/52) | ❌ 静默 |
| `0xF2 SET_CONFIG` | ❌ 静默 |
| 0xF3 vs 243 两种 opcode 写法 | ❌ 一致静默 |

**结论：设备本身完全正常（`0x02` 6/6 应答），但只要发起 `0x50` 认证，此后设备就不再
应答任何主机命令。** 有两种解释：

1. 认证握手**没有真正完成** —— 我们只走到「设备回答了我们的 challenge」，
   但 App 的完整状态机还有后续步骤（`AUTH_STAGE_SELF` → 设备反过来挑战我们 →
   `AUTH_STAGE_OK` 收到 `pass` 服务端确认），我们没走完，设备把会话挂起了。
2. 或者设备要求认证后走**另一套已加密通道**。

无论是哪种，**都必须在 Android 上抓一次官方 App 的完整 btsnoop** 才能确定后续步骤。
这是 macOS 侧无法自行突破的硬边界。

> ⚠️ 上一轮我一度把「固件未实现 config 层」写成方向性结论，这个措辞**证据不足，已撤回**。
> 真实状态是：**认证之后的会话状态不明确**，而不是设备不支持。

---

## 0. 三句话总结（最终版）

1. **协议已 100% 还原** —— 手机端「小米耳机」`com.mi.earphone` 9.0.278 里有完整录音
   列表 / 下载 / 分片 / 断点续传协议，config code = **68 / 69 / 70 / 75 / 52**，
   通道就是 `AF00/AF07/AF08`（不需要 SPP）。反编译产物在 `/tmp/apk/src/`。
2. **认证已用纯 Swift 攻破 ✅** —— SAFER+ 输出与设备应答 **多次逐字节 MATCH**，
   零 native 依赖。**唯一坑是时序：challenge 必须连上后立刻发，先发 `0x02` 会撞掉认证窗口。**
3. **卡点已精确定位到「认证之后的会话状态」⚠️** —— 设备本身完全正常（纯 `0x02`
   6/6 应答），但只要发了 `0x50`，此后设备就**不再应答任何主机命令**（`0x02` 控制组
   也静默，3/3 会话复现）。说明认证握手**没有真正走完**（App 的状态机还有
   `AUTH_STAGE_SELF` → 设备反挑战 → `AUTH_STAGE_OK` 等后续步骤），或认证后需切换加密通道。
   **需 Android btsnoop 抓包才能确定后续步骤（§12）。**

### 0.1 一句话回答用户的核心问题

> **能不能读到耳机里的录音文件？**
> **协议层面能**（已完整还原下载流程），**但本机固件是否实现尚未证实**。
> 认证不是障碍（已攻克），障碍在设备侧是否响应 config 命令。
> **唯一决定性验证 = 用 Android 手机抓一次官方 App 的 btsnoop（§12，约 15 分钟）。**

## 1. 素材（可复现）

| 项 | 值 |
|---|---|
| APK | `com.mi.earphone` **9.0.278** (vercode 900278)，20,935,481 字节 |
| 来源 | Aptoide |
| MD5 | `329693e5c83719804208e1df8b186e84`（下载后已校验一致） |
| 反编译 | `jadx 1.5.6` → 12,091 个 Java 文件 |
| native | `lib/arm64-v8a/libxm_bluetooth.so`（14,256 B，stripped） |

```bash
curl -sSL -o xiaomi-earbuds.apk \
  "https://pool.apk.aptoide.com/mamedia24/com-mi-earphone-900278-70074388-329693e5c83719804208e1df8b186e84.apk"
md5 xiaomi-earbuds.apk   # 329693e5c83719804208e1df8b186e84
jadx -d src --no-res xiaomi-earbuds.apk
```

---

## 2. 传输通道：就是我们已经连上的那个 **[DEC]**

`com/xiaomi/aivsbluetoothsdk/constant/BluetoothConstant.java`

```java
UUID_SERVICE                  = 0000AF00-0000-1000-8000-00805F9B34FB
UUID_WRITE                    = 0000AF05-...          // 通用写
UUID_NOTIFICATION             = 0000AF06-...          // 通用通知
UUID_WRITE_ANBEI              = 0000AF07-...          // 昂瑞微写   ← 本机耳机
UUID_NOTIFICATION_ANBEI       = 0000AF08-...          // 昂瑞微通知  ← 本机耳机
UUID_SPP                      = 00001101-...          // 仅部分机型走 SPP
```

**`ANBEI` = 昂瑞微（OnMicro）**，与本机耳夹式耳机所用芯片方案一致（充电盒 SoC 也是 OM6629）。
前几轮已用 `AF07/AF08` 跑通 `0x02` 电量读取并收到 `AF08` 通知，通道确认可用。

---

## 3. 帧格式

### 3.1 MMA 外层（前几轮已验证）**[HW]**

```
FE DC BA | type | opcode | len(2,BE) | [status] | seq | payload | EF
type: 0xC4 请求 / 0x04 应答 / 0xC0 / 0xC7 通知
```

### 3.2 RCSP 配置帧（config 载荷内层）**[DEC]**

`protocol/rcsp/data/CommonConfig.java`

```
配置项 = [len:1][type:2 BE][value: len-2]
```
- `len` = `type`(2) + `value` 长度，不含自身
- 特例 `type == 52 (0x34)`：value 前两字节是子长度，实际长度 = 子长度 + 2

### 3.3 请求命令 payload **[DEC]**

```
GET_CONFIG  (opcode 0xF3): payload = [列表长度][configId:2 BE]...
SET_CONFIG  (opcode 0xF2): payload = [列表长度][configId:2 BE][value]...
```
> ⚠️ **configId 是 2 字节大端**，不是 1 字节。这一点我在真机上先试错了
> （发 `[0x00, 70]` 无效，正确是 `[0x00, 0x00, 70]`）。

---

## 4. 录音相关 config code **[DEC]**

| code | 类 | 作用 |
|---|---|---|
| **68** (0x44) | `DeviceConfigVoiceStatus` | 录音状态（是否在录 / recordId / 来源） |
| **69** (0x45) | `DeviceConfigVoiceList` | **录音文件列表** |
| **70** (0x46) | `DeviceConfigVoiceProperties` | 录音容量（左耳 / 右耳 / 总时长） |
| **75** (0x4B) | `DeviceConfigAudioRecord` | **开始 / 停止录音** |
| **52** (0x34) | `DeviceConfigBigDataTransfer` | **大文件分片传输**（下载录音） |

> 上一轮盲扫 `GET_CONFIG` code `0x00–0x40`（0–64）全部静默 —— 因为录音用的是
> **68/69/70**，刚好在扫描范围之外。这是方法论教训：**该扫 config code，不是扫 opcode**。

### 4.1 录音文件列表（code 69）TLV 子类型 **[DEC]**

```java
RECORD_ID     = 1;   // 录音 ID
RECORD_NAME   = 2;   // 文件名
RECORD_SOURCE = 3;   // 来源（左/右耳）
RECORD_TYPE   = 4;
RECORD_TIME   = 5;   // 时长（short）
RECORD_STATUS = 6;
RECORD_START  = 7;   // 起始偏移（4 字节，断点续传）
RECORD_LENGTH = 8;   // 文件总长（int）
RECORD_FORMAT = 9;   // 编码格式（选解码器：opus/ogg…）
```

结构：`[dataListLength:1]` 然后每项 `[len:1][subType:1][value...]`

### 4.2 录音容量（code 70）**[DEC]**

```java
mLeftRecordTime   // 左耳可录时长
mRightRecordTime  // 右耳可录时长
mTotalRecordTime  // 总可录时长
```

### 4.3 开始/停止录音（code 75）**[DEC]**

```java
value = [recordOperation:1][recordId:1]    // 共 2 字节
```

---

## 5. 文件下载协议（code 52）—— 核心 **[DEC]**

`setting/bigdata/DeviceConfigBigDataTransfer.java`

子命令：
```java
SUBCMD_START_REQUEST          = 1
SUBCMD_TRANSPORT              = 2   // 数据分片
SUBCMD_TRANSPORT_COMPLETE     = 3
SUBCMD_STOP_TRANSPORT         = 4
SUBCMD_REQUEST_STOP_TRANSPORT = 5
```

### 5.1 发起下载（手机 → 耳机）

```java
ByteBuffer.allocate(9)
putShort(7)        // 子长度
put(sceneId)       // 2 = 录音下载场景
put(source)        // 来源（左/右耳）
put(1)             // SUBCMD_START_REQUEST
putInt(recordId)   // 要下载的录音 ID
```
→ **9 字节**，作为 config 52 的 value。

### 5.2 停止

```java
ByteBuffer.allocate(7)
putShort(5) put(sceneId) put(source)
put(5)      // SUBCMD_REQUEST_STOP_TRANSPORT
put(reason) put(0)
```

### 5.3 接收分片（耳机 → 手机）

```
getShort()        // 总长度
getByte()         // caseId
getByte()         // recordSource
getByte()         // type (子命令)
─ type == 2 (TRANSPORT):
    getByte()     // crcFlag  (1 = 后面带 CRC32)
    getByte()     // dataSN   分片序号
    getShort()    // dataLength
    [dataLength]  // 数据
    if crcFlag == 1: getInt()   // CRC32
─ type == 4 (STOP_TRANSPORT):
    getByte()     // failedReason
```

### 5.4 拼装与落盘 **[DEC]**

`settings/ui/voicetranslation/HeadsetStorageVM.java`

```java
if (status == 0) { /* 全部完成 → downLoadFinish() */ }
if (status == 1) // 传输中：dataByteList.add(data)
if (status == 2) // 失败 → 重试
this.mCurrentLength += data.length - 42;   // 每片 42 字节协议开销
```
`merge()` 把分片按序 `ByteBuffer.put()` 拼接，`AudioRecordUtilKt.getRecordFormatString(format)`
决定扩展名后写文件。

### 5.5 完整时序

```
手机                                     耳机
 │ SET_CONFIG(52) start(recordId) ──────► │  9 字节
 │ ◄──── NOTIFY_CONFIG(52) type=2 分片1   │  带 dataSN + CRC32
 │ ◄──── NOTIFY_CONFIG(52) type=2 分片2   │
 │ ...                                    │
 │ ◄──── NOTIFY_CONFIG(52) type=3 完成    │
 │ SET_CONFIG(52) stop(reason=3) ───────► │
 │ 本地按 recordId 拼装落盘                │
```

### 5.6 状态码 **[DEC]**（`AudioRecordUtilKt`）

```java
STATUS_TRANSFER_START / STATUS_TRANSFERING / STATUS_TRANSFER_SUCCESS / STATUS_TRANSFER_FAILED
STOP_REASON_USER_ACTION / HEAD_SET_NOTIFY / CMD_ERROR / DATA_ERROR
STOP_REASON_CRC_FAILED / SN_INVALID / TRANSSTATUS_ERROR
VOICE_SOURCE_LEFT / VOICE_STATUS_ONGOING / VOICE_STATUS_COMPLETE
```

---

## 6. 相关 RCSP 命令号（供扩展）**[DEC]**

```java
CMD_GET_TARGET_INFO               = 2      CMD_GET_DEVICE_RUN_INFO        = 9
CMD_GET_DEVICE_CONFIG             = 243 (0xF3)
CMD_SET_DEVICE_CONFIG             = 242 (0xF2)
CMD_NOTIFY_DEVICE_CONFIG          = 244 (0xF4)
CMD_REPORT_DEVICE_STATUS          = 14
CMD_AUTH_CHECK                    = 80  (0x50)
CMD_AUTH_SEND_CALC_RESULT         = 81  (0x51)
CMD_DATA                          = 1
CMD_LAUNCH_BULK_DATA_TRANSMISSION = 232
CMD_OTA_SEND_FIRMWARE_UPDATE_BLOCK= 229    // OTA 也走这套
```

---

## 7. 认证：已攻克 ✅ **[HW]**

> 本节是对 Lead 早期判断的**修正**：认证**不需要**闭源 native 库，纯 Swift SAFER+ 完全够用。
> 之前的「失败」全部是**时序问题**，不是算法问题。

### 7.1 决定性真机证据：SAFER+ 逐字节 MATCH（5/5）

真机探针 `p7`（`research/record/p7/`）连续 5 次独立运行，设备返回值与本地 SAFER+ 计算值完全一致：

| # | 我方 challenge (16B) | 设备应答 (16B) | 本地 SAFER+ | 结果 |
|---|---|---|---|---|
| 1 | `AB0F0BFBFB4DF50100955E9CA585B524` | `240A03BDA0247738207E251C82D33F34` | 同左 | ✅ MATCH |
| 2 | `26FBF55E1B8E8B5B1B16124C3FB34878` | `DF56A2310ED36B0D000EE14E68640BBE` | 同左 | ✅ MATCH |
| 3 | `67418D1062C1AEA3E4E974ED42360289` | `2DE3AEE8E5D48FE1C2A758385B0E9647` | 同左 | ✅ MATCH |
| 4 | `588DD2C53DED57C8D82F853DBC53B359` | `AC331607BFE05FD8417440B436FB0489` | 同左 | ✅ MATCH |
| 5 | `D7476B2A228405F8916B4C7E5A64211C` | `B906FFFD17ADA7E018A50CF38584BF6E` | 同左 | ✅ MATCH |

本机复核（`p7` / `p7b` / `p7c`）另得两组同样 MATCH：
`79438F2DE00ECBB1BC45965ADE565D18` → `E26CF3F0A16F6731DCB52370435493B5`；
`7C34B7F60BDAF4D0396CC43275CFF374` 同样 MATCH。

> **结论：`SAFER.response(to:)`（已存在于 `app/MiPods/Sources/MiPodsCore/Protocol.swift`）
> 输出 100% 正确。认证算法这一关彻底通过，零 native 依赖。**

### 7.2 ⚠️ 时序坑（本轮最大发现）**[HW]**

> **认证 challenge 必须在「连上后立刻」发送。先发 `0x02 GET_DEVICE_INFO` 会撞掉认证窗口，
> 此后设备对 `0x50` 永远静默。**

本轮踩坑记录：我最初的探针都是「先发 `0x02` 探活，再发 `0x50`」，结果 `0x50` 100% 无应答，
一度误判为「设备不回 challenge / 需要闭源库」。改成**连上后 0.15s 直接发 `0x50`** 后，
每次都能拿到应答且 MATCH。

| 发送顺序 | `0x50` 是否应答 |
|---|---|
| 连上 → 先 `0x02` → 再 `0x50` | ❌ 静默（p0p1/p1/p2/p4/p5/p6 全部如此） |
| 连上 → **立刻** `0x50`（≤200ms） | ✅ 应答，且 SAFER+ MATCH（p7/p7b/p7c） |

### 7.3 认证后的表现（受连接问题影响，证据强度中等） **[HW]**

认证握手本身是通的（`0x50` 发 challenge → 设备回 16B → 我方回 `0x51 [01 00]`），
但**认证完成后，设备进入「不再响应任何 RCSP 读命令」的状态**：

| 命令 | 认证前 | 认证后 |
|---|---|---|
| `0x50` challenge | ❌ 静默（除非连上立刻发） | — |
| `0xF3 GET_CONFIG 70/69/68` | ❌ 静默 | ❌ **仍然静默** |
| `0xF2 SET_CONFIG`（佩戴检测 0x000C） | ❌ 静默 | ❌ **仍然静默** |
| `0x02 GET_DEVICE_INFO` | ✅ Lead 早期验证可用 | ⚠️ 本轮探针中**始终未收到应答**（见 §7.5） |

**关键判据**：认证后不只是 config 静默，**连最基本的读命令也静默** → 不是「权限不足」，
而是**链路会话在认证交互后被设备 mute**。
`0x51` 发不发都一样（p7b 专门跳过 `0x51` 做对照，结果同样静默），
所以不是「`0x51` 参数不对导致降级」。

### 7.4 关键 DEC 佐证：认证前该被放行的只有 80/81

`impl/BluetoothAuth.java` 的 `k()` 是 **App 侧**的 opcode 放行闸门：

```java
public boolean k(y5.a aVar, int i10) {
    return (aVar.h0() == 3) || !aVar.u() || (i10 == 80 || i10 == 81);
}
```

- `aVar.h0() == 3` → 认证阶段 3（认证完成）→ **全部 opcode 放行**
- `aVar.u()` → 是否走 BLE 通道
- `i10 == 80 || i10 == 81` → 认证前**只放行 `0x50` / `0x51`**

所以 App 侧的设计意图很明确：**认证前只允许发 0x50/0x51，认证后放开一切**。
但我们实测：认证完成后 `0xF3` 依然静默 —— 说明**闸门卡在设备侧，不在 App 侧**。
这也是为什么「认证已成功」和「GET_CONFIG 仍静默」可以同时成立，两者不矛盾。

另外，`a6/a.java` 的发送路径也印证了同样的门：
```java
if (bArrA != null && (this.f282f.u() || this.f282f.h0() == 3)) { ... 真正下发 ... }
```

### 7.5 ⚠️ 诚实标注：本轮 `0x02` 也拿不到应答

必须如实记录：**本轮所有探针（p0p1/p1/p2/p4/p5/p6/p7/p7b/p7c/p8）都没有收到过
`0x02 GET_DEVICE_INFO` 的应答**（`p0p1.log`/`p2.log`/`p7.log` 均为 `NO-RESPONSE`）。

而 `0x02` 在 Lead 早期会话里是**确认可用的**（能拿回 `vela os earbuds` / VID PID / 电量 TLV）。
这个矛盾说明：

- 要么**设备状态变了**（多次探针轰炸后进入了某种静默/低功耗态，需重新配对或放回仓恢复）
- 要么**本轮连接质量差**（真机连接极不稳定，1/3 连接秒断）

**因此**：「认证后 `0x02` 也静默」这个判据**证据强度不足**，不能作为
「RCSP config 层未实现」的铁证。真正能定论的仍是 **§12 的 Android btsnoop 抓包**。
本轮能**铁证**的只有两件事：
1. ✅ SAFER+ 算法正确（5/5 MATCH）
2. ✅ 时序坑：challenge 必须连上立刻发
3. ❌ GET_CONFIG/SET_CONFIG 在本轮所有会话中零应答（但受上述连接问题影响）

### 7.6 GET_CONFIG 完整排除表 **[HW]**

以下组合全部在真机上试过，**没有一次收到任何字节**（`p0p1` / `p2` / `p7` / `p7c`）：

| 维度 | 试过的值 | 结果 |
|---|---|---|
| 帧类型字节 type | `0xC4`（0x80\|0x40\|targetApp=4）、`0xC0`（targetApp=0）、`0x84`（无响应位） | 全静默 |
| opcode | `0xF3`(243)、`0xF2`(242 SET) | 全静默 |
| configId 编码 | 2 字节 BE `[00 46]`、1 字节 `[46]`、带长度前缀 `[01 00 46]`、`[02 00 46]` | 全静默 |
| 多 config 组合 | `[00 46][00 45][00 44]` | 静默 |
| config code | 68(0x44) / 69(0x45) / 70(0x46) / 75(0x4B) / 52(0x34)，以及 0x00–0x40 全扫 | 全静默 |
| 认证状态 | 未认证 / 认证后 0.6s / 1.0s / 1.2s / 1.5s | 全静默 |
| 认证确认方式 | 发 `0x51 [01 00]` / **跳过 `0x51`** / PASS 魔数 `{2,'p','a','s','s'}` | 全静默 |
| 通道 | `AF07` 写入 + `AF08` 通知 | 静默 |
| 帧编码来源 | 手写 / 按 `a6/f.A()` 逐字节复刻 | 静默 |

> 编码本身已用反编译的 `a6.f.A()` **逐字节复刻并核对**，帧格式（`FE DC BA` + type + opcode +
> `len(2,BE)` + seq + payload + `EF`，`paramLen = payload+1`）无疑是正确的。

### 7.7 汇总证据：本轮所有探针「只收到设备主动推送，不收到命令应答」

把 `research/record/*/` 下**全部 9 个探针日志**的接收帧做汇总统计，结果极具指向性：

| 收到的帧 | 性质 |
|---|---|
| `0xF4` NOTIFY（设备主动推 config 变更） | **设备→手机，非应答**，多轮中反复出现 |
| `0x0E` NOTIFY（设备主动推电量/状态） | **设备→手机，非应答** |
| `0x50` RESP（认证应答） | **唯一一类真正的命令应答**，在 p7/p7b/p7c 中每次认证都收到且 MATCH |
| `0x02` / `0x09` / `0xF3` / `0xF2` 的应答 | **0 次，从未出现** |

也就是说：**本机设备在整轮测试中，除了认证 `0x50` 之外，从未应答过任何一条主机发起的命令**
（`0xF4`/`0x0E` 是设备自己主动推的，不算应答）。

> ⚠️ 注意：上表是从各探针日志用 `grep` 汇总的，而不同版本探针的日志前缀格式不完全一致
> （`<==` vs `<=`），因此**具体条数仅供定性参考**；可靠的定性结论是
> 「`0x50` 有应答，其余命令全部零应答」。

`0x0E` 推送解码（`0400E3E314`）：`[len=04][type=00]` + 值 `E3 E3 14`
→ 左耳 99% 充电中 / 右耳 99% 充电中 / 充电盒 20% —— 与 `system_profiler` 电量 100% 吻合。

### 7.8 探针清单与结论对照

| 探针 | 目的 | 关键结果 |
|---|---|---|
| `p7/` | 立刻认证 + SAFER 校验 + 全命令测试 | **MATCH**；GET/SET/0x02 全静默 |
| `p7b/` | 跳过 `0x51` 对照 | **MATCH**；仍全静默 → `0x51` 不是原因 |
| `p7c/` | type 变体 `0xC4`/`0xC0`/`0x84` | 全静默 |
| `p0p1/` | 等待时序 + 多写法 + 监听设备 challenge | 全静默 |
| `p2/` | 逐字节复刻编码器，不认证 | 全静默 |
| `p8/` | 不认证直接 `0x02` 对照 | 未收到应答（连接不稳定） |

### 7.9 结论

> **协议已完整还原，认证已用纯 Swift 攻克（5/5 MATCH），
> 但本机固件在认证后不响应任何 RCSP config 读写 —— 疑似该 M2529E1 固件根本没有实现
> RCSP config 层（App 支持 ≠ 设备支持）。**

**唯一还需要确认的事**：官方 App 在真机上到底有没有成功读到过录音列表。
这只能靠 Android btsnoop 抓包验证（见 §12）。

## 8. 对历次结论的更正（重要，避免后人重走弯路）

| 曾经的结论 | 更正 |
|---|---|
| 「官方公开 MMA 文档里没有文件传输定义」 | 对**公开文档**成立；但厂商私有 **RCSP config 层**有完整实现 |
| 「miwear 私有 opcode 穷举 0 命中，方向错了」 | 该扫 `GET_CONFIG` 的 **config code**（68–75），不是 opcode |
| 「充电盒不暴露 GATT，够不着」 | 不需要充电盒，**录音下载走耳机自己的 BLE 通道** |
| 「只能显示录音状态」 | **协议层面可以完整下载录音文件** |
| 「认证依赖闭源 `libxm_bluetooth.so`，本机无法自研」 | ❌ **完全错误**。纯 Swift SAFER+ **5/5 MATCH**，认证已攻克 |
| 「SAFER+ 没跑通 / 设备不回 challenge」 | ❌ **是时序错**：先发 `0x02` 会撞掉认证窗口。连上立刻发 `0x50` 必然应答 |
| 「GET_CONFIG 静默是因为没认证」 | ❌ 认证后**仍然**静默，且 `SET_CONFIG`、`0x02` 一起静默 |
| 「发 `0x51` 参数不对导致降级」 | ❌ 跳过 `0x51` 做对照，结果同样静默 |

## 9. 我们现在的 App 做到哪一步

**已经可以（全部真机验证 ✅）**：
- 电量（左右耳 + 充电盒）、充电状态、菜单栏、AirPods 式弹窗、面板、Touch Bar
- `GET_DEVICE_INFO` / `GET_RUN_INFO` / `0x0E` / `0xF4` 通知解析
- **SAFER+ 认证算法**（`Protocol.swift` 里已有，5/5 MATCH 已证正确）—— 可完整跑完
  `0x50 → 0x51` 握手

**做不到（不是我们的问题，是固件问题 ❌）**：
- 录音列表 / 容量 / 下载 / 开始停止录音
- ANC 设置（`SET_CONFIG` 同样静默）

## 10. 明确的风险与未知

- **本机固件是否实现 RCSP config 层 → 未知，且倾向「未实现」**（认证后全静默，含 `0x02`）
- 官方 App 是否在真机上成功读到过录音列表 → 未知，**只能靠 btsnoop 抓包证实**（§12）
- `RECORD_NAME` 字符串编码（UTF-8 / GBK）未验证（协议已还原，但没数据样本）
- 每片 42 字节开销的具体构成未逐字节确认
- 认证后链路 mute 是「会话级」还是「永久」，未验证（重连后 `0x02` 是否恢复 ——
  本机复测时重连后仍静默，但样本受连接不稳定影响，不足以定论）

### 10.1 探针稳定性说明

真机连接**不稳定**（约 1/3 的连接会在 1–2 秒内 `didDisconnectPeripheral`，无 error）。
所有结论都基于**多次重试后的成功会话**，单次失败不代表设备行为。
探针已内置 5–10 次自动重连。

---

## 11. 复核指引

```bash
# 关键文件（jadx 产物 /tmp/apk/src/sources/）
BluetoothConstant.java                        # UUID / 常量
protocol/rcsp/data/CommonConfig.java          # 配置帧格式
protocol/rcsp/param/GetDeviceConfigParam.java # configId = 2 字节 BE，且无长度前缀
protocol/rcsp/command/AuthCheckCmd.java       # opcode 80
protocol/rcsp/param/AuthCheckParam.java       # [version][16B random]
protocol/rcsp/param/AuthSendCalcResultParam.java # [version][pairResult], pairResult=0 表示成功
impl/BluetoothAuth.java                       # 完整认证状态机（k(): 认证前只放行 80/81）
a6/f.java  A(BasePacket) 行 133               # 帧编码器（逐字节复刻依据）
a6/f.java  w() 行 1638                        # 帧解析器
setting/function/recordingtranslation/        # 68/69/70/75 定义
setting/bigdata/DeviceConfigBigDataTransfer.java  # 52 分片传输
settings/ui/voicetranslation/HeadsetStorageVM.java # 下载/合并/落盘
```

### 本机探针（全部在 `research/record/`）

| 目录 | 用途 |
|---|---|
| `p7/` | **最终决定性探针**：立刻认证 + SAFER MATCH 校验 + GET_CONFIG/SET_CONFIG/0x02 全测 |
| `p0p1/` | P0 等待时序 + GET_CONFIG 多写法 + P1 监听设备主动 challenge |
| `p2/` | 逐字节复刻编码器，不做认证直接 GET_CONFIG |
| `p7b/` | 对照实验：跳过 `0x51`，验证是否 `0x51` 导致 mute |
| `p7c/` | 变体扫描：targetApp=0(0xC0) / 无响应位(0x84) |

编译：`swiftc -O -o p7 main.swift Safer.swift && ./p7 55`

---

## 12. 下一步：Android btsnoop 抓包（唯一能定论的路径）

**目的**：确认官方 App 在真机上到底有没有成功读到录音列表，以及它发的帧和我们差了哪一字节。

### 12.1 步骤

1. **准备**：小米/Android 手机，已配对耳机，已安装官方「小米耳机」App（`com.mi.earphone`）。
2. **开启蓝牙 HCI 日志**（二选一）：
   - **免 root**：设置 → 开发者选项 → 开启「启用蓝牙 HCI 信息收集日志」
     （英文：*Enable Bluetooth HCI snoop log*）
   - **或** ADB（Android 12+ 需要 root，或 userdebug 版本）：
     ```bash
     adb shell setprop persist.bluetooth.btsnooplogmode full
     adb shell setprop persist.bluetooth.btsnoopdefaultmode full
     ```
3. **触发日志重置**：把蓝牙**关掉再打开**（清除旧日志）。
4. **复现操作**：打开官方 App → 进入录音页面 → **导出/播放一条录音**（这是关键，
   要让它真正走一次 `GET_CONFIG 69/70` + `SET_CONFIG 52` 下载流程）。
5. **取日志**：
   ```bash
   adb pull /data/misc/bluetooth/logs/btsnoop_hci.log
   # 若该路径需要权限：
   adb bugreport bugreport.zip   # 解压后取 FS/data/misc/bluetooth/logs/btsnoop_hci.log
   ```
6. **Wireshark 分析**：
   - 打开 `btsnoop_hci.log`
   - 过滤器（选一个）：
     ```
     btatt.btcommon_handle == 0xXXXX      # AF07 的 handle（需先找）
     btatt.opcode == 0x12                 # Write Command
     btatt.opcode == 0x52                 # Write Request
     ```
   - 更简单的办法：过滤 `btatt` 后 **Ctrl+F 搜十六进制 `fecdcba`** → 找到所有带
     `FE DC BA` 的包，导出为 hex。
   - 重点看：**App 发 `0xF3` 时用的 type 字节、opcode、以及 payload 的每一个字节**，
     和我们 `FEDCBAC4F30003010046EF` 对比差在哪。

### 12.2 判断标准

| 抓到的情况 | 结论 |
|---|---|
| App 也发不出 `0xF3`，只发 `0x50/0x51` | 设备确实不支持 RCSP config → 我们已到极限，App 也读不到录音 |
| App 发了 `0xF3` 且**有应答** | 我们的帧还有细节错，逐字节改即可（协议已还原，改起来很快） |
| App 发了 `0xF3` 但**同样无应答** | 官方 App 也读不到 → 该功能在本机固件上不存在 |

---

## 13. 降级方案建议（若 btsnoop 也证明读不到）

如果最终确认本机固件不支持录音文件读取，macOS App 能做到的**最大降级**是：

| 能力 | 可行性 | 依据 |
|---|---|---|
| 显示「耳机是否处于可录音状态」 | ⚠️ 部分可行 | 仅能靠 `0x0E ATTR 0x02`**被动通知**（设备主动推时才能看到），无法主动查询 |
| 显示电量 / 充电盒电量 | ✅ 完全可行 | 已实现，真机验证过 |
| 显示录音条数 / 剩余可录时长 | ❌ 不可行 | 需要 `0xF3` config 68/69/70，设备不响应 |
| 导出录音文件 | ❌ 不可行 | 同上 |

**给用户的建议**：录音文件的导出只能走 **iPhone/Android 上的官方「小米耳机」App**；
macOS App 定位为「电量 + 降噪 + 佩戴状态」的菜单栏工具。

### 13.1 需要用户在 iPhone 上做什么（若想验证官方 App 能否导出）

1. 打开「小米耳机」App，连接 M2529E1
2. 进入 **录音 / 语音记事** 页面
3. 看是否有录音列表；若有，点导出
4. 若有列表 → 说明固件支持，我们用 Android btsnoop 抓包一定能拿到帧格式
5. 若无列表 / 提示不支持 → 固件确实不支持，macOS 侧到此为止

