import AppKit
// Compile-level + runtime check of NSTouchBar availability and window-level constants.
print("NSWindow.Level.screenSaver = \(NSWindow.Level.screenSaver.rawValue)")
print("NSWindow.Level.statusBar = \(NSWindow.Level.statusBar.rawValue)")
print("NSWindow.Level.popUpMenu = \(NSWindow.Level.popUpMenu.rawValue)")
print("NSWindow.Level.mainMenu = \(NSWindow.Level.mainMenu.rawValue)")
print("NSWindow.Level.floating = \(NSWindow.Level.floating.rawValue)")
print("NSWindow.Level.modalPanel = \(NSWindow.Level.modalPanel.rawValue)")
let cb: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
print("collectionBehavior raw = \(cb.rawValue)")
let style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
print("styleMask raw = \(style.rawValue)")
print("NSTouchBar class = \(NSTouchBar.self)")
print("NSTouchBarItem class = \(NSTouchBarItem.self)")
print("has NSTouchBarProvider = \(NSTouchBarProvider.self)")
// Check Touch Bar presence
let sel = NSSelectorFromString("isTouchBarAvailable")
print("class func isTouchBarAvailable exists on NSTouchBar: \(NSTouchBar.responds(to: sel))")
if NSTouchBar.responds(to: sel) { print("touch bar available = \(String(describing: NSTouchBar.perform(sel)))") }
