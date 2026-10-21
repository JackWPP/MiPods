import os, sys, json
root = sys.argv[1]
out = sys.argv[2]
kws = ["FE95","fe95","0x038F","038F","GATT","gatt","180F","180f","Battery Service","earbud","Earbud","EARBUD","Buds","buds","TWS","tws","headset","Headset","RFCOMM","rfcomm","SPP","A2DP","a2dp","降噪","通透","耳机","充电盒","入耳","电量"]
encs = ["utf-8", "utf-16-le"]
results = {}
skipped = 0
for dirpath, dirnames, filenames in os.walk(root):
    for fn in filenames:
        p = os.path.join(dirpath, fn)
        try:
            sz = os.path.getsize(p)
        except OSError:
            continue
        if sz == 0 or sz > 300*1024*1024:
            skipped += 1
            continue
        try:
            data = open(p,'rb').read()
        except OSError:
            skipped += 1
            continue
        hits = {}
        for kw in kws:
            n = 0
            for enc in encs:
                try:
                    b = kw.encode(enc)
                except Exception:
                    continue
                n += data.count(b)
            if n: hits[kw] = n
        if hits:
            results[p] = hits
json.dump({"skipped":skipped,"results":results}, open(out,'w'), ensure_ascii=False, indent=1)
# print compact
for p,h in sorted(results.items(), key=lambda kv: -sum(kv[1].values())):
    print(f"{p}: {h}")
print("skipped:", skipped, "files_with_hits:", len(results))
