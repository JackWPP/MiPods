import sys
path = sys.argv[1]
kws = sys.argv[2].split('|')
win = int(sys.argv[3]); limit = int(sys.argv[4])
data = open(path,'r',encoding='utf-8',errors='replace').read()
print(f"# file={path} size={len(data)}")
for kw in kws:
    idxs=[]; s=0
    while True:
        i = data.find(kw, s)
        if i<0: break
        idxs.append(i); s=i+1
    print(f"\n## {kw!r} hits={len(idxs)}")
    for i in idxs[:limit]:
        print(f"  @{i}: ...{data[max(0,i-win):i+win]}...".replace('\n','\\n'))
