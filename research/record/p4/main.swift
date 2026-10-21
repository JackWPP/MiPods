// research/record/p4/main.swift
// Target: reproduce run1's ONLY successful 0x50 RESPONSE, then complete the SAFER
// handshake and immediately read record configs.
//
// run1 evidence (gatt_pass1.log): we sent
//   FEDCBAC45000120001<16B random>EF
// and got
//   RX RESP op=0x50 seq=0x00 st=00 payload=01759345A01AD27466B1996998C95A22CF
// i.e. the buds ANSWERED the phone challenge with 16 bytes. Per the APK:
//   - phone sends AuthCheckParam(version=1, random) on opcode 80
//   - buds replies with result (its encryption of our random)
//   - phone then sends AuthSendCalcResultParam(version=1, pairResult=0) on opcode 81
//   - pairResult 0 == "auth ok"
// So after replying, the device may consider auth done. We then read configs.
//
// We also try: send 0x51 FIRST (claim success immediately) then read configs.
//
// SAFETY: auth handshake + GET_CONFIG reads only. No SET, no voice, no OTA.
//
// Usage: ./p4 <seconds>

import Foundation
import CoreBluetooth

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }
func encCmd(opcode: UInt8, payload: [UInt8], seq: UInt8, targetApp: UInt8 = 4) -> [UInt8] {
    let tb: UInt8 = 0x80 | 0x40 | (targetApp & 0x07)
    let paramLen = payload.count + 1
    var o: [UInt8] = [0xFE, 0xDC, 0xBA, tb, opcode,
                      UInt8((paramLen >> 8) & 0xFF), UInt8(paramLen & 0xFF), seq]
    o.append(contentsOf: payload); o.append(0xEF); return o
}
func encResp(opcode: UInt8, seq: UInt8, status: UInt8 = 0, targetApp: UInt8 = 4) -> [UInt8] {
    [0xFE, 0xDC, 0xBA, (targetApp & 0x07), opcode, 0x00, 0x02, status, seq, 0xEF]
}

var out: [String] = []
func LOG(_ s: String) { print(s); fflush(stdout); out.append(s) }
let LOGPATH = "p4.log"

final class P: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var c: CBCentralManager!
    var t: CBPeripheral?
    var w: CBCharacteristic?
    var buf: [UInt8] = []
    var seq: UInt8 = 0
    let TARGET = "1300D6D417E2"
    var traffic: [String] = []
    var done = false, started = false, reconn = 0
    var gotChallengeReply = false
    var gotAuthConfirm = false

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
        LOG("[found] \(p.name ?? "?") rssi=\(r)"); t = p; cm.stopScan()
        p.delegate = self; cm.connect(p, options: nil)
    }
    func centralManager(_ cm: CBCentralManager, didConnect p: CBPeripheral) {
        LOG("[conn] ok"); p.discoverServices(nil)
    }
    func centralManager(_ cm: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        LOG("[conn] DISC \(error?.localizedDescription ?? "")")
        guard !done else { return }
        reconn += 1; guard reconn <= 5 else { finish("max reconn"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, !self.done else { return }
            self.t = nil; self.buf.removeAll(); self.w = nil; self.started = false
            self.c.scanForPeripherals(withServices: nil, options: nil)
        }
    }
    var sawW = false, sawN = false
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] where s.uuid.uuidString == "AF00" { p.discoverCharacteristics(nil, for: s) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid.uuidString == "AF07" { w = ch; sawW = true }
            if ch.uuid.uuidString == "AF08" { sawN = true; p.setNotifyValue(true, for: ch) }
        }
        guard sawW, sawN, !started else { return }
        started = true
        // run1 sent the challenge ~2.5s after connect (after reads) -- mimic that
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in self?.phaseA(p) }
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        if let e = error { LOG("[wr] ERR \(e.localizedDescription)") }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let d = ch.value else { return }
        buf.append(contentsOf: [UInt8](d)); parse(p)
    }
    func parse(_ p: CBPeripheral) {
        while true {
            guard let s = buf.firstIndex(where: { $0 == 0xFE }) else { buf.removeAll(); return }
            if s > 0 { buf.removeFirst(s) }
            guard buf.count >= 7 else { return }
            let isReq = (buf[3] & 0x40) != 0
            let len = Int(buf[5]) << 8 | Int(buf[6])
            guard len >= 1, len <= 4096 else { buf.removeFirst(1); continue }
            let tot = 7 + len + 1
            guard buf.count >= tot else { return }
            guard buf[tot - 1] == 0xEF else { buf.removeFirst(1); continue }
            let typeRaw = buf[3], op = buf[4]
            let bs = 7 + (isReq ? 0 : 1)
            let sq = buf[bs]
            let pl = Array(buf[(bs + 1)..<(tot - 1)])
            buf.removeFirst(tot)
            var st = "--"
            if !isReq && tot > 8 { st = String(format: "%02X", buf[7]) }
            let tn: String
            switch typeRaw {
            case 0xC4: tn = "PHONE_REQ"; case 0x04: tn = "RESP"
            case 0xC0: tn = "BUDS_REQ"; case 0xC7: tn = "NOTIFY"
            default: tn = String(format: "T%02X", typeRaw)
            }
            let line = String(format: "%@ op=0x%02X seq=0x%02X st=%@ payload=%@", tn, op, sq, st, hex(pl))
            LOG("  <= " + line); traffic.append(line)

            // ---- auth state machine ----
            if op == 0x50 {
                if typeRaw == 0x04 {
                    gotChallengeReply = true
                    LOG("  [AUTH] *** buds answered our challenge *** -> send 0x51 pairResult=0")
                    write(p, encCmd(opcode: 0x51, payload: [0x01, 0x00], seq: nextSeq()))
                } else if pl.count >= 17 {
                    let ans = Safer.computeResponse(to: Array(pl[1..<17]))
                    LOG("  [AUTH] buds-initiated challenge -> SAFER answer \(hex(ans))")
                    write(p, encResp(opcode: 0x50, seq: sq))
                }
            } else if op == 0x51 {
                if isReq { write(p, encResp(opcode: 0x51, seq: sq)) }
                else { gotAuthConfirm = true; LOG("  [AUTH] *** 0x51 confirmed ***") }
            } else if isReq {
                write(p, encResp(opcode: op, seq: sq))
            }
        }
    }
    func write(_ p: CBPeripheral, _ f: [UInt8]) {
        guard let w else { return }
        let ty: CBCharacteristicWriteType = w.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(Data(f), for: w, type: ty)
        LOG("  => op=0x\(String(format: "%02X", f[4])) \(hex(f))")
    }

    // ---- Phase A: challenge only, watch for the run1 reply ----
    func phaseA(_ p: CBPeripheral) {
        LOG("\n===== PHASE A: send 0x50 challenge (reproduce run1) =====")
        traffic = []
        let ch = (0..<16).map { _ in UInt8.random(in: 0...255) }
        write(p, encCmd(opcode: 0x50, payload: [0x01] + ch, seq: nextSeq()))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, !self.done else { return }
            LOG("  >> challengeReply=\(self.gotChallengeReply) traffic=\(self.traffic.count)")
            out.append("VERDICT challengeReply=\(self.gotChallengeReply) frames=\(self.traffic.count)")
            self.phaseB(p)
        }
    }
    // ---- Phase B: read record configs ----
    func phaseB(_ p: CBPeripheral) {
        LOG("\n===== PHASE B: GET_CONFIG 70/69/68 after auth attempt =====")
        traffic = []
        let codes: [UInt16] = [0x0046, 0x0045, 0x0044]
        var i = 0
        func next() {
            guard !self.done, i < codes.count else {
                LOG("  >> phaseB frames=\(self.traffic.count)")
                out.append("VERDICT phaseB frames=\(self.traffic.count)")
                self.phaseC(p); return
            }
            let c = codes[i]; i += 1
            self.write(p, encCmd(opcode: 0xF3,
                                 payload: [UInt8(c >> 8), UInt8(c & 0xFF)], seq: self.nextSeq()))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { next() }
        }
        next()
    }
    // ---- Phase C: control ----
    func phaseC(_ p: CBPeripheral) {
        LOG("\n===== PHASE C: control 0x02 =====")
        traffic = []
        write(p, encCmd(opcode: 0x02, payload: [0xFF,0xFF,0xFF,0xFF], seq: nextSeq()))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.done else { return }
            LOG("  >> phaseC frames=\(self.traffic.count)")
            out.append("VERDICT phaseC control frames=\(self.traffic.count)")
            self.finish("done")
        }
    }
    func finish(_ why: String) {
        guard !done else { return }; done = true
        LOG("\n===== SUMMARY (\(why)) =====")
        for l in out where l.hasPrefix("VERDICT") { LOG(l) }
        try? out.joined(separator: "\n").write(toFile: LOGPATH, atomically: true, encoding: .utf8)
        LOG("[log] \(LOGPATH)"); exit(0)
    }
}

let secs = Double(CommandLine.arguments.dropFirst().first ?? "60") ?? 60
let pr = P()
DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
    try? out.joined(separator: "\n").write(toFile: LOGPATH, atomically: true, encoding: .utf8); exit(0)
}
RunLoop.main.run()
