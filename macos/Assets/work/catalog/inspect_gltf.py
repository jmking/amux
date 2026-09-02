import sys, json, struct, os
def load(path):
    with open(path,'rb') as f:
        data=f.read()
    if data[:4]==b'glTF':
        magic,ver,length=struct.unpack('<III',data[:12])
        clen,ctype=struct.unpack('<II',data[12:20])
        return json.loads(data[20:20+clen])
    return json.loads(data)
def summ(path):
    try: g=load(path)
    except Exception as e:
        print(f"## {path}\n  ERROR {e}"); return
    anims=[a.get('name','?') for a in g.get('animations',[])]
    meshes=[m.get('name','?') for m in g.get('meshes',[])]
    mats=[m.get('name','?') for m in g.get('materials',[])]
    skins=len(g.get('skins',[]))
    imgs=[(i.get('uri') or f"bufferView:{i.get('bufferView')}") for i in g.get('images',[])]
    # bounds from accessor min/max of POSITION
    mn=[1e9]*3; mx=[-1e9]*3
    for m in g.get('meshes',[]):
        for p in m.get('primitives',[]):
            a=g['accessors'][p['attributes']['POSITION']]
            if 'min' in a:
                mn=[min(x,y) for x,y in zip(mn,a['min'])]; mx=[max(x,y) for x,y in zip(mx,a['max'])]
    size=[round(b-a,2) for a,b in zip(mn,mx)] if mn[0]<1e8 else None
    nodes=len(g.get('nodes',[]))
    print(f"## {os.path.relpath(path,'/Users/justinking/dev/amux/macos/Assets/src')}  ({os.path.getsize(path)//1024} KB)")
    print(f"  gen={g.get('asset',{}).get('generator','?')} nodes={nodes} skins={skins} meshes={len(meshes)} mats={len(mats)} anims={len(anims)}")
    print(f"  bbox(mesh-space, no node xform) min={[round(x,2) for x in mn] if size else None} max={[round(x,2) for x in mx] if size else None} size={size}")
    print(f"  meshes={meshes[:30]}")
    print(f"  materials={mats[:30]}")
    print(f"  images={imgs[:10]}")
    if anims: print(f"  animations={anims}")
for p in sys.argv[1:]: summ(p)
