import Foundation
import CoreBluetooth
func h(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }

final class P: NSObject, CBCentralManagerDelegate {
    var c: CBCentralManager!
    override init() { super.init(); c = CBCentralManager(delegate: self, queue: nil) }
    func centralManagerDidUpdateState(_ cm: CBCentralManager) {
        guard cm.state == .poweredOn else { return }
        print("=== retrieveConnectedPeripherals with no services ===")
        let a = cm.retrieveConnectedPeripherals(withServices: [])
        print("count=\(a.count)")
        for p in a { print("  \(p.name ?? "?") \(p.identifier.uuidString)") }

        print("=== with 0x180F ===")
        for p in cm.retrieveConnectedPeripherals(withServices: [CBUUID(string: "180F")]) { print("  \(p.name ?? "?") \(p.identifier.uuidString)") }

        print("=== with 0xAF00 ===")
        for p in cm.retrieveConnectedPeripherals(withServices: [CBUUID(string: "AF00")]) { print("  \(p.name ?? "?") \(p.identifier.uuidString)") }

        print("=== with 0xFD2D ===")
        for p in cm.retrieveConnectedPeripherals(withServices: [CBUUID(string: "FD2D")]) { print("  \(p.name ?? "?") \(p.identifier.uuidString)") }

        print("=== with 0xFEE0/FE95/1812/FE59 ===")
        for s in ["FEE0", "FE95", "1812", "FE59", "180A", "1801", "1800", "1846", "FFE0"] {
            let r = cm.retrieveConnectedPeripherals(withServices: [CBUUID(string: s)])
            if !r.isEmpty { for p in r { print("  [\(s)] \(p.name ?? "?") \(p.identifier.uuidString)") } }
        }
        // Known UUIDs from system
        print("=== retrievePeripherals by known identifiers ===")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
    }
}
let p = P()
RunLoop.main.run(until: Date().addingTimeInterval(6))
