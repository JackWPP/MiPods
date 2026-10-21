import Foundation
import CoreBluetooth

let target = "00:13:D6:E2:17:D4".uppercased()

final class S: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var mgr: CBCentralManager!
    var found = false
    var done = false
    func start() {
        mgr = CBCentralManager(delegate: self, queue: nil)
    }
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        print("STATE=\(c.state.rawValue) auth=\(CBManager.authorization.rawValue)")
        if c.state == .poweredOn {
            print("SCANNING...")
            c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        } else { done = true }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let id = p.identifier.uuidString
        // print any peripheral whose advertisement mentions 0x038F / FE95 service or whose name looks like xiaomi
        var svcHex: [String] = []
        if let uu = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            for u in uu { svcHex.append(u.uuidString) }
        }
        let kCBAdvDataManufacturerData = advertisementData["kCBAdvDataManufacturerData"] as? Data
        var mfg = ""
        if let d = kCBAdvDataManufacturerData, d.count >= 2 {
            let cid = UInt16(d[0]) | (UInt16(d[1]) << 8)
            mfg = String(format: "companyId=0x%04X ", cid)
            if cid == 0x038F { print("HIT_XIAOMI name=\(p.name ?? "-") id=\(id) mfg=\(d.map{String(format:"%02X",$0)}.joined()) svc=\(svcHex)") }
        }
        if let n = p.name, n.uppercased().contains(target) || n.localizedCaseInsensitiveContains("clip") || n.localizedCaseInsensitiveContains("buds") {
            print("HIT_NAME name=\(n) id=\(id) mfg=\(mfg) svc=\(svcHex) rssi=\(rssi)")
        }
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        print("CONNECTED \(p.name ?? "-")")
        p.delegate = self
        p.discoverServices(nil)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?) {
        for s in p.services ?? [] {
            print("SERVICE \(s.uuid.uuidString) primary=\(s.isPrimary)")
            p.discoverCharacteristics(nil, for: s)
        }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            print("  CHAR svc=\(s.uuid.uuidString) uuid=\(ch.uuid.uuidString) props=\(ch.properties.rawValue)")
        }
    }
}
let s = S()
s.start()
RunLoop.main.run(until: Date().addingTimeInterval(12))
print("DONE")
