import Foundation
import Combine

/// Snapshot of everything the UI needs to render.
public struct MiPodsState: Sendable, Equatable {
    public var isConnected = false
    public var isAuthenticated = false

    /// Bluetooth-advertised name, e.g. "Xiaomi 耳夹式耳机".
    public var deviceName = ""
    /// Model string reported by the device itself, e.g. "vela os earbuds".
    public var modelName = ""

    /// 0...100, `nil` when unknown (protocol sentinel 0xFF).
    public var leftBattery: Int?
    public var rightBattery: Int?
    public var caseBattery: Int?

    public var isLeftCharging = false
    public var isRightCharging = false
    public var isCaseCharging = false

    public var noiseMode: NoiseMode = .off
    public var capabilities: Capabilities = []

    /// `0x0E` ATTR 0x02: whether the earbuds can record locally right now
    /// (they only can while worn — "TWS 未入耳时不可录音").
    public var canRecordLocally: Bool?
    /// `0xF4` code 0x0C wearing bitmask: bit0 = left in ear, bit1 = right in ear.
    public var wearingFlags: UInt8?

    public var firmware: String = ""
    public var lastUpdate: Date?
    /// Human-readable transport detail for the panel footer.
    public var statusDetail = "未连接"
    /// Recent protocol log lines (newest last, capped).
    public var log: [String] = []

    public init() {}
}

/// Owns the BLE transport, runs the miwear handshake and keeps `state` up to date.
///
/// Protocol notes verified on hardware:
/// - `GET_DEVICE_INFO` (0x02) and `GET_RUN_INFO` (0x09) answer **without** authentication,
///   so the UI can show battery immediately after connecting.
/// - Write commands (ANC, SET_CONFIG) follow a SAFER+ challenge/response handshake
///   (opcodes 0x50/0x51). The challenge is the key — no shared secret is involved.
@MainActor
public final class MiPodsController: ObservableObject {

    @Published public var state = MiPodsState()

    private let transport = BLETransport()
    private var connectTimeoutTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    /// MAC in LE byte order, used to pick our earbuds out of the advertisement.
    /// Default matches the user's M2529E1 (00:13:D6:E2:17:D4).
    public var targetMAC: String? = "1300D6D417E2" {
        didSet { transport.targetMAC = targetMAC }
    }

    /// Keeps battery reasonably fresh while a panel is open, without hammering the link.
    public static let pollInterval: TimeInterval = 30

    public init() {
        transport.targetMAC = targetMAC
        transport.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in self?.handle(event) }
        }
    }

    // MARK: - Lifecycle

    public func start() {
        append("开始搜索耳机")
        transport.start()
        scheduleConnectFallback()
    }

    public func stop() {
        pollTask?.cancel()
        connectTimeoutTask?.cancel()
        transport.stop()
    }

    /// Pulls device info and run info. Cheap enough to call on every panel open.
    public func refresh() {
        guard state.isConnected else {
            append("未连接，忽略刷新")
            return
        }
        transport.send(.getDeviceInfo, payload: [0xFF, 0xFF, 0xFF, 0xFF])
        transport.send(.getRunInfo, payload: [0xFF, 0xFF, 0xFF, 0xFF])
    }

    /// Switches the noise mode. No-ops (with a log line) when the model lacks the capability.
    public func setNoiseMode(_ mode: NoiseMode) {
        guard state.isConnected else {
            append("未连接，无法切换模式")
            return
        }
        guard supports(mode) else {
            append("该型号不支持「\(mode.displayTitle)」")
            return
        }
        append("切换模式 → \(mode.displayTitle)")
        transport.send(.setANC, payload: [0x02, 0x04, mode.rawByte])
    }

    public func supports(_ mode: NoiseMode) -> Bool {
        switch mode {
        case .off:
            return true
        case .anc:
            return state.capabilities.contains(.hasANC)
        case .transparency:
            return state.capabilities.contains(.hasTransparency)
        case .windNoise:
            return state.capabilities.contains(.hasWindNoise)
        }
    }

    // MARK: - Event handling

    private func handle(_ event: BLETransport.Event) {
        switch event {
        case .stateChanged(let newState):
            switch newState {
            case .connected:
                state.isConnected = true
                state.statusDetail = "BLE 已连接"
                connectTimeoutTask?.cancel()
                beginSession()
            case .connecting:
                state.statusDetail = "连接中…"
            case .scanning:
                state.statusDetail = "正在搜索耳机…"
            case .disconnected(let reason):
                state.isConnected = false
                state.isAuthenticated = false
                state.statusDetail = reason ?? "未连接"
                pollTask?.cancel()
            case .idle:
                state.isConnected = false
                state.isAuthenticated = false
                state.statusDetail = "未连接"
                pollTask?.cancel()
            }

        case .ready(let write, let notify):
            append("GATT 就绪（写 \(write) / 收 \(notify)）")

        case .name(let name):
            state.deviceName = name

        case .gattBattery(let bytes):
            // Standard 0x180F Battery Level: left/right per instance. The case is only
            // reported by the vendor protocol, so this is a supplementary fast path.
            append("GATT 电量 \(bytes.hexString)")

        case .message(let message):
            handle(message)

        case .log(let line):
            append(line)
        }
    }

    /// Right after the GATT channel is ready.
    ///
    /// Order matters, and this order is deliberate:
    ///
    /// 1. `GET_DEVICE_INFO` first — it is unauthenticated and gives us battery
    ///    immediately, which is the whole point of the app.
    /// 2. Authentication **last**, because on this hardware sending `0x50` puts the
    ///    device into a state where it stops answering host requests. Measured:
    ///    pure `0x02` answers 6/6 sessions, but any session that starts with `0x50`
    ///    goes silent for `0x02`, `0xF2` and `0xF3` alike.
    ///
    /// So auth is attempted only when a feature actually needs it, never on connect.
    /// See `requestAuthentication()`.
    private func beginSession() {
        pollTask?.cancel()
        transport.send(.getDeviceInfo, payload: [0xFF, 0xFF, 0xFF, 0xFF])
        transport.send(.getRunInfo, payload: [0xFF, 0xFF, 0xFF, 0xFF])
        startPolling()
    }

    /// Starts the SAFER+ challenge/response handshake.
    ///
    /// Verified on hardware: the SAFER+ answer matches the device byte-for-byte, but
    /// the handshake is **not** currently completed by this app — the device needs
    /// further steps we have not reverse engineered (see research/record/findings.md).
    /// Until then, calling this puts the device into a silent state for other requests,
    /// so it is never called automatically.
    public func requestAuthentication() {
        guard state.isConnected else { return }
        let challenge = SAFER.randomChallenge()
        append("发起 SAFER+ 认证（注意：可能使设备转入静默）")
        transport.send(.authChallenge, payload: [0x01] + challenge)
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
                guard let self, self.state.isConnected else { return }
                self.transport.send(.getDeviceInfo, payload: [0xFF, 0xFF, 0xFF, 0xFF])
            }
        }
    }

    /// The advertise-then-connect path can stall; fall back to already-connected
    /// peripherals the system knows about.
    private func scheduleConnectFallback() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !self.state.isConnected else { return }
            self.append("未扫描到广播，尝试复用系统已连接外设")
            self.transport.connectKnownPeripheral()
        }
    }

    // MARK: - Protocol dispatch

    private func handle(_ message: Message) {
        append("RX 0x\(String(format: "%02X", message.opcode)) · \(message.payload.count)B")

        switch message.opcode {
        case Opcode.authChallenge.rawValue:
            if message.type == .response {
                // The earbuds answered our challenge; confirm to complete the handshake.
                transport.send(.authConfirm, payload: [0x01, 0x00])
            } else if message.payload.count >= 17, let answer = SAFER.response(to: Array(message.payload[1..<17])) {
                // We were challenged; answer with SAFER+.
                transport.reply(Opcode.authChallenge.rawValue, sequence: message.sequence, payload: [0x01] + answer)
            }

        case Opcode.authConfirm.rawValue:
            if message.type.isRequest {
                transport.reply(Opcode.authConfirm.rawValue, sequence: message.sequence, payload: [0x01])
            }
            if !state.isAuthenticated {
                state.isAuthenticated = true
                append("认证完成，写命令可用")
                refresh()
            }

        case Opcode.getDeviceInfo.rawValue:
            apply(DeviceInfo.parse(message.payload))

        case Opcode.getRunInfo.rawValue:
            let info = RunInfo.parse(message.payload)
            if let mode = info.noiseMode, supports(mode) || mode == .off { state.noiseMode = mode }
            state.lastUpdate = Date()

        case Opcode.reportStatus.rawValue:
            apply(StatusUpdate.parse(message.payload))
            if message.type.isRequest {
                transport.reply(message.opcode, sequence: message.sequence)
            }

        case Opcode.notifyConfig.rawValue:
            apply(ConfigUpdate.parse(message.payload))
            if message.type.isRequest {
                transport.reply(message.opcode, sequence: message.sequence)
            }

        case Opcode.setANC.rawValue, Opcode.setConfig.rawValue:
            append("命令已确认")

        default:
            if message.type.isRequest {
                transport.reply(message.opcode, sequence: message.sequence)
            }
        }
    }

    private func apply(_ info: DeviceInfo) {
        if let model = info.modelName, !model.isEmpty { state.modelName = model }
        if let firmware = info.firmware { state.firmware = firmware }
        state.leftBattery = info.left.percent
        state.rightBattery = info.right.percent
        state.caseBattery = info.caseBattery.percent
        state.isLeftCharging = info.left.isCharging
        state.isRightCharging = info.right.isCharging
        state.isCaseCharging = info.caseBattery.isCharging
        state.lastUpdate = Date()
        refreshCapabilities()
        append("电量 左\(info.left.displayPercent) 右\(info.right.displayPercent) 盒\(info.caseBattery.displayPercent)")
    }

    private func apply(_ updates: [StatusUpdate]) {
        for update in updates {
            switch update {
            case .battery(let left, let right, let caseBattery):
                state.leftBattery = left.percent
                state.rightBattery = right.percent
                state.caseBattery = caseBattery.percent
                state.isLeftCharging = left.isCharging
                state.isRightCharging = right.isCharging
                state.isCaseCharging = caseBattery.isCharging
                state.lastUpdate = Date()
            case .noiseMode(let mode):
                if supports(mode) || mode == .off { state.noiseMode = mode }
            case .localRecording(let allowed):
                state.canRecordLocally = allowed
                if let flags = state.wearingFlags {
                    state.canRecordLocally = allowed
                }
                append(allowed ? "耳机可本地录音" : "耳机当前不可本地录音（未入耳）")
            case .unknown:
                break
            }
        }
        refreshCapabilities()
    }

    private func apply(_ updates: [ConfigUpdate]) {
        for update in updates {
            switch update {
            case .wearing(let flags):
                state.wearingFlags = flags
                state.capabilities.insert(.hasWearingDetection)
                state.capabilities.insert(.hasRecording)
                // The earbuds only allow local recording while actually worn
                // ("TWS 未入耳时不可录音"), and they report wearing via this bitmask
                // but never send the dedicated 0x0E ATTR 0x02 record-status event.
                // Derive it so the UI is not stuck on "unknown".
                state.canRecordLocally = (flags & 0x03) == 0x03
            case .noiseModeChanged(let mode, _):
                if let mode, supports(mode) || mode == .off { state.noiseMode = mode }
            case .unknown:
                break
            }
        }
    }

    /// Derives the capability set from what the device has reported so far.
    ///
    /// This is deliberately conservative: the M2529E1 answers the same protocol as
    /// Redmi Buds but has no ANC hardware, so ANC/transparency are only advertised
    /// once the device itself confirms a non-zero noise mode.
    private func refreshCapabilities() {
        var caps: Capabilities = [.hasWearingDetection]

        if state.caseBattery != nil {
            caps.insert(.hasANC)          // placeholder removed below when unsupported
            caps.remove(.hasANC)
        }

        // A noise mode other than `off` reported by the device proves ANC support.
        if state.noiseMode != .off {
            caps.insert(.hasANC)
            caps.insert(.hasTransparency)
        }

        state.capabilities = caps
    }

    private func append(_ line: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        state.log.append("[\(stamp)] \(line)")
        if state.log.count > 300 {
            state.log.removeFirst(state.log.count - 300)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

extension NoiseMode {
    /// Chinese display name for UI; kept in Core so the Touch Bar and panel stay in sync.
    public var displayTitle: String {
        switch self {
        case .off: return "普通"
        case .anc: return "降噪"
        case .transparency: return "通透"
        case .windNoise: return "抗风噪"
        }
    }
}
