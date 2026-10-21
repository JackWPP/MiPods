import Foundation

// MARK: - Battery

/// One battery reading from the earbuds.
///
/// Wire format (verified on hardware, M2529E1 "vela os earbuds"): one byte per part,
/// bit 7 = charging, bits 0...6 = percentage, `0xFF` = unknown / not present.
public struct BatteryLevel: Sendable, Equatable {
    /// 0...100, or `nil` when the device reports "unknown".
    public var percent: Int?
    public var isCharging: Bool
    public var isPresent: Bool

    public static let unknown = BatteryLevel(percent: nil, isCharging: false, isPresent: false)

    public init(raw: UInt8) {
        if raw == 0xFF {
            self.percent = nil
            self.isCharging = false
            self.isPresent = false
            return
        }
        self.percent = Int(raw & 0x7F)
        self.isCharging = (raw & 0x80) != 0
        self.isPresent = true
    }

    public init(percent: Int?, isCharging: Bool, isPresent: Bool = true) {
        self.percent = percent
        self.isCharging = isCharging
        self.isPresent = isPresent
    }

    public var displayPercent: String { percent.map { "\($0)%" } ?? "--" }
}

// MARK: - Noise control

/// ANC / transparency state as reported by the earbuds.
///
/// Raw values follow the official Xiaomi MMA spec (`ATTR_DEVICE_ANC_MODE`):
/// 0 = off, 1 = noise cancelling, 2 = transparency, 3 = wind noise reduction.
public enum NoiseMode: Int, Sendable, CaseIterable, Equatable {
    case off = 0x00
    case anc = 0x01
    case transparency = 0x02
    case windNoise = 0x03

    public init?(rawByte: UInt8) {
        self.init(rawValue: Int(rawByte))
    }

    public var rawByte: UInt8 { UInt8(rawValue) }
}

/// Which controls a given model actually supports.
///
/// Populated by capability probing, because the open-ear M2529E1 answers the exact
/// same protocol as Redmi Buds yet has no ANC hardware at all — drawing three mode
/// buttons would produce dead controls.
public struct Capabilities: OptionSet, Sendable, Equatable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let hasANC = Capabilities(rawValue: 1 << 0)
    public static let hasTransparency = Capabilities(rawValue: 1 << 1)
    public static let hasWearingDetection = Capabilities(rawValue: 1 << 2)
    public static let hasRecording = Capabilities(rawValue: 1 << 3)
    public static let hasFindMyEarbuds = Capabilities(rawValue: 1 << 4)
    public static let hasEqualizer = Capabilities(rawValue: 1 << 5)
    public static let hasWindNoise = Capabilities(rawValue: 1 << 6)

    /// Battery reporting is always available when connected.
    public static let none: Capabilities = []
}

// MARK: - Device info

/// Decoded `GET_DEVICE_INFO` (opcode 0x02) response.
public struct DeviceInfo: Sendable, Equatable {
    public var modelName: String?
    public var firmware: String?
    public var vendorID: String?
    public var productID: String?
    public var voiceCodec: UInt8?
    public var deviceType: UInt8?
    public var left = BatteryLevel.unknown
    public var right = BatteryLevel.unknown
    public var caseBattery = BatteryLevel.unknown

    public init() {}

    /// Firmware is reported as two bytes nibble-encoded, e.g. 0x15 0x12 -> "1.5.1.2".
    static func version(_ a: UInt8, _ b: UInt8) -> String {
        "\(a >> 4).\(a & 0xF).\(b >> 4).\(b & 0xF)"
    }

    public static func parse(_ payload: [UInt8]) -> DeviceInfo {
        var info = DeviceInfo()
        for entry in TLV.parse(payload) {
            switch entry.index {
            case 0x00:
                let name = String(decoding: entry.data, as: UTF8.self)
                    .trimmingCharacters(in: .controlCharacters)
                    .trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { info.modelName = name }
            case 0x01 where entry.data.count >= 2:
                info.firmware = version(entry.data[0], entry.data[1])
            case 0x03 where entry.data.count >= 4:
                info.vendorID = String(format: "%02X%02X", entry.data[0], entry.data[1])
                info.productID = String(format: "%02X%02X", entry.data[2], entry.data[3])
            case 0x07 where entry.data.count >= 3:
                info.left = BatteryLevel(raw: entry.data[0])
                info.right = BatteryLevel(raw: entry.data[1])
                info.caseBattery = BatteryLevel(raw: entry.data[2])
            case 0x08:
                info.voiceCodec = entry.data.first
            case 0x0D:
                info.deviceType = entry.data.first
            default:
                break
            }
        }
        return info
    }
}

// MARK: - Run info

/// Decoded `GET_DEVICE_RUN_INFO` (opcode 0x09) response.
public struct RunInfo: Sendable, Equatable {
    public var noiseMode: NoiseMode?
    public var autoPlayEnabled: Bool?
    public var gameModeEnabled: Bool?
    /// MTU reported by the device; the earbuds answer 0x0400.
    public var mtu: Int?

    public init() {}

    public static func parse(_ payload: [UInt8]) -> RunInfo {
        var info = RunInfo()
        for entry in TLV.parse(payload) {
            switch entry.index {
            case 0x02 where entry.data.count >= 2:
                info.mtu = Int(entry.data[0]) << 8 | Int(entry.data[1])
            case 0x09:
                if let value = entry.data.first { info.noiseMode = NoiseMode(rawByte: value) }
            case 0x0A:
                // Inverted on the wire: 0x00 means the feature is on.
                if let value = entry.data.first { info.autoPlayEnabled = value == 0x00 }
            case 0x0B:
                if let value = entry.data.first { info.gameModeEnabled = value == 0x00 }
            default:
                break
            }
        }
        return info
    }
}

// MARK: - Notifications

public enum StatusUpdate: Sendable, Equatable {
    case battery(left: BatteryLevel, right: BatteryLevel, caseBattery: BatteryLevel)
    case localRecording(Bool)
    case noiseMode(NoiseMode)
    case unknown(index: UInt8, data: [UInt8])

    /// `REPORT_STATUS` (opcode 0x0E) entries.
    ///
    /// The official spec assigns battery to attribute 0x00, but this firmware reports
    /// it at 0x04 — so both are accepted and anything with three bytes is treated as
    /// `[left, right, case]` battery.
    public static func parse(_ payload: [UInt8]) -> [StatusUpdate] {
        TLV.parse(payload).map { entry in
            switch entry.index {
            case 0x00, 0x04:
                // `where` on a multi-pattern case only scopes to the LAST pattern, so the
                // length check must live inside the branch — otherwise a short 0x00 entry
                // crashes on `entry.data[1]`.
                guard entry.data.count >= 3 else {
                    return .unknown(index: entry.index, data: entry.data)
                }
                return .battery(left: BatteryLevel(raw: entry.data[0]),
                                right: BatteryLevel(raw: entry.data[1]),
                                caseBattery: BatteryLevel(raw: entry.data[2]))
            case 0x02:
                return .localRecording((entry.data.first ?? 0) != 0)
            case 0x03:
                if let mode = entry.data.first.flatMap(NoiseMode.init(rawByte:)) {
                    return .noiseMode(mode)
                }
                return .unknown(index: entry.index, data: entry.data)
            default:
                return .unknown(index: entry.index, data: entry.data)
            }
        }
    }
}

public enum ConfigUpdate: Sendable, Equatable {
    /// Config code 0x0C: in-ear / in-case bitmask.
    case wearing(flags: UInt8)
    /// Config code 0x0B: active noise mode plus its strength.
    case noiseModeChanged(mode: NoiseMode?, strength: UInt8)
    case unknown(code: UInt8, data: [UInt8])

    public static func parse(_ payload: [UInt8]) -> [ConfigUpdate] {
        TLV.parse(payload).map { entry in
            guard let code = entry.data.first else {
                return .unknown(code: 0, data: entry.data)
            }
            let data = Array(entry.data.dropFirst())
            switch code {
            case 0x0C:
                return .wearing(flags: data.first ?? 0)
            case 0x0B where data.count >= 2:
                return .noiseModeChanged(mode: NoiseMode(rawByte: data[0]), strength: data[1])
            default:
                return .unknown(code: code, data: data)
            }
        }
    }
}
