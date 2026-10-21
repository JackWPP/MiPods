import Foundation
import CoreBluetooth

let TARGET = "1300D6D417E2"
final class G: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var c: CBCentralManager!; var t: CBPeripheral?
    override init() { super.init(); c = CBCentralManager(delegate: self, queue: nil) }
    func centralManagerDidUpdateState(_ cm: CBCentralManager) {
        guard cm.state == .poweredOn else { return }
        cm.scanForPeripherals(withServices: nil, options: nil)
    }
    func centralManager(_ cm: CBCentralManager, didDiscover p: CBPeripheral, advertisementData d: [String: Any], rssi r: NSNumber) {
        guard let m = d[CBAdvertisementDataManufacturerDataKey] as? Data,
              m.map({ String(format: "%02X", $0) }).joined().contains(TARGET), t == nil else { return }
        t = p; cm.stopScan(); p.delegate = self; cm.connect(p, options: nil)
    }
    func centralManager(_ cm: CBCentralManager, didConnect p: CBPeripheral) {
        print("CONNECTED"); p.delegate = self; p.discoverServices(nil)
    }
    func centralManager(_ cm: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { print("FAIL \(error?.localizedDescription ?? "")") }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { print("SERVICE \(s.uuid.uuidString)"); p.discoverCharacteristics(nil, for: s) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            print("  CHAR \(ch.uuid.uuidString) props=0x\(String(ch.properties.rawValue, radix: 16))")
            if ch.properties.contains(.read) { p.readValue(for: ch) }
            if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                p.setNotifyValue(true, for: ch)
                // also read cached value
                p.readValue(for: ch)
            }
        }
        /* descriptors not needed */
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        let hex = ch.value?.map { String(format: "%02X", $0) }.joined() ?? "nil"
        let ascii = ch.value.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        print("VALUE \(ch.uuid.uuidString) = \(hex)  \(ascii)")
    }
}
let g = G()
RunLoop.main.run(until: Date().addingTimeInterval(20))
print("done")
