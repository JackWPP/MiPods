// research/record/p1/main.swift
// DECISIVE: run1 got a real `0x50 RESPONSE` from the buds (payload 01 + 16B).
// We sent `0x51 [01][00]` right after, then the link dropped -- and we NEVER
// tested GET_CONFIG(70/69/68) after that "auth claimed success" step.
// This probe closes exactly that gap, with several orderings.
//
// SAFETY: only 0x50/0x51 auth handshake + 0xF3 (GET_CONFIG, read) + 0x02/0x09 reads.
// No SET_CONFIG, no 0xD0-0xD3, no OTA, no unpair/reboot.
//
// Usage: ./p1 <seconds>

import Foundation
import CoreBluetooth

enum MType: UInt8 { case phoneRequest = 0xC4, response = 0x04, earbudsRequest = 0xC0, earbudsNotify = 0xC7 }

/// Byte-exact replica of the APK encoder a6/f.java -> A(BasePacket)
/// type byte = 0x80 (command) | 0x40 (hasResponse) | targetApp
/// paramLen = paramData.count + 1 (the +1 is the seq/opCodeSn byte)
func encFrame(opcode: UInt8, payload: [UInt8], seq: UInt8,
              hasResponse: Bool = true, targetApp: UInt8 = 4,
              typ: Bool = true /* command */) -> [UInt8] {
    var tb: UInt8 = 0
    if typ { tb |= 0x80 }
    if hasResponse { tb |= 0x40 }
    tb |= (targetApp & 0x07)
    // command: body = [seq] + payload          (paramLen = payload+1)
    // response: body = [status=0] + [seq]      (paramLen = 2)
    var body: [UInt8]
    let paramLen: Int
    if typ {
        paramLen = payload.count + 1
        body = [seq] + payload
    } else {
        paramLen = 2
        body = [0x00, seq]
    }
    var out: [UInt8] = [0xFE, 0xDC, 0xBA, tb, opcode,
                        UInt8((paramLen >> 8) & 0xFF), UInt8(paramLen & 0xFF)]
    out.append(contentsOf: body)
    out.append(0xEF)
    return out
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }

var out: [String] = []
func LOG(_ s: String) { print(s); fflush(stdout); out.append(s) }
let LOGPATH = "p1.log"

final class P: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var c: CBCentralManager!
    var t: CBPeripheral?
    var w: CBCharacteristic?
    var buf: [UInt8] = []
    var seq: UInt8 = 0
    let TARGET = "1300D6D417E2"

    var traffic: [String] = []      // frames seen in current step
    var authed = false
    var done = false
    var reconnects = 0

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
        guard reconnects <= 5 else { finish("too many reconnects"); return }
        LOG("[reconn] retry #\(reconnects) in 3s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.done else { return }
            self.t = nil; self.buf.removeAll(); self.w = nil
            self.c.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    var sawW = false, sawN = false, started = false
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
        // short settle, matching run1 (which discovered+read first, then authed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.phaseA(p) }
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
            LOG("  <== " + line); traffic.append(line)
            handle(p, typeRaw: typeRaw, op: op, seq: sq, payload: payload, isReq: isReq)
        }
    }

    func handle(_ p: CBPeripheral, typeRaw: UInt8, op: UInt8, seq sq: UInt8,
                payload: [UInt8], isReq: Bool) {
        switch op {
        case 0x50:
            if typeRaw == 0x04 {
                // buds answered OUR challenge -> claim success with pairResult=0
                LOG("  [auth] got 0x50 RESPONSE from buds -> sending 0x51 [01 00]")
                sendAuthConfirm(p, seq: nextSeq())
            } else if payload.count >= 17 {
                // device-initiated challenge; answer with SAFER then it could unlock
                let ans = Safer.computeResponse(to: Array(payload[1..<17]))
                LOG("  [auth] buds challenge -> SAFER answer \(hex(ans))")
                write(p, encFrame(opcode: 0x50, payload: [0x01] + ans, seq: sq,
                                  hasResponse: false, typ: false))
            } else if isReq {
                write(p, encFrame(opcode: 0x50, payload: [], seq: sq, hasResponse: false, typ: false))
            }
        case 0x51:
            if isReq {
                write(p, encFrame(opcode: 0x51, payload: [0x01], seq: sq, hasResponse: false, typ: false))
            } else {
                LOG("  [auth] *** 0x51 RESPONSE -- auth confirmed by buds ***")
                authed = true
            }
        case 0xF4, 0x0E:
            if isReq { write(p, encFrame(opcode: op, payload: [], seq: sq, hasResponse: false, typ: false)) }
        default:
            if isReq { write(p, encFrame(opcode: op, payload: [], seq: sq, hasResponse: false, typ: false)) }
        }
    }

    func write(_ p: CBPeripheral, _ f: [UInt8]) {
        guard let w else { LOG("  !! no AF07"); return }
        let ty: CBCharacteristicWriteType = w.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(Data(f), for: w, type: ty)
        LOG("  ==> SEND op=0x\(String(format: "%02X", f[4])) \(hex(f))")
    }
    func sendAuthConfirm(_ p: CBPeripheral, seq: UInt8) {
        // AuthSendCalcResultParam(version=1, pairResult=0) => payload [01][00]
        write(p, encFrame(opcode: 0x51, payload: [0x01, 0x00], seq: seq))
    }
    func reqConfig(_ p: CBPeripheral, _ code: UInt16) {
        write(p, encFrame(opcode: 0xF3, payload: [UInt8(code >> 8), UInt8(code & 0xFF)], seq: nextSeq()))
    }

    // ---- Phase A: the exact untested gap ----
    // 1. auth challenge FIRST (like run1 did)
    // 2. on 0x50 RESPONSE -> 0x51 [01 00]
    // 3. immediately GET_CONFIG 70 / 69 / 68
    func phaseA(_ p: CBPeripheral) {
        LOG("\n===== PHASE A: auth-first, then config (run1's untested gap) =====")
        traffic = []
        let ch = (0..<16).map { _ in UInt8.random(in: 0...255) }
        write(p, encFrame(opcode: 0x50, payload: [0x01] + ch, seq: nextSeq()))

        // after 1.6s, whether or not we saw a response, push config reads
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, !self.done else { return }
            LOG("  >> traffic after auth step: \(self.traffic.count) frame(s)")
            self.phaseB(p)
        }
    }

    func phaseB(_ p: CBPeripheral) {
        LOG("\n===== PHASE B: GET_CONFIG 70/69/68 right after auth claim =====")
        traffic = []
        reqConfig(p, 0x0046)   // 70 capacity
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, !self.done else { return }
            self.reqConfig(p, 0x0045)   // 69 list
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, !self.done else { return }
                self.reqConfig(p, 0x0044)  // 68 status
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                    guard let self, !self.done else { return }
                    LOG("  >> phase B traffic: \(self.traffic.count) frame(s)")
                    self.phaseC(p)
                }
            }
        }
    }

    // ---- Phase C: control -- 0x02 must reply to prove link is alive ----
    func phaseC(_ p: CBPeripheral) {
        LOG("\n===== PHASE C: control 0x02 GET_DEVICE_INFO (link liveness) =====")
        traffic = []
        write(p, encFrame(opcode: 0x02, payload: [0xFF,0xFF,0xFF,0xFF], seq: nextSeq()))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, !self.done else { return }
            LOG("  >> PHASE C traffic: \(self.traffic.count) frame(s)")
            self.phaseD(p)
        }
    }

    // ---- Phase D: run info (known-good read) ----
    func phaseD(_ p: CBPeripheral) {
        LOG("\n===== PHASE D: control 0x09 GET_RUN_INFO =====")
        traffic = []
        write(p, encFrame(opcode: 0x09, payload: [0xFF,0xFF,0xFF,0xFF], seq: nextSeq()))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, !self.done else { return }
            LOG("  >> PHASE D traffic: \(self.traffic.count) frame(s)")
            self.finish("all phases done")
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
    LOG("[timeout]")
    try? out.joined(separator: "\n").write(toFile: LOGPATH, atomically: true, encoding: .utf8)
    exit(0)
}
RunLoop.main.run()
