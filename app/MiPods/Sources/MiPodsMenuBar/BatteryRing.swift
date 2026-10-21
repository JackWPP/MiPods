import SwiftUI
import MiPodsCore

/// 单个组件的电量环。
///
/// 视觉规则（对齐 AirPods 弹窗的语言）：
/// - 圆环从底部起顺时针填充（`rotationEffect(-90°)`）
/// - 低电量变红（**20% 以下**），充电中显示绿色闪电角标
/// - 充电盒用独立的青蓝色，与左右耳区分（用户一眼能分辨三个数）
struct BatteryRing: View {

    enum Role {
        case left, right, case_

        var label: String {
            switch self {
            case .left: return L10n.batteryLeft
            case .right: return L10n.batteryRight
            case .case_: return L10n.batteryCase
            }
        }

        /// 正常状态下的环色。
        ///
        /// 三个环必须**一眼可分**，所以不只是色相不同，明度也拉开：
        /// 左耳冷蓝（最暗）→ 右耳天蓝（中）→ 充电盒琥珀（最暖）。
        /// 最初给盒用了浅青绿，实测在白底上对比度不足、几乎看不出进度弧，
        /// 因此换成琥珀色（对"盒子"也更直觉）。
        var tint: Color {
            switch self {
            case .left: return Color(red: 0.24, green: 0.52, blue: 0.98)   // 冷蓝
            case .right: return Color(red: 0.16, green: 0.72, blue: 0.88)  // 天蓝
            case .case_: return Color(red: 0.96, green: 0.62, blue: 0.16)  // 琥珀
            }
        }

        var symbolName: String {
            switch self {
            case .left: return "earbuds.left"
            case .right: return "earbuds.right"
            case .case_: return "airpods.chargingcase"
            }
        }
    }

    let role: Role
    let level: Int?
    let isCharging: Bool

    /// 直径。HUD 用小号（44），面板用大号（72）。
    var size: CGFloat = 44
    /// 环宽。
    var lineWidth: CGFloat = 4
    /// 是否显示下方的文字标签。
    var showsLabel: Bool = true

    private var fraction: Double {
        guard let level else { return 0 }
        return min(max(Double(level) / 100.0, 0), 1)
    }

    private var isLow: Bool {
        guard let level else { return false }
        return level <= 20
    }

    private var ringColor: Color {
        // 低电优先警示 —— 但充电中不算低电（正在补电，红色会吓人）
        if isLow && !isCharging { return .red }
        // 保持各角色自有色相：原先「充电中一律染绿」会让三个环全变成同一个绿色，
        // 用户就分不清哪个是左耳、哪个是盒子了。充电状态改用绿色闪电角标表达。
        return role.tint
    }

    private var levelText: String {
        guard let level else { return L10n.unknown }
        return "\(level)%"
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // 轨道
                Circle()
                    .stroke(ringColor.opacity(0.16), lineWidth: lineWidth)

                // 进度
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(
                        ringColor,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.35), value: fraction)

                // 中心内容：电量数字 + 充电角标
                VStack(spacing: 1) {
                    Text(levelText)
                        .font(.system(size: size * 0.28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(level == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))

                    if isCharging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: size * 0.16, weight: .bold))
                            .foregroundStyle(.green)
                    }
                }
            }
            .frame(width: size, height: size)

            if showsLabel {
                Text(role.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.batteryAccessibility(role.label, level: level, charging: isCharging))
    }
}

/// 三路电量并排（HUD 与面板共用，只靠参数区分尺寸）。
struct BatteryTriplet: View {
    let state: MiPodsState
    var ringSize: CGFloat = 44
    var ringLineWidth: CGFloat = 4
    var spacing: CGFloat = 18

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            BatteryRing(role: .left,
                        level: state.leftLevel,
                        isCharging: state.isChargingLeft,
                        size: ringSize,
                        lineWidth: ringLineWidth)
            BatteryRing(role: .right,
                        level: state.rightLevel,
                        isCharging: state.isChargingRight,
                        size: ringSize,
                        lineWidth: ringLineWidth)
            BatteryRing(role: .case_,
                        level: state.caseLevel,
                        isCharging: state.isChargingCase,
                        size: ringSize,
                        lineWidth: ringLineWidth)
        }
    }
}

#if DEBUG
#Preview("电量环 — 正常") {
    HStack(spacing: 20) {
        BatteryRing(role: .left, level: 71, isCharging: true)
        BatteryRing(role: .right, level: 74, isCharging: true)
        BatteryRing(role: .case_, level: 30, isCharging: false)
    }
    .padding()
}

#Preview("电量环 — 低电/未知") {
    HStack(spacing: 20) {
        BatteryRing(role: .left, level: 12, isCharging: false)
        BatteryRing(role: .right, level: nil, isCharging: false)
        BatteryRing(role: .case_, level: 100, isCharging: false)
    }
    .padding()
}
#endif
