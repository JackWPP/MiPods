import Foundation
import CoreBluetooth
let targetID = UUID(uuidString: "0FE718F1-7C78-DDC2-EB17-67F3CF732AF6")!
final class P: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var mgr: CBCentralManager!
    func start() { mgr = CBCentralManager(delegate: self, queue: nil) }
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else { return }
        if let p = c.retrievePeripherals(withIdentifiers: [targetID]).first {
            p.delegate = self; c.connect(p, options: nil)
        }
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        print("CONNECTED \(p.name ?? "-")")
        p.discoverServices(nil)
    }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        print("DISCONNECTED \(error?.localizedDescription ?? "clean")")
    }
    var svcDumped = Set<CBUUID>()
    func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
    }
    func cbName(_ pr: CBCharacteristicProperties) -> String {
        var a:[String]=[]
        if pr.contains(.read){a.append("READ")}
        if pr.contains(.write){a.append("WRITE")}
        if pr.contains(.writeWithoutResponse){a.append("WNR")}
        if pr.contains(.notify){a.append("NOTIFY")}
        if pr.contains(.indicate){a.append("INDICATE")}
        if pr.contains(.authenticatedSignedWrites){a.append("AUTHSIGNED")}
        return a.joined(separator:"|")
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        print("== SERVICE \(s.uuid.uuidString)")
        for ch in s.characteristics ?? [] {
            print("   CHAR \(ch.uuid.uuidString) props=\(cbName(ch.properties))")
            if ch.properties.contains(.read) { p.readValue(for: ch) }
            if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                p.setNotifyValue(true, for: ch)
                print("      -> subscribed")
            }
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        let d = ch.value ?? Data()
        print("   VALUE \(ch.uuid.uuidString) len=\(d.count) hex=\(d.map{String(format:"%02X",$0)}.joined())")
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        if let e = error { print("   NOTIFY_ERR \(ch.uuid.uuidString): \(e.localizedDescription)") }
    }
}
let p = P(); p.start()
RunLoop.main.run(until: Date().addingTimeInterval(20))
print("DONE")
