import Foundation
import CoreBluetooth
final class B: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var mgr: CBCentralManager!
    var target: CBPeripheral?
    func start(){ mgr = CBCentralManager(delegate:self, queue:nil, options:[CBCentralManagerOptionShowPowerAlertKey:false]) }
    func centralManagerDidUpdateState(_ c: CBCentralManager){
        print("STATE=\(c.state.rawValue)")
        guard c.state == .poweredOn else { return }
        // scan to obtain a connectable instance
        c.scanForPeripherals(withServices:nil, options:[CBCentralManagerScanOptionAllowDuplicatesKey:true])
        DispatchQueue.main.asyncAfter(deadline:.now()+6){
            c.stopScan()
            print("scan stopped")
        }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber){
        if p.name?.contains("耳夹式") == true {
            guard target == nil else { return }
            target = p
            print("TARGET \(p.name ?? "-") id=\(p.identifier.uuidString)")
            p.delegate = self
            c.connect(p, options:nil)
        }
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral){
        print("CONNECTED \(p.name ?? "-")")
        p.discoverServices([CBUUID(string:"180F")])
    }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?){
        print("FAIL \(error?.localizedDescription ?? "-")")
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?){
        print("SERVICES \(p.services?.map{$0.uuid.uuidString} ?? [])")
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for:s) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?){
        print("SVC \(s.uuid.uuidString) chars=\((s.characteristics ?? []).map{$0.uuid.uuidString})")
        for ch in s.characteristics ?? [] where ch.properties.contains(.read) { p.readValue(for: ch) }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?){
        let d = ch.value ?? Data()
        print("BATTERY \(ch.uuid.uuidString) = \(d.map{String(format:"%02X",$0)}.joined()) -> \(d.first.map{Int($0)} ?? -1)%")
    }
}
let b = B(); b.start()
RunLoop.main.run(until: Date().addingTimeInterval(30))
print("DONE")
