import Foundation
import CoreBluetooth
final class S: NSObject, CBCentralManagerDelegate {
    var c: CBCentralManager!
    var seen = Set<String>()
    override init() { super.init(); c = CBCentralManager(delegate: self, queue: nil) }
    func centralManagerDidUpdateState(_ cm: CBCentralManager) {
        guard cm.state == .poweredOn else { return }
        cm.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
    func centralManager(_ cm: CBCentralManager, didDiscover p: CBPeripheral, advertisementData d: [String: Any], rssi r: NSNumber) {
        guard let m = d[CBAdvertisementDataManufacturerDataKey] as? Data, m.count >= 2 else { return }
        let hex = m.map { String(format: "%02X", $0) }.joined()
        guard hex.hasPrefix("8F03") else { return }
        let key = hex
        guard !seen.contains(key) else { return }
        seen.insert(key)
        let name = (d[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "."
        // Decode: 8F03 | proto(16?) | ... | MACs
        print("ADV name=\(name) rssi=\(r) len=\(m.count)")
        print("    \(hex)")
    }
}
let s = S()
RunLoop.main.run(until: Date().addingTimeInterval(20))
