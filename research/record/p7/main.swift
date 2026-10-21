// research/record/p7/main.swift -- FINAL probe for Lead's remaining questions
//
// 1. Auth challenge IMMEDIATELY on connect (Lead's key timing fix), print MATCH.
// 2. After auth, GET_CONFIG 70/69/68 (2-byte BE configId).
// 3. Test 0xF2 SET_CONFIG (wear detection, benign) -- does SET answer when GET doesn't?
// 4. Verify 0xF3 == 243 explicitly.
//
// SAFETY: the only SET sent is wear-detection (0x000C) which is cosmetic & reversible.
// No format/delete/record-start/OTA/unpair.
//
// Frame encoder = byte-exact a6/f.A():
//   type = 0x80 | 0x40 | targetApp(4) = 0xC4 ; paramLen = payload.count + 1
//
// Usage: ./p7 <seconds>

import Foundation
import CoreBluetooth

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }
func encCmd(_ op: UInt8, _ pl: [UInt8], _ sq: UInt8, targetApp: UInt8 = 4) -> [UInt8] {
    let tb: UInt8 = 0x80 | 0x40 | (targetApp & 0x07)
    let n = pl.count + 1
    return [0xFE, 0xDC, 0xBA, tb, op, UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF), sq] + pl + [0xEF]
}
func encResp(_ op: UInt8, _ sq: UInt8, status: UInt8 = 0, targetApp: UInt8 = 4) -> [UInt8] {
    [0xFE, 0xDC, 0xBA, (targetApp & 0x07), op, 0x00, 0x02, status, sq, 0xEF]
}

var log: [String] = []
func L(_ s: String) { print(s); fflush(stdout); log.append(s) }
let LOGPATH = "p7.log"

final class P: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var c: CBCentralManager!
    var t: CBPeripheral?
    var w: CBCharacteristic?
    var buf: [UInt8] = []
    var seq: UInt8 = 0
    var done = false, reconn = 0
    var started = false
    var authSent = false
    var challenge: [UInt8] = []
    var matches = 0, attempts = 0
    var traffic: [String] = []
    let T = "1300D6D417E2"

    // results for the report
    var rAuthAnswer = "-", rAuthMatch = "-"
    var rCfg = "-", rSet = "-", rOp243 = "-", rCtrl = "-"

    override init() { super.init(); c = CBCentralManager(delegate: self, queue: nil) }
    func nextSeq() -> UInt8 { let s = seq; seq &+= 1; return s }

    func centralManagerDidUpdateState(_ cm: CBCentralManager) {
        guard cm.state == .poweredOn else { return }
        cm.scanForPeripherals(withServices: nil, options: nil)
    }
    func centralManager(_ cm: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData d: [String: Any], rssi r: NSNumber) {
        guard t == nil, let m = d[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
        guard m.map({ String(format: "%02X", $0) }).joined().contains(T) else { return }
        L("[found] rssi=\(r)"); t = p; cm.stopScan(); p.delegate = self; cm.connect(p, options: nil)
    }
    func centralManager(_ cm: CBCentralManager, didConnect p: CBPeripheral) {
        L("[conn] ok"); p.discoverServices(nil)
    }
    func centralManager(_ cm: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        L("[conn] DISC")
        guard !done else { return }
        reconn += 1
        guard reconn <= 10 else { finish("max reconn"); return }
        L("[reconn] #\(reconn)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, !self.done else { return }
            self.t = nil; self.buf.removeAll(); self.w = nil
            self.started = false; self.authSent = false; self.challenge = []
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
        // *** LEAD'S KEY FIX: auth challenge must be sent IMMEDIATELY, not after 0x02 ***
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.sendChallenge(p)
        }
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        if let e = error { L("[wr] ERR \(e.localizedDescription)") }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let d = ch.value else { return }
        buf.append(contentsOf: [UInt8](d)); parse(p)
    }

    func write(_ p: CBPeripheral, _ f: [UInt8]) {
        guard let w else { return }
        let ty: CBCharacteristicWriteType = w.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(Data(f), for: w, type: ty)
        L("  => op=0x\(String(format: "%02X", f[4])) \(hex(f))")
    }

    func sendChallenge(_ p: CBPeripheral) {
        guard !authSent else { return }
        authSent = true
        challenge = (0..<16).map { _ in UInt8.random(in: 0...255) }
        L("\n[PHASE A] auth challenge IMMEDIATELY (challenge=\(hex(challenge)))")
        write(p, encCmd(0x50, [0x01] + challenge, nextSeq()))

        // after 2.2s, continue regardless
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self, !self.done else { return }
            L("  >> phaseA frames=\(self.traffic.count) match=\(self.rAuthMatch)")
            self.phaseB(p)
        }
    }

    func phaseB(_ p: CBPeripheral) {
        L("\n[PHASE B] GET_CONFIG 70=0x0046 / 69=0x0045 / 68=0x0044")
        traffic = []
        var codes: [UInt16] = [0x0046, 0x0045, 0x0044]
        var re: [String] = []
        func nxt() {
            guard !self.done else { return }
            guard !codes.isEmpty else {
                self.rCfg = self.traffic.isEmpty ? "NO-RESPONSE(all 3)" : self.traffic.joined(separator: " | ")
                L("  >> phaseB frames=\(self.traffic.count)")
                self.phaseB2(p); return
            }
            let c = codes.removeFirst()
            self.write(p, encCmd(0xF3, [UInt8(c >> 8), UInt8(c & 0xFF)], self.nextSeq()))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { nxt() }
        }
        _ = re; _ = codes; codes = [0x0046, 0x0045, 0x0044]
        nxt()
    }

    // opcode 243 explicit (same as 0xF3) to prove equivalence
    func phaseB2(_ p: CBPeripheral) {
        traffic = []
        L("\n[PHASE B2] opcode 243 (= 0xF3) with configId 70")
        write(p, encCmd(0xF3, [0x00, 0x46], nextSeq()))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, !self.done else { return }
            self.rOp243 = self.traffic.isEmpty ? "NO-RESPONSE" : self.traffic.joined(separator: " | ")
            self.phaseC(p)
        }
    }

    // SET_CONFIG test: wear detection 0x000C = 1 (benign, reversible)
    func phaseC(_ p: CBPeripheral) {
        traffic = []
        L("\n[PHASE C] SET_CONFIG 0xF2 [04 00 0C 01] (wear-detect on; benign/reversible)")
        write(p, encCmd(0xF2, [0x04, 0x00, 0x0C, 0x01], nextSeq()))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.done else { return }
            self.rSet = self.traffic.isEmpty ? "NO-RESPONSE" : self.traffic.joined(separator: " | ")
            self.phaseD(p)
        }
    }

    func phaseD(_ p: CBPeripheral) {
        traffic = []
        L("\n[PHASE D] control 0x02 GET_DEVICE_INFO (is link alive at all?)")
        write(p, encCmd(0x02, [0xFF, 0xFF, 0xFF, 0xFF], nextSeq()))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.done else { return }
            self.rCtrl = self.traffic.isEmpty ? "NO-RESPONSE" : self.traffic.joined(separator: " | ")
            self.phaseE(p)
        }
    }

    // Phase E: targetApp variants + no-response bit
    func phaseE(_ p: CBPeripheral) {
        traffic = []
        L("\n[PHASE E] variant sweep: targetApp=0 (0xC0), no-response (0x84), opcode-only")
        // E1: targetApp=0 -> type 0xC0
        write(p, encCmd(0xF3, [0x00, 0x46], nextSeq(), targetApp: 0))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, !self.done else { return }
            L("  >> E1(0xC0) frames=\(self.traffic.count)")
            // E2: hasResponse=0 -> type 0x84
            let tb: UInt8 = 0x80 | 0x04
            let n = 3
            var f: [UInt8] = [0xFE,0xDC,0xBA,tb,0xF3,UInt8((n >> 8) & 0xFF),UInt8(n & 0xFF),self.nextSeq(),0x00,0x46,0xEF]
            self.write(p, f)
            f = []
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                guard let self, !self.done else { return }
                L("  >> E2(0x84) frames=\(self.traffic.count)")
                self.finish("all phases done")
            }
        }
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
            let tr = buf[3], op = buf[4]
            let bs = 7 + (isReq ? 0 : 1)
            let sq = buf[bs]
            let pl = Array(buf[(bs + 1)..<(tot - 1)])
            buf.removeFirst(tot)
            let line = "T\(String(format: "%02X", tr)) op=0x\(String(format: "%02X", op)) req=\(isReq) payload=\(hex(pl))"
            L("  <= " + line); traffic.append(line)

            if op == 0x50 {
                if tr == 0x04 {
                    // buds answered OUR challenge
                    let answer = pl.count >= 17 ? Array(pl[1..<17]) : pl
                    rAuthAnswer = hex(answer)
                    let expect = Safer.computeResponse(to: challenge)
                    attempts += 1
                    let ok = (answer == expect)
                    if ok { matches += 1 }
                    rAuthMatch = ok ? "MATCH" : "MISMATCH expect=\(hex(expect))"
                    L("  [AUTH] device answer = \(hex(answer))")
                    L("  [AUTH] SAFER+ expect  = \(hex(expect))")
                    L("  [AUTH] >>> \(rAuthMatch)")
                    // DO NOT send 0x51 -- test whether 0x51 is what mutes the device
                    L("  [AUTH] SKIPPING 0x51 on purpose (isolate whether 0x51 mutes link)")
                } else if isReq {
                    write(p, encResp(0x50, sq))
                }
            } else if op == 0x51 {
                if isReq { write(p, encResp(0x51, sq)) }
                else { L("  [AUTH] *** 0x51 CONFIRMED by device ***") }
            } else if isReq {
                write(p, encResp(op, sq))
            }
        }
    }

    func finish(_ why: String) {
        guard !done else { return }; done = true
        L("\n\n========== FINAL RESULTS (\(why)) ==========")
        L("AUTH_ANSWER   : \(rAuthAnswer)")
        L("AUTH_MATCH    : \(rAuthMatch)  (attempts=\(attempts) matches=\(matches))")
        L("GET_CONFIG    : \(rCfg)")
        L("OPCODE_243    : \(rOp243)")
        L("SET_CONFIG    : \(rSet)")
        L("CONTROL_0x02  : \(rCtrl)")
        try? log.joined(separator: "\n").write(toFile: LOGPATH, atomically: true, encoding: .utf8)
        L("[log] \(LOGPATH)"); exit(0)
    }
}

let secs = Double(CommandLine.arguments.dropFirst().first ?? "55") ?? 55
let pr = P()
DispatchQueue.main.asyncAfter(deadline: .now() + secs) { pr.finish("timeout") }
RunLoop.main.run()
