// research/record/p0p1/main.swift
// DECISIVE tests: P0 (is auth really required? maybe we just need to wait / use 2-byte configId)
//                 P1 (does the buds ever initiate a 0x50 challenge on its own?)
//
// RULE: read/query only. Never SET_CONFIG, never 0xD0-0xD3, never OTA.
//
// Key facts taken from APK decompile (Lead, verified independently here):
//   GetDeviceConfigParam.getParamData() == exactly [typeHi, typeLo] for each type.
//   NO length prefix in the payload. Opcode 0xF3.
//   Config IDs: 68 status, 69 list, 70 properties(capacity), 75 start/stop, 52 bigfile.
//
// Usage: ./p0p1 <seconds>

import Foundation
import CoreBluetooth

enum MType: UInt8 { case phoneRequest = 0xC4, response = 0x04, earbudsRequest = 0xC0, earbudsNotify = 0xC7 }
func encFrame(type: MType, opcode: UInt8, seq: UInt8, payload: [UInt8]) -> [UInt8] {
    let extra = (type.rawValue & 0x40) != 0 ? 1 : 2
    let len = payload.count + extra
    var b: [UInt8] = [0xFE, 0xDC, 0xBA, type.rawValue, opcode,
                      UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)]
    if (type.rawValue & 0x40) == 0 { b.append(0x00) }
    b.append(seq); b.append(contentsOf: payload); b.append(0xEF)
    return b
}
func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }

var out: [String] = []
func LOG(_ s: String) { print(s); fflush(stdout); out.append(s) }
let LOGPATH = "p0p1.log"

final class P: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var c: CBCentralManager!
    var t: CBPeripheral?
    var w: CBCharacteristic?
    var buf: [UInt8] = []
    var seq: UInt8 = 0
    let TARGET = "1300D6D417E2"
    var step = 0
    var testLog: [String] = []
    var done = false

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
        LOG("[found] \(p.name ?? "?")")
        t = p; cm.stopScan(); p.delegate = self; cm.connect(p, options: nil)
    }
    func centralManager(_ cm: CBCentralManager, didConnect p: CBPeripheral) {
        LOG("[conn] connected"); p.discoverServices(nil)
    }
    func centralManager(_ cm: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        LOG("[conn] DISCONNECTED \(error?.localizedDescription ?? "")")
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] where s.uuid.uuidString == "AF00" {
            p.discoverCharacteristics(nil, for: s)
        }
    }
    var sawAF07 = false, sawAF08 = false, gotService = false
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid.uuidString == "AF07" { w = ch; sawAF07 = true }
            if ch.uuid.uuidString == "AF08" { sawAF08 = true; p.setNotifyValue(true, for: ch) }
        }
        guard sawAF07 && sawAF08, !gotService else { return }
        gotService = true
        LOG("[gatt] AF07+AF08 ready")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.run(p) }
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
            let line = String(format: "  <== %@ op=0x%02X seq=0x%02X st=%@ payload=%@",
                              tn, op, sq, st, hex(payload))
            LOG(line); testLog.append(line)
            if isReq {
                // ack unknown device requests so it doesn't stall
                write(p, encFrame(type: .response, opcode: op, seq: sq, payload: []))
            }
        }
    }

    func write(_ p: CBPeripheral, _ f: [UInt8]) {
        guard let w else { LOG("  !! no AF07"); return }
        let ty: CBCharacteristicWriteType = w.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(Data(f), for: w, type: ty)
        LOG("  ==> SEND op=0x\(String(format: "%02X", f[4])) \(hex(f))")
    }

    // --- ordered experiment ---
    var queue: [(String, () -> Void)] = []
    var qi = 0

    func run(_ p: CBPeripheral) {
        queue = []

        // P0-idle: send NOTHING for 10s, see if buds initiates 0x50 (P1 test)
        queue.append(("P1-idle10s: send nothing, watch for buds-initiated 0x50", {}))

        // P0-a: baseline sanity, must reply unauth
        queue.append(("P0-a baseline GET_DEVICE_INFO 0x02", {
            self.write(p, encFrame(type: .phoneRequest, opcode: 0x02, seq: self.nextSeq(),
                                   payload: [0xFF,0xFF,0xFF,0xFF]))
        }))

        // P0-b: GET_CONFIG with CORRECT 2-byte configId, no len prefix
        //       code 70 = 0x0046 capacity, 69 = 0x0045 list, 68 = 0x0044 status
        for (name, code) in [("70 capacity", 0x0046), ("69 list", 0x0045),
                             ("68 status", 0x0044), ("75 recordctl", 0x004B),
                             ("52 bigfile", 0x0034)] {
            queue.append(("P0-b GET_CONFIG \(name) => payload [\(String(format: "%02X %02X", (code >> 8) & 0xFF, code & 0xFF))]", {
                self.write(p, encFrame(type: .phoneRequest, opcode: 0xF3, seq: self.nextSeq(),
                                       payload: [UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]))
            }))
        }

        // P0-c: variant WITH 1-byte len prefix = [01][00][46]  (test if we got format wrong)
        queue.append(("P0-c GET_CONFIG 70 variant [01 00 46]", {
            self.write(p, encFrame(type: .phoneRequest, opcode: 0xF3, seq: self.nextSeq(),
                                   payload: [0x01, 0x00, 0x46]))
        }))
        // P0-d: variant [02 00 46]
        queue.append(("P0-d GET_CONFIG 70 variant [02 00 46]", {
            self.write(p, encFrame(type: .phoneRequest, opcode: 0xF3, seq: self.nextSeq(),
                                   payload: [0x02, 0x00, 0x46]))
        }))
        // P0-e: multi-config form [00 46][00 45][00 44]
        queue.append(("P0-e GET_CONFIG multi 70+69+68", {
            self.write(p, encFrame(type: .phoneRequest, opcode: 0xF3, seq: self.nextSeq(),
                                   payload: [0x00,0x46, 0x00,0x45, 0x00,0x44]))
        }))

        // P1: now issue auth challenge and watch
        queue.append(("P1 AUTH 0x50 challenge [01][16B]", {
            let ch = (0..<16).map { _ in UInt8.random(in: 0...255) }
            self.write(p, encFrame(type: .phoneRequest, opcode: 0x50,
                                   seq: self.nextSeq(), payload: [0x01] + ch))
        }))

        // P0-f: retry config AFTER auth attempt, in case auth half-succeeded
        queue.append(("P0-f GET_CONFIG 70 AFTER auth attempt", {
            self.write(p, encFrame(type: .phoneRequest, opcode: 0xF3, seq: self.nextSeq(),
                                   payload: [0x00, 0x46]))
        }))
        // P0-g: GET_RUN_INFO again as a link-liveness control at the end
        queue.append(("P0-g control GET_RUN_INFO 0x09", {
            self.write(p, encFrame(type: .phoneRequest, opcode: 0x09, seq: self.nextSeq(),
                                   payload: [0xFF,0xFF,0xFF,0xFF]))
        }))

        LOG("\n===== STARTING P0/P1 EXPERIMENTS (\(queue.count) steps) =====")
        qi = 0
        advance(p)
    }

    func advance(_ p: CBPeripheral) {
        guard qi < queue.count else { finish(); return }
        let (label, action) = queue[qi]
        qi += 1
        testLog = []
        LOG("\n--- [\(qi)/\(queue.count)] \(label) ---")
        action()
        // wait 2.6s (app uses 2000ms timeout for config commands)
        let isIdle = label.hasPrefix("P1-idle10s")
        let wait = isIdle ? 10.0 : 2.6
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            let verdict = self.testLog.isEmpty ? "NO-RESPONSE" : "TRAFFIC(\(self.testLog.count))"
            LOG("  >>> VERDICT \(label): \(verdict)")
            out.append("VERDICT \(label): \(verdict) \(self.testLog.joined(separator: " || "))")
            self.advance(p)
        }
    }

    func finish() {
        guard !done else { return }; done = true
        LOG("\n\n========== SUMMARY ==========")
        for l in out where l.hasPrefix("VERDICT ") { LOG(l) }
        try? out.joined(separator: "\n").write(toFile: LOGPATH, atomically: true, encoding: .utf8)
        LOG("[log] \(LOGPATH)")
        exit(0)
    }
}

let secs = Double(CommandLine.arguments.dropFirst().first ?? "120") ?? 120
let pr = P()
DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
    LOG("[timeout]")
    try? out.joined(separator: "\n").write(toFile: LOGPATH, atomically: true, encoding: .utf8)
    exit(0)
}
RunLoop.main.run()
