import Foundation
import CoreBluetooth
func h(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }
let TARGET = "1300D6D417E2"
final class P: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var c: CBCentralManager!; var p: CBPeripheral?
    var w: CBCharacteristic?; var n: CBCharacteristic?
    var fired = false
    override init() { super.init(); c = CBCentralManager(delegate: self, queue: nil) }
    func centralManagerDidUpdateState(_ cm: CBCentralManager) {
        guard cm.state == .poweredOn else { return }
        cm.scanForPeripherals(withServices: nil, options: nil)
    }
    func centralManager(_ cm: CBCentralManager, didDiscover p: CBPeripheral, advertisementData d: [String: Any], rssi r: NSNumber) {
        guard let m = d[CBAdvertisementDataManufacturerDataKey] as? Data, h([UInt8](m)).contains(TARGET), self.p == nil else { return }
        self.p = p; cm.stopScan(); p.delegate = self; cm.connect(p, options: nil)
    }
    func centralManager(_ cm: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices([CBUUID(string: "AF00")]) }
    func centralManager(_ cm: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { print("DISC"); exit(2) }
    func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?) { for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) } }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid.uuidString == "AF07" { w = ch }
            if ch.uuid.uuidString == "AF08" { n = ch; p.setNotifyValue(true, for: ch) }
        }
        guard w != nil, n != nil, !fired else { return }
        fired = true
        let pl: [UInt8] = [0xFF,0xFF,0xFF,0xFF]
        let len = pl.count + 1
        var f: [UInt8] = [0xFE,0xDC,0xBA,0xC4,0x02,UInt8((len>>8)&0xFF),UInt8(len&0xFF),0]
        f.append(contentsOf: pl); f.append(0xEF)
        p.writeValue(Data(f), for: w!, type: .withResponse)
        print("TX 0x02 \(h(f))")
        DispatchQueue.main.asyncAfter(deadline: .now()+6) { print("NOANSWER"); exit(1) }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let d = ch.value else { return }
        let bytes = [UInt8](d)
        print("RX \(h(bytes))")
        if bytes.count > 10, bytes[4] == 0x02 { print("ANSWERED"); exit(0) }
    }
}
let pr = P()
RunLoop.main.run(until: Date().addingTimeInterval(9))
