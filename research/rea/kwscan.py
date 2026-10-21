import re, sys, json
path = sys.argv[1]
kws = sys.argv[2].split(',')
win = int(sys.argv[3]) if len(sys.argv)>3 else 160
limit = int(sys.argv[4]) if len(sys.argv)>4 else 6
data = open(path, 'r', encoding='utf-8', errors='replace').read()
print(f"# file={path} size={len(data)}")
for kw in kws:
    print(f"\n## KW: {kw}  total_hits={data.lower().count(kw.lower())}")
    start = 0; n = 0
    while n < limit:
        i = data.lower().find(kw.lower(), start)
        if i < 0: break
        lo = max(0, i-win); hi = min(len(data), i+win)
        snippet = data[lo:hi].replace('\n', '\\n')
        print(f"--- hit{n+1} @char{i}: ...{snippet}...")
        start = i+len(kw); n += 1
