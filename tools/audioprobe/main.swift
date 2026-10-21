import Foundation
import AVFoundation
import CoreAudio

func fourCC(_ v: UInt32) -> String {
    let bytes = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    return String(bytes: bytes, encoding: .utf8) ?? "?"
}

var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                      mScope: kAudioObjectPropertyScopeGlobal,
                                      mElement: kAudioObjectPropertyElementMain)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
let count = Int(size) / MemoryLayout<AudioObjectID>.size
var devices = [AudioObjectID](repeating: 0, count: count)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices)

func strProp(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var s: CFString = "" as CFString
    var sz = UInt32(MemoryLayout<CFString>.size)
    let st = withUnsafeMutablePointer(to: &s) { p in AudioObjectGetPropertyData(id, &a, 0, nil, &sz, p) }
    return st == noErr ? (s as String) : "?"
}
func u32Prop(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v: UInt32 = 0; var sz = UInt32(4)
    AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v); return v
}
func inputChannels(_ id: AudioObjectID) -> Int {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &sz) == noErr, sz > 0 else { return 0 }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(sz), alignment: 16)
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, buf) == noErr else { return 0 }
    let abl = buf.assumingMemoryBound(to: AudioBufferList.self)
    var total = 0
    let items = UnsafeMutableAudioBufferListPointer(abl)
    for b in items { total += Int(b.mNumberChannels) }
    return total
}

var defIn = AudioObjectID(0)
var a2 = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var sz2 = UInt32(4)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a2, 0, nil, &sz2, &defIn)

print("DEVICES:")
for d in devices {
    let name = strProp(d, kAudioObjectPropertyName)
    let uid = strProp(d, kAudioDevicePropertyDeviceUID)
    let transport = u32Prop(d, kAudioDevicePropertyTransportType)
    let ch = inputChannels(d)
    print(String(format: "  [%u] %@ uid=%@ transport=%@(%u) inputCh=%d default=%@",
                 d, name, uid, fourCC(transport), transport, ch, d == defIn ? "YES" : "no"))
}
print("defaultInput=\(strProp(defIn, kAudioObjectPropertyName))")
