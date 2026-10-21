import SwiftUI
import MiPodsCore

/// AirPods 式浮动 HUD 的内容视图。
///
/// 这个视图只负责「长得像 AirPods 弹窗」，**不负责窗口**。
/// 窗口层级、置顶、不抢焦点全部在 `HUDController` 里（那部分是实测定过的参数）。
///
/// 复用要点：HUDController 每次弹出都会**重建** NSHostingView，
/// 这样这里的 `.onAppear` 才会重新播放入场弹簧动画。
struct HUDView: View {

    let state: MiPodsState

    /// 弹簧动画触发标志：`onAppear` 时置 true。
    @State private var appeared = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            // 左：耳机图标 + 名称 + 当前模式
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "earbuds")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)

                    Text(state.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }

                HStack(spacing: 5) {
                    // 连接状态圆点
                    Circle()
                        .fill(state.isConnected ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)

                    Text(state.isConnected ? L10n.statusConnected : L10n.statusDisconnected)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    // 仅在设备真的支持降噪时才显示模式，避免误导
                    if state.canSwitchNoiseMode {
                        Text("·")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Text(state.noiseModeTitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 4)

            // 右：三路电量
            BatteryTriplet(state: state, ringSize: 40, ringLineWidth: 3.5, spacing: 14)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            // `.ultraThinMaterial` 是 SwiftUI 对 NSVisualEffectView 的封装，
            // 自动跟随浅色/深色模式与「降低透明度」辅助功能设置。
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        )
        .fixedSize()
        // 入场弹簧：从略小 + 略透明放大到位
        .scaleEffect(appeared ? 1.0 : 0.92)
        .opacity(appeared ? 1.0 : 0.0)
        .onAppear {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                appeared = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [L10n.appName, state.displayName,
                     state.isConnected ? L10n.statusConnected : L10n.statusDisconnected]
        parts.append(L10n.batteryAccessibility(L10n.batteryLeft, level: state.leftLevel, charging: state.isChargingLeft))
        parts.append(L10n.batteryAccessibility(L10n.batteryRight, level: state.rightLevel, charging: state.isChargingRight))
        parts.append(L10n.batteryAccessibility(L10n.batteryCase, level: state.caseLevel, charging: state.isChargingCase))
        if state.canSwitchNoiseMode { parts.append("当前模式 \(state.noiseModeTitle)") }
        return parts.joined(separator: "，")
    }
}
