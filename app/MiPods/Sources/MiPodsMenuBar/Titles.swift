import Foundation

/// 全部用户可见文案集中在此（中文）。
///
/// 设计意图：UI 层不出现任何裸字符串。将来若要国际化，只需把本文件换成
/// String Catalog / `.strings` 查表，其余视图代码一行都不用改。
enum L10n {

    // MARK: - 通用

    static let appName = "小米耳机"
    static let unknown = "—"
    static let percent = "%d%%"

    // MARK: - 连接状态

    static let statusConnected = "已连接"
    static let statusDisconnected = "未连接"
    static let statusConnecting = "连接中…"
    static let statusSearching = "正在搜索耳机…"

    static let actionRefresh = "刷新"
    static let actionReconnect = "重新连接"
    static let actionDisconnect = "断开"
    static let actionQuit = "退出"

    // MARK: - 电量

    static let batteryLeft = "左耳"
    static let batteryRight = "右耳"
    static let batteryCase = "充电盒"
    static let batteryUnknown = "未知"

    /// 充电中角标：电量环旁的小闪电。
    static let charging = "充电中"

    /// 电量环的无障碍描述，例如「左耳 71%，充电中」。
    static func batteryAccessibility(_ label: String, level: Int?, charging: Bool) -> String {
        guard let level else { return "\(label) 电量未知" }
        return charging ? "\(label) \(level)%，充电中" : "\(label) \(level)%"
    }

    // MARK: - 降噪模式

    static let modeTitle = "模式"
    static let modeOff = "普通"
    static let modeANC = "降噪"
    static let modeTransparency = "通透"
    static let modeWindNoise = "抗风噪"

    /// 本耳机不支持任何降噪能力时的说明。
    /// M2529E1（耳夹式）为开放式结构，物理上无主动降噪，
    /// 其 3Mic + VPU 仅用于通话降噪 —— 因此这里不是「功能缺失」，而是如实说明。
    static let noModeSupport = "本耳机不支持主动降噪"
    static let noModeSupportDetail = "开放式耳夹结构，通话降噪由耳机独立完成，无需 App 干预"

    // MARK: - 录音

    static let recordingTitle = "录音"
    static let recordingAvailable = "耳机可本地录音"
    static let recordingUnavailable = "耳机当前不可本地录音"
    static let recordingUnknown = "录音状态未知"
    static let recordingLocalHint = "录音保存在耳机/充电盒内，需在手机端小米耳机 App 导出"
    static let recordingOpenApp = "打开小米耳机 App"
    static let inputDevice = "当前输入设备"
    static let inputNotEarbuds = "当前输入不是耳机麦克风"
    static let actionOpenSoundSettings = "打开声音设置"
    static let actionRefreshInput = "重新检测输入设备"

    // MARK: - 信息区

    static let infoTitle = "设备信息"
    static let infoModel = "型号"
    static let infoFirmware = "固件"
    static let infoAddress = "地址"
    static let infoUpdated = "更新于"

    // MARK: - 能力

    static let capabilityTitle = "支持的能力"
    static let capANC = "主动降噪"
    static let capTransparency = "通透模式"
    static let capWearingDetection = "入耳检测"
    static let capRecording = "麦克风"

    // MARK: - 提示

    static let bluetoothOff = "蓝牙未开启"
    static let bluetoothOffDetail = "请在系统设置中打开蓝牙后重试"
    static let permissionDenied = "缺少蓝牙权限"
    static let permissionDeniedDetail = "请在系统设置 → 隐私与安全性 → 蓝牙 中允许本 App"
    static let notPaired = "未找到已配对的耳机"
    static let notPairedDetail = "请先在系统设置 → 蓝牙 中配对小米耳机"

    // MARK: - 时间

    /// 「刚刚 / 12 秒前 / 3 分钟前」这种相对时间。
    static func relativeTime(from date: Date?, now: Date = Date()) -> String {
        guard let date else { return unknown }
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<2: return "刚刚"
        case ..<60: return "\(seconds) 秒前"
        case ..<3600: return "\(seconds / 60) 分钟前"
        default: return "\(seconds / 3600) 小时前"
        }
    }
}
