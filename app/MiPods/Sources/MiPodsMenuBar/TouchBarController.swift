import AppKit
import SwiftUI
import MiPodsCore

/// 面板窗口的 Touch Bar 支持。
///
/// ## 为什么只能这样用
///
/// 本机实测（macOS 27 / MacBookPro17,1，证据见 `research/rea/findings.md` §4.2）：
/// - Control Strip **对第三方关闭**：`com.apple.private.controlstrip` 是私有 entitlement，
///   仅 `ControlStrip.app` 持有；SDK 头文件无任何 ControlStrip API；
///   `NSTouchBar.instancesRespond(to: "presentSystemModalTouchBar:")` 等 5 个私有方法
///   运行时全部返回 `false`。→ **不要试图常驻 Touch Bar**。
/// - 公开 API 唯一可行的用法：**窗口成为 key window 时**，把 `NSTouchBar` 挂到它的响应链上。
///
/// 所以本类的定位是「面板打开时的增强」：点开菜单栏面板 → Touch Bar 上出现
/// 3 个电量 + 模式按钮，随手可点，关掉面板就恢复系统默认。
///
/// 注意：本机 `MacBookPro17,1` 确实有 Touch Bar（`dfr-drv` / `TouchBarServer`），
/// 但用户也可能在外接键盘上使用 —— 那时 Touch Bar 不存在，本类所有操作应安全降级为空操作。
@MainActor
final class TouchBarController: NSObject, NSTouchBarDelegate {

    private weak var controller: MiPodsController?

    /// 由控制器持有，避免被释放。
    private var touchBar: NSTouchBar?

    /// 挂在哪个视图上（面板的 hosting view）。
    private weak var hostView: NSView?

    init(controller: MiPodsController) {
        self.controller = controller
        super.init()
    }

    // MARK: - 安装 / 卸载

    /// 面板打开时调用：给宿主视图挂上 Touch Bar。
    func attach(to view: NSView) {
        hostView = view
        let bar = touchBar ?? makeTouchBar()
        touchBar = bar
        view.touchBar = bar
    }

    /// 面板关闭时调用：从视图摘掉，避免残留在 Touch Bar 上。
    func detach() {
        hostView?.touchBar = nil
        hostView = nil
    }

    // MARK: - 构造

    private func makeTouchBar() -> NSTouchBar {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [
            .batteryLeft,
            .batteryRight,
            .batteryCase,
            .flexibleSpace,
            .modeButtons,
        ]
        return bar
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case .batteryLeft:
            return batteryItem(identifier, label: L10n.batteryLeft, level: controller?.state.leftLevel ?? nil,
                               charging: controller?.state.isChargingLeft ?? false)
        case .batteryRight:
            return batteryItem(identifier, label: L10n.batteryRight, level: controller?.state.rightLevel ?? nil,
                               charging: controller?.state.isChargingRight ?? false)
        case .batteryCase:
            return batteryItem(identifier, label: L10n.batteryCase, level: controller?.state.caseLevel ?? nil,
                               charging: controller?.state.isChargingCase ?? false)
        case .modeButtons:
            return modeItem(identifier)
        default:
            return nil
        }
    }

    private func batteryItem(_ identifier: NSTouchBarItem.Identifier,
                             label: String,
                             level: Int?,
                             charging: Bool) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)
        let text = level.map { "\(label) \($0)%" } ?? "\(label) \(L10n.unknown)"
        let symbol = charging ? "bolt.fill" : "earbuds"
        item.view = NSHostingView(rootView: TouchBarBatteryLabel(
            label: label, level: level, charging: charging, symbol: symbol, fallbackText: text
        ))
        return item
    }

    private func modeItem(_ identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)

        guard let controller, controller.state.canSwitchNoiseMode else {
            // 不支持模式切换 → 不显示任何按钮，而不是显示灰按钮
            item.view = NSHostingView(rootView: TouchBarUnsupportedLabel(text: L10n.noModeSupport))
            return item
        }

        let modes = controller.state.availableNoiseModes
        let current = controller.state.noiseMode

        item.view = NSHostingView(rootView: HStack(spacing: 8) {
            ForEach(modes, id: \.self) { mode in
                Button(action: {
                    controller.setNoiseMode(mode)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: mode.symbolName)
                            .font(.system(size: 13, weight: .medium))
                        Text(mode.localizedTitle)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(mode == current ? 0.28 : 0.08))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6))
        return item
    }
}

// MARK: - Touch Bar 上的小视图

/// Touch Bar 电量标签（自适应深色底，触控栏本身是黑色）。
private struct TouchBarBatteryLabel: View {
    let label: String
    let level: Int?
    let charging: Bool
    let symbol: String
    let fallbackText: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(charging ? Color.green : Color.white.opacity(0.85))

            if let level {
                Text("\(level)%")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(level <= 20 ? Color.red : Color.white)
            } else {
                Text(L10n.unknown)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 8)
        .accessibilityLabel(fallbackText)
    }
}

private struct TouchBarUnsupportedLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Color.white.opacity(0.45))
            .padding(.horizontal, 8)
    }
}

// MARK: - 标识符

extension NSTouchBarItem.Identifier {
    static let batteryLeft  = NSTouchBarItem.Identifier("com.mipods.touchbar.battery.left")
    static let batteryRight = NSTouchBarItem.Identifier("com.mipods.touchbar.battery.right")
    static let batteryCase  = NSTouchBarItem.Identifier("com.mipods.touchbar.battery.case")
    static let modeButtons  = NSTouchBarItem.Identifier("com.mipods.touchbar.mode")
}
