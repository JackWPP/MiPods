import Foundation
import CoreAudio
import MiPodsCore

/// 探测「当前系统默认输入设备是不是耳机麦克风」。
///
/// 为什么需要它：这付耳机没有 ANC，但**有麦克风**（3Mic + VPU，用于通话降噪）。
/// 用户真正的痛点之一是「录音时不确定是不是录到了耳机麦」。
/// 这个类只做只读查询，不切换设备（切换默认设备需用户授权感强，交给系统设置更稳妥）。
///
/// macOS 侧耳机麦克风走标准 HFP，系统把它当普通输入设备暴露给 `AVAudioEngine`，
/// 因此**录音能力完全不需要碰 BLE 协议**。
final class AudioInputProbe {

    static let shared = AudioInputProbe()

    private init() {}

    /// 当前默认输入设备的名字（如 "Xiaomi 耳夹式耳机"）。
    func defaultInputDeviceName() -> String? {
        guard let deviceID = defaultInputDeviceID() else { return nil }
        return deviceName(deviceID)
    }

    /// 默认输入设备是否为这付耳机。
    func isEarbudAsDefaultInput(matching deviceNameHint: String) -> Bool {
        guard let current = defaultInputDeviceName() else { return false }
        let hint = deviceNameHint.trimmingCharacters(in: .whitespaces)
        if hint.isEmpty { return false }
        return current.localizedCaseInsensitiveContains(hint)
    }

    /// 给面板用的一行摘要文案。
    func summaryText(for state: MiPodsState) -> String {
        guard let current = defaultInputDeviceName() else { return L10n.batteryUnknown }
        if isEarbudAsDefaultInput(matching: state.displayName) {
            return current
        }
        return "\(current)（\(L10n.inputNotEarbuds)）"
    }

    // MARK: - CoreAudio

    private func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    private func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        let result = name as String
        return result.isEmpty ? nil : result
    }
}
