import Foundation
import CoreBluetooth
func h(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }
let TARGET = "1300D6D417E2"
let PASS: [UInt8] = [2, 112, 97, 115, 115]

final class P: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var c: CBCentralManager!; var p: CBPeripheral?
    var w: CBCharacteristic?; var n: CBCharacteristic?
    var seq: UInt8 = 0; var buf: [UInt8] = []
    var attempt = 0; var tryTimer: Timer?
    var gotAuthReply = false
    override init() { super.init(); c = CBCentralManager(delegate: self, queue: nil) }
    func centralManagerDidUpdateState(_ cm: CBCentralManager) {
        guard cm.state == .poweredOn else { return }
        cm.scanForPeripherals(withServices: nil, options: nil)
    }
    func centralManager(_ cm: CBCentralManager, didDiscover p: CBPeripheral, advertisementData d: [String: Any], rssi r: NSNumber) {
        guard let m = d[CBAdvertisementDataManufacturerDataKey] as? Data, h([UInt8](m)).contains(TARGET), self.p == nil else { return }
        self.p = p; cm.stopScan(); p.delegate = self; cm.connect(p, options: nil)
    }
    func centralManager(_ cm: CBCentralManager, didConnect p: CBPeripheral) {
        print("[conn] attempt loop start"); p.discoverServices([CBUUID(string: "AF00")])
    }
    func centralManager(_ cm: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { print("[disc]") }
    func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?) { for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) } }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid.uuidString == "AF07" { w = ch }
            if ch.uuid.uuidString == "AF08" { n = ch; p.setNotifyValue(true, for: ch) }
        }
        guard w != nil, n != nil, tryTimer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now()+0.6) { self.send(0x02, [0xFF,0xFF,0xFF,0xFF]) }
        // retry auth every 2.5s up to 6 times, and also try the PASS magic on later attempts
        tryTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
            if self.gotAuthReply { return }
            self.attempt += 1
            if self.attempt > 6 {
                print("=== GAVE UP after 6 attempts, gotAuthReply=\(self.gotAuthReply) ===")
                exit(0)
            }
            let pl: [UInt8]
            if self.attempt <= 3 {
                pl = [0x01] + (0..<16).map { _ in UInt8.random(in: 0...255) }
            } else {
                pl = PASS
            }
            print("=== AUTH attempt #\(self.attempt) payload=\(h(pl)) ===")
            self.send(0x50, pl)
        }
        DispatchQueue.main.asyncAfter(deadline: .now()+45) { print("=== TIMEOUT ==="); exit(0) }
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
        print("  RX \(h([UInt8](d)))")
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
            if op == 0x50 {
                gotAuthReply = true
                print("   *** GOT AUTH REPLY! first byte=\(pl.first ?? 0) ***")
                if let v = pl.first, v == 0, pl.count >= 17 {
                    let a = Safer.computeResponse(to: Array(pl[1..<17]))
                    reply(0x50, sq, [0x00] + a)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now()+0.5) {
                        self.send(0x51, PASS)
                        DispatchQueue.main.asyncAfter(deadline: .now()+0.9) {
                            print("=== TRY GET_CONFIG 70 AFTER AUTH ===")
                            self.send(0xF3, [0x00, 0x00, 0x46])
                        }
                    }
                }
            } else if op == 0x51 {
                print("   *** AUTH CONFIRMED ***")
                DispatchQueue.main.asyncAfter(deadline: .now()+0.6) { self.send(0xF3, [0x00, 0x00, 0x46]) }
            } else if op == 0xF3 {
                print("   *** GET_CONFIG ANSWERED! \(h(pl)) ***")
            } else if isReq { reply(op, sq, []) }
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
RunLoop.main.run(until: Date().addingTimeInterval(50))
