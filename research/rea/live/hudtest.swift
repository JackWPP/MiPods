import AppKit
import SwiftUI

// Empirical check: build the AirPods-style capsule HUD and report the effective
// window level / collection behavior / activation policy behaviour.
struct Capsule: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "earbuds").font(.system(size: 26))
            VStack(alignment: .leading, spacing: 2) {
                Text("Xiaomi 耳夹式耳机").font(.system(size: 12, weight: .semibold))
                Text("L 60%   R 60%   Case 60%").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .fixedSize()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // LSUIElement equivalent: no Dock icon
let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 60),
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
panel.isFloatingPanel = true
panel.becomesKeyOnlyIfNeeded = true   // never steal keyboard focus
panel.hidesOnDeactivate = false       // survive switching apps
panel.level = .screenSaver            // 1000 -> above full-screen apps
panel.backgroundColor = .clear
panel.isOpaque = false
panel.hasShadow = true
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
let host = NSHostingView(rootView: Capsule())
host.frame.size = host.fittingSize
panel.setContentSize(host.fittingSize)
panel.contentView = host
if let scr = NSScreen.main {
    let f = scr.visibleFrame
    panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width/2, y: f.maxY - panel.frame.height - 24))
}
panel.alphaValue = 0
panel.orderFrontRegardless()
NSAnimationContext.runAnimationGroup { ctx in
    ctx.duration = 0.22
    panel.animator().alphaValue = 1
}
// Report the values the runtime actually accepted
DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
    print("LEVEL=\(panel.level.rawValue) (screenSaver=\(NSWindow.Level.screenSaver.rawValue))")
    print("COLLECTION=\(panel.collectionBehavior.rawValue) canJoinAllSpaces=\(panel.collectionBehavior.contains(.canJoinAllSpaces)) fullScreenAuxiliary=\(panel.collectionBehavior.contains(.fullScreenAuxiliary))")
    print("STYLE=\(panel.styleMask.rawValue) isKeyWindow=\(panel.isKeyWindow) canBecomeKey=\(panel.canBecomeKey) canBecomeMain=\(panel.canBecomeMain)")
    print("ACTIVATION_POLICY=\(app.activationPolicy().rawValue) (accessory=1)")
    print("FRAME=\(panel.frame)")
    print("VISIBLE=\(panel.isVisible) OCCLUSION=\(panel.occlusionState.rawValue)")
    print("HUD_OK")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { app.terminate(nil) }
app.run()
