import AppKit

// Runtime probe: which Touch Bar display mechanisms are actually reachable?
let app = NSApplication.shared

// 1) Private system-modal API used by some apps
let systemModalSels = [
  "presentSystemModalTouchBar:",
  "presentSystemModalTouchBar:systemTrayItemIdentifier:",
  "dismissSystemModalTouchBar:",
  "presentSystemModalFunctionBar:",
  "presentSystemModalFunctionBar:systemTrayItemIdentifier:"
]
for s in systemModalSels {
  let sel = NSSelectorFromString(s)
  print("NSTouchBar.\(s) instance-reachable = \(NSTouchBar.instancesRespond(to: sel))")
}

// 2) App-global Touch Bar (NSApplication inherits NSResponder.touchBar)
let selTB = NSSelectorFromString("setTouchBar:")
print("NSApplication responds to touchBar setter = \(NSApplication.instancesRespond(to: selTB))")
let selMT = NSSelectorFromString("makeTouchBar")
print("NSApplication responds to makeTouchBar = \(NSApplication.instancesRespond(to: selMT))")
print("NSApplication conforms to NSTouchBarProvider = \(app is NSTouchBarProvider)")

// 3) NSTouchBarItem identifiers available publicly
let ids: [NSTouchBarItem.Identifier] = [
  .fixedSpaceSmall, .fixedSpaceLarge, .flexibleSpace, .otherItemsProxy
]
print("public item identifiers: \(ids.map { $0.rawValue })")

// 4) Is there any Control Strip related public identifier?
let candidates = ["ControlStrip", "com.apple.controlstrip", "NSTouchBarItemIdentifierControlStrip"]
for c in candidates {
  print("identifier '\(c)' defined publicly = \(NSTouchBarItem.Identifier(rawValue: c).rawValue == c ? "type-exists-but-not-a-constant" : "?")")
}

// 5) App-level bar assignability test (accessory app, no window)
app.setActivationPolicy(.accessory)
let bar = NSTouchBar()
bar.defaultItemIdentifiers = []
app.touchBar = bar
print("app.touchBar assigned = \(app.touchBar != nil)")
print("app.isActive = \(app.isActive)")
