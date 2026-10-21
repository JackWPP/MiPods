// Minimal link-health test: connect, then send the EXACT frame that worked in run1
// repeatedly, and report whether ANY reply arrives. No auth, no config.
import Foundation
import CoreBluetooth
func hex(_ b:[UInt8])->String{ b.map{String(format:"%02X",$0)}.joined() }
var log:[String]=[]
func L(_ s:String){ print(s); fflush(stdout); log.append(s) }
final class P:NSObject,CBCentralManagerDelegate,CBPeripheralDelegate{
 var c:CBCentralManager!; var t:CBPeripheral?; var w:CBCharacteristic?; var buf:[UInt8]=[]
 var seq:UInt8=0; var got=0; var tries=0; var done=false
 let T="1300D6D417E2"
 override init(){super.init();c=CBCentralManager(delegate:self,queue:nil)}
 func centralManagerDidUpdateState(_ cm:CBCentralManager){ if cm.state == .poweredOn { cm.scanForPeripherals(withServices:nil,options:nil) } }
 func centralManager(_ cm:CBCentralManager,didDiscover p:CBPeripheral,advertisementData d:[String:Any],rssi r:NSNumber){
   guard t == nil, let m = d[CBAdvertisementDataManufacturerDataKey] as? Data else {return}
   guard m.map{String(format:"%02X",$0)}.joined().contains(T) else {return}
   L("[found] \(p.name ?? "?") rssi=\(r)"); t=p; cm.stopScan(); p.delegate=self; cm.connect(p,options:nil) }
 func centralManager(_ cm:CBCentralManager,didConnect p:CBPeripheral){ L("[conn] ok"); p.discoverServices(nil) }
 func centralManager(_ cm:CBCentralManager,didDisconnectPeripheral p:CBPeripheral,error:Error?){
   L("[conn] DISC \(error?.localizedDescription ?? "")"); guard !done else{return}
   DispatchQueue.main.asyncAfter(deadline:.now()+2){ [weak self] in
     guard let self, !self.done else{return}
     self.t=nil; self.buf.removeAll(); self.w=nil
     self.c.scanForPeripherals(withServices:nil,options:nil) } }
 func peripheral(_ p:CBPeripheral,didDiscoverServices e:Error?){
   for s in p.services ?? [] where s.uuid.uuidString=="AF00" { p.discoverCharacteristics(nil,for:s) } }
 func peripheral(_ p:CBPeripheral,didDiscoverCharacteristicsFor s:CBService,error:Error?){
   for ch in s.characteristics ?? [] {
     if ch.uuid.uuidString=="AF07" { w=ch }
     if ch.uuid.uuidString=="AF08" { p.setNotifyValue(true,for:ch) } }
   guard w != nil else {return}
   DispatchQueue.main.asyncAfter(deadline:.now()+1.1){ [weak self] in self?.ping(p) } }
 func peripheral(_ p:CBPeripheral,didUpdateValueFor ch:CBCharacteristic,error:Error?){
   guard let d=ch.value else{return}; buf.append(contentsOf:[UInt8](d))
   while true {
     guard let s=buf.firstIndex(where:{$0==0xFE}) else {buf.removeAll();return}
     if s>0 {buf.removeFirst(s)}
     guard buf.count>=7 else{return}
     let isReq=(buf[3]&0x40) != 0
     let len=Int(buf[5])<<8|Int(buf[6]); guard len>=1,len<=4096 else{buf.removeFirst(1);continue}
     let tot=7+len+1; guard buf.count>=tot else{return}
     guard buf[tot-1]==0xEF else{buf.removeFirst(1);continue}
     let op=buf[4]; let bs=7+(isReq ? 0:1); let sq=buf[bs]
     let pl=Array(buf[(bs+1)..<(tot-1)]); buf.removeFirst(tot)
     got+=1; L("  <= op=0x\(String(format:"%02X",op)) seq=\(sq) payload=\(hex(pl))")
     if isReq { write(p,[0xFE,0xDC,0xBA,0x04,op,0x00,0x02,0x00,sq,0xEF]) }
   } }
 func write(_ p:CBPeripheral,_ f:[UInt8]){
   guard let w else{return}
   let ty:CBCharacteristicWriteType = w.properties.contains(.write) ? .withResponse : .withoutResponse
   p.writeValue(Data(f),for:w,type:ty); L("  => \(hex(f))") }
 func ping(_ p:CBPeripheral){
   // EXACT bytes that worked in run1
   let f:[UInt8]=[0xFE,0xDC,0xBA,0xC4,0x02,0x00,0x05,0x00,0xFF,0xFF,0xFF,0xFF,0xEF]
   tries+=1
   if tries>6 { finish(); return }
   L("--- ping #\(tries) ---"); write(p,f)
   DispatchQueue.main.asyncAfter(deadline:.now()+2.0){ [weak self] in
     guard let self,!self.done else{return}
     if self.got>0 { self.finish() } else { self.ping(p) } } }
 func finish(){ guard !done else{return}; done=true
   L("\nRESULT: got \(got) frame(s) over \(tries) ping(s)")
   L(got>0 ? "LINK OK - device replies" : "LINK DEAD - no reply at all")
   try? log.joined(separator:"\n").write(toFile:"p3.log",atomically:true,encoding:.utf8); exit(0) }
}
let s=Double(CommandLine.arguments.dropFirst().first ?? "45") ?? 45
let pr=P()
DispatchQueue.main.asyncAfter(deadline:.now()+s){ pr.finish() }
RunLoop.main.run()
