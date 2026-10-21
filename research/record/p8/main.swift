// p8: control -- does 0x02 work in a FRESH connection when auth is NOT sent?
// If yes: auth challenge itself (not just 0x51) puts the device into a
// "no more RCSP reads" state. If no: the device just stops answering after one session.
import Foundation
import CoreBluetooth
func hex(_ b:[UInt8])->String{ b.map{String(format:"%02X",$0)}.joined() }
func encCmd(_ op:UInt8,_ pl:[UInt8],_ sq:UInt8)->[UInt8]{
 let n=pl.count+1
 return [0xFE,0xDC,0xBA,0xC4,op,UInt8((n>>8)&0xFF),UInt8(n&0xFF),sq]+pl+[0xEF] }
func encResp(_ op:UInt8,_ sq:UInt8)->[UInt8]{[0xFE,0xDC,0xBA,0x04,op,0x00,0x02,0x00,sq,0xEF]}
var log:[String]=[]
func L(_ s:String){print(s);fflush(stdout);log.append(s)}
final class P:NSObject,CBCentralManagerDelegate,CBPeripheralDelegate{
 var c:CBCentralManager!; var t:CBPeripheral?; var w:CBCharacteristic?
 var buf:[UInt8]=[]; var seq:UInt8=0; var done=false,started=false
 var got=[String]()
 let T="1300D6D417E2"
 override init(){super.init();c=CBCentralManager(delegate:self,queue:nil)}
 func nextSeq()->UInt8{let s=seq;seq &+= 1;return s}
 func centralManagerDidUpdateState(_ cm:CBCentralManager){ if cm.state == .poweredOn { cm.scanForPeripherals(withServices:nil,options:nil) } }
 func centralManager(_ cm:CBCentralManager,didDiscover p:CBPeripheral,advertisementData d:[String:Any],rssi r:NSNumber){
  guard t==nil, let m=d[CBAdvertisementDataManufacturerDataKey] as? Data else{return}
  guard m.map{String(format:"%02X",$0)}.joined().contains(T) else{return}
  L("[found]"); t=p; cm.stopScan(); p.delegate=self; cm.connect(p,options:nil) }
 func centralManager(_ cm:CBCentralManager,didConnect p:CBPeripheral){ L("[conn]"); p.discoverServices(nil) }
 func centralManager(_ cm:CBCentralManager,didDisconnectPeripheral p:CBPeripheral,error:Error?){
   L("[conn] DISC"); guard !done else{return}; finish() }
 func peripheral(_ p:CBPeripheral,didDiscoverServices e:Error?){
  for s in p.services ?? [] where s.uuid.uuidString=="AF00" { p.discoverCharacteristics(nil,for:s) } }
 func peripheral(_ p:CBPeripheral,didDiscoverCharacteristicsFor s:CBService,error:Error?){
  for ch in s.characteristics ?? [] {
   if ch.uuid.uuidString=="AF07" { w=ch }
   if ch.uuid.uuidString=="AF08" { p.setNotifyValue(true,for:ch) } }
  guard w != nil,!started else{return}
  started=true
  // NO AUTH. Just send 0x02 three times with gaps.
  DispatchQueue.main.asyncAfter(deadline:.now()+0.15){ [weak self] in self?.ping(p,1) } }
 func ping(_ p:CBPeripheral,_ n:Int){
  guard n<=2 else { finish(); return }
  L("\n[PING \(n)] 0x02 (no auth)")
  write(p,encCmd(0x02,[0xFF,0xFF,0xFF,0xFF],nextSeq()))
  DispatchQueue.main.asyncAfter(deadline:.now()+2.0){ [weak self] in
   guard let self,!self.done else{return}; self.ping(p,n+1) } }
 func peripheral(_ p:CBPeripheral,didUpdateValueFor ch:CBCharacteristic,error:Error?){
  guard let d=ch.value else{return}; buf.append(contentsOf:[UInt8](d)); parse(p) }
 func parse(_ p:CBPeripheral){
  while true {
   guard let s=buf.firstIndex(where:{$0==0xFE}) else{buf.removeAll();return}
   if s>0 {buf.removeFirst(s)}
   guard buf.count>=7 else{return}
   let isReq=(buf[3]&0x40) != 0
   let len=Int(buf[5])<<8|Int(buf[6]); guard len>=1,len<=4096 else{buf.removeFirst(1);continue}
   let tot=7+len+1; guard buf.count>=tot else{return}
   guard buf[tot-1]==0xEF else{buf.removeFirst(1);continue}
   let op=buf[4]; let bs=7+(isReq ? 0:1); let sq=buf[bs]
   let pl=Array(buf[(bs+1)..<(tot-1)]); buf.removeFirst(tot)
   let line="op=0x\(String(format:"%02X",op)) req=\(isReq) payload=\(hex(pl))"
   L("  <= "+line); got.append(line)
   if isReq { write(p,encResp(op,sq)) } } }
 func write(_ p:CBPeripheral,_ f:[UInt8]){
  guard let w else{return}
  let ty:CBCharacteristicWriteType = w.properties.contains(.write) ? .withResponse : .withoutResponse
  p.writeValue(Data(f),for:w,type:ty); L("  => \(hex(f))") }
 func finish(){ guard !done else{return}; done=true
  L("\nRESULT frames=\(got.count)  \(got.isEmpty ? "LINK SILENT after connect" : "LINK OK")")
  try? log.joined(separator:"\n").write(toFile:"p8.log",atomically:true,encoding:.utf8); exit(0) }
}
let s=Double(CommandLine.arguments.dropFirst().first ?? "30") ?? 30
let pr=P()
DispatchQueue.main.asyncAfter(deadline:.now()+s){ pr.finish() }
RunLoop.main.run()
