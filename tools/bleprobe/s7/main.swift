import Foundation
import CoreBluetooth

func h(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }
let TARGET = "1300D6D417E2"

final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var c: CBCentralManager!
    var p: CBPeripheral?
    var w: CBCharacteristic?
    var n: CBCharacteristic?
    var seq: UInt8 = 0
    var buf: [UInt8] = []
    var step = 0
    var timer: Timer?
    var log: [String] = []

    override init() { super.init(); c = CBCentralManager(delegate: self, queue: nil) }

    func centralManagerDidUpdateState(_ cm: CBCentralManager) {
        guard cm.state == .poweredOn else { return }
        cm.scanForPeripherals(withServices: nil, options: nil)
        print("[scan]")
    }
    func centralManager(_ cm: CBCentralManager, didDiscover p: CBPeripheral, advertisementData d: [String: Any], rssi r: NSNumber) {
        guard let m = d[CBAdvertisementDataManufacturerDataKey] as? Data,
              h([UInt8](m)).contains(TARGET), self.p == nil else { return }
        self.p = p; cm.stopScan(); p.delegate = self; cm.connect(p, options: nil)
    }
    func centralManager(_ cm: CBCentralManager, didConnect p: CBPeripheral) {
        print("[conn]"); p.discoverServices([CBUUID(string: "AF00")])
    }
    func centralManager(_ cm: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        print("[disc] reconnecting in 2s")
        w = nil; n = nil; seq = 0; buf = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.c.scanForPeripherals(withServices: nil, options: nil) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid.uuidString == "AF07" { w = ch }
            if ch.uuid.uuidString == "AF08" { n = ch; p.setNotifyValue(true, for: ch) }
        }
        guard w != nil, n != nil, timer == nil else { return }
        start()
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: true) { _ in self.tick() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.send(0x02, [0xFF,0xFF,0xFF,0xFF]) }
    }

    func tick() {
        step += 1
        switch step {
        case 2: send(0x50, [0x01] + (0..<16).map { _ in UInt8.random(in: 0...255) })
        case 4: send(0x09, [0xFF,0xFF,0xFF,0xFF])
        case 6: send(0x01, [0x01, 0x00])                 // XM_DATA probe
        case 8: send(0xF3, [0x00, 0x00])                 // GET_CONFIG 0x00
        case 10: send(0xF3, [0x00, 0x02])
        case 12: send(0xF3, [0x00, 0x0C])
        case 14: send(0x10, [0xFF,0xFF,0xFF,0xFF])
        case 16: send(0x20, [0xFF,0xFF,0xFF,0xFF])
        case 18: send(0x23, [0xFF,0xFF,0xFF,0xFF])
        case 20:
            timer?.invalidate(); timer = nil
            print("=== DONE ===")
            exit(0)
        default: break
        }
    }

    func send(_ op: UInt8, _ pl: [UInt8]) {
        guard let w, let p else { return }
        let len = pl.count + 1
        var f: [UInt8] = [0xFE,0xDC,0xBA,0xC4,op,UInt8((len>>8)&0xFF),UInt8(len&0xFF),seq]
        f.append(contentsOf: pl); f.append(0xEF); seq &+= 1
        let ty: CBCharacteristicWriteType = w.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(Data(f), for: w, type: ty)
        print("TX op=0x\(String(format:"%02X",op)) \(h(f))")
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
            print("  RX ty=0x\(String(ty,radix:16)) op=0x\(String(format:"%02X",op)) seq=\(String(format:"%02X",sq)) \(h(pl))")
            if op == 0x50, ty == 0x04, pl.count >= 17 {
                let a = Safer.computeResponse(to: Array(pl[1..<17]))
                reply(0x50, sq, [0x01] + a); print("   -> SAFER answer sent")
            }
            if op == 0x51, isReq { reply(0x51, sq, [0x01]); print("   *** AUTH OK ***") }
            else if isReq && op != 0x50 { reply(op, sq, []) }
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
let pr = Probe()
RunLoop.main.run(until: Date().addingTimeInterval(40))
