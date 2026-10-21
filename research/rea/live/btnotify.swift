import Foundation
import IOBluetooth
// Can a 3rd-party app get *connect events* (not just poll)?
func addr(_ d: IOBluetoothDevice) -> String { d.addressString ?? "-" }
let centers = NotificationCenter.default
// Method A: IOBluetoothDevice connect notifications (documented, deprecated-ish but works)
let n1 = IOBluetoothDevice.register(forConnectNotifications: nil, selector: nil)
print("register(forConnectNotifications:) returned \(n1.map{String(describing:$0)} ?? "nil")")
// Method B: KVO on isConnected of a known device
if let dev = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first(where: { ($0.name ?? "").contains("耳夹式") }) {
    print("found device \(dev.name ?? "-") connected=\(dev.isConnected())")
    var ctx = 0
    let obs = dev.observe(\.isConnected, options: [.new, .old]) { d, ch in
        print("KVO isConnected changed -> \(d.isConnected())")
    }
    _ = obs
    // Method C: notification for name
    let token = centers.addObserver(forName: NSNotification.Name("IOBluetoothDeviceConnectNotification"), object: nil, queue: nil) { n in
        print("NC IOBluetoothDeviceConnectNotification: \(n)")
    }
    _ = token
} else { print("no target device in pairedDevices") }
RunLoop.main.run(until: Date().addingTimeInterval(6))
print("DONE")
