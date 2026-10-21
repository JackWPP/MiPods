import Foundation
import IOBluetooth

// Probe SDP records of the Xiaomi earbuds to find the miwear/RFCOMM control channel.
let target = "00-13-D6-E2-17-D4"

guard let dev = IOBluetoothDevice(addressString: target) else {
    print("device not found for \(target)")
    exit(1)
}

print("name: \(dev.name ?? "?")")
print("address: \(dev.addressString ?? "?")")
print("connected: \(dev.isConnected())")
print("paired: \(dev.isPaired())")

let st = dev.performSDPQuery(nil)
print("performSDPQuery status: \(st)")
Thread.sleep(forTimeInterval: 3.0)

let services = (dev.services as? [IOBluetoothSDPServiceRecord]) ?? []
print("SDP record count: \(services.count)")

for (i, rec) in services.enumerated() {
    let name = rec.getServiceName() ?? "<unnamed>"
    var channelID: BluetoothRFCOMMChannelID = 0
    let rc = rec.getRFCOMMChannelID(&channelID)
    print("---- [\(i)] name=\(name)  rfcomm=\(rc == kIOReturnSuccess ? String(channelID) : "n/a(\(rc))")")
    if let attrs = rec.attributes {
        for key in [0x0000, 0x0001, 0x0004, 0x0100] {
            if let el = attrs[NSNumber(value: key)] as? IOBluetoothSDPDataElement {
                print("     attr[0x\(String(format: "%04X", key))] = \(el)")
            }
        }
    }
}
