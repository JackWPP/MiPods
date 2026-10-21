import Foundation
import SwiftUI
import MiPodsCore

/// **契约适配层** —— UI 与 `MiPodsCore` 的唯一接触面。
///
/// 为什么单独抽一层：`MiPodsCore` 的类型一旦调整，只需改这一个文件，
/// 其余视图文件都不用动。
///
/// 已对齐的真实契约（`Sources/MiPodsCore/MiPodsController.swift` + `Models.swift`）：
/// - `leftBattery` / `rightBattery` / `caseBattery`: `Int?`，`nil` = 协议哨兵 0xFF
/// - `Capabilities`: `OptionSet`，7 个能力位（含 `hasWindNoise` / `hasEqualizer` / `hasFindMyEarbuds`）
/// - `NoiseMode`: 4 档 `off(0) / anc(1) / transparency(2) / windNoise(3)`，Core 已提供中文 `displayTitle`
/// - 额外字段：`isAuthenticated` / `firmware` / `statusDetail` / `log`
extension MiPodsState {

    // MARK: - 电量

    /// 左耳电量 0–100，`nil` 表示未知。
    var leftLevel: Int? { Self.normalize(leftBattery) }
    var rightLevel: Int? { Self.normalize(rightBattery) }
    var caseLevel: Int? { Self.normalize(caseBattery) }

    /// 把裸值收敛到 0–100；越界或协议哨兵值统一当作未知。
    ///
    /// Core 层已经做过 `0xFF -> nil`，这里再兜一次底是为了防止
    /// 未来协议扩展（如 0x7F 表示「不适用」）直接漏到 UI 上画出 127%。
    private static func normalize(_ raw: Int?) -> Int? {
        guard let raw, (0...100).contains(raw) else { return nil }
        return raw
    }

    // MARK: - 充电状态

    var isChargingLeft: Bool { isLeftCharging }
    var isChargingRight: Bool { isRightCharging }
    var isChargingCase: Bool { isCaseCharging }

    // MARK: - 降噪模式

    /// 当前模式的显示文案。
    ///
    /// 直接复用 Core 的 `NoiseMode.displayTitle`（中文已在 Core 定义），
    /// 避免 UI 与 Touch Bar 出现两套不一致的译名。
    /// 但**能力探测优先**：本耳机（M2529E1 耳夹式）物理上无 ANC，
    /// `capabilities` 不支持时一律显示「普通」，不显示「降噪」字样误导用户。
    var noiseModeTitle: String {
        guard canSwitchNoiseMode else { return NoiseMode.off.displayTitle }
        return noiseMode.displayTitle
    }

    /// 当前设备**实际可用**的模式列表（用于按能力渲染分段控件）。
    ///
    /// 规则：
    /// - 永远包含「普通」
    /// - 每个额外模式都要有对应能力位才出现
    /// - 只剩「普通」时返回**空数组** —— 调用方据此显示「不支持」说明，
    ///   而不是画一个只有一档的分段控件或三个灰按钮
    var availableNoiseModes: [NoiseMode] {
        var modes: [NoiseMode] = [.off]
        if capabilities.contains(.hasANC) { modes.append(.anc) }
        if capabilities.contains(.hasTransparency) { modes.append(.transparency) }
        if capabilities.contains(.hasWindNoise) { modes.append(.windNoise) }
        return modes.count > 1 ? modes : []
    }

    /// 是否可以切换模式。
    var canSwitchNoiseMode: Bool { !availableNoiseModes.isEmpty }

    // MARK: - 展示用

    /// 耳机显示名：优先蓝牙广播名（对用户友好），空则退回设备自报型号，再空用通用名。
    var displayName: String {
        if !deviceName.trimmingCharacters(in: .whitespaces).isEmpty { return deviceName }
        if !modelName.trimmingCharacters(in: .whitespaces).isEmpty { return modelName }
        return L10n.appName
    }

    /// 副标题里显示的型号：只在它和 `displayName` 不同的时候才值得显示。
    var secondaryModelName: String? {
        let model = modelName.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty, model != displayName else { return nil }
        return model
    }

    /// 菜单栏图标旁的电量简写，例如「71 / 74 / 30」，未知用「—」。
    var compactBatteryText: String {
        [leftLevel, rightLevel, caseLevel]
            .map { $0.map(String.init) ?? L10n.unknown }
            .joined(separator: " / ")
    }

    /// 三路电量里最低的一路（用于菜单栏图标着色：低电变红）。
    var lowestBattery: Int? {
        [leftLevel, rightLevel, caseLevel].compactMap { $0 }.min()
    }

    /// 是否有任何一路在充电。
    var isAnyCharging: Bool { isChargingLeft || isChargingRight || isChargingCase }

    /// 面板底部那行连接细节：优先用 Core 给的 `statusDetail`，
    /// 没连上时退回本地的中文状态文案。
    var connectionDetail: String {
        let detail = statusDetail.trimmingCharacters(in: .whitespaces)
        if !detail.isEmpty { return detail }
        return isConnected ? L10n.statusConnected : L10n.statusDisconnected
    }

    /// 是否值得显示固件版本（Core 从 `GET_DEVICE_INFO` TLV 0x01 解出来的）。
    var hasFirmwareInfo: Bool {
        !firmware.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// MARK: - NoiseMode 展示

extension NoiseMode {

    /// 模式中文名。**直接转发 Core 的 `displayTitle`**，不另立一套译名。
    var localizedTitle: String { displayTitle }

    /// SF Symbols 图标名（纯 UI 关注点，Core 不该知道）。
    var symbolName: String {
        switch self {
        case .anc: return "waveform.path.ecg"
        case .transparency: return "ear"
        case .windNoise: return "wind"
        case .off: return "speaker.slash"
        }
    }
}
