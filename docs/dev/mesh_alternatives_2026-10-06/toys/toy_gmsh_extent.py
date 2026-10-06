"""Domain-extent check: +-500 km box (km units), flat earth surface via OCC fragment,
3 sites 1 km apart at 4 m (0.004 km), grading 0.4 km/km to 100 km. Not a scaling test."""
import sys, time, json, numpy as np, gmsh
algo = int(sys.argv[1]); t0 = time.perf_counter()
gmsh.initialize(); gmsh.option.setNumber("General.Terminal", 0); gmsh.model.add("ext")
o = gmsh.model.occ
air = o.addBox(-500, -500, 0, 1000, 1000, 500); earth = o.addBox(-500, -500, -500, 1000, 1000, 500)
o.fragment([(3, air)], [(3, earth)]); o.synchronize()
vols = gmsh.model.getEntities(3)
zc = {v[1]: gmsh.model.occ.getCenterOfMass(3, v[1])[2] for v in vols}
va = [t for t, z in zc.items() if z > 0][0]; ve = [t for t, z in zc.items() if z < 0][0]
sites = [(-1.0, 0.0, 0.0), (0.0, 0.0, 0.0), (1.0, 0.3, 0.0)]
sp = [o.addPoint(*s) for s in sites]; o.synchronize()
f = gmsh.model.mesh.field
fd = f.add("Distance"); f.setNumbers(fd, "PointsList", sp)
th = f.add("Threshold"); f.setNumber(th, "InField", fd)
for k, v in dict(SizeMin=0.004, SizeMax=100.0, DistMin=0.006, DistMax=250.0).items(): f.setNumber(th, k, v)
f.setAsBackgroundMesh(th)
for k, v in {"Mesh.MeshSizeExtendFromBoundary": 0, "Mesh.MeshSizeFromPoints": 0, "Mesh.MeshSizeFromCurvature": 0,
             "Mesh.Algorithm": 6, "Mesh.Algorithm3D": algo, "General.NumThreads": 1}.items(): gmsh.option.setNumber(k, v)
t1 = time.perf_counter(); gmsh.model.mesh.generate(3); tm = time.perf_counter() - t1
ntag, xyz, _ = gmsh.model.mesh.getNodes(); xyz = xyz.reshape(-1, 3)
idx = np.full(int(ntag.max()) + 1, -1); idx[ntag] = np.arange(len(ntag))
T = []
for v in (va, ve):
    _, et = gmsh.model.mesh.getElementsByType(4, v); T.append(idx[et.reshape(-1, 4)])
T = np.vstack(T); P = xyz[T]
vol = np.einsum("ij,ij->i", np.cross(P[:, 1]-P[:, 0], P[:, 2]-P[:, 0]), P[:, 3]-P[:, 0]) / 6
# earth surface = boundary between the two volumes
surf = [s[1] for s in gmsh.model.getBoundary([(3, va)], oriented=False) if abs(o.getCenterOfMass(2, s[1])[2]) < 1e-9][0]
_, ft = gmsh.model.mesh.getElementsByType(2, surf); ft = idx[ft.reshape(-1, 3)]; c = xyz[ft].mean(axis=1)
se = []
for s in sites:
    k = np.argmin(((c[:, :2] - s[:2])**2).sum(1)); q = xyz[ft[k]]
    se.append(round(1000 * max(np.linalg.norm(q[a]-q[b]) for a, b in ((0, 1), (1, 2), (2, 0))), 2))
E = np.linalg.norm(P[:, [0, 0, 0, 1, 1, 2]] - P[:, [1, 2, 3, 2, 3, 3]], axis=2)
print(json.dumps(dict(algo=algo, tets=len(T), nodes=int(len(np.unique(T))), earth_surface_tris=len(ft),
      site_tri_max_edge_m=se, min_edge_m=round(1000 * float(E.min()), 3), max_edge_km=round(float(E.max()), 1),
      vol_rel_err=float(abs(np.abs(vol).sum() - 1e9) / 1e9), neg=int((vol <= 0).sum()),
      t_mesh_s=round(tm, 2), t_total_s=round(time.perf_counter() - t0, 2))))
gmsh.finalize()
