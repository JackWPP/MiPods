import Foundation
import CoreBluetooth
func h(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }
// Charging case MAC C0:13:D6:E2:17:D5 -> LE order bytes: C0 13 D6 E2 17 D5
let CASE_ADDR = "C0 13 D6 E2 17 D5"
final class P: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var c: CBCentralManager!; var seen = Set<String>(); var connected = Set<String>()
    override init() { super.init(); c = CBCentralManager(delegate: self, queue: nil) }
    func centralManagerDidUpdateState(_ cm: CBCentralManager) {
        guard cm.state == .poweredOn else { return }
        cm.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        print("[scan]")
    }
    func centralManager(_ cm: CBCentralManager, didDiscover p: CBPeripheral, advertisementData d: [String: Any], rssi r: NSNumber) {
        let name = (d[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "."
        let mfr = (d[CBAdvertisementDataManufacturerDataKey] as? Data).map { h([UInt8]($0)) } ?? "-"
        let key = p.identifier.uuidString
        // Try to connect to anything whose adv contains the case MAC or has no name but Xiaomi company
        let looksLikeCase = mfr.contains("C013D6E217D5") || mfr.contains("D517E2D613C0")
        if looksLikeCase, !connected.contains(key) {
            connected.insert(key)
            print("CASE? name=\(name) id=\(key) rssi=\(r) mfr=\(mfr) -> connecting")
            p.delegate = self
            cm.connect(p, options: nil)
            return
        }
        if seen.insert(mfr).inserted {
            print("ADV name=\(name) rssi=\(r) len=\(mfr.count/2) \(mfr)")
        }
    }
    func centralManager(_ cm: CBCentralManager, didConnect p: CBPeripheral) {
        print("CONNECTED \(p.name ?? "?") \(p.identifier.uuidString)")
        p.discoverServices(nil)
    }
    func centralManager(_ cm: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { print("FAILED \(error?.localizedDescription ?? "")") }
    func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?) {
        print("SERVICES of \(p.name ?? p.identifier.uuidString):")
        for s in p.services ?? [] { print("  \(s.uuid.uuidString)"); p.discoverCharacteristics(nil, for: s) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            print("    CHAR \(ch.uuid.uuidString) props=0x\(String(ch.properties.rawValue, radix:16))")
            if ch.properties.contains(.read) { p.readValue(for: ch) }
            if ch.properties.contains(.notify) { p.setNotifyValue(true, for: ch) }
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if let v = ch.value { print("    VALUE \(ch.uuid.uuidString) = \(h([UInt8](v)))") }
    }
}
let p = P()
RunLoop.main.run(until: Date().addingTimeInterval(20))
