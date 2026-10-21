import Foundation
import CoreBluetooth
func h(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }
let TARGET = "1300D6D417E2"
final class P: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var c: CBCentralManager!; var p: CBPeripheral?
    var w: CBCharacteristic?; var n: CBCharacteristic?
    var seq: UInt8 = 0; var buf: [UInt8] = []
    var fired = false; var challenge: [UInt8] = []
    var answers = 0
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
    func centralManager(_ cm: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { print("DISC answers=\(answers)"); exit(2) }
    func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?) { for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) } }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid.uuidString == "AF07" { w = ch }
            if ch.uuid.uuidString == "AF08" { n = ch; p.setNotifyValue(true, for: ch) }
        }
        guard w != nil, n != nil, !fired else { return }
        fired = true
        challenge = (0..<16).map { _ in UInt8.random(in: 0...255) }
        mma(0x50, [0x01] + challenge)   // FIRST FRAME
        DispatchQueue.main.asyncAfter(deadline: .now()+14) { print("EXIT answers=\(self.answers)"); exit(0) }
    }
    func mma(_ op: UInt8, _ pl: [UInt8]) {
        guard let w, let p else { return }
        let len = pl.count + 1
        var f: [UInt8] = [0xFE,0xDC,0xBA,0xC4,op,UInt8((len>>8)&0xFF),UInt8(len&0xFF),seq]
        f.append(contentsOf: pl); f.append(0xEF); seq &+= 1
        p.writeValue(Data(f), for: w, type: .withResponse)
        print("TX \(h(f))")
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let d = ch.value else { return }
        buf.append(contentsOf: [UInt8](d)); drain()
    }
    func drain() {
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
            let sq = buf[bs]; let pl = Array(buf[(bs+1)..<(total-1)]); let op = buf[4]
            buf.removeFirst(total)
            print("  RX op=0x\(String(format:"%02X",op)) pl=\(h(pl))")
            if op == 0x50, pl.count >= 17 {
                answers += 1
                print("   >>> AUTH answered; MATCH=\(Safer.computeResponse(to: challenge) == Array(pl[1..<17]))")
                // Full handshake: confirm, then PASS, then query
                mma(0x51, [0x01, 0x00])
                DispatchQueue.main.asyncAfter(deadline: .now()+0.6) {
                    print("   -> PASS raw")
                    if let w = self.w, let p = self.p {
                        p.writeValue(Data([2,112,97,115,115]), for: w, type: .withResponse)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now()+0.8) {
                        print("   -> 0x02 control (must work)")
                        self.mma(0x02, [0xFF,0xFF,0xFF,0xFF])
                        print("   -> GET_CONFIG 70")
                        self.mma(0xF3, [0x02, 0x00, 70])
                    }
                }
            }
        }
    }
}
let pr = P()
RunLoop.main.run(until: Date().addingTimeInterval(18))
