"""Toy: 1 km cube (+-500 m), DEM terrain as discrete surface splitting air/earth,
3 sites, Distance+Threshold fields (4 m at site -> 150 m far), mesh, export arrays.
usage: python toy_gmsh.py ALGO3D NTHREADS TAG"""
import sys, time, math, hashlib, json
import numpy as np, gmsh
algo, nthr, tag = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
H = 500.0                       # half width, m
sites = np.array([[-60.0, -40.0], [0.0, 55.0], [80.0, -10.0]])
def topo(x, y):                 # DEM: gentle 6 m bumps (point cloud on a 25 m grid)
    return 6.0*np.sin(x/90.0)*np.cos(y/120.0)
t0 = time.perf_counter()
gmsh.initialize(); gmsh.option.setNumber("General.Terminal", 0)
gmsh.model.add("toy")
# --- terrain as a discrete surface from a DEM grid (gmsh tutorial x2 pattern)
N = 40; xs = np.linspace(-H, H, N+1)
X, Y = np.meshgrid(xs, xs, indexing="ij"); Z = topo(X, Y)
def nid(i, j): return (N+1)*i + j + 1
coords = np.c_[X.ravel(), Y.ravel(), Z.ravel()].ravel()
nodes = np.arange(1, (N+1)**2 + 1)
tris = []
for i in range(N):
    for j in range(N):
        tris += [nid(i,j), nid(i+1,j), nid(i,j+1), nid(i+1,j), nid(i+1,j+1), nid(i,j+1)]
corner = [nid(0,0), nid(N,0), nid(N,N), nid(0,N)]
for k in range(4): gmsh.model.addDiscreteEntity(0, k+1)
for k, c in enumerate(corner): gmsh.model.setCoordinates(k+1, *coords[3*(c-1):3*c])
for k in range(4): gmsh.model.addDiscreteEntity(1, k+1, [k+1, (k+1) % 4 + 1])
gmsh.model.addDiscreteEntity(2, 1, [1, 2, 3, 4])
gmsh.model.mesh.addNodes(2, 1, nodes, coords)
for k in range(4): gmsh.model.mesh.addElementsByType(k+1, 15, [], [corner[k]])
edges = [[nid(i,0) for i in range(N+1)], [nid(N,j) for j in range(N+1)],
         [nid(i,N) for i in range(N,-1,-1)], [nid(0,j) for j in range(N,-1,-1)]]
for k, e in enumerate(edges):
    gmsh.model.mesh.addElementsByType(k+1, 1, [], np.c_[e[:-1], e[1:]].ravel())
gmsh.model.mesh.addElementsByType(1, 2, [], tris)
gmsh.model.mesh.reclassifyNodes(); gmsh.model.mesh.createGeometry()
# --- box: air above, earth below the terrain (built-in kernel, shares the terrain)
g = gmsh.model.geo
zt = [topo(-H,-H), topo(H,-H), topo(H,H), topo(-H,H)]
cxy = [(-H,-H), (H,-H), (H,H), (-H,H)]
top = [g.addPoint(x, y, -H) for x, y in cxy]   # z positive down: top of air is z=-H ... use z-up here, flip on export
bot = [g.addPoint(x, y, +H) for x, y in cxy]
# NB: this toy uses z UP for the DEM; top of air at z=+H, bottom at z=-H
g.remove([(0,t) for t in top+bot]); 
top = [g.addPoint(x, y, +H) for x, y in cxy]; bot = [g.addPoint(x, y, -H) for x, y in cxy]
def ring(p): return [g.addLine(p[k], p[(k+1) % 4]) for k in range(4)]
ct, cb = ring(top), ring(bot)
vt = [g.addLine(k+1, top[k]) for k in range(4)]     # terrain corner -> top
vb = [g.addLine(k+1, bot[k]) for k in range(4)]     # terrain corner -> bottom
st = g.addPlaneSurface([g.addCurveLoop(ct)]); sb = g.addPlaneSurface([g.addCurveLoop(cb)])
sa, se = [], []
for k in range(4):
    kn = (k+1) % 4
    sa.append(g.addPlaneSurface([g.addCurveLoop([k+1, vt[kn], -ct[k], -vt[k]])]))
    se.append(g.addPlaneSurface([g.addCurveLoop([k+1, vb[kn], -cb[k], -vb[k]])]))
va = g.addVolume([g.addSurfaceLoop([st] + sa + [1])])
ve = g.addVolume([g.addSurfaceLoop([sb] + se + [1])])
# site points (not embedded) only feed the Distance field
sp = [g.addPoint(x, y, float(topo(x, y))) for x, y in sites]
g.synchronize()
gmsh.model.addPhysicalGroup(3, [va], 10, "air"); gmsh.model.addPhysicalGroup(3, [ve], 20, "earth")
gmsh.model.addPhysicalGroup(2, [1], 100, "earth_surface")
# --- size fields: site Distance+Threshold (2 rings), global grading, Min
f = gmsh.model.mesh.field
fd = f.add("Distance"); f.setNumbers(fd, "PointsList", sp)
t1 = f.add("Threshold"); f.setNumber(t1, "InField", fd)
for k, v in dict(SizeMin=4.0, SizeMax=150.0, DistMin=6.0, DistMax=600.0).items(): f.setNumber(t1, k, v)
# global grading (Usui-ellipsoid stand-in): MathEval of radial distance, capped by Min
t2 = f.add("MathEval"); f.setString(t2, "F", "40 + 0.25*Sqrt(x*x + y*y + 4*z*z)")
fm = f.add("Min"); f.setNumbers(fm, "FieldsList", [t1, t2])
import os
SMIN = float(os.environ.get("SMIN", "4.0"))
f.setNumber(t1, "SizeMin", SMIN)
if os.environ.get("CALLBACK"):   # pure-Python size law instead of fields (Usui laws could be ported 1:1 here)
    S3 = np.c_[sites, topo(sites[:,0], sites[:,1])].tolist(); NCALL = [0]
    def cb(dim, tag, x, y, z, lc):
        NCALL[0] += 1
        dmin = min(((x-a)**2 + (y-b)**2 + (z-c)**2) ** 0.5 for a, b, c in S3)
        hs = min(150.0, max(SMIN, SMIN + (150.0 - SMIN) * (dmin - 6.0) / 594.0))
        return min(hs, 40 + 0.25 * (x*x + y*y + 4*z*z) ** 0.5)
    gmsh.model.mesh.setSizeCallback(cb); gmsh.option.setNumber("Mesh.MeshSizeMax", 1e22)
else:
    f.setAsBackgroundMesh(fm)
for k, v in {"Mesh.MeshSizeExtendFromBoundary": 0, "Mesh.MeshSizeFromPoints": 0,
             "Mesh.MeshSizeFromCurvature": 0, "Mesh.Algorithm": 6, "Mesh.Algorithm3D": algo,
             "General.NumThreads": nthr, "Mesh.MaxNumThreads3D": nthr, "Mesh.MaxNumThreads2D": 1, "Mesh.MaxNumThreads1D": 1}.items():
    gmsh.option.setNumber(k, v)
if len(sys.argv) > 4 and sys.argv[4] == "plc":
    import plc_export; plc_export.run(gmsh, np, sites, topo, st, sb, sa, se); sys.exit(0)
t1s = time.perf_counter(); gmsh.model.mesh.generate(3); tmesh = time.perf_counter() - t1s
# --- export: nodes, tets with region attribute, boundary triangles per entity
ntag, xyz, _ = gmsh.model.mesh.getNodes(); xyz = xyz.reshape(-1, 3)
idx = np.full(int(ntag.max()) + 1, -1); idx[ntag] = np.arange(len(ntag))
tets, attr = [], []
for vol, a in ((va, 10), (ve, 20)):
    _, et = gmsh.model.mesh.getElementsByType(4, vol); et = idx[et.reshape(-1, 4)]
    tets.append(et); attr.append(np.full(len(et), a))
tets = np.vstack(tets); attr = np.concatenate(attr)
used = np.unique(tets); print("orphan nodes (site points etc.):", len(xyz) - len(used))
faces = {}
for s in [1, st, sb] + sa + se:
    _, ft = gmsh.model.mesh.getElementsByType(2, s); faces[s] = idx[ft.reshape(-1, 3)]
# volumes (signed) and neighbour build, as a converter would
P = xyz[tets]; vol = np.einsum("ij,ij->i", np.cross(P[:,1]-P[:,0], P[:,2]-P[:,0]), P[:,3]-P[:,0]) / 6
F = np.sort(np.vstack([tets[:, [1,2,3]], tets[:, [0,2,3]], tets[:, [0,1,3]], tets[:, [0,1,2]]]), axis=1)
_, inv, cnt = np.unique(F, axis=0, return_inverse=True, return_counts=True)
nbnd = int((cnt == 1).sum()); nbf = sum(len(v) for k, v in faces.items() if k != 1)
# site triangle size
surf = faces[1]; c = xyz[surf].mean(axis=1)
site_edge = []
for x, y in sites:
    k = np.argmin((c[:,0]-x)**2 + (c[:,1]-y)**2); q = xyz[surf[k]]
    site_edge.append(max(np.linalg.norm(q[a]-q[b]) for a, b in ((0,1),(1,2),(2,0))))
sn = np.unique(surf); dz = float(np.abs(xyz[sn,2] - topo(xyz[sn,0], xyz[sn,1])).max())
h = hashlib.md5(np.round(xyz[used], 9).tobytes() + tets.tobytes()).hexdigest()
res = dict(tag=tag, algo=algo, threads=nthr, nodes=int(len(used)), tets=int(len(tets)),
           air=int((attr == 10).sum()), earth=int((attr == 20).sum()),
           earth_surface_tris=int(len(surf)), outer_bnd_tris=nbf, bnd_faces_from_tets=nbnd,
           min_vol=float(abs(vol).min()), sum_vol_rel_err=float(abs(abs(vol).sum() - (2*H)**3) / (2*H)**3),
           neg_vol=int((vol < 0).sum()), site_tri_max_edge_m=[round(e, 2) for e in site_edge],
           surf_dem_maxdev_m=round(dz, 3), t_mesh_s=round(tmesh, 3), ncall=(NCALL[0] if os.environ.get("CALLBACK") else None), t_total_s=round(time.perf_counter() - t0, 2), md5=h)
np.savez(f"out/gmsh_{tag}.npz", xyz=xyz, tets=tets, attr=attr); print(json.dumps(res))
gmsh.finalize()
