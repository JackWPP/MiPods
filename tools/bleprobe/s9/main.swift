import Foundation
import CoreBluetooth
func h(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }
let TARGET = "1300D6D417E2"

final class P: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var c: CBCentralManager!; var p: CBPeripheral?
    var chars: [CBUUID: CBCharacteristic] = [:]
    var done = false; var timer: Timer?
    override init() { super.init(); c = CBCentralManager(delegate: self, queue: nil) }
    func centralManagerDidUpdateState(_ cm: CBCentralManager) {
        guard cm.state == .poweredOn else { return }
        cm.scanForPeripherals(withServices: nil, options: nil); print("[scan]")
    }
    func centralManager(_ cm: CBCentralManager, didDiscover p: CBPeripheral, advertisementData d: [String: Any], rssi r: NSNumber) {
        guard let m = d[CBAdvertisementDataManufacturerDataKey] as? Data, h([UInt8](m)).contains(TARGET), self.p == nil else { return }
        self.p = p; cm.stopScan(); p.delegate = self; cm.connect(p, options: nil)
    }
    func centralManager(_ cm: CBCentralManager, didConnect p: CBPeripheral) { print("[conn]"); p.discoverServices(nil) }
    func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?) { for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) } }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            chars[ch.uuid] = ch
            if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                p.setNotifyValue(true, for: ch)
            }
        }
        guard !done, s.uuid == CBUUID(string: "01000100-0000-1000-8000-009078563412") else { return }
        done = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.explore() }
    }
    func explore() {
        guard let p else { return }
        print("=== exploring FD2D (FF10..FF13) + CF07/CF08 + 0300/0200 ===")
        for uuidStr in ["FF11","FF12","FF13","0000CF07-0000-0000-0000-000000000000","03000300-0000-1000-8000-009278563412"] {
            let id = CBUUID(string: uuidStr)
            if let ch = chars[id], ch.properties.contains(.read) {
                p.readValue(for: ch); print("  read \(uuidStr)")
            }
        }
        // Try writing a benign miwear frame to FF10 (write-only) and see if anything notifies
        if let ff10 = chars[CBUUID(string: "FF10")] {
            let probe: [UInt8] = [0xFE,0xDC,0xBA,0xC4,0x02,0x00,0x05,0x00,0xFF,0xFF,0xFF,0xFF,0xEF]
            print("  write miwear GET_DEVICE_INFO to FF10: \(h(probe))")
            p.writeValue(Data(probe), for: ff10, type: .withResponse)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { _ in
            print("=== done ==="); exit(0)
        }
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        print("  WRITE \(ch.uuid.uuidString) ok=\(error == nil) \(error?.localizedDescription ?? "")")
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let v = ch.value else { return }
        print("  VALUE \(ch.uuid.uuidString) = \(h([UInt8](v)))  ascii=\"\(String(bytes: v, encoding: .utf8) ?? "")\"")
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        print("  SUBSCRIBE \(ch.uuid.uuidString) ok=\(error == nil) \(error?.localizedDescription ?? "")")
    }
}
let pr = P()
RunLoop.main.run(until: Date().addingTimeInterval(30))
