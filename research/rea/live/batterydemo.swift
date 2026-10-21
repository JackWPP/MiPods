import Foundation
import CoreBluetooth
let targetID = UUID(uuidString: "0FE718F1-7C78-DDC2-EB17-67F3CF732AF6")!
final class B: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var mgr: CBCentralManager!
    func start(){ mgr = CBCentralManager(delegate:self, queue:nil) }
    func centralManagerDidUpdateState(_ c: CBCentralManager){
        guard c.state == .poweredOn else { return }
        // IMPORTANT: this is how you reach an already-connected (system-paired) device
        let connected = c.retrieveConnectedPeripherals(withServices:[CBUUID(string:"180F")])
        if let p = connected.first {
            print("FOUND_VIA_CONNECTED \(p.name ?? "-")")
            p.delegate = self; c.connect(p, options:nil)
        } else if let p = c.retrievePeripherals(withIdentifiers:[targetID]).first {
            p.delegate = self; c.connect(p, options:nil)
        }
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral){
        print("CONNECTED \(p.name ?? "-")"); p.discoverServices(nil)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?){
        for s in p.services ?? [] {
            if s.uuid == CBUUID(string:"180F") || s.uuid == CBUUID(string:"180A") { p.discoverCharacteristics(nil, for:s) }
        }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?){
        print("SVC \(s.uuid.uuidString)")
        for ch in s.characteristics ?? [] {
            if ch.properties.contains(.read) { p.readValue(for: ch) }
            if ch.properties.contains(.notify) { p.setNotifyValue(true, for: ch) }
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?){
        let d = ch.value ?? Data()
        var s = "" ; if let t = String(data:d, encoding:.utf8) { s = t }
        print("VAL \(ch.uuid.uuidString) len=\(d.count) hex=\(d.map{String(format:"%02X",$0)}.joined()) ascii=\(s)")
    }
}
let b = B(); b.start()
RunLoop.main.run(until: Date().addingTimeInterval(15))
print("DONE")
