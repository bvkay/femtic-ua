#!/usr/bin/env python3
"""acc_site_diag.py -- per-site diagnosis of half-space errors against the local mesh around each site.

    python acc_site_diag.py RUN_DIR RHO MESH_STATS_JSON

For each test frequency: Spearman rank correlation of the per-site max |rho_a error| (and the diagonal ratio)
with the size of the surface triangle holding the site, the depth of the earth element below it, the height
of the air element above it, and the site's distance from the array centre. Diagnostic only (no pass/fail).
"""
import glob
import json
import math
import sys

import numpy as np

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from acc_analyse import read_csv_mt  # noqa: E402

MU0 = 4e-7 * math.pi


def rank(a):
    return np.argsort(np.argsort(a)).astype(float)


def spearman(a, b):
    return float(np.corrcoef(rank(a), rank(b))[0, 1])


run, rho, msj = sys.argv[1], float(sys.argv[2]), sys.argv[3]
ps = {p["station"]: p for p in json.load(open(msj))["per_site"]}
rows = [r for fn in sorted(glob.glob(f"{run}/result_*_iter0.csv")) for r in read_csv_mt(fn)]
freqs = sorted({r["Freq[Hz]"] for r in rows}, reverse=True)
keys = ["tri_max_edge", "tri_mean_edge", "earth_el_depth", "earth_el_max_edge", "air_el_height", "r_centre"]
print(f"{'f Hz':>9} " + " ".join(f"{k:>16}" for k in keys) + "   (Spearman r: |rho err| / diag ratio)")
for f in freqs:
    rr = sorted([r for r in rows if r["Freq[Hz]"] == f], key=lambda r: r["StaID"])
    w = 2 * math.pi * f
    st = [int(r["StaID"]) for r in rr]
    z = lambda r, c: complex(r[f"Re({c})_Cal"], r[f"Im({c})_Cal"])
    e = np.array([max(abs(abs(z(r, "Zxy")) ** 2 / (w * MU0) / rho - 1), abs(abs(z(r, "Zyx")) ** 2 / (w * MU0) / rho - 1)) for r in rr])
    dg = np.array([max(abs(z(r, "Zxx")), abs(z(r, "Zyy"))) / abs(z(r, "Zxy")) for r in rr])
    cols = {k: np.array([ps[s][k] for s in st]) for k in keys if k != "r_centre"}
    cols["r_centre"] = np.array([math.hypot(ps[s]["x"], ps[s]["y"]) for s in st])
    print(f"{f:>9g} " + " ".join(f"{spearman(e, cols[k]):>+7.2f}/{spearman(dg, cols[k]):>+7.2f} " for k in keys))
f = freqs[0]
rr = sorted([r for r in rows if r["Freq[Hz]"] == f], key=lambda r: r["StaID"])
w = 2 * math.pi * f
z = lambda r, c: complex(r[f"Re({c})_Cal"], r[f"Im({c})_Cal"])
print(f"\nworst 8 sites at {f:g} Hz: station site x y  err_xy% err_yx%  diag%  tri_max_edge_m earth_depth_m air_height_m")
lst = []
for r in rr:
    s = int(r["StaID"])
    exy = 100 * (abs(z(r, "Zxy")) ** 2 / (w * MU0) / rho - 1)
    eyx = 100 * (abs(z(r, "Zyx")) ** 2 / (w * MU0) / rho - 1)
    dg = 100 * max(abs(z(r, "Zxx")), abs(z(r, "Zyy"))) / abs(z(r, "Zxy"))
    lst.append((max(abs(exy), abs(eyx)), s, exy, eyx, dg))
for m, s, exy, eyx, dg in sorted(lst, reverse=True)[:8]:
    p = ps[s]
    print(f"  {s:4d} {p['site']:>16} {p['x']:7.2f} {p['y']:7.2f}  {exy:+6.2f} {eyx:+6.2f}  {dg:5.2f}  "
          f"{1000 * p['tri_max_edge']:5.1f} {1000 * p['earth_el_depth']:5.1f} {1000 * p['air_el_height']:5.1f}")
