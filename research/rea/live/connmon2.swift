import Foundation
import IOBluetooth

final class Mon: NSObject {
  var globalNote: IOBluetoothUserNotification?
  var discNote: IOBluetoothUserNotification?
  func start() {
    globalNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
    print("A) +[IOBluetoothDevice registerForConnectNotifications:selector:] -> \(globalNote == nil ? "nil/FAILED" : "OK")")

    _ = NotificationCenter.default.addObserver(
      forName: NSNotification.Name("IOBluetoothDeviceConnectNotification"), object: nil, queue: nil
    ) { n in print("C) NSNotification: \(n.name.rawValue)") }
    print("C) NSNotification observer installed")

    if let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
      print("B) pairedDevices() -> \(paired.count)")
      for d in paired where (d.name ?? "").contains("耳夹式") {
        print("B) TARGET name=\(d.name ?? "-") addr=\(d.addressString ?? "-") isConnected=\(d.isConnected()) isPaired=\(d.isPaired())")
        let n = d.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
        discNote = n
        print("B) -[IOBluetoothDevice registerForDisconnectNotification:selector:] -> \(n == nil ? "nil/FAILED" : "OK")")
      }
    }
  }
  @objc func connected(_ n: IOBluetoothUserNotification, device: IOBluetoothDevice) { print("EVENT CONNECT: \(device.name ?? "-")") }
  @objc func disconnected(_ n: IOBluetoothUserNotification, device: IOBluetoothDevice) { print("EVENT DISCONNECT: \(device.name ?? "-")") }
}
let m = Mon(); m.start()
RunLoop.main.run(until: Date().addingTimeInterval(4))
print("DONE")
