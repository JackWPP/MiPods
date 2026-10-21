import Foundation

// MARK: - Frame codec
//
// Wire format observed on Xiaomi "vela os earbuds" (M2529E1) over BLE GATT
// service 0xAF00, characteristic AF07 (write) / AF08 (notify):
//
//   FE DC BA | type | opcode | length(2, BE) | [status] | sequence | payload | EF
//
// `length` counts the status byte (responses only), the sequence byte and the payload.
// Types with bit 0x40 set (requests / notifications) carry no status byte.

public enum MessageType: UInt8, Sendable, Equatable {
    case phoneRequest = 0xC4
    case response = 0x04
    case earbudsRequest = 0xC0
    case earbudsNotify = 0xC7

    public var isRequest: Bool { rawValue & 0x40 != 0 }

    public init?(code: UInt8) {
        // Accept unknown codes by mapping them onto the nearest known family.
        switch code {
        case 0xC4: self = .phoneRequest
        case 0x04: self = .response
        case 0xC0: self = .earbudsRequest
        case 0xC7: self = .earbudsNotify
        default:
            if code & 0x40 != 0 {
                self = .phoneRequest
            } else {
                self = .response
            }
        }
    }
}

public enum Opcode: UInt8, Sendable {
    case getDeviceInfo = 0x02
    case setANC = 0x08
    case getRunInfo = 0x09
    case setChannel = 0x0A      // host tells the device which transport to serve (0 = BLE, 1 = SPP)
    case wakeClassic = 0x0B     // wake the classic BT module before opening SPP
    case reportStatus = 0x0E
    case authChallenge = 0x50
    case authConfirm = 0x51
    case setConfig = 0xF2
    case getConfig = 0xF3
    case notifyConfig = 0xF4
}

public struct Message: Equatable, Sendable {
    public static let header: [UInt8] = [0xFE, 0xDC, 0xBA]
    public static let trailer: UInt8 = 0xEF

    public var type: MessageType
    public var opcode: UInt8
    public var sequence: UInt8
    public var payload: [UInt8]

    public init(type: MessageType, opcode: UInt8, sequence: UInt8, payload: [UInt8] = []) {
        self.type = type
        self.opcode = opcode
        self.sequence = sequence
        self.payload = payload
    }

    /// Encodes the frame. Responses carry an explicit zero status byte.
    public func encode() -> [UInt8] {
        let length = payload.count + (type.isRequest ? 1 : 2)
        var bytes = Message.header
        bytes.reserveCapacity(payload.count + 9)
        bytes.append(type.rawValue)
        bytes.append(opcode)
        bytes.append(UInt8((length >> 8) & 0xFF))
        bytes.append(UInt8(length & 0xFF))
        if !type.isRequest { bytes.append(0x00) }
        bytes.append(sequence)
        bytes.append(contentsOf: payload)
        bytes.append(Message.trailer)
        return bytes
    }
}

/// Incremental frame decoder: tolerates split reads, concatenated frames and stray bytes.
public struct FrameDecoder: Sendable {
    static let maxBodyLength = 4096
    private static let fixedPrefix = 7

    private var buffer: [UInt8] = []
    public private(set) var discardedByteCount = 0

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [Message] {
        buffer.append(contentsOf: bytes)
        var messages: [Message] = []

        while true {
            guard let start = buffer.firstIndex(where: { $0 == 0xFE }) else {
                let keep = min(buffer.count, 2)
                discard(buffer.count - keep)
                break
            }
            if start > 0 { discard(start) }
            guard buffer.count >= Self.fixedPrefix else { break }

            // Header sanity: FE DC BA
            guard buffer[1] == 0xDC, buffer[2] == 0xBA else { discard(1); continue }

            guard let type = MessageType(code: buffer[3]) else { discard(1); continue }
            let length = Int(buffer[5]) << 8 | Int(buffer[6])
            let minimum = type.isRequest ? 1 : 2
            guard length >= minimum, length <= Self.maxBodyLength else { discard(1); continue }

            let total = Self.fixedPrefix + length + 1
            guard buffer.count >= total else { break }
            guard buffer[total - 1] == Message.trailer else { discard(1); continue }

            let bodyStart = Self.fixedPrefix + (type.isRequest ? 0 : 1)
            let sequence = buffer[bodyStart]
            let payload = Array(buffer[(bodyStart + 1)..<(total - 1)])
            messages.append(Message(type: type, opcode: buffer[4], sequence: sequence, payload: payload))
            buffer.removeFirst(total)
        }
        return messages
    }

    private mutating func discard(_ count: Int) {
        guard count > 0 else { return }
        buffer.removeFirst(min(count, buffer.count))
        discardedByteCount += count
    }
}

// MARK: - TLV

/// `len | index | data...` entries, where `len` counts the index byte plus the data.
public struct TLV: Sendable {
    public let index: UInt8
    public let data: [UInt8]

    public static func parse(_ payload: [UInt8]) -> [TLV] {
        var entries: [TLV] = []
        var i = 0
        while i + 1 < payload.count {
            let length = Int(payload[i])
            guard length >= 1, i + 1 + length <= payload.count else { break }
            entries.append(TLV(index: payload[i + 1], data: Array(payload[(i + 2)..<(i + 1 + length)])))
            i += length + 1
        }
        return entries
    }
}

// MARK: - SAFER+
//
// Bluetooth-flavoured SAFER+ variant (128-bit key, 8 rounds) as used by Xiaomi
// earbuds for the 0x50 challenge/response handshake. The challenge itself is the
// key; the encrypted plaintext is a fixed constant block. No shared secret exists,
// so this is fully reimplementable.
public enum SAFER {
    static let blockSize = 16
    static let pattern = 0x9999

    static let sequence: [UInt8] = [
        0x11, 0x22, 0x33, 0x33, 0x22, 0x11, 0x11, 0x22, 0x33, 0x33, 0x22, 0x11, 0x11, 0x22, 0x33, 0x33,
    ]

    static let coefficients: [[Int]] = [
        [2, 1, 1, 1, 4, 2, 1, 1, 2, 2, 4, 2, 4, 4, 16, 8],
        [2, 1, 1, 1, 4, 2, 1, 1, 1, 1, 2, 1, 2, 2, 8, 4],
        [1, 1, 4, 2, 2, 2, 4, 2, 16, 8, 4, 4, 2, 1, 1, 1],
        [1, 1, 4, 2, 1, 1, 2, 1, 8, 4, 2, 2, 2, 1, 1, 1],
        [16, 8, 2, 2, 4, 2, 4, 4, 1, 1, 4, 2, 1, 1, 2, 1],
        [8, 4, 1, 1, 2, 1, 2, 2, 1, 1, 4, 2, 1, 1, 2, 1],
        [2, 2, 4, 2, 4, 4, 16, 8, 2, 1, 1, 1, 4, 2, 1, 1],
        [1, 1, 2, 1, 2, 2, 8, 4, 2, 1, 1, 1, 4, 2, 1, 1],
        [4, 2, 4, 4, 16, 8, 2, 2, 1, 1, 2, 1, 1, 1, 4, 2],
        [2, 1, 2, 2, 8, 4, 1, 1, 1, 1, 2, 1, 1, 1, 4, 2],
        [4, 4, 16, 8, 1, 1, 2, 1, 4, 2, 1, 1, 4, 2, 2, 2],
        [2, 2, 8, 4, 1, 1, 2, 1, 4, 2, 1, 1, 2, 1, 1, 1],
        [1, 1, 2, 1, 1, 1, 4, 2, 4, 4, 16, 8, 2, 2, 4, 2],
        [1, 1, 2, 1, 1, 1, 4, 2, 2, 2, 8, 4, 1, 1, 2, 1],
        [4, 2, 1, 1, 2, 1, 1, 1, 4, 2, 2, 2, 16, 8, 4, 4],
        [4, 2, 1, 1, 2, 1, 1, 1, 2, 1, 1, 1, 8, 4, 2, 2],
    ]

    struct Tables: Sendable {
        let biasMatrix: [[UInt8]]
        let exp: [UInt8]
        let log: [UInt8]
    }

    static let tables = makeTables()

    static func modPow(_ base: Int, _ exponent: Int, _ modulus: Int) -> Int {
        var result = 1, b = base % modulus, e = exponent
        while e > 0 {
            if e & 1 == 1 { result = result * b % modulus }
            b = b * b % modulus
            e >>= 1
        }
        return result
    }

    static func makeTables() -> Tables {
        var bias: [[UInt8]] = []
        for i in 0..<16 {
            var row: [UInt8] = []
            for j in 0..<16 {
                let exponent = 17 * (i + 2) + (j + 1)
                let inner = modPow(45, exponent, 257)
                let value = modPow(45, inner, 257)
                row.append(value == 256 ? 0 : UInt8(value))
            }
            bias.append(row)
        }
        var exp = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 {
            exp[i] = i == 128 ? 0 : UInt8(truncatingIfNeeded: modPow(45, i, 257))
        }
        var log = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 {
            if i == 0 {
                log[0] = 128
            } else {
                let value = modPow(45, i, 257)
                if value != 256 { log[value] = UInt8(i) }
            }
        }
        return Tables(biasMatrix: bias, exp: exp, log: log)
    }

    static func usesXorMode(_ index: Int) -> Bool { (1 << index) & pattern != 0 }

    static func keySchedule(_ challenge: [UInt8]) -> [[UInt8]] {
        var key = challenge
        key[15] ^= 6
        var keys: [[UInt8]] = [key]
        var register = key
        register.append(key.reduce(0, ^))
        for keyIndex in 1...16 {
            for i in 0..<17 {
                let value = register[i]
                register[i] = (value >> 5) | (value << 3)
            }
            var next = [UInt8](repeating: 0, count: 16)
            for i in 0..<16 {
                next[i] = register[(keyIndex + i) % 17] &+ tables.biasMatrix[keyIndex - 1][i]
            }
            keys.append(next)
        }
        return keys
    }

    static func encrypt(_ plaintext: [UInt8], keys: [[UInt8]]) -> [UInt8] {
        var c = plaintext
        for round in 0..<8 {
            if round == 2 {
                for i in 0..<blockSize {
                    c[i] = usesXorMode(i) ? c[i] ^ plaintext[i] : c[i] &+ plaintext[i]
                }
            }
            for i in 0..<blockSize {
                let k = keys[round * 2][i]
                c[i] = usesXorMode(i) ? c[i] ^ k : c[i] &+ k
            }
            for i in 0..<blockSize {
                c[i] = usesXorMode(i) ? tables.exp[Int(c[i])] : tables.log[Int(c[i])]
            }
            for i in 0..<blockSize {
                let k = keys[round * 2 + 1][i]
                c[i] = usesXorMode(i) ? k &+ c[i] : k ^ c[i]
            }
            let copy = c
            for i in 0..<blockSize {
                var sum: UInt8 = 0
                for j in 0..<blockSize {
                    sum = sum &+ UInt8(truncatingIfNeeded: coefficients[i][j] &* Int(Int8(bitPattern: copy[j])))
                }
                c[i] = sum
            }
        }
        for i in 0..<blockSize {
            let k = keys[16][i]
            c[i] = usesXorMode(i) ? k ^ c[i] : c[i] &+ k
        }
        return c
    }

    /// Computes the 16-byte answer for a 16-byte challenge.
    public static func response(to challenge: [UInt8]) -> [UInt8]? {
        guard challenge.count == blockSize else { return nil }
        return encrypt(sequence, keys: keySchedule(challenge))
    }

    public static func randomChallenge() -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<blockSize).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}
