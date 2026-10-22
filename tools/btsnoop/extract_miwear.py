#!/usr/bin/env python3
"""从 Android btsnoop 日志还原小米耳机 miwear 协议帧。

背景：手机上 com.xiaomi.bluetooth 通过 L2CAP CoC（动态 CID）承载 miwear 帧，
帧内层格式与 macOS 端 BLE GATT (AF00/AF07/AF08) 完全相同：

    FE DC BA | type | opcode | len(2,BE) | [status] | seq | payload | EF
    type: 0xC0 设备请求 / 0xC1 主机请求 / 0x01 应答 / 0xC7 设备通知
          bit7=1 表示请求(无 status 字节), bit6=hasResponse, bit0-2=targetApp

用法:
    python3 extract_miwear.py <btsnoop.log> [--opcode F3] [--contains 0034] [--full]
"""
import sys, struct, re

FRAME_HDR = b"\xfe\xdc\xba"
TYPE_NAMES = {0xC0: "DEV_REQ", 0xC1: "HOST_REQ", 0x01: "RSP", 0xC7: "DEV_NTF"}
OPCODES = {
    0x01: "DATA", 0x02: "GET_DEV_INFO", 0x08: "SET_ANC", 0x09: "GET_RUN_INFO",
    0x0A: "CHANNEL", 0x0E: "REPORT_STATUS", 0x50: "AUTH_CHECK", 0x51: "AUTH_CONFIRM",
    0xF2: "SET_CONFIG", 0xF3: "GET_CONFIG", 0xF4: "NOTIFY_CONFIG",
}


def records(path):
    data = open(path, "rb").read()
    if data[:8] != b"btsnoop\0":
        raise SystemExit("not btsnoop")
    off = 16
    while off + 24 <= len(data):
        ol, il, flags, drops, ts = struct.unpack(">IIIIQ", data[off:off+24])
        off += 24
        pkt = data[off:off+il]
        off += il
        yield flags, ts, pkt


def frames_from_stream(stream):
    """Incrementally carve frames out of a byte stream."""
    out = []
    i = 0
    while True:
        j = stream.find(FRAME_HDR, i)
        if j < 0:
            break
        if j + 7 > len(stream):
            break
        length = (stream[j+5] << 8) | stream[j+6]
        total = 7 + length + 1
        if total < 8 or j + total > len(stream):
            break
        if stream[j+total-1] != 0xEF:
            i = j + 1
            continue
        is_req = bool(stream[j+3] & 0x40)
        body = j + 7 + (0 if is_req else 1)
        seq = stream[body]
        payload = stream[body+1:j+total-1]
        out.append(dict(type=stream[j+3], opcode=stream[j+4], seq=seq,
                        payload=payload, raw=stream[j:j+total]))
        i = j + total
    return out


def main():
    path = sys.argv[1]
    want_op = None
    contains = None
    full = "--full" in sys.argv
    if "--opcode" in sys.argv:
        want_op = int(sys.argv[sys.argv.index("--opcode")+1], 16)
    if "--contains" in sys.argv:
        contains = sys.argv[sys.argv.index("--contains")+1].upper()

    base = None
    streams = {"TX": bytearray(), "RX": bytearray()}
    buf = []   # (time, dir, frame)
    for flags, ts, pkt in records(path):
        if base is None:
            base = ts
        if not pkt or pkt[0] != 0x02 or len(pkt) < 7:
            continue
        d = "TX" if (flags & 1) == 0 else "RX"
        l2len = struct.unpack("<H", pkt[3:5])[0]
        inner = pkt[7:7+l2len]
        streams[d] += inner
        # carve frames after each append
        for f in frames_from_stream(bytes(streams[d])):
            pass
        # simple approach: carve fresh each time for this direction only on new data
        fs = frames_from_stream(bytes(streams[d]))
        buf = [(ts, d, f) for f in fs]

    # final carve
    all_frames = []
    for d in ("TX", "RX"):
        pass
    # re-do properly: maintain per-direction carved index
    base = None
    carved = {"TX": 0, "RX": 0}
    streams = {"TX": bytearray(), "RX": bytearray()}
    collected = []
    for flags, ts, pkt in records(path):
        if base is None:
            base = ts
        if not pkt or pkt[0] != 0x02 or len(pkt) < 7:
            continue
        d = "TX" if (flags & 1) == 0 else "RX"
        l2len = struct.unpack("<H", pkt[3:5])[0]
        streams[d] += pkt[7:7+l2len]
        stream = bytes(streams[d])
        i = carved[d]
        while True:
            j = stream.find(FRAME_HDR, i)
            if j < 0 or j + 7 > len(stream):
                break
            length = (stream[j+5] << 8) | stream[j+6]
            total = 7 + length + 1
            if total < 8 or j + total > len(stream):
                break
            if stream[j+total-1] != 0xEF:
                i = j + 1
                continue
            is_req = bool(stream[j+3] & 0x40)
            body = j + 7 + (0 if is_req else 1)
            seq = stream[body]
            payload = stream[body+1:j+total-1]
            collected.append(dict(t=(ts-base)/1e6, dir=d, type=stream[j+3],
                                  opcode=stream[j+4], seq=seq, payload=payload,
                                  raw=stream[j:j+total]))
            i = j + total
        carved[d] = i

    collected.sort(key=lambda f: f["t"])
    shown = 0
    for f in collected:
        if want_op is not None and f["opcode"] != want_op:
            continue
        if contains is not None and contains not in f["raw"].hex().upper():
            continue
        shown += 1
        tname = TYPE_NAMES.get(f["type"], hex(f["type"]))
        oname = OPCODES.get(f["opcode"], hex(f["opcode"]))
        hexs = f["raw"].hex().upper()
        if not full and len(hexs) > 180:
            hexs = hexs[:180] + f"...({len(f['raw'])}B)"
        print(f"{f['t']:9.3f} {f['dir']} {tname:8} op=0x{f['opcode']:02X}({oname:15}) "
              f"seq=0x{f['seq']:02X} pl={len(f['payload']):4}B  {hexs}")
    print(f"\n# total miwear frames={len(collected)} shown={shown}", file=sys.stderr)


if __name__ == "__main__":
    main()
