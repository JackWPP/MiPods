import AppKit
import SwiftUI
import MiPodsCore

/// AirPods 式浮动 HUD 的窗口控制器。
///
/// ## 为什么是这套参数
///
/// 本文件里的每一个窗口属性都是**在本机实测验证过**的（macOS 27 / M1 / MacBookPro17,1），
/// 实测输出见 `research/rea/findings.md` §4.1 与 `research/rea/live/hudtest.swift`：
///
/// ```
/// LEVEL=1000 (screenSaver=1000)              ← 高于全屏 App
/// COLLECTION=337  canJoinAllSpaces=true  fullScreenAuxiliary=true
/// STYLE=128  isKeyWindow=false  canBecomeKey=false  canBecomeMain=false   ← 不抢焦点
/// ACTIVATION_POLICY=1 (accessory)            ← 无 Dock 图标
/// ```
///
/// 三个关键点，少一个都会出问题：
/// 1. `.nonactivatingPanel` + `becomesKeyOnlyIfNeeded` → 弹窗出现时你正在打字的 App **不失焦**
/// 2. `level = .screenSaver` → 盖住全屏视频/游戏
/// 3. `.fullScreenAuxiliary` → **只设 level 不设这个，全屏时仍会被挡住**
@MainActor
final class HUDController {

    /// 从 `MiPodsController` 读取状态；HUD 只是展示，不持有业务逻辑。
    private weak var controller: MiPodsController?

    private var panel: NSPanel?

    /// 自动收起任务，重复触发时先取消旧的。
    private var dismissTask: Task<Void, Never>?

    /// 防抖时间戳：连接事件与 BLE 数据可能同时到达，避免连弹两次。
    private var lastShown = Date.distantPast

    /// 防抖窗口（秒）。连接抖动、GATT 重连、状态刷新都可能连触发，
    /// 实测 1.5s 不够（耳机一次连接会连着报好几轮），放宽到 20s：
    /// 一次连接只弹一次 HUD，用户主动点「刷新」仍可手动再弹。
    private let debounceInterval: TimeInterval = 20

    /// 自动收起延迟（秒）。
    private let autoDismissDelay: TimeInterval = 4.0

    /// HUD 上沿距屏幕可视区顶部的距离。
    private let topInset: CGFloat = 24

    init(controller: MiPodsController) {
        self.controller = controller
    }

    // MARK: - 显示 / 隐藏

    /// 弹出 HUD（带防抖）。连接状态变化时调用。
    func show() { show(force: false) }

    /// 用户主动点击时调用：忽略防抖，一定弹出。
    func showForced() { show(force: true) }

    private func show(force: Bool) {
        if !force {
            guard Date().timeIntervalSince(lastShown) > debounceInterval else { return }
        }
        lastShown = Date()

        guard let controller else { return }

        dismissTask?.cancel()

        let panel = panel ?? makePanel()
        self.panel = panel

        // 每次重建 hosting view —— 这样 HUDView 的 .onAppear 才会重播弹簧动画。
        let hosting = NSHostingView(rootView: HUDView(state: controller.state))
        hosting.frame.size = hosting.fittingSize
        hosting.layoutSubtreeIfNeeded()
        panel.setContentSize(hosting.fittingSize)
        panel.contentView = hosting

        positionTopCenter(panel)

        // 淡入（AirPods 原版是从顶部轻微下落 + 淡入）
        panel.alphaValue = 0
        panel.orderFrontRegardless()   // 关键：不激活 App 也能显示
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        // 自动收起
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self!.autoDismissDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide(animated: true)
        }
    }

    /// 立即收起 HUD。
    func hide(animated: Bool = false) {
        dismissTask?.cancel()
        dismissTask = nil
        guard let panel else { return }

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
            }
        } else {
            panel.alphaValue = 0
            panel.orderOut(nil)
        }
    }

    /// 状态变化时若 HUD 正在显示，刷新其内容（不重置弹簧动画）。
    func updateIfVisible() {
        guard let panel, panel.isVisible, let controller else { return }
        let hosting = NSHostingView(rootView: HUDView(state: controller.state))
        hosting.frame.size = hosting.fittingSize
        hosting.layoutSubtreeIfNeeded()
        panel.setContentSize(hosting.fittingSize)
        panel.contentView = hosting
        positionTopCenter(panel)
    }

    // MARK: - 窗口构造

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 76),
            styleMask: [.borderless, .nonactivatingPanel],  // 无边框 + 不激活宿主 App
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel        = true
        panel.becomesKeyOnlyIfNeeded = true    // 永不抢键盘焦点
        panel.hidesOnDeactivate      = false   // 切到别的 App 时别消失
        panel.level                  = .screenSaver   // 1000，盖住全屏 App

        // 背景交给 SwiftUI 的 .ultraThinMaterial，窗口本身必须全透明
        panel.backgroundColor = .clear
        panel.isOpaque        = false
        panel.hasShadow       = true
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false

        // 四个 flag 缺一不可：
        // .canJoinAllSpaces    → 所有桌面空间都显示
        // .fullScreenAuxiliary → 全屏 App 之上（只设 level 不够！）
        // .stationary          → 不跟随 Exposé/切 Space 滑动
        // .ignoresCycle        → Cmd+` 不会切到它
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]

        return panel
    }

    /// 顶部居中，与 AirPods 原生弹窗一致。
    private func positionTopCenter(_ panel: NSPanel) {
        // 优先用鼠标所在屏，其次主屏 —— 多显示器时弹在用户正在看的屏幕。
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }

        let area = screen.visibleFrame
        let size = panel.frame.size
        let x = area.midX - size.width / 2
        // visibleFrame.maxY 已排除菜单栏高度，再让出 topInset
        let y = area.maxY - size.height - topInset
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }
}
