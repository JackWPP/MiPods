# 研究记录

这个目录记录了 MiPods 的全部逆向与验证过程，所有结论都区分 **观察**、**推断** 与 **未知**。

| 文档 | 内容 |
|---|---|
| [web/findings.md](web/findings.md) | 公开资料研究：小米官方 MMA 协议、开源实现交叉验证、录音功能真相 |
| [rea/findings.md](rea/findings.md) | 官方 Mac App 逆向（确认无耳机代码）+ macOS 窗口/触控栏实测 + AirPods 式 HUD 方案 |
| [record/findings.md](record/findings.md) | **手机端 App 反编译**：完整录音文件协议（列表/下载/分片/CRC）+ SAFER+ 四组真机验证 |

## 证据等级

- **[HW]** 真机实测（有可复现的探针与抓包字节）
- **[DEC]** 反编译源码（有文件路径可复核）
- **[DOC]** 官方公开文档
- **[?]** 待验证 / 证据不足

## 关于未分发的第三方材料

以下内容**仅作研究参考，未随本仓库分发**（版权/许可证原因）：

- 小米官方 MMA 协议文档快照 —— 版权归小米，请从
  [小爱开放平台](https://developers.xiaoai.mi.com/) 查阅
- Gadgetbridge（GPL-3.0）、redmi-buds-bar（AGPL-3.0）、galaxy-buds-menubar（GPL-3.0）
  的源码快照 —— 请从各自仓库获取
- 手机端「小米耳机」APK —— 版权归小米，本研究通过 Aptoide 获取并校验 MD5 后分析

## 复现探针

`tools/` 与 `research/*/` 下的 `.swift` / `.py` 是开发期的探针源码（编译产物未提交）。
典型用法：

```bash
cd tools/bleprobe
swiftc -O -o probe s24/main.swift Safer.swift && ./probe
```
