import json, os, struct, sys
src, outdir = sys.argv[1], sys.argv[2]
with open(src,'rb') as f:
    data = f.read()
# header: 4 x uint32: size prefix, header size, json size, string pickle len
a, b, c, d = struct.unpack('<IIII', data[:16])
print("header sizes:", a, b, c, d, file=sys.stderr)
# standard: [4][headerSize][jsonSize][jsonLen]
json_size = struct.unpack('<I', data[12:16])[0]
base = 16
hdr = json.loads(data[base:base+json_size].decode('utf-8'))
content_off = base + json_size
content_off = (content_off + 3) & ~3  # align 4? asar aligns to 4
print("json_size", json_size, "content_off", content_off, file=sys.stderr)
total = 0
def walk(node, path):
    global total
    for name, ent in node.get('files', {}).items():
        p = os.path.join(path, name)
        if ent.get('files') is not None:
            walk(ent, p)
        elif 'link' in ent:
            pass
        else:
            size = ent.get('size', 0)
            off = ent.get('offset', '0')
            off = int(off)
            full = os.path.join(outdir, p)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full,'wb') as o:
                o.write(data[content_off+off:content_off+off+size])
            total += 1
os.makedirs(outdir, exist_ok=True)
walk(hdr, '')
print("files extracted:", total, file=sys.stderr)
