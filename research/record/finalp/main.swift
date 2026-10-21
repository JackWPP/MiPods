// research/record/final_probe.swift  -- decisive closing tests
//
// Replicates the ONE run that worked (run1: 0x02 replied unauth, auth 0x50 ignored,
// no traffic), then:
//   T1  0x02 GET_DEVICE_INFO baseline            (expect reply)
//   T2  0x01 XM_DATA probes  [Byte4/Byte5]       (THE decisive test)
//   T3  FD2D FF10 miwear frame write             (is FF10 a second miwear pipe?)
//   T4  FD2D FF11/FF12/FF13 raw + frame writes   (observe)
//   T5  auth 0x50 (record outcome, do NOT abort rest)
//
// SAFETY: read/query only. Deny-list blocks 0xF2(SET) 0xD0-0xD3(voice) 0x03(reboot)
// 0x0F(unpair) 0xE0/0xEF(OTA) 0xF0/0xF1(vendor). No bulk-fill scans this run.
//
// Usage: ./final_probe <seconds>

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
func hexSp(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }

var topLines: [String] = []
func LOG(_ s: String) { print(s); fflush(stdout); topLines.append(s) }
let logPath = "final_probe.log"

let DENY: Set<UInt8> = [0x03,0x06,0x08,0x0A,0x0B,0x0C,0x0D,0x0F,0x30,0x32,0x34,
                        0xD0,0xD1,0xD2,0xD3,0xE0,0xEF,0xF0,0xF1,0xF2]

final class P: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var c: CBCentralManager!
    var t: CBPeripheral?
    var w: CBCharacteristic?          // AF07
    var ff10: CBCharacteristic?
    var ff11: CBCharacteristic?
    var ff12: CBCharacteristic?
    var ff13: CBCharacteristic?
    var buf: [UInt8] = []
    var seq: UInt8 = 0
    let TARGET = "1300D6D417E2"
    var gotAnyFrame = false

    // reply capture per test
    var captureLabel = ""
    var captured: [String] = []

    override init() { super.init(); c = CBCentralManager(delegate: self, queue: nil) }
    func nextSeq() -> UInt8 { let s = seq; seq &+= 1; return s }

    func centralManagerDidUpdateState(_ cm: CBCentralManager) {
        guard cm.state == .poweredOn else { LOG("[bt] state=\(cm.state.rawValue)"); return }
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
        LOG("[conn] connected -> discovering"); p.discoverServices(nil)
    }
    var retries = 0
    func centralManager(_ cm: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        LOG("[conn] DISCONNECTED \(error?.localizedDescription ?? "no error")")
        guard !finishedAll else { return }
        retries += 1
        guard retries <= 8 else { LOG("[reconn] giving up"); saveAndExit(); return }
        LOG("[reconn] retry #\(retries) in 2.5s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            self.t = nil; self.buf.removeAll(); self.pending = 0; self.idx = 0; self.steps = []
            self.c.scanForPeripherals(withServices: nil, options: nil)
        }
    }
    var finishedAll = false
    func saveAndExit() {
        finishedAll = true
        LOG("\n========== SUMMARY ==========")
        for l in topLines where l.hasPrefix("RESULT ") { LOG(l) }
        try? topLines.joined(separator: "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        LOG("[log] wrote \(logPath)")
        exit(0)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
    }

    var pending = 0, totalSvc = 0
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        pending += 1
        totalSvc = (p.services ?? []).count
        for ch in s.characteristics ?? [] {
            switch ch.uuid.uuidString {
            case "AF07": if ch.properties.contains(.write) { w = ch }
            case "AF08": p.setNotifyValue(true, for: ch)
            case "FF10": ff10 = ch
            case "FF11": ff11 = ch; p.setNotifyValue(true, for: ch)
            case "FF12": ff12 = ch; p.setNotifyValue(true, for: ch)
            case "FF13": ff13 = ch; p.setNotifyValue(true, for: ch)
            default: break
            }
        }
        if pending >= totalSvc {
            LOG("[gatt] AF07=\(w != nil) FF10=\(ff10 != nil) FF11=\(ff11 != nil) FF12=\(ff12 != nil) FF13=\(ff13 != nil)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.runTests(p) }
        }
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        if let e = error { LOG("[wr] \(ch.uuid.uuidString) ERR \(e.localizedDescription)") }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let d = ch.value else { return }
        let b = [UInt8](d)
        if ch.uuid.uuidString != "AF08" {
            let h = hexSp(b)
            LOG("[rx-other] \(ch.uuid.uuidString) = \(h)")
            captured.append("[\(captureLabel)] \(ch.uuid.uuidString)=\(h)")
            gotAnyFrame = true
            return
        }
        buf.append(contentsOf: b)
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
            let tname: String
            switch typeRaw {
            case 0xC4: tname = "PHONE_REQ"; case 0x04: tname = "RESP"
            case 0xC0: tname = "BUDS_REQ";  case 0xC7: tname = "NOTIFY"
            default: tname = String(format: "T%02X", typeRaw)
            }
            let line = String(format: "  [%] RX %@ op=0x%02X req=%@ payload=%@",
                              captureLabel, tname, op, isReq ? "Y" : "N", hex(payload))
            LOG(line)
            captured.append(String(format: "%@ op=0x%02X req=%@ payload=%@", tname, op, isReq ? "Y":"N", hex(payload)))
            gotAnyFrame = true
            // ACK device-initiated requests except auth (handled below)
            if isReq && op != 0x50 {
                write(p, w, encFrame(type: .response, opcode: op, seq: sq, payload: []))
            }
            if op == 0x50 && !isReq && payload.count >= 17 {
                let ans = Safer.computeResponse(to: Array(payload[1..<17]))
                LOG("  [auth] buds challenge -> sending answer")
                write(p, w, encFrame(type: .response, opcode: 0x50, seq: sq, payload: [0x01] + ans))
            }
            if op == 0x50 && isReq {
                // buds sends its own challenge as request
                let c = payload.count >= 17 ? Array(payload[1..<17]) : Array(payload.prefix(16))
                if c.count == 16 {
                    let ans = Safer.computeResponse(to: c)
                    LOG("  [auth] buds REQUEST challenge -> sending answer")
                    write(p, w, encFrame(type: .response, opcode: 0x50, seq: sq, payload: [0x01] + ans))
                }
            }
        }
    }

    func write(_ p: CBPeripheral, _ ch: CBCharacteristic?, _ f: [UInt8]) {
        guard let ch else { LOG("  [wr] missing characteristic"); return }
        let ty: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(Data(f), for: ch, type: ty)
        LOG("  SEND \(ch.uuid.uuidString) \(hex(f))")
    }

    // ---- test sequence ----
    var steps: [(String, () -> Void)] = []
    var idx = 0

    func runTests(_ p: CBPeripheral) {
        steps = []

        // T1 baseline device info
        steps.append(("T1 GET_DEVICE_INFO 0x02", {
            self.captureLabel = "T1"
            self.write(p, self.w, encFrame(type: .phoneRequest, opcode: 0x02, seq: self.nextSeq(),
                                           payload: [0xFF,0xFF,0xFF,0xFF]))
        }))
        // T2 XM_DATA 0x01 probes -- THE decisive test
        // frame: FEDCBAC4 01 len seq [SN] [XM_CMD] ... EF
        for (label, payload) in [
            ("T2a XM_DATA SN=00 CMD=01", [UInt8(0x00), 0x01]),
            ("T2b XM_DATA SN=00 CMD=02", [UInt8(0x00), 0x02]),
            ("T2c XM_DATA SN=00 CMD=0E", [UInt8(0x00), 0x0E]),
            ("T2d XM_DATA SN=00 CMD=F3", [UInt8(0x00), 0xF3]),
            ("T2e XM_DATA SN=00 CMD=09", [UInt8(0x00), 0x09]),
            ("T2f XM_DATA SN=00 CMD=00", [UInt8(0x00), 0x00]),
            ("T2g XM_DATA SN=01 CMD=01", [UInt8(0x01), 0x01]),
            ("T2h XM_DATA empty", [UInt8]()),
        ] {
            steps.append((label, {
                self.captureLabel = label
                self.write(p, self.w, encFrame(type: .phoneRequest, opcode: 0x01,
                                               seq: self.nextSeq(), payload: payload))
            }))
        }
        // T3 FF10 with a miwear GET_DEVICE_INFO frame (lead reports no response)
        steps.append(("T3 FF10 miwear 0x02 frame", {
            self.captureLabel = "T3"
            self.write(p, self.ff10, encFrame(type: .phoneRequest, opcode: 0x02,
                                              seq: self.nextSeq(), payload: [0xFF,0xFF,0xFF,0xFF]))
        }))
        // T3b FF10 raw 4-byte probe
        steps.append(("T3b FF10 raw FFFFFFFF", {
            self.captureLabel = "T3b"
            self.write(p, self.ff10, [0xFF,0xFF,0xFF,0xFF])
        }))
        // T4 FF11/12/13 raw probes
        for (label, ch) in [("T4a FF11", ff11), ("T4b FF12", ff12), ("T4c FF13", ff13)] {
            steps.append((label, {
                self.captureLabel = label
                self.write(p, ch, [0xFF,0xFF,0xFF,0xFF])
            }))
        }
        // T5 auth last so it cannot kill earlier tests
        steps.append(("T5 AUTH 0x50 challenge", {
            self.captureLabel = "T5"
            let ch = (0..<16).map { _ in UInt8.random(in: 0...255) }
            self.write(p, self.w, encFrame(type: .phoneRequest, opcode: 0x50,
                                           seq: self.nextSeq(), payload: [0x01] + ch))
        }))

        LOG("\n===== TEST SEQUENCE (\(steps.count) steps) =====")
        idx = 0
        advance(p)
    }

    func advance(_ p: CBPeripheral) {
        guard idx < steps.count else { finish(); return }
        let (label, action) = steps[idx]
        idx += 1
        gotAnyFrame = false
        captured = []
        LOG("\n--- STEP \(label) ---")
        action()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self else { return }
            if !self.gotAnyFrame {
                LOG("  => NO RESPONSE to \(label)")
                topLines.append("RESULT \(label): NO-RESPONSE")
            } else {
                LOG("  => GOT TRAFFIC for \(label): \(self.captured.count) frame(s)")
                topLines.append("RESULT \(label): TRAFFIC \(self.captured.joined(separator: " | "))")
            }
            self.advance(p)
        }
    }

    func finish() {
        LOG("\n\n========== SUMMARY ==========")
        for l in topLines where l.hasPrefix("RESULT ") { LOG(l) }
        try? topLines.joined(separator: "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        LOG("[log] wrote \(logPath)")
        exit(0)
    }
}

let secs = Double(CommandLine.arguments.dropFirst().first ?? "90") ?? 90
let pr = P()
DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
    LOG("[timeout]")
    try? topLines.joined(separator: "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
    exit(0)
}
RunLoop.main.run()
