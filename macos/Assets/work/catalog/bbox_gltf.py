import sys, json, struct, os, math
SRC='/Users/justinking/dev/amux/macos/Assets/src'
def load(path):
    data=open(path,'rb').read()
    if data[:4]==b'glTF':
        clen,=struct.unpack('<I',data[12:16]); return json.loads(data[20:20+clen])
    return json.loads(data)
def quat_to_mat(q):
    x,y,z,w=q
    return [[1-2*(y*y+z*z),2*(x*y-z*w),2*(x*z+y*w)],[2*(x*y+z*w),1-2*(x*x+z*z),2*(y*z-x*w)],[2*(x*z-y*w),2*(y*z+x*w),1-2*(x*x+y*y)]]
def node_mat(n):
    if 'matrix' in n:
        m=n['matrix']; return [[m[0],m[4],m[8],m[12]],[m[1],m[5],m[9],m[13]],[m[2],m[6],m[10],m[14]],[0,0,0,1]]
    t=n.get('translation',[0,0,0]); r=n.get('rotation',[0,0,0,1]); s=n.get('scale',[1,1,1])
    R=quat_to_mat(r)
    return [[R[i][j]*s[j] for j in range(3)]+[t[i]] for i in range(3)]+[[0,0,0,1]]
def mul(a,b): return [[sum(a[i][k]*b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]
def xf(m,p): return [m[i][0]*p[0]+m[i][1]*p[1]+m[i][2]*p[2]+m[i][3] for i in range(3)]
def bbox(path, verbose=False):
    g=load(path); mn=[1e9]*3; mx=[-1e9]*3; hit=[False]
    I=[[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]]
    def visit(ni,parent):
        n=g['nodes'][ni]; W=mul(parent,node_mat(n))
        if 'mesh' in n:
            skinned='skin' in n
            for p in g['meshes'][n['mesh']]['primitives']:
                a=g['accessors'][p['attributes']['POSITION']]
                if 'min' not in a: continue
                # skinned meshes: vertices are in bind space, use skin root-ish: just use W anyway but report
                for cx in (a['min'][0],a['max'][0]):
                    for cy in (a['min'][1],a['max'][1]):
                        for cz in (a['min'][2],a['max'][2]):
                            q=xf(W,[cx,cy,cz]); hit[0]=True
                            for i in range(3): mn[i]=min(mn[i],q[i]); mx[i]=max(mx[i],q[i])
            if verbose:
                print(f"    node '{n.get('name')}' mesh='{g['meshes'][n['mesh']].get('name')}' skinned={skinned} T={n.get('translation')} R={n.get('rotation')} S={n.get('scale')}")
        for c in n.get('children',[]): visit(c,W)
    scene=g.get('scenes',[{}])[g.get('scene',0)]
    for r in scene.get('nodes',[]): visit(r,I)
    if not hit[0]: return None
    return [round(v,3) for v in mn],[round(v,3) for v in mx],[round(b-a,3) for a,b in zip(mn,mx)]
if __name__=='__main__':
    for p in sys.argv[1:]:
        try:
            r=bbox(p)
            print(f"{os.path.relpath(p,SRC):90s} size(w,h,d)={r[2] if r else None} min={r[0] if r else None}")
        except Exception as e: print(p,'ERR',e)
