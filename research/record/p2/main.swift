// research/record/p2/main.swift
// FINAL clean test: NO auth attempt at all, so nothing can disturb the link.
// Byte-exact APK encoder (a6/f.java A()):
//   type byte = 0x80(cmd) | 0x40(hasResponse) | targetApp(4=com.mi.earphone) = 0xC4
//   paramLen  = payload.count + 1 (the +1 is the seq byte)
//   body      = [seq] + payload
//
// Sequence: control 0x02 (must reply) -> GET_CONFIG 70/69/68 -> 0x01 XM_DATA -> control 0x09
// Every step re-verifies link liveness with a control read first.
//
// Usage: ./p2 <seconds>

import Foundation
import CoreBluetooth

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }

/// Byte-exact replica of APK encoder.
func encCmd(opcode: UInt8, payload: [UInt8], seq: UInt8,
           targetApp: UInt8 = 4) -> [UInt8] {
    let tb: UInt8 = 0x80 | 0x40 | (targetApp & 0x07)   // = 0xC4
    let paramLen = payload.count + 1
    var out: [UInt8] = [0xFE, 0xDC, 0xBA, tb, opcode,
                        UInt8((paramLen >> 8) & 0xFF), UInt8(paramLen & 0xFF), seq]
    out.append(contentsOf: payload)
    out.append(0xEF)
    return out
}
/// Response type byte: type=0, hasResponse=0, targetApp -> 0x04
func encResp(opcode: UInt8, seq: UInt8, status: UInt8 = 0, targetApp: UInt8 = 4) -> [UInt8] {
    let tb: UInt8 = (targetApp & 0x07)  // = 0x04
    return [0xFE, 0xDC, 0xBA, tb, opcode, 0x00, 0x02, status, seq, 0xEF]
}

var out: [String] = []
func LOG(_ s: String) { print(s); fflush(stdout); out.append(s) }
let LOGPATH = "p2.log"

final class P: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var c: CBCentralManager!
    var t: CBPeripheral?
    var w: CBCharacteristic?
    var buf: [UInt8] = []
    var seq: UInt8 = 0
    let TARGET = "1300D6D417E2"
    var traffic: [String] = []
    var done = false
    var reconnects = 0
    var started = false

    override init() { super.init(); c = CBCentralManager(delegate: self, queue: nil) }
    func nextSeq() -> UInt8 { let s = seq; seq &+= 1; return s }

    func centralManagerDidUpdateState(_ cm: CBCentralManager) {
        guard cm.state == .poweredOn else { LOG("[bt] \(cm.state.rawValue)"); return }
        cm.scanForPeripherals(withServices: nil, options: nil)
    }
    func centralManager(_ cm: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData d: [String: Any], rssi r: NSNumber) {
        guard t == nil, let m = d[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
        guard m.map({ String(format: "%02X", $0) }).joined().contains(TARGET) else { return }
        LOG("[found] \(p.name ?? "?") rssi=\(r)")
        t = p; cm.stopScan(); p.delegate = self; cm.connect(p, options: nil)
    }
    func centralManager(_ cm: CBCentralManager, didConnect p: CBPeripheral) {
        LOG("[conn] connected"); p.discoverServices(nil)
    }
    func centralManager(_ cm: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        LOG("[conn] DISCONNECTED \(error?.localizedDescription ?? "")")
        guard !done else { return }
        reconnects += 1
        guard reconnects <= 6 else { finish("max reconnects"); return }
        LOG("[reconn] #\(reconnects) in 3s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.done else { return }
            self.t = nil; self.buf.removeAll(); self.w = nil; self.started = false
            self.c.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    var sawW = false, sawN = false
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] where s.uuid.uuidString == "AF00" {
            p.discoverCharacteristics(nil, for: s)
        }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid.uuidString == "AF07" { w = ch; sawW = true }
            if ch.uuid.uuidString == "AF08" { sawN = true; p.setNotifyValue(true, for: ch) }
        }
        guard sawW, sawN, !started else { return }
        started = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.run(p) }
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        if let e = error { LOG("[wr] ERR \(e.localizedDescription)") }
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
            var st = "--"
            if !isReq && total > 8 { st = String(format: "%02X", buf[7]) }
            let tn: String
            switch typeRaw {
            case 0xC4: tn = "PHONE_REQ"; case 0x04: tn = "RESP"
            case 0xC0: tn = "BUDS_REQ";  case 0xC7: tn = "NOTIFY"
            default: tn = String(format: "T%02X", typeRaw)
            }
            let line = String(format: "%@ op=0x%02X seq=0x%02X st=%@ payload=%@",
                              tn, op, sq, st, hex(payload))
            LOG("  <= " + line); traffic.append(line)
            if isReq {
                write(p, encResp(opcode: op, seq: sq))
            }
        }
    }

    func write(_ p: CBPeripheral, _ f: [UInt8]) {
        guard let w else { LOG("  !! no AF07"); return }
        let ty: CBCharacteristicWriteType = w.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(Data(f), for: w, type: ty)
        LOG("  => op=0x\(String(format: "%02X", f[4])) \(hex(f))")
    }

    // ---- sequential experiment, NO auth ----
    var steps: [(String, () -> Void, Double)] = []
    var si = 0

    func run(_ p: CBPeripheral) {
        steps = [
            ("CTRL-1 baseline 0x02 GET_DEVICE_INFO", {
                self.write(p, encCmd(opcode: 0x02, payload: [0xFF,0xFF,0xFF,0xFF], seq: self.nextSeq()))
            }, 2.0),
            ("CFG-70 capacity  [00 46]", {
                self.write(p, encCmd(opcode: 0xF3, payload: [0x00, 0x46], seq: self.nextSeq()))
            }, 2.2),
            ("CFG-69 filelist  [00 45]", {
                self.write(p, encCmd(opcode: 0xF3, payload: [0x00, 0x45], seq: self.nextSeq()))
            }, 2.2),
            ("CFG-68 status    [00 44]", {
                self.write(p, encCmd(opcode: 0xF3, payload: [0x00, 0x44], seq: self.nextSeq()))
            }, 2.2),
            ("XM_DATA 0x01 [SN=00][CMD=00]", {
                self.write(p, encCmd(opcode: 0x01, payload: [0x00, 0x00], seq: self.nextSeq()))
            }, 2.2),
            ("CTRL-2 0x02 again (link still alive?)", {
                self.write(p, encCmd(opcode: 0x02, payload: [0xFF,0xFF,0xFF,0xFF], seq: self.nextSeq()))
            }, 2.2),
            ("CTRL-3 0x09 GET_RUN_INFO", {
                self.write(p, encCmd(opcode: 0x09, payload: [0xFF,0xFF,0xFF,0xFF], seq: self.nextSeq()))
            }, 2.2),
        ]
        LOG("\n===== P2: GET_CONFIG with byte-exact encoding, NO auth (\(steps.count) steps) =====")
        si = 0
        advance(p)
    }

    func advance(_ p: CBPeripheral) {
        guard si < steps.count else { finish("all steps done"); return }
        let (label, action, wait) = steps[si]
        si += 1
        traffic = []
        LOG("\n--- [\(si)/\(steps.count)] \(label) ---")
        action()
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, !self.done else { return }
            let v = self.traffic.isEmpty ? "NO-RESPONSE" : "TRAFFIC(\(self.traffic.count))"
            LOG("  >>> \(label): \(v)")
            out.append("VERDICT \(label): \(v) \(self.traffic.joined(separator: " || "))")
            self.advance(p)
        }
    }

    func finish(_ why: String) {
        guard !done else { return }; done = true
        LOG("\n\n========== SUMMARY (\(why)) ==========")
        for l in out where l.hasPrefix("VERDICT") { LOG(l) }
        try? out.joined(separator: "\n").write(toFile: LOGPATH, atomically: true, encoding: .utf8)
        LOG("[log] \(LOGPATH)")
        exit(0)
    }
}

let secs = Double(CommandLine.arguments.dropFirst().first ?? "60") ?? 60
let pr = P()
DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
    try? out.joined(separator: "\n").write(toFile: LOGPATH, atomically: true, encoding: .utf8)
    exit(0)
}
RunLoop.main.run()
