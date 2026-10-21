import Foundation
import CoreBluetooth
func h(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }
func fromHex(_ s: String) -> [UInt8] {
    var o: [UInt8] = []; var i = s.startIndex
    while i < s.endIndex { let n = s.index(i, offsetBy: 2); o.append(UInt8(s[i..<n], radix: 16)!); i = n }
    return o
}
let TARGET = "1300D6D417E2"
let PASS: [UInt8] = [2, 112, 97, 115, 115]
final class P: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var c: CBCentralManager!; var p: CBPeripheral?
    var w: CBCharacteristic?; var n: CBCharacteristic?
    var seq: UInt8 = 0; var buf: [UInt8] = []
    var fired = false
    var myChallenge: [UInt8] = []
    override init() { super.init(); c = CBCentralManager(delegate: self, queue: nil) }
    func centralManagerDidUpdateState(_ cm: CBCentralManager) {
        guard cm.state == .poweredOn else { return }
        cm.scanForPeripherals(withServices: nil, options: nil)
    }
    func centralManager(_ cm: CBCentralManager, didDiscover p: CBPeripheral, advertisementData d: [String: Any], rssi r: NSNumber) {
        guard let m = d[CBAdvertisementDataManufacturerDataKey] as? Data, h([UInt8](m)).contains(TARGET), self.p == nil else { return }
        self.p = p; cm.stopScan(); p.delegate = self; cm.connect(p, options: nil)
    }
    func centralManager(_ cm: CBCentralManager, didConnect p: CBPeripheral) { print("[conn]"); p.discoverServices([CBUUID(string: "AF00")]) }
    func centralManager(_ cm: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { print("[disc]") }
    func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?) { for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) } }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid.uuidString == "AF07" { w = ch }
            if ch.uuid.uuidString == "AF08" { n = ch; p.setNotifyValue(true, for: ch) }
        }
        guard w != nil, n != nil, !fired else { return }
        fired = true
        myChallenge = (0..<16).map { _ in UInt8.random(in: 0...255) }
        print("=== MY CHALLENGE = \(h(myChallenge)) ===")
        send(0x50, [0x01] + myChallenge)
        DispatchQueue.main.asyncAfter(deadline: .now()+20) { print("=== DONE ==="); exit(0) }
    }
    func send(_ op: UInt8, _ pl: [UInt8]) {
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
            let sq = buf[bs]; let pl = Array(buf[(bs+1)..<(total-1)]); let op = buf[4]; let ty = buf[3]
            buf.removeFirst(total)
            print("  FRAME ty=0x\(String(ty,radix:16)) op=0x\(String(format:"%02X",op)) pl=\(h(pl))")
            if op == 0x50, pl.count >= 17 {
                let devAnswer = Array(pl[1..<17])
                print("   DEVICE ANSWER = \(h(devAnswer))")
                let expected = Safer.computeResponse(to: myChallenge)
                print("   SAFER+ EXPECT = \(h(expected))")
                print("   >>> MATCH = \(expected == devAnswer) <<<")
                // Regardless, send PASS confirmation
                DispatchQueue.main.asyncAfter(deadline: .now()+0.4) {
                    print("   sending AUTH_CONFIRM [0x01, 0x00]")
                    self.send(0x51, [0x01, 0x00])
                    DispatchQueue.main.asyncAfter(deadline: .now()+1.0) {
                        print("   === GET_CONFIG 70 ==="); self.send(0xF3, [0x00, 0x00, 0x46])
                    }
                }
            } else if op == 0x51 { print("   *** AUTH CONFIRMED ***") }
            else if op == 0xF3 { print("   *** GET_CONFIG ANSWERED! \(h(pl)) ***") }
            else if isReq { reply(op, sq, []) }
        }
    }
    func reply(_ op: UInt8, _ sq: UInt8, _ pl: [UInt8]) {
        guard let w, let p else { return }
        let len = pl.count + 2
        var f: [UInt8] = [0xFE,0xDC,0xBA,0x04,op,UInt8((len>>8)&0xFF),UInt8(len&0xFF),0x00,sq]
        f.append(contentsOf: pl); f.append(0xEF)
        p.writeValue(Data(f), for: w, type: .withResponse)
    }
}
let pr = P()
RunLoop.main.run(until: Date().addingTimeInterval(25))
