// p6: EXACT run1 replication. run1 did: discover ALL services/chars, subscribe AF08,
// read every readable char, THEN send 0x50 -> and the buds replied
//   RESP op=0x50 seq=00 st=00 payload=01 + 16B.
// That is the only observed successful auth step. Replicate, then continue to GET_CONFIG.
import Foundation
import CoreBluetooth
func hex(_ b:[UInt8])->String{ b.map{String(format:"%02X",$0)}.joined() }
func encCmd(_ op:UInt8,_ pl:[UInt8],_ sq:UInt8)->[UInt8]{
 let n=pl.count+1
 return [0xFE,0xDC,0xBA,0xC4,op,UInt8((n>>8)&0xFF),UInt8(n&0xFF),sq]+pl+[0xEF] }
func encResp(_ op:UInt8,_ sq:UInt8)->[UInt8]{ [0xFE,0xDC,0xBA,0x04,op,0x00,0x02,0x00,sq,0xEF] }
var log:[String]=[]
func L(_ s:String){ print(s); fflush(stdout); log.append(s) }
final class P:NSObject,CBCentralManagerDelegate,CBPeripheralDelegate{
 var c:CBCentralManager!; var t:CBPeripheral?; var w:CBCharacteristic?
 var buf:[UInt8]=[]; var seq:UInt8=0
 var done=false, reconn=0, phase=0
 var saw50=false
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
  L("[conn] DISC after phase \(phase)")
  guard !done else{return}
  reconn += 1; guard reconn<=4 else{finish();return}
  DispatchQueue.main.asyncAfter(deadline:.now()+3){ [weak self] in
   guard let self,!self.done else{return}
   self.t=nil; self.buf.removeAll(); self.w=nil; self.phase=0; self.saw50=false
   self.c.scanForPeripherals(withServices:nil,options:nil) } }
 func peripheral(_ p:CBPeripheral,didDiscoverServices e:Error?){
  for s in p.services ?? [] { p.discoverCharacteristics(nil,for:s) } }
 var pend=0,tot=0,allCh:[CBCharacteristic]=[]
 func peripheral(_ p:CBPeripheral,didDiscoverCharacteristicsFor s:CBService,error:Error?){
  pend += 1; tot=(p.services ?? []).count
  for ch in s.characteristics ?? [] {
   allCh.append(ch)
   if ch.uuid.uuidString=="AF07" { w=ch }
   if ch.properties.contains(.notify)||ch.properties.contains(.indicate) { p.setNotifyValue(true,for:ch) } }
  guard pend>=tot, phase==0 else{return}
  phase=1
  L("[gatt] \(allCh.count) chars; subscribing done; reading all readable (run1 did this)")
  for ch in allCh where ch.properties.contains(.read) { p.readValue(for:ch) }
  // run1 sent 0x50 right after reads -- do it with a small delay to let reads land
  DispatchQueue.main.asyncAfter(deadline:.now()+1.5){ [weak self] in self?.sendChallenge(p) } }
 func sendChallenge(_ p:CBPeripheral){
  guard phase==1 else{return}; phase=2
  L("\n[PHASE2] send 0x50 challenge (run1's successful step)")
  let r=(0..<16).map{_ in UInt8.random(in:0...255)}
  write(p,encCmd(0x50,[0x01]+r,nextSeq()))
  DispatchQueue.main.asyncAfter(deadline:.now()+2.5){ [weak self] in
   guard let self,!self.done else{return}
   L("  >> saw50=\(self.saw50)")
   log.append("VERDICT run1-replication saw50=\(self.saw50)")
   self.afterAuth(p) } }
 func afterAuth(_ p:CBPeripheral){
  guard phase==2 else{return}; phase=3
  L("\n[PHASE3] GET_CONFIG 70/69/68")
  let codes:[UInt16]=[0x0046,0x0045,0x0044]; var i=0
  func nxt(){
   guard !self.done,i<codes.count else {
    log.append("VERDICT afterAuth attempted \(i) configs")
    self.control(p); return }
   let c=codes[i]; i += 1
   self.write(p,encCmd(0xF3,[UInt8(c>>8),UInt8(c&0xFF)],self.nextSeq()))
   DispatchQueue.main.asyncAfter(deadline:.now()+1.5){ nxt() } }
  nxt() }
 func control(_ p:CBPeripheral){
  L("\n[PHASE4] control 0x02")
  write(p,encCmd(0x02,[0xFF,0xFF,0xFF,0xFF],nextSeq()))
  DispatchQueue.main.asyncAfter(deadline:.now()+2.0){ [weak self] in self?.finish() } }
 func peripheral(_ p:CBPeripheral,didUpdateValueFor ch:CBCharacteristic,error:Error?){
  guard let d=ch.value else{return}; buf.append(contentsOf:[UInt8](d)); parse(p) }
 func parse(_ p:CBPeripheral){
  while true {
   guard let s=buf.firstIndex(where:{$0==0xFE}) else{buf.removeAll();return}
   if s>0 {buf.removeFirst(s)}
   guard buf.count>=7 else{return}
   let isReq=(buf[3]&0x40) != 0
   let len=Int(buf[5])<<8|Int(buf[6]); guard len>=1,len<=4096 else{buf.removeFirst(1);continue}
   let t2=7+len+1; guard buf.count>=t2 else{return}
   guard buf[t2-1]==0xEF else{buf.removeFirst(1);continue}
   let tr=buf[3],op=buf[4]; let bs=7+(isReq ? 0:1); let sq=buf[bs]
   let pl=Array(buf[(bs+1)..<(t2-1)]); buf.removeFirst(t2)
   L("  <= T\(String(format:"%02X",tr)) op=0x\(String(format:"%02X",op)) req=\(isReq) payload=\(hex(pl))")
   if op==0x50 {
    if tr==0x04 { saw50=true; L("  [AUTH] *** 0x50 RESPONSE -> send 0x51 [01 00] ***")
      write(p,encCmd(0x51,[0x01,0x00],nextSeq())) }
    else if pl.count>=17 {
      let a=Safer.computeResponse(to:Array(pl[1..<17]))
      L("  [AUTH] device challenge -> SAFER \(hex(a))")
      write(p,[0xFE,0xDC,0xBA,0x04,0x50,0x00,0x12,0x00]+[0x01]+a+[0xEF]) } }
   else if isReq { write(p,encResp(op,sq)) } } }
 func write(_ p:CBPeripheral,_ f:[UInt8]){
  guard let w else{return}
  let ty:CBCharacteristicWriteType = w.properties.contains(.write) ? .withResponse : .withoutResponse
  p.writeValue(Data(f),for:w,type:ty); L("  => op=0x\(String(format:"%02X",f[4])) \(hex(f))") }
 func finish(){ guard !done else{return}; done=true
  L("\nRESULT saw50=\(saw50)")
  try? log.joined(separator:"\n").write(toFile:"p6.log",atomically:true,encoding:.utf8); exit(0) }
}
let s=Double(CommandLine.arguments.dropFirst().first ?? "55") ?? 55
let pr=P()
DispatchQueue.main.asyncAfter(deadline:.now()+s){ pr.finish() }
RunLoop.main.run()
