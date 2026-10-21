import Foundation
import CoreBluetooth
import IOBluetooth

// Probe: how can a third-party app learn the earbuds are connected?
final class P: NSObject, CBCentralManagerDelegate {
    var mgr: CBCentralManager!
    func start() { mgr = CBCentralManager(delegate: self, queue: nil) }
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else { return }
        print("--- retrieveConnectedPeripherals(withServices: []) ---")
        let all = c.retrieveConnectedPeripherals(withServices: [])
        print("count=\(all.count)")
        for p in all { print("  connected: \(p.name ?? "-") id=\(p.identifier.uuidString)") }
        print("--- retrieveConnectedPeripherals(withServices:[180F,180A]) ---")
        let svc = c.retrieveConnectedPeripherals(withServices: [CBUUID(string:"180F"), CBUUID(string:"180A")])
        for p in svc { print("  bysvc: \(p.name ?? "-") id=\(p.identifier.uuidString)") }
        print("--- retrievePeripherals(withIdentifiers:) target ---")
        let t = UUID(uuidString:"0FE718F1-7C78-DDC2-EB17-67F3CF732AF6")!
        for p in c.retrievePeripherals(withIdentifiers:[t]) { print("  known: \(p.name ?? "-")") }
        print("--- IOBluetooth paired devices ---")
        if let arr = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            print("paired count=\(arr.count)")
            for d in arr {
                print("  paired: name=\(d.name ?? "-") addr=\(d.addressString ?? "-") connected=\(d.isConnected())")
            }
        } else { print("paired: nil (needs permission or none)") }
        exit(0)
    }
}
let p = P(); p.start()
RunLoop.main.run(until: Date().addingTimeInterval(8))
print("TIMEOUT")
