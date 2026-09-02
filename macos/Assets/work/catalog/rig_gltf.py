import sys, json, struct, os
def load(path):
    data=open(path,'rb').read()
    if data[:4]==b'glTF':
        clen,=struct.unpack('<I',data[12:16]); return json.loads(data[20:20+clen])
    return json.loads(data)
for p in sys.argv[1:]:
    g=load(p); print('##',os.path.basename(p))
    for si,s in enumerate(g.get('skins',[])):
        names=[g['nodes'][j].get('name','?') for j in s['joints']]
        print(f"  skin{si} joints({len(names)}): {names}")
    # print top-level hierarchy w/ transforms up to depth 3
    def walk(ni,d):
        n=g['nodes'][ni]
        if d<=3: print('   '+'  '*d+f"{n.get('name')} T={n.get('translation')} R={n.get('rotation')} S={n.get('scale')} mesh={n.get('mesh')} skin={n.get('skin')}")
        for c in n.get('children',[]): walk(c,d+1)
    for r in g['scenes'][g.get('scene',0)]['nodes']: walk(r,0)
    for m in g.get('materials',[]):
        pbr=m.get('pbrMetallicRoughness',{})
        print(f"  mat {m.get('name')}: base={pbr.get('baseColorFactor')} tex={'baseColorTexture' in pbr} emissive={m.get('emissiveFactor')}")
    # animation durations
    for a in g.get('animations',[]):
        mx=0
        for s in a['samplers']:
            acc=g['accessors'][s['input']]; mx=max(mx,acc.get('max',[0])[0])
        print(f"  anim {a.get('name')} {mx:.2f}s")
