// research/record/auth_probe.swift
// Minimal isolate: connect -> subscribe AF08 -> GET_DEVICE_INFO (baseline) -> AUTH 0x50 -> log 20s
// Purpose: find out WHY the full scan got zero replies (auth never completed in run 2).
import Foundation
import CoreBluetooth

enum MType: UInt8 { case phoneRequest = 0xC4, response = 0x04, earbudsRequest = 0xC0, earbudsNotify = 0xC7 }
func encFrame(type: MType, opcode: UInt8, seq: UInt8, payload: [UInt8]) -> [UInt8] {
    let extra = (type.rawValue & 0x40) != 0 ? 1 : 2
    let len = payload.count + extra
    var b: [UInt8] = [0xFE, 0xDC, 0xBA, type.rawValue, opcode,
                      UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)]
    if (type.rawValue & 0x40) == 0 { b.append(0x00) }
    b.append(seq)
    b.append(contentsOf: payload)
    b.append(0xEF)
    return b
}
func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }

final class P: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var c: CBCentralManager!
    var t: CBPeripheral?
    var w: CBCharacteristic?
    var buf: [UInt8] = []
    var seq: UInt8 = 0
    let TARGET = "1300D6D417E2"
    var sentInfo = false

    override init() { super.init(); c = CBCentralManager(delegate: self, queue: nil) }
    func nextSeq() -> UInt8 { let s = seq; seq &+= 1; return s }

    func centralManagerDidUpdateState(_ cm: CBCentralManager) {
        guard cm.state == .poweredOn else { return }
        cm.scanForPeripherals(withServices: nil, options: nil)
    }
    func centralManager(_ cm: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData d: [String: Any], rssi r: NSNumber) {
        guard t == nil, let m = d[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
        guard m.map({ String(format: "%02X", $0) }).joined().contains(TARGET) else { return }
        print("[found] \(p.name ?? "?")")
        t = p; cm.stopScan(); p.delegate = self; cm.connect(p, options: nil)
    }
    func centralManager(_ cm: CBCentralManager, didConnect p: CBPeripheral) {
        print("[conn] ok"); p.discoverServices(nil)
    }
    func centralManager(_ cm: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        print("[conn] DISCONNECTED \(error?.localizedDescription ?? "")")
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] where s.uuid.uuidString == "AF00" {
            p.discoverCharacteristics(nil, for: s)
        }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid.uuidString == "AF07" { w = ch }
            if ch.uuid.uuidString == "AF08" { p.setNotifyValue(true, for: ch) }
        }
        guard w != nil else { print("[!] no AF07"); return }
        // baseline: this MUST work unauthenticated per prior verification
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let f = encFrame(type: .phoneRequest, opcode: 0x02, seq: self.nextSeq(),
                             payload: [0xFF, 0xFF, 0xFF, 0xFF])
            print("SEND baseline 0x02 \(hex(f))")
            self.write(p, f)
            self.sentInfo = true
        }
    }
    func write(_ p: CBPeripheral, _ f: [UInt8]) {
        guard let w else { return }
        let ty: CBCharacteristicWriteType = w.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(Data(f), for: w, type: ty)
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        if let e = error { print("[wr] ERR \(e.localizedDescription)") }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let d = ch.value else { return }
        buf.append(contentsOf: [UInt8](d))
        parse(p)
    }
    func parse(_ p: CBPeripheral) {
        while true {
            guard let s = buf.firstIndex(where: { $0 == 0xFE }) else { buf.removeAll(); return }
            if s > 0 { buf.removeFirst(s) }
            guard buf.count >= 7 else { return }
            let isReq = (buf[3] & 0x40) != 0
            let len = Int(buf[5]) << 8 | Int(buf[6])
            guard len >= 1, len <= 4096 else { buf.removeFirst(1); continue }
            let total = 7 + len + 1
            guard buf.count >= total else { return }
            guard buf[total - 1] == 0xEF else { buf.removeFirst(1); continue }
            let typeRaw = buf[3], op = buf[4]
            let bodyStart = 7 + (isReq ? 0 : 1)
            let sq = buf[bodyStart]
            let payload = Array(buf[(bodyStart + 1)..<(total - 1)])
            buf.removeFirst(total)
            print(String(format: "RX T%02X op=%02X seq=%02X req=%@ payload=%@",
                         typeRaw, op, sq, isReq ? "Y" : "N", hex(payload)))
            handle(p, typeRaw: typeRaw, op: op, seq: sq, payload: payload, isReq: isReq)
        }
    }
    var sentAuth = false
    func handle(_ p: CBPeripheral, typeRaw: UInt8, op: UInt8, seq sq: UInt8,
                payload: [UInt8], isReq: Bool) {
        switch op {
        case 0x02:
            print(">>> DEVICE_INFO OK -> link works unauth")
            if !sentAuth {
                sentAuth = true
                let challenge = (0..<16).map { _ in UInt8.random(in: 0...255) }
                let f = encFrame(type: .phoneRequest, opcode: 0x50, seq: nextSeq(),
                                 payload: [0x01] + challenge)
                print("SEND AUTH 0x50 \(hex(f))")
                write(p, f)
            }
        case 0x50:
            if typeRaw == 0x04 {
                print(">>> buds challenge-response received -> sending AUTH_CONFIRM")
                write(p, encFrame(type: .phoneRequest, opcode: 0x51, seq: nextSeq(), payload: [0x01, 0x00]))
            } else if payload.count >= 17 {
                let ans = Safer.computeResponse(to: Array(payload[1..<17]))
                print(">>> computing answer \(hex(ans))")
                write(p, encFrame(type: .response, opcode: 0x50, seq: sq, payload: [0x01] + ans))
            }
        case 0x51:
            if isReq {
                write(p, encFrame(type: .response, opcode: 0x51, seq: sq, payload: [0x01]))
            } else {
                print(">>> *** AUTH COMPLETE ***")
            }
        case 0xF4, 0x0E:
            if isReq { write(p, encFrame(type: .response, opcode: op, seq: sq, payload: [])) }
        default:
            if isReq { write(p, encFrame(type: .response, opcode: op, seq: sq, payload: [])) }
        }
    }
}

let secs = Double(CommandLine.arguments.dropFirst().first ?? "25") ?? 25
let p = P()
DispatchQueue.main.asyncAfter(deadline: .now() + secs) { print("[done]"); exit(0) }
RunLoop.main.run()
