import AppKit
import SwiftUI
import Combine
import MiPodsCore

/// App 入口。
///
/// 用 `NSApplication` + `NSStatusItem` 而不是 SwiftUI 的 `MenuBarExtra`，原因有三：
/// 1. **窗口层级控制**：HUD 需要 `level = .screenSaver` + `.fullScreenAuxiliary`，
///    `MenuBarExtra` 的弹出窗口我们拿不到足够的控制权。
/// 2. **`MenuBarExtra` 的窗口是 SwiftUI 管理的**，面板需要挂 Touch Bar（`view.touchBar`），
///    必须自己持有 NSWindow 才能拿到宿主视图。
/// 3. **HUD 要在「非活跃 App」状态下弹出**，需要 `orderFrontRegardless()` 这类 AppKit 级能力。
///
/// 激活策略用 `.accessory`：菜单栏有图标、**Dock 无图标**、App 切换器里不出现。
@main
struct MiPodsApp {

    static func main() {
        let app = NSApplication.shared
        // 必须在 UI 建立前设置，否则 Dock 图标会先闪一下
        app.setActivationPolicy(.accessory)

        let delegate = AppDelegate()
        app.delegate = delegate
        // 强引用住 delegate：NSApplication.delegate 是 weak 的
        objc_setAssociatedObject(app, "MiPodsAppDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        app.run()
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let controller = MiPodsController()

    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var hud: HUDController?
    private var touchBar: TouchBarController?

    /// 观察 controller.state 变化，用于刷新菜单栏与（可见时）HUD。
    private var cancellables = Set<AnyCancellable>()

    /// 上一次看到的连接状态，用于「刚连上 → 弹 HUD」。
    private var wasConnected = false

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        let hud = HUDController(controller: controller)
        self.hud = hud

        let touchBar = TouchBarController(controller: controller)
        self.touchBar = touchBar

        // 状态变化 → 更新菜单栏标题 + HUD + Touch Bar
        controller.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.updateStatusItemTitle(state)

                // 连接状态由「未连接 → 已连接」时弹 HUD
                if state.isConnected && !self.wasConnected {
                    self.hud?.show()
                }
                self.wasConnected = state.isConnected

                // HUD 若正显示，实时刷新内容
                self.hud?.updateIfVisible()
            }
            .store(in: &cancellables)

        controller.start()

        // 开发用：MIPODS_DEMO=1 时自动打开面板并弹 HUD，便于截图验证
        if ProcessInfo.processInfo.environment["MIPODS_DEMO"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.openPanel()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
                self?.hud?.show()
            }
        }

        // 冷启动时耳机可能已经连着：主动读一次，若已连接也弹一次 HUD
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.controller.state.isConnected else { return }
            self.hud?.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hud?.hide()
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "earbuds",
                accessibilityDescription: L10n.appName
            )
            button.image?.isTemplate = true    // 自动适配深浅色菜单栏
            button.imagePosition = .imageLeading
            button.action = #selector(togglePanel)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        updateStatusItemTitle(controller.state)
    }

    private func updateStatusItemTitle(_ state: MiPodsState) {
        guard let button = statusItem?.button else { return }

        if state.isConnected {
            // 已连接：图标 + 「左/右/盒」紧凑电量
            button.title = " " + state.compactBatteryText
            button.image = NSImage(
                systemSymbolName: "earbuds",
                accessibilityDescription: L10n.appName
            )

            // 低电变红，给用户一眼可见的警示
            if let lowest = state.lowestBattery, lowest <= 20, !state.isAnyCharging {
                button.contentTintColor = .systemRed
            } else {
                button.contentTintColor = nil
            }
        } else {
            // 未连接：只留图标
            button.title = ""
            button.contentTintColor = nil
            button.image = NSImage(
                systemSymbolName: "earbuds",
                accessibilityDescription: L10n.statusDisconnected
            )
        }
        button.image?.isTemplate = true
    }

    // MARK: - 面板

    @objc private func togglePanel() {
        if panel?.isVisible == true {
            closePanel()
        } else {
            openPanel()
        }
    }

    private func openPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let view = PanelView(
            controller: controller,
            onShowHUD: { [weak self] in self?.hud?.showForced() },
            onOpenSoundSettings: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        )

        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        panel.setContentSize(size)
        panel.contentView = hosting
        panel.layoutIfNeeded()

        positionPanelBelowStatusItem(panel)

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 面板成为 key window 时才挂 Touch Bar
        touchBar?.attach(to: hosting)
    }

    private func closePanel() {
        touchBar?.detach()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu            // 101，高于普通窗口
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = true

        // 点击面板外自动收起（AirPods 风格面板的行为）
        panel.delegate = self
        return panel
    }

    /// 面板出现在菜单栏图标正下方、右对齐。
    private func positionPanelBelowStatusItem(_ panel: NSPanel) {
        let size = panel.frame.size
        guard let screen = NSScreen.main ?? statusItem?.button?.window?.screen else { return }
        let visible = screen.visibleFrame

        // Determine the status item's horizontal centre. `NSStatusItem.button.bounds`
        // is unreliable (zero-size until laid out), so prefer the button window frame and
        // fall back to the current mouse position (the click that opened us).
        var centerX: CGFloat
        if let button = statusItem?.button, let window = button.window {
            let rectInWindow = button.convert(button.bounds, to: nil)
            let rectInScreen = window.convertToScreen(rectInWindow)
            if rectInScreen.width > 0 {
                centerX = rectInScreen.midX
            } else if window.frame.width > 0 {
                centerX = window.frame.midX
            } else {
                centerX = NSEvent.mouseLocation.x
            }
        } else {
            centerX = NSEvent.mouseLocation.x
        }

        var x = centerX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)

        // Menu bar height is the gap between the screen top and the visible frame top.
        let menuBarHeight = screen.frame.maxY - visible.maxY
        let y = screen.frame.maxY - menuBarHeight - size.height - 6
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }
}

// MARK: - 点击面板外收起

extension AppDelegate: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        // 面板失焦就收起，避免挡住别的 App
        closePanel()
    }
}

// MARK: - 菜单验证

extension AppDelegate: NSMenuDelegate {}
