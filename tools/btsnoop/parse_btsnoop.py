#!/usr/bin/env python3
"""从 btsnoop (HCI H4) 日志里提取 ATT 层收发的原始字节。

用途：抓官方 App 与小米耳机之间的 BLE 流量，还原认证与录音下载协议。
不依赖 Wireshark。

用法:
    python3 parse_btsnoop.py <btsnoop_hci.log> [--filter-hex FEDCBA] [--all-att]
"""
import sys, struct, datetime

ATT_OPCODES = {
    0x01: "ErrorRsp", 0x02: "MtuReq", 0x03: "MtuRsp",
    0x04: "FindInfoReq", 0x05: "FindInfoRsp",
    0x06: "FindByTypeValueReq", 0x07: "FindByTypeValueRsp",
    0x08: "ReadByTypeReq", 0x09: "ReadByTypeRsp",
    0x0A: "ReadReq", 0x0B: "ReadRsp",
    0x0C: "ReadBlobReq", 0x0D: "ReadBlobRsp",
    0x10: "ReadByGroupReq", 0x11: "ReadByGroupRsp",
    0x12: "WriteReq", 0x13: "WriteRsp",
    0x16: "PrepareWriteReq", 0x17: "PrepareWriteRsp",
    0x18: "ExecWriteReq", 0x19: "ExecWriteRsp",
    0x1B: "Notify", 0x1D: "Indicate", 0x1E: "Confirm",
    0x52: "WriteCmd",
}

def read_records(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"btsnoop\0":
        raise SystemExit("not a btsnoop file")
    version, datalink = struct.unpack(">II", data[8:16])
    off = 16
    while off + 24 <= len(data):
        orig_len, incl_len, flags, drops, ts = struct.unpack(">IIIIQ", data[off:off+24])
        off += 24
        pkt = data[off:off+incl_len]
        off += incl_len
        yield flags, ts, pkt

def main():
    path = sys.argv[1]
    filt = None
    all_att = "--all-att" in sys.argv
    if "--filter-hex" in sys.argv:
        filt = bytes.fromhex(sys.argv[sys.argv.index("--filter-hex")+1])

    base_ts = None
    n_pkt = n_att = n_hit = 0
    for flags, ts, pkt in read_records(path):
        if not pkt:
            continue
        n_pkt += 1
        h4 = pkt[0]
        if h4 != 0x02:            # only ACL data
            continue
        if len(pkt) < 5:
            continue
        handle = struct.unpack("<H", pkt[1:3])[0] & 0x0FFF
        l2len, cid = struct.unpack("<HH", pkt[3:7]) if len(pkt) >= 7 else (0, 0)
        if cid != 0x0004:         # only ATT
            continue
        att = pkt[7:7+l2len]
        if len(att) < 1:
            continue
        n_att += 1
        op = att[0]
        direction = "RX" if (flags & 0x01) else "TX"   # RX = controller->host

        # extract attribute handle + value for write/notify
        ah = None; val = b""
        if op in (0x12, 0x52, 0x1B, 0x1D) and len(att) >= 3:
            ah = struct.unpack("<H", att[1:3])[0]
            val = att[3:]
        elif op == 0x0B and len(att) >= 1:   # read response
            val = att[1:]

        hit = (filt is None) or (filt in att)
        if filt is not None and not hit:
            # still print if the value contains our filter
            if not (filt in val):
                continue
        if filt is None and not all_att and op not in (0x12, 0x52, 0x1B, 0x1D):
            continue
        n_hit += 1
        if base_ts is None:
            base_ts = ts
        rel = (ts - base_ts) / 1e6
        print(f"{rel:8.3f}s conn={handle:04x} {direction} "
              f"{ATT_OPCODES.get(op, hex(op)):12} attr={('0x%04x' % ah) if ah is not None else '-':8} "
              f"len={len(val):4} {val.hex().upper()}")

    print(f"\n# packets={n_pkt} att={n_att} shown={n_hit}", file=sys.stderr)

if __name__ == "__main__":
    main()
