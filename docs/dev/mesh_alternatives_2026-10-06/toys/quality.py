import numpy as np
def dihedral_min(X, T):
    P = X[T]; faces = [(1, 2, 3), (0, 2, 3), (0, 1, 3), (0, 1, 2)]
    N = []
    for f in faces:
        a, b, c = (P[:, i] for i in f); n = np.cross(b - a, c - a); N.append(n / np.linalg.norm(n, axis=1)[:, None])
    ang = []
    for i in range(4):
        for j in range(i + 1, 4):
            ang.append(180 - np.degrees(np.arccos(np.clip(np.einsum("ij,ij->i", N[i], N[j]), -1, 1))))
    ang = np.array(ang); return ang.min(0), ang.max(0)
def rd(stem):
    n = np.loadtxt(stem + ".node", skiprows=1, comments="#"); e = np.loadtxt(stem + ".ele", skiprows=1, comments="#")
    return n[:, 1:4], e[:, 1:5].astype(np.int64) - 1
cases = {"tetgen exe q1.4 + 3 mtr rounds": rd("out/exe_e3a/toy.4")}
for t in ("q_del", "q_hxt"):
    d = np.load(f"out/gmsh_{t}.npz"); cases[f"gmsh {t}"] = (d["xyz"], d["tets"])
for k, (X, T) in cases.items():
    mn, mx = dihedral_min(X, T)
    print(f"{k:34s} n={len(T):6d} min-dihedral p0 {mn.min():5.1f} p1 {np.percentile(mn,1):5.1f} median {np.median(mn):5.1f} | max-dihedral max {mx.max():6.1f} | n(min<10deg) {int((mn<10).sum())}")
