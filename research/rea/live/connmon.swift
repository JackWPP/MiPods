import Foundation
import IOBluetooth

// Verify the three connect-detection strategies empirically.
final class Mon: NSObject {
  var note: IOBluetoothUserNotification?
  func start() {
    note = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
    print("A) register(forConnectNotifications:) -> \(note == nil ? "nil (FAILED)" : "OK, notification object created")")

    let kv = NotificationCenter.default.addObserver(
      forName: NSNotification.Name("IOBluetoothDeviceConnectNotification"), object: nil, queue: nil
    ) { n in print("C) NSNotification fired: \(n.name)") }
    print("C) NSNotification observer installed: \(kv != 0)")

    if let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
      print("B) pairedDevices() -> \(paired.count) devices")
      for d in paired where (d.name ?? "").contains("耳夹式") {
        print("B) TARGET name=\(d.name ?? "-") addr=\(d.addressString ?? "-") isConnected=\(d.isConnected())")
        // single-object connect notification
        if let n = d.register(forConnectNotifications: self, selector: #selector(connected(_:device:))) {
          print("B) per-device connect notification registered OK")
        } else { print("B) per-device connect notification FAILED (device already connected -> expected)") }
        if let n = d.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:))) {
          print("B) per-device DISCONNECT notification registered OK: \(n)")
        } else { print("B) per-device disconnect notification FAILED") }
      }
    }
  }
  @objc func connected(_ n: IOBluetoothUserNotification, device: IOBluetoothDevice) { print("EVENT connect: \(device.name ?? "-")") }
  @objc func disconnected(_ n: IOBluetoothUserNotification, device: IOBluetoothDevice) { print("EVENT disconnect: \(device.name ?? "-")") }
}
let m = Mon(); m.start()
RunLoop.main.run(until: Date().addingTimeInterval(4))
print("DONE")
