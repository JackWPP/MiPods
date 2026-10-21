import Foundation
import CoreBluetooth
for i in stride(from: 0, to: 4, by: 1) { _ = i }
final class B: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var mgr: CBCentralManager!
    func start(){ mgr = CBCentralManager(delegate:self, queue:nil) }
    func centralManagerDidUpdateState(_ c: CBCentralManager){
        guard c.state == .poweredOn else { print("state=\(c.state.rawValue)"); return }
        let connected = c.retrieveConnectedPeripherals(withServices:[CBUUID(string:"180F")])
        if let p = connected.first {
            print("FOUND_VIA_CONNECTED \(p.name ?? "-") state=\(p.state.rawValue)")
            p.delegate = self
            if p.state == .connected { print("already connected -> discoverServices"); p.discoverServices(nil) }
            else { c.connect(p, options:nil) }
        } else { print("NO_CONNECTED_PERIPHERAL_WITH_180F") }
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral){
        print("CONNECTED \(p.name ?? "-")"); p.discoverServices(nil)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?){
        print("SERVICES n=\(p.services?.count ?? 0)")
        for s in p.services ?? [] {
            print("  SVC \(s.uuid.uuidString)")
            p.discoverCharacteristics(nil, for:s)
        }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?){
        for ch in s.characteristics ?? [] {
            if ch.properties.contains(.read) { p.readValue(for: ch) }
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?){
        let d = ch.value ?? Data()
        let t = String(data:d, encoding:.utf8) ?? ""
        print("VAL \(ch.uuid.uuidString) len=\(d.count) hex=\(d.map{String(format:"%02X",$0)}.joined()) ascii=\(t)")
    }
}
let b = B(); b.start()
RunLoop.main.run(until: Date().addingTimeInterval(20))
print("DONE")
