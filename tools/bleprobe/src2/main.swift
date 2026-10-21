import Foundation
import CoreBluetooth
// SAFER+ in Safer.swift

enum MType: UInt8 { case phoneRequest = 0xC4, response = 0x04, earbudsRequest = 0xC0, earbudsNotify = 0xC7 }
func encFrame(type: MType, opcode: UInt8, seq: UInt8, payload: [UInt8]) -> [UInt8] {
    let isReq = (type.rawValue & 0x40) != 0
    let len = payload.count + (isReq ? 1 : 2)
    var b: [UInt8] = [0xFE, 0xDC, 0xBA, type.rawValue, opcode, UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)]
    if !isReq { b.append(0x00) }
    b.append(seq); b.append(contentsOf: payload); b.append(0xEF)
    return b
}
func h(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }
let TARGET = "1300D6D417E2"

final class P: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var c: CBCentralManager!; var t: CBPeripheral?
    var w: CBCharacteristic?; var n: CBCharacteristic?
    var seq: UInt8 = 0; var buf: [UInt8] = []; var started = false
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
    func centralManager(_ cm: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { print("[disc]") }
    func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?) { for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) } }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid.uuidString == "AF07" { w = ch }
            if ch.uuid.uuidString == "AF08" { n = ch; p.setNotifyValue(true, for: ch) }
        }
        guard w != nil, n != nil, !started else { return }
        started = true
        let ch = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let steps: [(Double, String, () -> Void)] = [
            (0.5, "AUTH_CHALLENGE", { self.tx(p, 0x50, [0x01] + ch) }),
            (2.5, "RUN_INFO", { self.tx(p, 0x09, [0xFF,0xFF,0xFF,0xFF]) }),
            (4.0, "ANC -> NORMAL(0)", { self.tx(p, 0x08, [0x02, 0x04, 0x00]) }),
            (6.5, "RUN_INFO", { self.tx(p, 0x09, [0xFF,0xFF,0xFF,0xFF]) }),
            (8.0, "ANC -> ANCON(1)", { self.tx(p, 0x08, [0x02, 0x04, 0x01]) }),
            (10.5, "RUN_INFO", { self.tx(p, 0x09, [0xFF,0xFF,0xFF,0xFF]) }),
            (12.0, "ANC -> TRANS(2)", { self.tx(p, 0x08, [0x02, 0x04, 0x02]) }),
            (14.5, "RUN_INFO", { self.tx(p, 0x09, [0xFF,0xFF,0xFF,0xFF]) }),
        ]
        for (i, (t, label, f)) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                print("--- step \(i+1): \(label) ---"); f()
            }
        }
    }
    func tx(_ p: CBPeripheral, _ op: UInt8, _ payload: [UInt8]) {
        guard let w = w else { return }
        let f = encFrame(type: .phoneRequest, opcode: op, seq: seq, payload: payload); seq &+= 1
        let ty: CBCharacteristicWriteType = w.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(Data(f), for: w, type: ty)
        print("  [tx] \(h(f))")
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let d = ch.value else { return }
        buf.append(contentsOf: [UInt8](d)); drain(p)
    }
    func drain(_ p: CBPeripheral) {
        while true {
            guard let s = buf.firstIndex(of: 0xFE) else { buf.removeAll(); return }
            if s > 0 { buf.removeFirst(s) }
            guard buf.count >= 7, buf[1] == 0xDC, buf[2] == 0xBA else { buf.removeFirst(min(1,buf.count)); continue }
            let isReq = (buf[3] & 0x40) != 0
            let len = Int(buf[5]) << 8 | Int(buf[6])
            guard len >= 1, len <= 4096 else { buf.removeFirst(1); continue }
            let total = 7 + len + 1
            guard buf.count >= total else { return }
            guard buf[total-1] == 0xEF else { buf.removeFirst(1); continue }
            let bs = 7 + (isReq ? 0 : 1)
            let sq = buf[bs]; let payload = Array(buf[(bs+1)..<(total-1)])
            let op = buf[4]; let ty = buf[3]
            buf.removeFirst(total)
            print("  [rx] ty=0x\(String(ty,radix:16)) op=0x\(String(format:"%02X",op)) seq=\(String(format:"%02X",sq)) pl=\(h(payload))")
            if isReq, op == 0x0E || op == 0xF4 {
                let f = encFrame(type: .response, opcode: op, seq: sq, payload: [])
                if let w = w { p.writeValue(Data(f), for: w, type: .withResponse) }
            }
            if op == 0x09 { tlv(payload, "RUN_INFO") }
            if op == 0x0E { tlv(payload, "STATUS") }
            if op == 0xF4 { tlv(payload, "NOTIFY_CFG") }
            if op == 0x08 { print("     ANC ACK") }
            if op == 0x50 {
                if ty == 0x04 {
                    // earbuds answered OUR challenge -> send AUTH_CONFIRM (reference flow)
                    print("     earbuds answered our challenge -> sending AUTH_CONFIRM")
                    let f = encFrame(type: .phoneRequest, opcode: 0x51, seq: self.seq, payload: [0x01, 0x00])
                    self.seq &+= 1
                    if let w = w { p.writeValue(Data(f), for: w, type: .withResponse) }
                } else if payload.count >= 17 {
                    let ans = Safer.computeResponse(to: Array(payload[1..<17]))
                    print("     SAFER+ answer = \(h(ans))")
                    let f = encFrame(type: .response, opcode: 0x50, seq: sq, payload: [0x01] + ans)
                    if let w = w { p.writeValue(Data(f), for: w, type: .withResponse) }
                }
            }
            if op == 0x51, isReq {
                let f = encFrame(type: .response, opcode: 0x51, seq: sq, payload: [0x01])
                if let w = w { p.writeValue(Data(f), for: w, type: .withResponse) }
                print("     *** AUTHENTICATED ***")
            }
        }
    }
    func tlv(_ payload: [UInt8], _ tag: String) {
        var i = 0
        while i + 1 < payload.count {
            let len = Int(payload[i]); guard len >= 1, i+1+len <= payload.count else { break }
            let idx = payload[i+1]; let data = Array(payload[(i+2)..<(i+1+len)])
            print("     [\(tag)] idx=0x\(String(format:"%02X",idx)) data=\(h(data)) ascii=\(String(bytes: data, encoding: .utf8) ?? "")")
            i += len + 1
        }
    }
}
let p = P()
RunLoop.main.run(until: Date().addingTimeInterval(17))
print("DONE")
