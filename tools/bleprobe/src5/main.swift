import Foundation
import CoreBluetooth

enum MType: UInt8 { case phoneRequest = 0xC4, response = 0x04, earbudsRequest = 0xC0, earbudsNotify = 0xC7 }
func enc(_ t: MType, _ op: UInt8, _ seq: UInt8, _ pl: [UInt8]) -> [UInt8] {
    let isReq = (t.rawValue & 0x40) != 0
    let len = pl.count + (isReq ? 1 : 2)
    var b: [UInt8] = [0xFE,0xDC,0xBA,t.rawValue,op,UInt8((len>>8)&0xFF),UInt8(len&0xFF)]
    if !isReq { b.append(0) }
    b.append(seq); b.append(contentsOf: pl); b.append(0xEF)
    return b
}
func h(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }
let TARGET = "1300D6D417E2"

final class P: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var c: CBCentralManager!; var t: CBPeripheral?
    var w: CBCharacteristic?; var n: CBCharacteristic?
    var seq: UInt8 = 0; var buf: [UInt8] = []; var started = false
    var authDone = false
    override init() { super.init(); c = CBCentralManager(delegate: self, queue: nil) }
    func centralManagerDidUpdateState(_ cm: CBCentralManager) {
        guard cm.state == .poweredOn else { return }
        cm.scanForPeripherals(withServices: nil, options: nil)
    }
    func centralManager(_ cm: CBCentralManager, didDiscover p: CBPeripheral, advertisementData d: [String: Any], rssi r: NSNumber) {
        guard let m = d[CBAdvertisementDataManufacturerDataKey] as? Data, h([UInt8](m)).contains(TARGET), t == nil else { return }
        t = p; cm.stopScan(); p.delegate = self; cm.connect(p, options: nil)
    }
    func centralManager(_ cm: CBCentralManager, didConnect p: CBPeripheral) { print("[conn]"); p.discoverServices(nil) }
    func centralManager(_ cm: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { print("[disc] \(error?.localizedDescription ?? "")") }
    func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?) { for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) } }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid.uuidString == "AF07" { w = ch }
            if ch.uuid.uuidString == "AF08" { n = ch; p.setNotifyValue(true, for: ch) }
        }
        guard w != nil, n != nil, !started else { return }
        started = true
        later(0.5) { self.tx(p, 0x50, [0x01] + (0..<16).map { _ in UInt8.random(in: 0...255) }) }
        // Probe GET-style opcodes only, spread out so each can answer.
        var t = 3.0
        for op: UInt8 in [0x02, 0x09, 0x10, 0x11, 0x12, 0x20, 0x21, 0x23, 0x25, 0x2A, 0x2F] {
            later(t) { self.tx(p, op, [0xFF,0xFF,0xFF,0xFF]) }
            t += 1.2
        }
        later(t + 1) { self.tx(p, 0x0E, [0xFF]) }
    }
    func later(_ d: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: f) }
    func tx(_ p: CBPeripheral, _ op: UInt8, _ pl: [UInt8]) {
        guard let w = w else { return }
        let f = enc(.phoneRequest, op, seq, pl); seq &+= 1
        let ty: CBCharacteristicWriteType = w.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(Data(f), for: w, type: ty)
        print("TX op=0x\(String(format:"%02X",op)) \(h(f))")
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let d = ch.value else { return }
        buf.append(contentsOf: [UInt8](d)); drain(p)
    }
    func drain(_ p: CBPeripheral) {
        while true {
            guard let i = buf.firstIndex(of: 0xFE) else { buf.removeAll(); return }
            if i > 0 { buf.removeFirst(i) }
            guard buf.count >= 7, buf[1] == 0xDC, buf[2] == 0xBA else { buf.removeFirst(1); continue }
            let isReq = (buf[3] & 0x40) != 0
            let len = Int(buf[5])<<8 | Int(buf[6])
            guard len >= 1, len <= 4096 else { buf.removeFirst(1); continue }
            let total = 7 + len + 1
            guard buf.count >= total else { return }
            guard buf[total-1] == 0xEF else { buf.removeFirst(1); continue }
            let bs = 7 + (isReq ? 0 : 1)
            let sq = buf[bs]; let pl = Array(buf[(bs+1)..<(total-1)]); let op = buf[4]; let ty = buf[3]
            buf.removeFirst(total)
            print("  RX ty=0x\(String(ty,radix:16)) op=0x\(String(format:"%02X",op)) seq=\(String(format:"%02X",sq)) \(h(pl))")
            if op == 0x50, ty == 0x04, pl.count >= 17 { let a = Safer.computeResponse(to: Array(pl[1..<17]))
                let f = enc(.response, 0x50, sq, [0x01] + a)
                if let w = w { p.writeValue(Data(f), for: w, type: .withResponse) }
                print("  -> SAFER answer")
            }
            if op == 0x51, isReq {
                let f = enc(.response, 0x51, sq, [0x01])
                if let w = w { p.writeValue(Data(f), for: w, type: .withResponse) }
                print("  *** AUTH OK ***"); authDone = true
            }
            if isReq && op != 0x50 && op != 0x51 {
                let f = enc(.response, op, sq, [])
                if let w = w { p.writeValue(Data(f), for: w, type: .withResponse) }
            }
        }
    }
}
let p = P()
RunLoop.main.run(until: Date().addingTimeInterval(22))
print("DONE")
