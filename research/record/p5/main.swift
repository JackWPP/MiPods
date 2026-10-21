// Listen on ALL notify characteristics; try 0x02 in several timings/variants.
// Goal: determine whether GET_DEVICE_INFO ever replies in a fresh GATT session.
import Foundation
import CoreBluetooth
func hex(_ b:[UInt8])->String{ b.map{String(format:"%02X",$0)}.joined() }
var log:[String]=[]
func L(_ s:String){ print(s); fflush(stdout); log.append(s) }
final class P:NSObject,CBCentralManagerDelegate,CBPeripheralDelegate{
 var c:CBCentralManager!; var t:CBPeripheral?; var w:CBCharacteristic?
 var bufs:[String:[UInt8]]=[:]
 var seq:UInt8=0; var done=false; var started=false; var reconn=0
 var anyReply=0
 let T="1300D6D417E2"
 override init(){super.init();c=CBCentralManager(delegate:self,queue:nil)}
 func nextSeq()->UInt8{let s=seq;seq &+= 1;return s}
 func centralManagerDidUpdateState(_ cm:CBCentralManager){ if cm.state == .poweredOn { cm.scanForPeripherals(withServices:nil,options:nil) } }
 func centralManager(_ cm:CBCentralManager,didDiscover p:CBPeripheral,advertisementData d:[String:Any],rssi r:NSNumber){
  guard t == nil, let m = d[CBAdvertisementDataManufacturerDataKey] as? Data else{return}
  guard m.map{String(format:"%02X",$0)}.joined().contains(T) else{return}
  L("[found] rssi=\(r)"); t=p; cm.stopScan(); p.delegate=self; cm.connect(p,options:nil) }
 func centralManager(_ cm:CBCentralManager,didConnect p:CBPeripheral){ L("[conn] ok"); p.discoverServices(nil) }
 func centralManager(_ cm:CBCentralManager,didDisconnectPeripheral p:CBPeripheral,error:Error?){
  L("[conn] DISC"); guard !done else{return}
  reconn += 1; guard reconn<=4 else{finish();return}
  DispatchQueue.main.asyncAfter(deadline:.now()+2.5){ [weak self] in
   guard let self,!self.done else{return}
   self.t=nil; self.bufs.removeAll(); self.w=nil; self.started=false
   self.c.scanForPeripherals(withServices:nil,options:nil) } }
 func peripheral(_ p:CBPeripheral,didDiscoverServices e:Error?){
  for s in p.services ?? [] { p.discoverCharacteristics(nil,for:s) } }
 func peripheral(_ p:CBPeripheral,didDiscoverCharacteristicsFor s:CBService,error:Error?){
  for ch in s.characteristics ?? [] {
   if ch.uuid.uuidString=="AF07" { w=ch }
   if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
     p.setNotifyValue(true,for:ch); bufs[ch.uuid.uuidString]=[] } }
  guard w != nil,!started else{return}
  started=true
  // variant 1: immediately
  DispatchQueue.main.asyncAfter(deadline:.now()+0.5){ [weak self] in self?.v1(p) } }
 func peripheral(_ p:CBPeripheral,didUpdateValueFor ch:CBCharacteristic,error:Error?){
  guard let d=ch.value else{return}
  let key=ch.uuid.uuidString
  var b=bufs[key] ?? []
  b.append(contentsOf:[UInt8](d))
  let raw=[UInt8](d)
  if key != "AF08" { L("  <raw \(key)> \(hex(raw))"); anyReply += 1 }
  while true {
   guard let s=b.firstIndex(where:{$0==0xFE}) else { bufs[key]=[]; return }
   if s>0 {b.removeFirst(s)}
   guard b.count>=7 else{bufs[key]=b;return}
   let isReq=(b[3]&0x40) != 0
   let len=Int(b[5])<<8|Int(b[6]); guard len>=1,len<=4096 else{b.removeFirst(1);continue}
   let tot=7+len+1; guard b.count>=tot else{bufs[key]=b;return}
   guard b[tot-1]==0xEF else{b.removeFirst(1);continue}
   let op=b[4]; let bs=7+(isReq ? 0:1); let sq=b[bs]
   let pl=Array(b[(bs+1)..<(tot-1)]); b.removeFirst(tot)
   L("  <= [\(key)] op=0x\(String(format:"%02X",op)) req=\(isReq) payload=\(hex(pl))")
   anyReply += 1
   if isReq { write(p,[0xFE,0xDC,0xBA,0x04,op,0x00,0x02,0x00,sq,0xEF]) }
  } }
 func write(_ p:CBPeripheral,_ f:[UInt8]){
  guard let w else{return}
  let ty:CBCharacteristicWriteType = w.properties.contains(.write) ? .withResponse : .withoutResponse
  p.writeValue(Data(f),for:w,type:ty); L("  => \(hex(f))") }
 func req(_ p:CBPeripheral,_ op:UInt8,_ pl:[UInt8]){ write(p,[0xFE,0xDC,0xBA,0xC4,op,0x00,UInt8(pl.count+1),nextSeq()] + pl + [0xEF]) }
 func v1(_ p:CBPeripheral){ L("\n[V1] 0x02 right after subscribe"); req(p,0x02,[0xFF,0xFF,0xFF,0xFF])
  DispatchQueue.main.asyncAfter(deadline:.now()+2.0){ [weak self] in self?.v2(p) } }
 func v2(_ p:CBPeripheral){ L("\n[V2] 0x02 after 4s settle"); DispatchQueue.main.asyncAfter(deadline:.now()+4.0){ [weak self] in
   guard let self else{return}; L("[V2] sending now"); self.req(p,0x02,[0xFF,0xFF,0xFF,0xFF])
   DispatchQueue.main.asyncAfter(deadline:.now()+2.0){ [weak self] in self?.v3(p) } } }
 func v3(_ p:CBPeripheral){ L("\n[V3] 0x02 payload 00000000 + 0x09")
  req(p,0x02,[0x00,0x00,0x00,0x00])
  DispatchQueue.main.asyncAfter(deadline:.now()+2.0){ [weak self] in
    guard let self else{return}; self.req(p,0x09,[0xFF,0xFF,0xFF,0xFF])
    DispatchQueue.main.asyncAfter(deadline:.now()+2.0){ [weak self] in self?.v4(p) } } }
 func v4(_ p:CBPeripheral){ L("\n[V4] 0x02 via FF10 write"); 
  // also try FF10
  req(p,0x02,[0xFF,0xFF,0xFF,0xFF])
  DispatchQueue.main.asyncAfter(deadline:.now()+2.0){ [weak self] in self?.finish() } }
 func finish(){ guard !done else{return}; done=true
  L("\nRESULT anyReply=\(anyReply)")
  try? log.joined(separator:"\n").write(toFile:"p5.log",atomically:true,encoding:.utf8); exit(0) }
}
let s=Double(CommandLine.arguments.dropFirst().first ?? "50") ?? 50
let pr=P()
DispatchQueue.main.asyncAfter(deadline:.now()+s){ pr.finish() }
RunLoop.main.run()
