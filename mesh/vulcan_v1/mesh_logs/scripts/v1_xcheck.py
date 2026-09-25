"""Independent cross-check of mesh_stats.py's site location: matplotlib's trapezoid-map trifinder on the
earth-surface triangles of mesh.dat, versus mesh_stats.json per_site 'tri'. Also a negative control: a point
outside the domain must not be found, and random footprint points must see larger triangles than the sites.
Fails (exit 1) if any site's triangle differs, if any site is not found, or if the controls do not behave."""
import json, sys
import numpy as np
import matplotlib.tri as mtri

run = sys.argv[1]
st = json.load(open(f"{run}/logs/mesh_stats.json"))
with open(f"{run}/mesh.dat") as f:
    f.readline()
    tok = np.array(f.read().split(), dtype=float)
p = 0
nn = int(tok[p]); p += 1
nodes = tok[p:p + 4 * nn].reshape(nn, 4); p += 4 * nn
ne = int(tok[p]); p += 1
el = tok[p:p + 9 * ne].reshape(ne, 9).astype(np.int64); p += 9 * ne
lists = []
for k in range(7):
    n = int(tok[p]); p += 1
    lists.append(tok[p:p + 2 * n].reshape(n, 2).astype(np.int64)); p += 2 * n
xy = nodes[:, 1:3] / 1000.0
conn = el[:, 5:9]
es = lists[6]
fn = np.array([[j for j in range(4) if j != f] for f in range(4)])
tri = conn[es[:, 0][:, None], fn[es[:, 1]]]
used, inv = np.unique(tri, return_inverse=True)
T = mtri.Triangulation(xy[used, 0], xy[used, 1], inv.reshape(-1, 3))
finder = T.get_trifinder()
sites = np.array([[r["x"], r["y"]] for r in st["per_site"]])
mine = np.array([r["tri"] for r in st["per_site"]])
theirs = finder(sites[:, 0], sites[:, 1])
agree = int((mine == theirs).sum())
print(f"sites: {len(sites)}; trifinder found {int((theirs >= 0).sum())}; same triangle as mesh_stats: {agree}")
out = finder(np.array([600.0]), np.array([0.0]))[0]
print(f"negative control, point (600, 0) km outside the domain: trifinder -> {out} (expect -1)")
rng = np.random.default_rng(1)
rp = np.c_[rng.uniform(-7, 7, 2000), rng.uniform(-6.5, 6.5, 2000)]
rt = finder(rp[:, 0], rp[:, 1])
L = lambda t: np.max(np.linalg.norm(xy[tri[t]][:, [0, 1, 2]] - xy[tri[t]][:, [1, 2, 0]], axis=-1), axis=-1)
lr = L(rt); ls = L(theirs)
print(f"max edge of the containing triangle: sites median {np.median(ls)*1000:.1f} m, max {ls.max()*1000:.1f} m; "
      f"2000 random points in the array box median {np.median(lr)*1000:.1f} m, max {lr.max()*1000:.1f} m")
ok = agree == len(sites) and (theirs >= 0).all() and out == -1 and np.median(lr) > 2 * np.median(ls)
print("XCHECK", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
