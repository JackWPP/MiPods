import Foundation
import CoreBluetooth

// Bounded, read-only GATT dump for the Xiaomi earbuds.
// NEVER writes to a characteristic (no writeValue calls at all).
let targetID = UUID(uuidString: "0FE718F1-7C78-DDC2-EB17-67F3CF732AF6")!
var connected: CBPeripheral?

final class D: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var mgr: CBCentralManager!
    func start() { mgr = CBCentralManager(delegate: self, queue: nil) }
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        print("STATE=\(c.state.rawValue)")
        guard c.state == .poweredOn else { return }
        let known = c.retrievePeripherals(withIdentifiers: [targetID])
        print("retrieved=\(known.count)")
        if let p = known.first {
            connected = p
            p.delegate = self
            print("connecting to \(p.name ?? "-") ...")
            c.connect(p, options: nil)
        } else {
            print("NOT_FOUND_AMONG_PAIRED; scanning")
            c.scanForPeripherals(withServices: nil, options: nil)
        }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        if p.identifier == targetID {
            print("discovered target")
            c.stopScan()
            connected = p; p.delegate = self
            c.connect(p, options: nil)
        }
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        print("CONNECTED name=\(p.name ?? "-") rssi=\(p.rssi?.intValue ?? 0)")
        p.discoverServices(nil)
    }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        print("FAIL_TO_CONNECT \(error?.localizedDescription ?? "-")")
    }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        print("DISCONNECTED \(error?.localizedDescription ?? "clean")")
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?) {
        if let e = e { print("svc err \(e)") }
        print("SERVICE_COUNT=\(p.services?.count ?? 0)")
        for s in p.services ?? [] {
            print("SERVICE uuid=\(s.uuid.uuidString) primary=\(s.isPrimary)")
            p.discoverCharacteristics(nil, for: s)
        }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        print("CHARACTERISTICS_FOR \(s.uuid.uuidString):")
        for ch in s.characteristics ?? [] {
            print("  CHAR uuid=\(ch.uuid.uuidString) props=0x\(String(ch.properties.rawValue, radix:16))")
        }
        // read only safe, no-write discovery aids
        for ch in s.characteristics ?? [] {
            if ch.properties.contains(.read) { p.readValue(for: ch) }
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        let d = ch.value ?? Data()
        print("  VALUE uuid=\(ch.uuid.uuidString) len=\(d.count) hex=\(d.map{String(format:"%02X",$0)}.joined())")
    }
    func peripheral(_ p: CBPeripheral, didDiscoverDescriptorsFor ch: CBCharacteristic, error: Error?) {}
}
let d = D(); d.start()
RunLoop.main.run(until: Date().addingTimeInterval(25))
print("DONE")
