import Foundation
import CoreBluetooth

final class S: NSObject, CBCentralManagerDelegate {
    var central: CBCentralManager!
    var hits = 0
    override init() { super.init(); central = CBCentralManager(delegate: self, queue: nil) }
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        print("[state] \(c.state.rawValue)")
        if c.state == .poweredOn {
            c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData d: [String: Any], rssi r: NSNumber) {
        let mfr = d[CBAdvertisementDataManufacturerDataKey] as? Data
        let mfrHex = mfr.map { $0.map { String(format: "%02X", $0) }.joined() } ?? "-"
        let name = (d[CBAdvertisementDataLocalNameKey] as? String) ?? (p.name ?? ".")
        let svc = (d[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? []
        let isXiaomi = mfrHex.hasPrefix("8F03") || name.localizedCaseInsensitiveContains("xiaomi") || name.localizedCaseInsensitiveContains("redmi") || name.localizedCaseInsensitiveContains("mi")
        if isXiaomi {
            hits += 1
            print("XIAOMI? name=\(name) id=\(p.identifier.uuidString) rssi=\(r) svc=\(svc) mfr=\(mfrHex) tx=\(d[CBAdvertisementDataTxPowerLevelKey] ?? "-")")
        } else if mfrHex.hasPrefix("4C00") == false && mfrHex != "-" {
            print("other name=\(name) mfr=\(mfrHex) rssi=\(r)")
        }
    }
}
let s = S()
RunLoop.main.run(until: Date().addingTimeInterval(Double(CommandLine.arguments.dropFirst().first ?? "12") ?? 12))
print("hits=\(s.hits)")
