#!/usr/bin/env python3
"""Independent checks of a FEMTIC tetra mesh produced by the makeTetraMesh -> tetgen -> makeMtr -> TetGen2Femtic chain.

Reads mesh.dat and resistivity_block_iter0.dat (what FEMTIC will actually consume) plus analysis_domain.dat,
and checks geometric/topological facts that the tools do not report about themselves.

Usage: python check_mesh.py RUN_DIR [--flat-surface-z Z_KM] [--air-rho 1e9]
Exit code 0 only if every check passes.
"""
import argparse, os, sys
import numpy as np

ap = argparse.ArgumentParser()
ap.add_argument("run_dir")
ap.add_argument("--flat-surface-z", type=float, default=None,
                help="if the earth surface is flat at this z (km, positive down), also check air/earth split by element centroid")
ap.add_argument("--air-rho", type=float, default=1.0e9)
a = ap.parse_args()
os.chdir(a.run_dir)

results = []
def check(name, ok, detail):
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}: {detail}")

# ---------- analysis domain (km -> m)
dom = np.loadtxt("analysis_domain.dat") * 1.0e3
box_vol = np.prod(dom[:, 1] - dom[:, 0])
box_area = (dom[0, 1] - dom[0, 0]) * (dom[1, 1] - dom[1, 0])

# ---------- mesh.dat
with open("mesh.dat") as f:
    tok = f.read().split()
assert tok[0] == "TETRA", tok[0]
p = 1
nn = int(tok[p]); p += 1
nodes = np.array(tok[p:p + 4 * nn], dtype=float).reshape(nn, 4); p += 4 * nn
ne = int(tok[p]); p += 1
el = np.array(tok[p:p + 9 * ne], dtype=np.int64).reshape(ne, 9); p += 9 * ne
lists = []
for k in range(7):  # -X,+X,-Y,+Y,-Z,+Z, earth surface
    n = int(tok[p]); p += 1
    lists.append(np.array(tok[p:p + 2 * n], dtype=np.int64).reshape(n, 2)); p += 2 * n
xyz = nodes[:, 1:4]
neigh = el[:, 1:5]
conn = el[:, 5:9]
print(f"mesh.dat: {nn} nodes, {ne} elements, boundary faces per plane "
      f"{[len(l) for l in lists[:6]]}, earth-surface faces {len(lists[6])}")

check("node ids contiguous", np.array_equal(nodes[:, 0].astype(int), np.arange(nn)), "ids 0..N-1")
check("element ids contiguous", np.array_equal(el[:, 0], np.arange(ne)), "ids 0..N-1")
check("node extents == analysis_domain box",
      np.allclose(xyz.min(0), dom[:, 0], atol=1e-3) and np.allclose(xyz.max(0), dom[:, 1], atol=1e-3),
      f"min {xyz.min(0)/1e3} km, max {xyz.max(0)/1e3} km")

# volumes
A, B, C, D = (xyz[conn[:, i]] for i in range(4))
vol = np.einsum("ij,ij->i", B - A, np.cross(C - A, D - A)) / 6.0
check("no degenerate elements", np.all(np.abs(vol) > 0), f"min |vol| = {np.abs(vol).min():.3e} m^3")
check("consistent orientation", np.all(vol > 0) or np.all(vol < 0),
      f"{(vol > 0).sum()} positive, {(vol < 0).sum()} negative")
tot = np.abs(vol).sum()
check("sum of element volumes == box volume", abs(tot / box_vol - 1) < 1e-9,
      f"{tot:.9e} vs {box_vol:.9e} m^3 (rel err {abs(tot/box_vol-1):.1e})")

# neighbour symmetry and boundary-face bookkeeping
bad = 0
for f in range(4):
    e = np.arange(ne); k = neigh[:, f]; m = k >= 0
    back = (neigh[k[m]] == e[m][:, None]).any(1)
    bad += int((~back).sum())
check("neighbour relation symmetric", bad == 0, f"{bad} one-way links")
nb = int((neigh < 0).sum()); nlist = sum(len(l) for l in lists[:6])
check("#faces with no neighbour == #faces on the 6 outer planes", nb == nlist, f"{nb} vs {nlist}")

# earth-surface faces: face i is opposite local node i (MeshDataTetraElement m_faceID2NodeID)
es = lists[6]
fn = np.array([[j for j in range(4) if j != f] for f in range(4)])
tri = conn[es[:, 0][:, None], fn[es[:, 1]]]
P, Q, R = (xyz[tri[:, i]] for i in range(3))
cr = np.cross(Q - P, R - P)
area_h = 0.5 * np.abs(cr[:, 2]).sum()   # horizontal projection
check("earth-surface faces tile the horizontal domain", abs(area_h / box_area - 1) < 1e-9,
      f"projected area {area_h:.9e} vs {box_area:.9e} m^2")

# ---------- resistivity_block_iter0.dat
with open("resistivity_block_iter0.dat") as f:
    rt = f.read().split()
ne2, npar = int(rt[0]), int(rt[1])
e2c = np.array(rt[2:2 + 2 * ne2], dtype=np.int64).reshape(ne2, 2)
q = 2 + 2 * ne2
cells = np.array(rt[q:q + 6 * npar], dtype=float).reshape(npar, 6)
print(f"resistivity_block_iter0.dat: {ne2} elements, {npar} parameter cells (cell 0 = air)")
check("element count agrees mesh.dat vs resistivity_block", ne2 == ne, f"{ne2} vs {ne}")
cell = e2c[:, 1]
check("cell indices in range", cell.min() >= 0 and cell.max() < npar, f"{cell.min()}..{cell.max()}")
used = np.bincount(cell, minlength=npar)
check("every parameter cell owns >= 1 element", np.all(used > 0), f"{int((used == 0).sum())} empty cells")
check("cell 0 is air: rho and fixed flag", cells[0, 1] == a.air_rho and int(cells[0, 5]) == 1,
      f"rho {cells[0,1]:g}, fixed {int(cells[0,5])}")
earth = cells[1:]
check("earth cells free (fixed flag 0)", np.all(earth[:, 5] == 0), f"{int((earth[:,5]!=0).sum())} fixed earth cells")
print(f"      earth cell starting resistivities: {sorted(set(earth[:,1].tolist()))}")
air_v = np.abs(vol)[cell == 0].sum(); earth_v = np.abs(vol)[cell > 0].sum()
print(f"      air volume {air_v/1e9:.6e} km^3, earth volume {earth_v/1e9:.6e} km^3")

if a.flat_surface_z is not None:
    z0 = a.flat_surface_z * 1e3
    cz = (A[:, 2] + B[:, 2] + C[:, 2] + D[:, 2]) / 4.0
    wrong_air = int(((cz < z0) & (cell != 0)).sum())
    wrong_earth = int(((cz > z0) & (cell == 0)).sum())
    check("flat surface: centroid above surface <=> air cell 0", wrong_air == 0 and wrong_earth == 0,
          f"{wrong_air} above-surface elements not air, {wrong_earth} below-surface elements in air")
    check("flat surface: earth-surface faces lie on z = surface",
          np.allclose(np.r_[P[:, 2], Q[:, 2], R[:, 2]], z0, atol=1e-6), f"max |z - z0| = {np.abs(np.r_[P[:,2],Q[:,2],R[:,2]]-z0).max():.2e} m")
    exp_air = box_area * (z0 - dom[2, 0]); exp_earth = box_area * (dom[2, 1] - z0)
    check("flat surface: air / earth volumes match the box split",
          abs(air_v / exp_air - 1) < 1e-9 and abs(earth_v / exp_earth - 1) < 1e-9,
          f"air {air_v:.9e}/{exp_air:.9e}, earth {earth_v:.9e}/{exp_earth:.9e}")

print(f"\n{sum(results)}/{len(results)} checks passed")
sys.exit(0 if all(results) else 1)
