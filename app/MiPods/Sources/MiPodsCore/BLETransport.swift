import Foundation
import CoreBluetooth

/// Transport over BLE GATT.
///
/// Verified on hardware (M2529E1 "vela os earbuds"): Xiaomi's miwear frame protocol
/// runs on service `AF00`, writing to `AF07` and receiving notifications on `AF08`.
/// This path needs no RFCOMM channel, no system pairing and never touches the audio
/// link, so A2DP playback is unaffected.
///
/// Note: the public Xiaomi MMA spec names the characteristics `AF05`/`AF06` while this
/// model exposes `AF07`/`AF08`, so characteristics are discovered **by role** rather
/// than hardcoded by UUID.
public final class BLETransport: NSObject {
    public enum Event: Sendable {
        case stateChanged(TransportState)
        case ready(write: String, notify: String)
        case name(String)
        case message(Message)
        case gattBattery([UInt8])
        case log(String)
    }

    public enum TransportState: Sendable, Equatable {
        case idle
        case scanning
        case connecting
        case connected
        case disconnected(String?)
    }

    /// Xiaomi's Bluetooth SIG company identifier, present in the advertisement.
    public static let xiaomiCompanyID: UInt16 = 0x038F

    public var onEvent: ((Event) -> Void)?

    /// When set, only a peripheral whose advertisement contains this MAC in LE byte
    /// order (e.g. "1300D6D417E2" for 00:13:D6:E2:17:D4) is accepted.
    public var targetMAC: String?

    /// Called on the transport queue; hop to the main actor before touching UI state.
    private let queue = DispatchQueue(label: "com.mipods.ble", qos: .utility)
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var decoder = FrameDecoder()
    private var sequence: UInt8 = 0
    private var isReady = false
    private var wantsScan = false

    public private(set) var state: TransportState = .idle

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    // MARK: - Public API

    public func start() {
        queue.async {
            self.wantsScan = true
            self.scanIfPossible()
        }
    }

    public func stop() {
        queue.async {
            self.wantsScan = false
            self.central.stopScan()
            if let peripheral = self.peripheral {
                self.central.cancelPeripheralConnection(peripheral)
            }
            self.peripheral = nil
            self.writeChar = nil
            self.notifyChar = nil
            self.isReady = false
            self.setState(.idle)
        }
    }

    /// Sends a request frame, allocating the next sequence number.
    public func send(_ opcode: Opcode, payload: [UInt8]) {
        queue.async {
            let frame = Message(type: .phoneRequest, opcode: opcode.rawValue,
                                sequence: self.sequence, payload: payload).encode()
            self.sequence &+= 1
            self.write(frame)
        }
    }

    /// Replies to a device-initiated request, echoing its sequence number.
    public func reply(_ opcode: UInt8, sequence seq: UInt8, payload: [UInt8] = []) {
        queue.async {
            let frame = Message(type: .response, opcode: opcode, sequence: seq, payload: payload).encode()
            self.write(frame)
        }
    }

    /// Resets the local sequence counter; called on every fresh connection.
    public func resetSequence() {
        queue.async { self.sequence = 0 }
    }

    // MARK: - Internals

    private func setState(_ newState: TransportState) {
        // Always dispatched on `queue`.
        guard state != newState else { return }
        state = newState
        onEvent?(.stateChanged(newState))
    }

    private func scanIfPossible() {
        guard wantsScan, central.state == .poweredOn else { return }
        // The earbuds advertise no service UUID, so a service filter would never match;
        // scan unfiltered and match on the Xiaomi company ID in manufacturer data.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        if state != .connected { setState(.scanning) }
    }

    private func write(_ frame: [UInt8]) {
        guard let peripheral, let writeChar else {
            onEvent?(.log("写入被丢弃：通道未就绪"))
            return
        }
        let type: CBCharacteristicWriteType =
            writeChar.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(Data(frame), for: writeChar, type: type)
        onEvent?(.log("TX \(frame.hexString)"))
    }
}

// MARK: - CBCentralManagerDelegate

extension BLETransport: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            scanIfPossible()
        case .unauthorized:
            setState(.disconnected("蓝牙权限被拒绝"))
        case .poweredOff:
            setState(.disconnected("蓝牙已关闭"))
        case .unsupported:
            setState(.disconnected("此设备不支持蓝牙低功耗"))
        default:
            setState(.disconnected(nil))
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        var isXiaomi = false

        if let mfr = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           mfr.count >= 2 {
            let company = UInt16(mfr[0]) | (UInt16(mfr[1]) << 8)
            isXiaomi = company == Self.xiaomiCompanyID
        }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        if !isXiaomi, let name,
           name.localizedCaseInsensitiveContains("xiaomi") || name.localizedCaseInsensitiveContains("redmi") {
            isXiaomi = true
        }
        guard isXiaomi else { return }

        if let targetMAC, !targetMAC.isEmpty {
            let mfrHex = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?
                .hexString ?? ""
            guard mfrHex.contains(targetMAC) else { return }
        }

        if let name, !name.isEmpty { onEvent?(.name(name)) }

        guard self.peripheral == nil else { return }
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        setState(.connecting)
        onEvent?(.log("发现 \(name ?? "小米设备")，正在连接"))
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager,
                               didConnect peripheral: CBPeripheral) {
        decoder = FrameDecoder()
        sequence = 0
        peripheral.discoverServices([CBUUID(string: "AF00"),
                                     CBUUID(string: "180F"),
                                     CBUUID(string: "180A")])
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral, error: Error?) {
        self.peripheral = nil
        setState(.disconnected(error?.localizedDescription ?? "连接失败"))
        scanIfPossible()
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        writeChar = nil
        notifyChar = nil
        isReady = false
        self.peripheral = nil
        setState(.disconnected(error?.localizedDescription))
        scanIfPossible()
    }

    /// Re-establishes the link using a peripheral the system already knows about.
    /// The earbuds do not always advertise after pairing, so falling back to
    /// `retrieveConnectedPeripherals` avoids a dead end.
    public func connectKnownPeripheral() {
        queue.async {
            guard self.central.state == .poweredOn, self.peripheral == nil else { return }
            let candidates = self.central.retrieveConnectedPeripherals(
                withServices: [CBUUID(string: "AF00")]
            )
            guard let candidate = candidates.first else { return }
            self.peripheral = candidate
            candidate.delegate = self
            self.setState(.connecting)
            self.onEvent?(.log("使用系统已连接外设重连"))
            self.central.connect(candidate, options: nil)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLETransport: CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services, !services.isEmpty else {
            onEvent?(.log("未发现服务：\(error?.localizedDescription ?? "空")"))
            return
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        let isAudioControl = service.uuid == CBUUID(string: "AF00")
        for characteristic in service.characteristics ?? [] {
            let props = characteristic.properties
            if isAudioControl {
                if props.contains(.write) || props.contains(.writeWithoutResponse) {
                    if writeChar == nil { writeChar = characteristic }
                    if props.contains(.notify) || props.contains(.indicate) {
                        notifyChar = characteristic
                        peripheral.setNotifyValue(true, for: characteristic)
                        if writeChar?.uuid == characteristic.uuid { writeChar = characteristic }
                    }
                } else if props.contains(.notify) || props.contains(.indicate) {
                    if notifyChar == nil {
                        notifyChar = characteristic
                        peripheral.setNotifyValue(true, for: characteristic)
                    }
                }
            }
            if characteristic.uuid == CBUUID(string: "2A19") {
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }

        if writeChar != nil, notifyChar != nil, !isReady {
            isReady = true
            setState(.connected)
            onEvent?(.ready(write: writeChar?.uuid.uuidString ?? "?",
                            notify: notifyChar?.uuid.uuidString ?? "?"))
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)

        if characteristic.uuid == CBUUID(string: "2A19") {
            onEvent?(.gattBattery(bytes))
            return
        }
        for message in decoder.feed(bytes) {
            onEvent?(.message(message))
        }
    }
}

// MARK: - Helpers

extension Array where Element == UInt8 {
    /// Uppercase hex, no separators. Used for logs and diagnostics.
    public var hexString: String {
        map { String(format: "%02X", $0) }.joined()
    }
}

extension Data {
    /// Uppercase hex, no separators.
    public var hexString: String {
        map { String(format: "%02X", $0) }.joined()
    }
}
