/// Challenge/response authentication: a Bluetooth-flavoured SAFER+ variant (128-bit key, 8 rounds)
/// ported from Gadgetbridge's `Authentication.java`. The challenge acts as the key, and the
/// encrypted plaintext is a fixed constant block.
public enum Safer {
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

    struct Tables {
        let biasMatrix: [[UInt8]]
        let exp: [UInt8]
        let log: [UInt8]
    }

    static let tables = makeTables()

    static func modPow(_ base: Int, _ exponent: Int, _ modulus: Int) -> Int {
        var result = 1
        var b = base % modulus
        var e = exponent
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

    static func randomChallenge() -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<blockSize).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    /// Computes the 16-byte answer for a 16-byte challenge. Returns an empty array for malformed input.
    static func computeResponse(to challenge: [UInt8]) -> [UInt8] {
        guard challenge.count == blockSize else { return [] }
        return encrypt(sequence, keys: keySchedule(challenge))
    }
}
