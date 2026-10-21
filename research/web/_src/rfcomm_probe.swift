import Foundation
import IOBluetooth

// End-to-end RFCOMM probe of the Xiaomi earbuds' MIWEAR control channel.
// Read-only: GET_DEVICE_INFO (+ auth handshake if required). No settings are changed.

let targetMAC = "00-13-D6-E2-17-D4"
let channelID = BluetoothRFCOMMChannelID(UInt8(CommandLine.arguments.count > 1 ? (UInt8(CommandLine.arguments[1]) ?? 28) : 28))

func hexdump(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

// MARK: - SAFER+ variant auth (ported from Gadgetbridge RedmiBuds Authentication.java)

let kSeq: [UInt8] = [0x11, 0x22, 0x33, 0x33, 0x22, 0x11, 0x11, 0x22,
                     0x33, 0x33, 0x22, 0x11, 0x11, 0x22, 0x33, 0x33]

let kCoefficients: [[Int]] = [
    [2,1,1,1,4,2,1,1,2,2,4,2,4,4,16,8],
    [2,1,1,1,4,2,1,1,1,1,2,1,2,2,8,4],
    [1,1,4,2,2,2,4,2,16,8,4,4,2,1,1,1],
    [1,1,4,2,1,1,2,1,8,4,2,2,2,1,1,1],
    [16,8,2,2,4,2,4,4,1,1,4,2,1,1,2,1],
    [8,4,1,1,2,1,2,2,1,1,4,2,1,1,2,1],
    [2,2,4,2,4,4,16,8,2,1,1,1,4,2,1,1],
    [1,1,2,1,2,2,8,4,2,1,1,1,4,2,1,1],
    [4,2,4,4,16,8,2,2,1,1,2,1,1,1,4,2],
    [2,1,2,2,8,4,1,1,1,1,2,1,1,1,4,2],
    [4,4,16,8,1,1,2,1,4,2,1,1,4,2,2,2],
    [2,2,8,4,1,1,2,1,4,2,1,1,2,1,1,1],
    [1,1,2,1,1,1,4,2,4,4,16,8,2,2,4,2],
    [1,1,2,1,1,1,4,2,2,2,8,4,1,1,2,1],
    [4,2,1,1,2,1,1,1,4,2,2,2,16,8,4,4],
    [4,2,1,1,2,1,1,1,2,1,1,1,8,4,2,2],
]

func powMod(_ b: Int, _ e: Int, _ m: Int) -> Int {
    var result = 1
    var base = b % m
    var exp = e
    while exp > 0 {
        if exp & 1 == 1 { result = (result * base) % m }
        base = (base * base) % m
        exp >>= 1
    }
    return result
}

let biasMatrix: [[UInt8]] = (0..<16).map { i in
    (0..<16).map { j in
        let exponent = 17 * (i + 2) + (j + 1)
        let inner = powMod(45, exponent, 257)
        let v = powMod(45, inner, 257)
        return UInt8(v == 256 ? 0 : v)
    }
}

let expTab: [UInt8] = (0..<256).map { i in
    if i == 128 { return 0 }
    let v = powMod(45, i, 257)
    return UInt8(v == 256 ? 0 : v)
}

var logTab = [UInt8](repeating: 0, count: 256)
for i in 0..<256 {
    if i == 0 {
        logTab[0] = 128
    } else {
        let v = powMod(45, i, 257)
        if v != 256 { logTab[v] = UInt8(i) }
    }
}

func keySchedule(_ keyInitIn: [UInt8]) -> [[UInt8]] {
    var keyInit = keyInitIn
    keyInit[15] ^= 6
    var keys: [[UInt8]] = [keyInit]
    var register = keyInit.map { Int($0) }
    var x = 0
    for b in keyInit { x ^= Int(b) }
    register.append(x)

    for keyIdx in 1..<17 {
        for i in 0..<17 {
            let b = register[i] & 0xFF
            register[i] = ((b >> 5) | ((b << 3) & 0xFF)) & 0xFF
        }
        var keyI = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 {
            keyI[i] = UInt8((register[(keyIdx + i) % 17] + Int(biasMatrix[keyIdx - 1][i])) & 0xFF)
        }
        keys.append(keyI)
    }
    return keys
}

func saferEncrypt(_ plaintext: [UInt8], _ keys: [[UInt8]]) -> [UInt8] {
    var c = plaintext
    let pattern = 0x9999
    for round in 0..<8 {
        if round == 2 {
            for i in 0..<16 {
                if (1 << i) & pattern != 0 { c[i] ^= plaintext[i] }
                else { c[i] = c[i] &+ plaintext[i] }
            }
        }
        for i in 0..<16 {
            if (1 << i) & pattern != 0 { c[i] ^= keys[round * 2][i] }
            else { c[i] = c[i] &+ keys[round * 2][i] }
        }
        for i in 0..<16 {
            if (1 << i) & pattern != 0 { c[i] = expTab[Int(c[i])] }
            else { c[i] = logTab[Int(c[i])] }
        }
        for i in 0..<16 {
            if (1 << i) & pattern != 0 { c[i] = keys[round * 2 + 1][i] &+ c[i] }
            else { c[i] = keys[round * 2 + 1][i] ^ c[i] }
        }
        let copy = c
        for i in 0..<16 {
            var s = 0
            for j in 0..<16 { s += kCoefficients[i][j] * Int(copy[j]) }
            c[i] = UInt8(s & 0xFF)
        }
    }
    for i in 0..<16 {
        if (1 << i) & pattern != 0 { c[i] = keys[16][i] ^ c[i] }
        else { c[i] = keys[16][i] &+ c[i] }
    }
    return c
}

func challengeResponse(_ challenge: [UInt8]) -> [UInt8] {
    saferEncrypt(kSeq, keySchedule(challenge))
}

// MARK: - Frame codec

func encodeFrame(type: UInt8, opcode: UInt8, seq: UInt8, payload: [UInt8]) -> [UInt8] {
    let isRequest = (type & 0x40) != 0
    let extra = isRequest ? 1 : 2
    let length = payload.count + extra
    var b: [UInt8] = [0xFE, 0xDC, 0xBA, type, opcode,
                      UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
    if !isRequest { b.append(0x00) }
    b.append(seq)
    b.append(contentsOf: payload)
    b.append(0xEF)
    return b
}

struct Frame { let type: UInt8; let opcode: UInt8; let seq: UInt8; let payload: [UInt8] }

func decodeFrames(_ buf: [UInt8]) -> [Frame] {
    var out: [Frame] = []
    var i = 0
    while i + 7 <= buf.count {
        guard buf[i] == 0xFE, buf[i+1] == 0xDC, buf[i+2] == 0xBA else { i += 1; continue }
        let type = buf[i+3]
        let opcode = buf[i+4]
        let len = Int(buf[i+5]) << 8 | Int(buf[i+6])
        let total = 7 + len + 1
        guard len >= 1, i + total <= buf.count else { break }
        guard buf[i + total - 1] == 0xEF else { i += 1; continue }
        let isRequest = (type & 0x40) != 0
        let bodyStart = i + 7 + (isRequest ? 0 : 1)
        let seq = buf[bodyStart]
        let payload = Array(buf[(bodyStart + 1)..<(i + total - 1)])
        out.append(Frame(type: type, opcode: opcode, seq: seq, payload: payload))
        i += total
    }
    return out
}

func parseTLV(_ payload: [UInt8]) -> [(UInt8, [UInt8])] {
    var entries: [(UInt8, [UInt8])] = []
    var i = 0
    while i + 1 < payload.count {
        let length = Int(payload[i])
        guard length >= 1, i + 1 + length <= payload.count else { break }
        entries.append((payload[i + 1], Array(payload[(i + 2)..<(i + 1 + length)])))
        i += length + 1
    }
    return entries
}

func describeBattery(_ bytes: [UInt8]) -> String {
    let names = ["left", "right", "case"]
    var parts: [String] = []
    for (idx, raw) in bytes.prefix(3).enumerated() {
        let n = idx < names.count ? names[idx] : "?\(idx)"
        if raw == 0xFF { parts.append("\(n)=unknown") }
        else {
            let charging = (raw & 0x80) != 0
            parts.append("\(n)=\(raw & 0x7F)%\(charging ? "(charging)" : "")")
        }
    }
    return parts.joined(separator: " ")
}

// MARK: - Runner

final class Runner: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var channel: IOBluetoothRFCOMMChannel?
    var buffer: [UInt8] = []
    var seq: UInt8 = 0
    var didAuth = false
    var sendDeviceInfoAfterAuth = false
    var done = false

    func nextSeq() -> UInt8 { defer { seq = seq &+ 1 }; return seq }

    func send(_ bytes: [UInt8], label: String) {
        print(">> [\(label)] \(hexdump(bytes))")
        guard let ch = channel else { return }
        var mutable = bytes
        let count = UInt16(bytes.count)
        let rc = mutable.withUnsafeMutableBytes { p in
            ch.writeSync(p.baseAddress, length: count)
        }
        if rc != kIOReturnSuccess { print("   write failed rc=\(rc)") }
    }

    func requestDeviceInfo() {
        send(encodeFrame(type: 0xC4, opcode: 0x02, seq: nextSeq(),
                         payload: [0xFF, 0xFF, 0xFF, 0xFF]), label: "GET_DEVICE_INFO")
    }

    func rfcommChannelOpenComplete(_ ch: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        print("channel open status: \(error)")
        guard error == kIOReturnSuccess else { done = true; return }
        channel = ch
        print("channel isOpen=\(ch.isOpen()) MTU=\(ch.getMTU())")
        requestDeviceInfo()
        // If nothing comes back within 2.5s, assume auth is required.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, !self.didAuth else { return }
            print("\n-- no reply yet, no reply to GET_DEVICE_INFO (auth likely required)")
            self.done = true
        }
    }

    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = [UInt8](UnsafeBufferPointer(start: dataPointer.assumingMemoryBound(to: UInt8.self), count: dataLength))
        print("<< \(hexdump(bytes))")
        buffer.append(contentsOf: bytes)
        let frames = decodeFrames(buffer)
        buffer.removeAll()

        for f in frames {
            let op = String(format: "%02X", f.opcode)
            print("   frame type=\(String(format: "%02X", f.type)) opcode=\(op) seq=\(f.seq) payload=\(hexdump(f.payload))")
            switch f.opcode {
            case 0x02:
                print("   *** DEVICE_INFO responded WITHOUT auth ***")
                for (idx, data) in parseTLV(f.payload) {
                    if idx == 0x07 { print("   battery(raw \(hexdump(data))): \(describeBattery(data))") }
                    else { print("   tlv 0x\(String(format: "%02X", idx)) = \(hexdump(data))") }
                }
                done = true
            case 0x50:
                // AUTH_CHALLENGE
                if f.type == 0xC4 || f.type == 0xC0 {
                    // buds asking us to answer a challenge
                    let challenge = Array(f.payload.dropFirst().prefix(16))
                    print("   buds challenge = \(hexdump(challenge))")
                    let answer = challengeResponse(challenge)
                    print("   our answer      = \(hexdump(answer))")
                    var payload: [UInt8] = [0x01]
                    payload.append(contentsOf: answer)
                    send(encodeFrame(type: 0x04, opcode: 0x50, seq: f.seq, payload: payload), label: "AUTH_RESPONSE")
                } else {
                    print("   auth response from buds: \(hexdump(f.payload))")
                }
            case 0x51:
                print("   AUTH_CONFIRM")
            case 0x0E:
                for (idx, data) in parseTLV(f.payload) {
                    if idx == 0x00 { print("   battery(raw \(hexdump(data))): \(describeBattery(data))") }
                    else { print("   status tlv 0x\(String(format: "%02X", idx)) = \(hexdump(data))") }
                }
            default:
                break
            }
        }
    }

    func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {
        print("channel closed")
        done = true
    }
}

guard let dev = IOBluetoothDevice(addressString: targetMAC) else {
    print("device not found"); exit(1)
}
print("device: \(dev.name ?? "?")  connected=\(dev.isConnected())  paired=\(dev.isPaired())")

let runner = Runner()
var newChannel: IOBluetoothRFCOMMChannel?
let rc = dev.openRFCOMMChannelAsync(&newChannel, withChannelID: channelID, delegate: runner)
print("openRFCOMMChannelAsync(channel \(channelID)) -> \(rc)")
if rc != kIOReturnSuccess {
    print("FAILED to open RFCOMM channel \(channelID)")
    exit(2)
}

let deadline = Date().addingTimeInterval(8)
while !runner.done && Date() < deadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
}
print("\n=== finished (done=\(runner.done)) ===")
exit(0)
