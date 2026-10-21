import Foundation
import CoreBluetooth

enum MType: UInt8 { case phoneRequest = 0xC4, response = 0x04, earbudsRequest = 0xC0, earbudsNotify = 0xC7 }

func encFrame(type: MType, opcode: UInt8, seq: UInt8, payload: [UInt8]) -> [UInt8] {
    let isReq = (type.rawValue & 0x40) != 0
    let len = payload.count + (isReq ? 1 : 2)
    var b: [UInt8] = [0xFE, 0xDC, 0xBA, type.rawValue, opcode, UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)]
    if !isReq { b.append(0x00) }
    b.append(seq)
    b.append(contentsOf: payload)
    b.append(0xEF)
    return b
}
func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
func hexc(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }

let TARGET = "1300D6D417E2"

final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var target: CBPeripheral?
    var writeChar: CBCharacteristic?
    var notifyChar: CBCharacteristic?
    var seq: UInt8 = 0
    var rxBuf: [UInt8] = []
    var txCount = 0
    var authState = "none"

    override init() { super.init(); central = CBCentralManager(delegate: self, queue: nil) }

    func centralManagerDidUpdateState(_ cm: CBCentralManager) {
        guard cm.state == .poweredOn else { print("[state] \(cm.state.rawValue)"); return }
        cm.scanForPeripherals(withServices: nil, options: nil)
    }
    func centralManager(_ cm: CBCentralManager, didDiscover p: CBPeripheral, advertisementData d: [String: Any], rssi r: NSNumber) {
        guard let m = d[CBAdvertisementDataManufacturerDataKey] as? Data,
              hexc([UInt8](m)).contains(TARGET), target == nil else { return }
        target = p; cm.stopScan(); p.delegate = self; cm.connect(p, options: nil)
    }
    func centralManager(_ cm: CBCentralManager, didConnect p: CBPeripheral) {
        print("[conn] connected"); p.discoverServices(nil)
    }
    func centralManager(_ cm: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { print("[conn] failed \(error?.localizedDescription ?? "")") }
    func centralManager(_ cm: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { print("[conn] disconnected") }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid.uuidString == "AF07" { writeChar = ch }
            if ch.uuid.uuidString == "AF08" { notifyChar = ch; p.setNotifyValue(true, for: ch) }
        }
        guard let _ = writeChar, let _ = notifyChar, txCount == 0 else { return }
        txCount = 1
        // Step 1 (t=0.8s): unauthenticated GET_DEVICE_INFO
        later(0.8) { self.send(p, .phoneRequest, 0x02, [0xFF, 0xFF, 0xFF, 0xFF], label: "GET_DEVICE_INFO(no-auth)") }
        // Step 2 (t=3s): auth challenge
        later(3.0) {
            let ch = (0..<16).map { _ in UInt8.random(in: 0...255) }
            self.authState = "sent-challenge"
            self.send(p, .phoneRequest, 0x50, [0x01] + ch, label: "AUTH_CHALLENGE")
        }
        // Step 3 (t=6s): GET_DEVICE_INFO again (post-auth)
        later(6.0) { self.send(p, .phoneRequest, 0x02, [0xFF, 0xFF, 0xFF, 0xFF], label: "GET_DEVICE_INFO(post-auth)") }
        // Step 4 (t=8s): GET_DEVICE_RUN_INFO
        later(8.0) { self.send(p, .phoneRequest, 0x09, [0xFF, 0xFF, 0xFF, 0xFF], label: "GET_RUN_INFO") }
    }

    func later(_ t: Double, _ f: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f)
    }
    func send(_ p: CBPeripheral, _ type: MType, _ op: UInt8, _ payload: [UInt8], label: String) {
        guard let w = writeChar else { return }
        let f = encFrame(type: type, opcode: op, seq: seq, payload: payload); seq &+= 1
        let ty: CBCharacteristicWriteType = w.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(Data(f), for: w, type: ty)
        print("[tx \(label)] seq=\(String(format: "%02X", seq &- 1)) \(hexc(f))")
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        if let e = error { print("[tx] ERROR \(e.localizedDescription)") }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let d = ch.value else { return }
        let bytes = [UInt8](d)
        print("[rx raw] \(hexc(bytes))  (\(bytes.count)B)")
        rxBuf.append(contentsOf: bytes)
        drain(p)
    }

    func drain(_ p: CBPeripheral) {
        while true {
            guard let s = rxBuf.firstIndex(of: 0xFE) else { rxBuf.removeAll(); return }
            if s > 0 { rxBuf.removeFirst(s) }
            guard rxBuf.count >= 7 else { return }
            guard rxBuf[1] == 0xDC, rxBuf[2] == 0xBA else { rxBuf.removeFirst(1); continue }
            let isReq = (rxBuf[3] & 0x40) != 0
            let len = Int(rxBuf[5]) << 8 | Int(rxBuf[6])
            guard len >= 1, len <= 4096 else { rxBuf.removeFirst(1); continue }
            let total = 7 + len + 1
            guard rxBuf.count >= total else { return }
            guard rxBuf[total - 1] == 0xEF else { rxBuf.removeFirst(1); continue }
            let bodyStart = 7 + (isReq ? 0 : 1)
            let sq = rxBuf[bodyStart]
            let payload = Array(rxBuf[(bodyStart + 1)..<(total - 1)])
            let op = rxBuf[4]; let ty = rxBuf[3]
            rxBuf.removeFirst(total)
            print("[rx] type=0x\(String(ty, radix: 16)) op=0x\(String(format: "%02X", op)) seq=0x\(String(format: "%02X", sq)) len=\(len) payload=\(hexc(payload))")
            handle(p, ty: ty, op: op, sq: sq, payload: payload, isReq: isReq)
        }
    }

    func handle(_ p: CBPeripheral, ty: UInt8, op: UInt8, sq: UInt8, payload: [UInt8], isReq: Bool) {
        switch op {
        case 0x50:
            if ty == 0x04, payload.count >= 17 {
                let ans = Safer.computeResponse(to: Array(payload[1..<17]))
                print("     -> computed SAFER+ response \(hexc(ans))")
                authState = "computed-answer"
                sendRaw(p, encFrame(type: .response, opcode: 0x50, seq: sq, payload: [0x01] + ans), label: "AUTH_ANSWER")
            }
        case 0x51:
            if isReq { sendRaw(p, encFrame(type: .response, opcode: 0x51, seq: sq, payload: [0x01]), label: "AUTH_CONFIRM_ACK") }
            print("     -> AUTH CONFIRMED")
        case 0x02:
            print("     *** DEVICE_INFO ***")
            parseTLV(payload, tag: "deviceInfo")
        case 0x09:
            print("     *** RUN_INFO ***")
            parseTLV(payload, tag: "runInfo")
        case 0x0E, 0xF4:
            if isReq { sendRaw(p, encFrame(type: .response, opcode: op, seq: sq, payload: []), label: "ACK(0x\(String(format: "%02X", op)))") }
            parseTLV(payload, tag: op == 0x0E ? "status" : "notifyConfig")
        default:
            break
        }
    }
    func sendRaw(_ p: CBPeripheral, _ f: [UInt8], label: String) {
        guard let w = writeChar else { return }
        let ty: CBCharacteristicWriteType = w.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(Data(f), for: w, type: ty)
        print("[tx \(label)] \(hexc(f))")
    }
    func parseTLV(_ payload: [UInt8], tag: String) {
        var i = 0
        while i + 1 < payload.count {
            let len = Int(payload[i])
            guard len >= 1, i + 1 + len <= payload.count else { break }
            let idx = payload[i + 1]
            let data = Array(payload[(i + 2)..<(i + 1 + len)])
            print("       [\(tag)] idx=0x\(String(format: "%02X", idx)) data=\(hexc(data)) ascii=\(String(bytes: data, encoding: .utf8) ?? "")")
            if idx == 0x07 && data.count >= 3 {
                let names = ["L", "R", "CASE"]
                for (n, b) in data.enumerated() where n < 3 {
                    print("       BATTERY \(names[n]): \(b & 0x7F)%  charging=\((b & 0x80) != 0)")
                }
            }
            i += len + 1
        }
    }
}

let probe = Probe()
RunLoop.main.run(until: Date().addingTimeInterval(Double(CommandLine.arguments.dropFirst().first ?? "20") ?? 20))
print("done")
