import AppKit
// Definitive Touch Bar presence check for this Mac
print("hw.model:", ProcessInfo.processInfo.environment["HW_MODEL"] ?? "n/a")
let cls = NSClassFromString("NSFunctionBar") ?? NSClassFromString("NSTouchBar")
print("NSTouchBar class present:", NSTouchBar.self)
// DFR display detection via IOKit service matching
import IOKit
var iterator: io_iterator_t = 0
let ok = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator)
print("ioreg scan ok=\(ok)")
if ok == KERN_SUCCESS {
    var found = 0
    var svc = IOIteratorNext(iterator)
    while svc != 0 {
        var nameBuf = [CChar](repeating: 0, count: 128)
        if IORegistryEntryGetName(svc, &nameBuf) == KERN_SUCCESS {
            let n = String(cString: nameBuf)
            if n.lowercased().contains("dfr") { print("DFR node:", n); found += 1 }
        }
        IOObjectRelease(svc)
        svc = IOIteratorNext(iterator)
    }
    IOObjectRelease(iterator)
    print("DFR node count=\(found)")
}
// Touch Bar availability via AppKit private-ish API
let sel = NSSelectorFromString("isTouchBarAvailable")
print("responds:", NSTouchBar.responds(to: sel))
