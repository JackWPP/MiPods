import Foundation
import CoreBluetooth

let TARGET_MAC_SUFFIX = "1300D6D417E2"   // LE-encoded 00:13:D6:E2:17:D4

final class G: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var c: CBCentralManager!
    var target: CBPeripheral?
    var connected = false
    override init() { super.init(); c = CBCentralManager(delegate: self, queue: nil) }

    func centralManagerDidUpdateState(_ cm: CBCentralManager) {
        print("[state] \(cm.state.rawValue)")
        guard cm.state == .poweredOn else { return }
        cm.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        print("[scan] for Xiaomi adv…")
    }

    func centralManager(_ cm: CBCentralManager, didDiscover p: CBPeripheral, advertisementData d: [String: Any], rssi r: NSNumber) {
        guard let mfr = d[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
        let hex = mfr.map { String(format: "%02X", $0) }.joined()
        guard hex.hasPrefix("8F03") else { return }
        print("ADV \(p.identifier.uuidString) rssi=\(r) len=\(mfr.count) hex=\(hex)")
        if hex.contains(TARGET_MAC_SUFFIX) && target == nil {
            print(">>> MATCH our earbuds. connecting…")
            target = p
            cm.stopScan()
            p.delegate = self
            cm.connect(p, options: nil)
        }
    }

    func centralManager(_ cm: CBCentralManager, didConnect p: CBPeripheral) {
        print(">>> CONNECTED \(p.name ?? "?")")
        connected = true
        p.delegate = self
        p.discoverServices(nil)
    }
    func centralManager(_ cm: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        print(">>> FAILED TO CONNECT: \(error?.localizedDescription ?? "nil")")
    }
    func centralManager(_ cm: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        print(">>> DISCONNECTED \(error?.localizedDescription ?? "")")
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let e = error { print("svc err \(e)"); return }
        for s in p.services ?? [] {
            print("SERVICE \(s.uuid)")
            p.discoverCharacteristics(nil, for: s)
        }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            print("   CHAR \(ch.uuid) props=\(ch.properties.rawValue)")
        }
    }
}

let g = G()
RunLoop.main.run(until: Date().addingTimeInterval(Double(CommandLine.arguments.dropFirst().first ?? "20") ?? 20))
print("done connected=\(g.connected)")
