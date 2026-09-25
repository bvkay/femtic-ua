import sys, math, statistics
L = open(sys.argv[1]).read().split('\n')
assert L[0].strip() == 'TETRA'
nn = int(L[1]); xyz = {}
for i in range(nn):
    p = L[2+i].split(); xyz[int(p[0])] = tuple(float(v) for v in p[1:4])
ne = int(L[2+nn]); elems = []
for i in range(ne):
    p = L[3+nn+i].split(); elems.append([int(v) for v in p[5:9]])
zs = sorted(set(round(v[2], 3) for v in xyz.values()))
print(f"nodes {nn}, elements {ne}; z range {min(zs):.0f}..{max(zs):.0f} m (z positive down? check sign)")
# surface = z closest to 0 among nodes inside station footprint
def near(x, y, r=15e3): return abs(x) <= r and abs(y) <= r
surf_nodes = [v for v in xyz.values() if abs(v[2]) < 1.0 and near(v[0], v[1])]
print(f"surface nodes (|z|<1 m) within +-15 km: {len(surf_nodes)}")
edges = []; depths = []
for e in elems:
    pts = [xyz[n] for n in e]
    if any(abs(p[2]) < 1.0 and near(p[0], p[1]) for p in pts):
        zc = sum(p[2] for p in pts)/4
        for a in range(4):
            for b in range(a+1, 4):
                edges.append(math.dist(pts[a], pts[b]))
        depths.append(zc)
print(f"elements touching surface within +-15 km: {len(depths)}")
q = sorted(edges)
pc = lambda f: q[int(f*(len(q)-1))]
print(f"edge length m: min {q[0]:.0f}  p10 {pc(.1):.0f}  median {pc(.5):.0f}  p90 {pc(.9):.0f}  max {q[-1]:.0f}")
for f in (1e-3, 1e-2, 1e-1, 1.0):
    d = 503.3*math.sqrt(100/f)
    print(f"f={f:g} Hz skin depth (100 ohm-m) = {d:.0f} m ; median surface edge / skin depth = {pc(.5)/d:.2f}")
