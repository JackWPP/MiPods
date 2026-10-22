# 官方 App 真机抓包分析（android btsnoop）

> 这是**实测得到的协议真值**，优先级高于任何反编译推断。
> 抓包环境：Xiaomi M531DA / Android 17 / `com.mi.earphone` 1.38.0 /
> 耳机 `00:13:D6:E2:17:D4`，抓包时间 2026-10-22 17:41–17:48。
>
> 原始日志**不入库**（含手机与其他设备 MAC），只保留解析工具与本分析结论。

---

## 0. 一句话结论

**整条录音下载协议已经完整打通并实测**：从认证握手到录音文件分片重组，
全部字节都有真机证据。剩余工作只剩「压缩音频的编解码封装」，不再是协议问题。

---

## 1. 关键更正：认证是 3 阶段，且我们之前帧格式有错

### 1.1 完整认证时序（官方真值）

```
t=5.231  TX  0xC1 0x50 seq=0x99  [01][16B 随机]        ← 主机挑战耳机
t=5.444  RX  0x01 0x50 seq=0x99  [01][16B 应答]        ← 耳机应答（= SAFER+，已验证吻合）
t=5.482  TX  0xC1 0x51 seq=0x9A  [01 00]               ← 主机确认
t=5.570  RX  0x01 0x51 seq=0x9A  [01]                  ← 耳机 ACK
t=5.577  RX  0xC0 0x50 seq=0x00  [01][16B 挑战]        ← ★ 耳机反过来挑战主机（type 0xC0 = 请求）
t=5.635  TX  0x01 0x50 seq=0x00  [01][16B 应答]        ← ★ 主机以「应答」类型回复
t=5.724  RX  0xC0 0x51 seq=0x01  [01 00]               ← 耳机发确认请求
t=5.836  TX  0x01 0x51 seq=0x01  [01]                  ← 主机 ACK
t=5.836  TX  0xC1 0x02 ... GET_DEVICE_INFO             ← ✅ 认证完成，后续命令全部正常
```

**这就是之前「设备静默」的真正原因**：我们漏了第 5 步 —— 耳机发来 `0xC0 0x50`
（请求类型）时，必须用 `0x01 0x50`（**应答类型**，带 status 字节）回答。
我们当时直接把后续命令发出去，设备在等认证收尾，于是全部丢弃。

### 1.2 targetApp 很重要：官方用 1，不是 4

帧类型字节 = `bit7(是否命令) | bit6(是否要应答) | targetApp`

| 字节 | 含义 | 谁用 |
|---|---|---|
| `0xC1` / `0x01` | targetApp=**1**（MIUI 系统蓝牙） | **认证与应用数据都走这个** |
| `0xC4` / `0x04` | targetApp=4（`com.mi.earphone`） | App 自己发的少量查询 |
| `0xC0` / `0xC7` | targetApp=0（广播/通用） | 设备主动上报请求 |

我们之前一直用 `0xC4` 做认证，`0x50` 能拿到应答但 `0x51` 收不到 ACK；
**改用 `0xC1` 后整条链路才走通**。

### 1.3 GET_CONFIG 的 payload 格式（我们之前一直发错）

官方实际发送：

```
FEDCBAC1 F3 0019 9E | 0001 0002 0003 0004 000A 000B 000F 000D 0025 001E 0023 0027 | EF
                      └────────── 就是裸的 2 字节大端 config ID 列表，没有任何前缀 ──────────┘
```

我们之前发的是 `[0x00, 0x00, code]` / `[0x02, 0x00, code]`，**多了一个前缀字节**，
所以设备把参数解析错，返回空 payload 或直接丢弃。

---

## 2. 录 音 下 载：config 52 分片传输（官方真值）

### 2.1 分片帧结构（RX，655 字节大包）

```
FEDCBA C4 F4 0291 | 02 | FF | 00 34 | 02 8B | 02 02 02 01 00 02 80 <640B data> <crc32:4> | EF
                    │    │    │       │       └ value(651)
                    │    │    │       └ subLen = 651
                    │    │    └ config type = 0x0034 (52, 大文件传输)
                    │    └ seq = 0xFF
                    └ status = 0x02
```

> ⚠️ 注意：这个 notify 帧**带 status 字节**（不是按 `bit6` 推断的「请求无 status」），
> 实际以「`00 34` 出现的位置」为准更可靠。

value 内层按 `DeviceConfigBigDataTransfer.valueToParams()` 逐字段解析：

```
caseId(1) | recordSource(1) | subcmd(1)
  subcmd=1  START     : 后面是下载参数
  subcmd=2  TRANSPORT : crcFlag(1) dataSN(1) dataLen(2,BE) data[dataLen] [crc32(4) if crcFlag==1]
  subcmd=3  COMPLETE
  subcmd=4  STOP      : failedReason(1)
  subcmd=5  REQ_STOP
```

### 2.2 实测重组结果

抓包中共有 **两次完整下载**（对应 App 里「2 个耳机录音待导入」）：

| 录音 | 分片数 | 重组大小 | 完成时刻 | 手机端保存的 m4a |
|---|---|---|---|---|
| 3 秒（2026-10-12 12:05:47） | 23 | 14,336 B | t=128.34s | 14,642 B |
| 58 秒（2026-10-18 14:14:18） | 256 | 163,840 B | t=146.95s | 240,646 B |

两次都用 `caseId=2`，**不能只按 caseId 分开**，必须按「完成事件（subcmd=3）」切段，
否则两条录音的分片会串在一起（这是我们第一版重组失败的原因）。

### 2.3 音频格式：不是容器，是裸压缩流

- BLE 上传输的数据**不含 `OggS` 头**，也不是 ADTS
- 手机端保存的 `.m4a` 以 `FF F9`（AAC ADTS 同步字）开头 → **App 做了转码**
- 在原始 btsnoop 里**搜不到** m4a 的任何字节 → 证实是解码后重新编码，不是简单封装
- 重组数据首字节 `0x86` / `0x83` 符合 **Opus TOC** 特征（config=16 → CELT NB）
- 手机端 APK 里有 `RECORD_FORMAT_OGG = 15` 常量，说明 format 是个枚举，需从 config 69 读取

**结论**：耳机存的是压缩音频流，App 解码后转 AAC。macOS 端要落地需要：
1. 读 `GET_CONFIG(69)` 拿 `RECORD_FORMAT`（TLV 子类型 9）确认编码
2. 按该编码解码（Opus 用 libopus / ffmpeg），再存 `.opus` 或转 `.wav`/`.m4a`

---

## 3. 传输通道（重要：手机走 L2CAP CoC，不是 ATT）

- 手机的 miwear 帧走 **L2CAP CoC（动态 CID，如 0x3040）**，不是标准 ATT
- 每帧外层有 4 字节头（如 `40 30 E3 FF` / `43 00 E1 EF`）——这是 RFCOMM/CoC 封装
- **内层 miwear 帧格式与 macOS BLE GATT（AF00/AF07/AF08）完全一致**，
  所以协议实现可以共用，只是 macOS 端用 ATT、手机端用 CoC

---

## 4. 复现方法

```bash
# 1. 手机开启蓝牙 HCI 日志
adb shell settings put secure bluetooth_hci_log 1
adb shell svc bluetooth disable && adb shell svc bluetooth enable

# 2. 在手机上操作：小米耳机 App → 录音转写 → 全部导入

# 3. 取日志
adb bugreport /tmp/bugreport
unzip -j /tmp/bugreport.zip 'FS/data/misc/bluetooth/logs/btsnoop_hci_*.log' -d /tmp/btsnoop

# 4. 解析
python3 tools/btsnoop/extract_miwear.py /tmp/btsnoop/btsnoop_hci_*.log
```

工具：
- `tools/btsnoop/extract_miwear.py` —— 从 btsnoop 还原 miwear 帧（含方向/时间）
- `tools/btsnoop/parse_btsnoop.py` —— 底层 ATT/ACL 提取

---

## 5. 尚未拿到、但已知道怎么拿

| 缺失项 | 为什么需要 | 怎么拿 |
|---|---|---|
| `GET_CONFIG(69)` 录音列表 | 需要 recordId / 文件名 / 时长 / 大小 / **format** | 重新抓包时先进入录音页**等列表刷新**再导入，或自己发 `F3` 查 0x45 |
| `GET_CONFIG(70)` 容量 | 面板显示「剩余可录时长」 | 同上，发 `F3` 查 0x46 |
| `subcmd=1` 起始请求 | 自己实现下载时要知道 start 参数 | 抓包中该帧在 t≈127s 之前，本次提取未覆盖到，下次从更早开始抓 |
| 音频编码确认 | 决定解码器 | 从 config 69 的 `RECORD_FORMAT` 得到 |
