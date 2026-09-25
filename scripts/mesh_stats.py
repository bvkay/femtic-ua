#!/usr/bin/env python3
"""mesh_stats.py -- size statistics of a FEMTIC tetra mesh (mesh.dat + resistivity_block_iter0.dat) around MT sites.

Reads only what FEMTIC consumes (mesh.dat, resistivity_block_iter0.dat) plus the station coordinates of
observe.dat (the positions FEMTIC will actually use) and analysis_domain.dat. Units: mesh.dat is in metres;
everything reported here is in km. Frame: x = north, y = east, z positive down.

Usage:
  python mesh_stats.py RUN_DIR --observe observe.dat [--station-map station_map.csv] [--surface-z 0]
                       [--json out.json] [--rho 3 100] [--fmax 200] [--tmax 1000]

Reports:
  counts (nodes, elements, air/earth elements, parameter cells, earth-surface triangles);
  earth-surface triangle edge lengths and edges of the tetrahedra that share a face with the surface
    (earth side and air side), inside the site footprint (convex hull of the sites) and within
    0.1 / 0.5 km of any site;
  element counts and sizes by depth shell (earth) and height shell (air);
  per-site: the surface triangle that contains the site (FEMTIC locates stations in these), nearest node,
    the earth element under it (E and, with OWNER_ELEMENT 0, H) and the air element above it (H with -1);
  parameter cells: size by depth, cells near sites, the cell under each site;
  skin depth versus element size for the given resistivities from fmax to tmax.
"""
import argparse
import json
import math
import os
import sys

import numpy as np
from scipy.spatial import Delaunay, cKDTree

ap = argparse.ArgumentParser()
ap.add_argument("run_dir")
ap.add_argument("--observe", required=True, help="FEMTIC observe.dat (MT block gives station x y in km)")
ap.add_argument("--station-map", default=None, help="station_map.csv (femtic_station_id -> site_id), optional")
ap.add_argument("--surface-z", type=float, default=0.0, help="flat earth-surface z in km (positive down)")
ap.add_argument("--json", default=None)
ap.add_argument("--rho", type=float, nargs="+", default=[3.0, 100.0])
ap.add_argument("--fmax", type=float, default=200.0, help="highest frequency to judge (Hz)")
ap.add_argument("--tmax", type=float, default=1000.0, help="longest period to judge (s)")
a = ap.parse_args()

out = {}


def q(v):
    """min / p10 / median / p90 / max / n of an array (km)."""
    v = np.asarray(v, dtype=float)
    if v.size == 0:
        return {"n": 0}
    return {"n": int(v.size), "min": float(v.min()), "p10": float(np.percentile(v, 10)),
            "median": float(np.median(v)), "p90": float(np.percentile(v, 90)), "max": float(v.max())}


def fq(d, unit="km", nd=4):
    if d.get("n", 0) == 0:
        return "n=0"
    return (f"n={d['n']:>8d}  min {d['min']:.{nd}f}  p10 {d['p10']:.{nd}f}  median {d['median']:.{nd}f}  "
            f"p90 {d['p90']:.{nd}f}  max {d['max']:.{nd}f} {unit}")


# ------------------------------------------------------------------ mesh.dat
with open(os.path.join(a.run_dir, "mesh.dat")) as f:
    head = f.readline().split()
    assert head[0] == "TETRA", head
    tok = np.array(f.read().split(), dtype=np.float64)
p = 0
nn = int(tok[p]); p += 1
nodes = tok[p:p + 4 * nn].reshape(nn, 4); p += 4 * nn
ne = int(tok[p]); p += 1
el = tok[p:p + 9 * ne].reshape(ne, 9).astype(np.int64); p += 9 * ne
lists = []
for k in range(7):
    n = int(tok[p]); p += 1
    lists.append(tok[p:p + 2 * n].reshape(n, 2).astype(np.int64)); p += 2 * n
del tok
assert np.array_equal(nodes[:, 0].astype(np.int64), np.arange(nn))
xyz = nodes[:, 1:4] / 1000.0          # km
conn = el[:, 5:9]
neigh = el[:, 1:5]

# ------------------------------------------------------------------ resistivity block
with open(os.path.join(a.run_dir, "resistivity_block_iter0.dat")) as f:
    rt = f.read().split()
ne2, ncell = int(rt[0]), int(rt[1])
assert ne2 == ne, (ne2, ne)
cell = np.array(rt[2:2 + 2 * ne2], dtype=np.int64).reshape(ne2, 2)[:, 1]
del rt

dom = np.loadtxt(os.path.join(a.run_dir, "analysis_domain.dat"))

# ------------------------------------------------------------------ stations (observe.dat MT block)
st_id, st_xy, freqs = [], [], set()
with open(a.observe) as f:
    L = [ln.split() for ln in f]
i = 0
while i < len(L):
    if L[i] and L[i][0] == "MT":
        nst = int(L[i][1]); i += 1
        for _ in range(nst):
            sid, x, y = int(L[i][0]), float(L[i][3]), float(L[i][4]); i += 1
            nf = int(L[i][0]); i += 1
            for k in range(nf):
                freqs.add(float(L[i + k][0]))
            i += nf
            st_id.append(sid); st_xy.append((x, y))
        break
    i += 1
st_xy = np.array(st_xy)
names = {s: str(s) for s in st_id}
if a.station_map:
    import csv
    with open(a.station_map) as f:
        for r in csv.DictReader(f):
            names[int(r["femtic_station_id"])] = r["site_id"]
freqs = sorted(freqs, reverse=True)
nsite = len(st_id)

# ------------------------------------------------------------------ geometry per element
P = xyz[conn]                         # (ne, 4, 3)
cen = P.mean(axis=1)
vol = np.abs(np.einsum("ij,ij->i", P[:, 1] - P[:, 0], np.cross(P[:, 2] - P[:, 0], P[:, 3] - P[:, 0]))) / 6.0
pairs = [(0, 1), (0, 2), (0, 3), (1, 2), (1, 3), (2, 3)]
elen = np.stack([np.linalg.norm(P[:, i] - P[:, j], axis=1) for i, j in pairs], axis=1)   # (ne, 6)
emax = elen.max(1)
emean = elen.mean(1)
zext = P[:, :, 2].max(1) - P[:, :, 2].min(1)      # vertical extent of each tet
z0 = a.surface_z
is_air = cell == 0
earth = ~is_air

# ------------------------------------------------------------------ counts
out["counts"] = {
    "nodes": nn, "elements": ne, "air_elements": int(is_air.sum()), "earth_elements": int(earth.sum()),
    "parameter_cells_incl_air": ncell, "earth_parameter_cells": ncell - 1,
    "outer_faces": [int(len(x)) for x in lists[:6]], "earth_surface_faces": int(len(lists[6])),
    "sites": nsite, "frequencies": len(freqs),
}

# unique edges of the whole mesh
E = np.concatenate([np.sort(conn[:, [i, j]], axis=1) for i, j in pairs])
E = np.unique(E, axis=0)
out["counts"]["edges"] = int(len(E))
del E

# ------------------------------------------------------------------ earth-surface triangles
es = lists[6]
fn = np.array([[j for j in range(4) if j != f] for f in range(4)])
tri = conn[es[:, 0][:, None], fn[es[:, 1]]]         # (nt, 3) node ids
listed_el = es[:, 0]
across = neigh[es[:, 0], es[:, 1]]                  # element on the other side of the face
listed_air = int(is_air[listed_el].sum())
out["surface_face_owner"] = {"listed_elements_in_air": listed_air, "listed_elements_in_earth": int((~is_air[listed_el]).sum()),
                             "across_in_air": int(is_air[across].sum()), "across_in_earth": int((~is_air[across]).sum())}
earth_side = np.where(is_air[listed_el], across, listed_el)
air_side = np.where(is_air[listed_el], listed_el, across)
assert np.all(~is_air[earth_side]) and np.all(is_air[air_side]), "surface faces do not separate air from earth"
tz = xyz[tri][:, :, 2]
out["surface_z_range_km"] = [float(tz.min()), float(tz.max())]

TE = np.unique(np.sort(np.concatenate([tri[:, [0, 1]], tri[:, [0, 2]], tri[:, [1, 2]]]), axis=1), axis=0)
te_len = np.linalg.norm(xyz[TE[:, 0]] - xyz[TE[:, 1]], axis=1)
te_mid = 0.5 * (xyz[TE[:, 0], :2] + xyz[TE[:, 1], :2])
tri_cen = xyz[tri][:, :, :2].mean(1)
tri_len = np.stack([np.linalg.norm(xyz[tri[:, i]] - xyz[tri[:, j]], axis=1) for i, j in [(0, 1), (0, 2), (1, 2)]], 1)

site_tree = cKDTree(st_xy)
hull = Delaunay(st_xy)


def in_hull(pts):
    return hull.find_simplex(pts) >= 0


def dsite(pts):
    return site_tree.query(pts)[0]


surf = {}
d_te = dsite(te_mid)
h_te = in_hull(te_mid)
r_te = np.hypot(te_mid[:, 0], te_mid[:, 1])
surf["all"] = q(te_len)
surf["footprint"] = q(te_len[h_te])
surf["within_0.5km_of_site"] = q(te_len[d_te <= 0.5])
surf["within_0.1km_of_site"] = q(te_len[d_te <= 0.1])
surf["within_0.03km_of_site"] = q(te_len[d_te <= 0.03])
surf["footprint_farther_than_0.5km"] = q(te_len[h_te & (d_te > 0.5)])
surf["r_le_10.5km"] = q(te_len[r_te <= 10.5])
out["surface_triangle_edges_km"] = surf
out["surface_triangles_in_footprint"] = int(in_hull(tri_cen).sum())

# tetrahedra sharing a face with the earth surface (earth side = element under the surface)
tt = {}
for side, ids in (("earth", earth_side), ("air", air_side)):
    c2 = cen[ids, :2]
    d = dsite(c2); h = in_hull(c2)
    tt[side] = {
        "all_edges_footprint": q(elen[ids][h].ravel()),
        "all_edges_within_0.5km": q(elen[ids][d <= 0.5].ravel()),
        "all_edges_within_0.1km": q(elen[ids][d <= 0.1].ravel()),
        "vertical_extent_footprint": q(zext[ids][h]),
        "vertical_extent_within_0.5km": q(zext[ids][d <= 0.5]),
        "vertical_extent_within_0.1km": q(zext[ids][d <= 0.1]),
    }
out["surface_tets_km"] = tt

# all tets touching the surface with at least one node (surface-touching)
surf_nodes = np.zeros(nn, bool); surf_nodes[np.unique(tri)] = True
touch = surf_nodes[conn].any(1)
tch = {}
for side, m in (("earth", touch & earth), ("air", touch & is_air)):
    ids = np.where(m)[0]
    c2 = cen[ids, :2]; d = dsite(c2); h = in_hull(c2)
    tch[side] = {"n": int(len(ids)), "edges_footprint": q(elen[ids][h].ravel()),
                 "edges_within_0.5km": q(elen[ids][d <= 0.5].ravel()),
                 "max_edge_per_tet_within_0.5km": q(emax[ids][d <= 0.5])}
out["node_touching_tets_km"] = tch

# ------------------------------------------------------------------ shells
edges_sh = [0, 0.2, 1, 5, 20, 100, np.inf]
lab = ["0-0.2", "0.2-1", "1-5", "5-20", "20-100", ">100"]
depth = cen[:, 2] - z0
h_el = in_hull(cen[:, :2])
rr = np.hypot(cen[:, 0], cen[:, 1])
sh = []
for k in range(len(lab)):
    lo, hi = edges_sh[k], edges_sh[k + 1]
    me = earth & (depth >= lo) & (depth < hi)
    ma = is_air & (-depth >= lo) & (-depth < hi)
    row = {"shell_km": lab[k], "earth_elements": int(me.sum()), "air_elements": int(ma.sum()),
           "earth_mean_edge_all": q(emean[me]), "earth_mean_edge_under_footprint": q(emean[me & h_el]),
           "earth_elements_under_footprint": int((me & h_el).sum()),
           "earth_elements_r_le_10.5": int((me & (rr <= 10.5)).sum()),
           "air_mean_edge_all": q(emean[ma])}
    sh.append(row)
out["shells"] = sh

# size profile under the array: median mean-edge of earth tets with centroid in the footprint, by depth bins
zb = np.r_[0, np.geomspace(0.01, 500, 41)]
prof = []
for k in range(len(zb) - 1):
    m = earth & h_el & (depth >= zb[k]) & (depth < zb[k + 1])
    if m.sum() == 0:
        continue
    prof.append({"z_lo": float(zb[k]), "z_hi": float(zb[k + 1]), "n": int(m.sum()),
                 "median_mean_edge": float(np.median(emean[m])), "p90_max_edge": float(np.percentile(emax[m], 90))})
out["profile_under_footprint"] = prof
# columns under the array are narrow at depth; also profile within r <= 10.5 km (core disc) and on the axis
prof2 = []
for k in range(len(zb) - 1):
    m = earth & (rr <= max(10.5, 0.5 * zb[k + 1])) & (depth >= zb[k]) & (depth < zb[k + 1])
    if m.sum() == 0:
        continue
    prof2.append({"z_lo": float(zb[k]), "z_hi": float(zb[k + 1]), "n": int(m.sum()),
                  "median_mean_edge": float(np.median(emean[m])), "p90_max_edge": float(np.percentile(emax[m], 90))})
out["profile_core_column"] = prof2


def L_at_depth(z, prof_):
    """median mean-edge of the profile bin containing depth z (km)."""
    for r in prof_:
        if r["z_lo"] <= z < r["z_hi"]:
            return r["median_mean_edge"], r["p90_max_edge"]
    return float("nan"), float("nan")


# ------------------------------------------------------------------ per site
node_tree = cKDTree(xyz[:, :2][surf_nodes])
dn, _ = node_tree.query(st_xy)
ttree = cKDTree(tri_cen)
T2 = xyz[tri][:, :, :2]
per = []
for s in range(nsite):
    pt = st_xy[s]
    _, cand = ttree.query(pt, k=64)
    found = -1
    for t in cand:
        A_, B_, C_ = T2[t]
        v0, v1, v2 = C_ - A_, B_ - A_, pt - A_
        den = v0[0] * v1[1] - v1[0] * v0[1]
        u = (v2[0] * v1[1] - v1[0] * v2[1]) / den
        v = (v0[0] * v2[1] - v2[0] * v0[1]) / den
        if u >= -1e-12 and v >= -1e-12 and u + v <= 1 + 1e-12:
            found = t
            break
    rec = {"station": st_id[s], "site": names[st_id[s]], "x": float(pt[0]), "y": float(pt[1]),
           "nearest_surface_node_km": float(dn[s]), "tri": int(found)}
    if found >= 0:
        e_el, a_el = int(earth_side[found]), int(air_side[found])
        rec.update({
            "tri_max_edge": float(tri_len[found].max()), "tri_min_edge": float(tri_len[found].min()),
            "tri_mean_edge": float(tri_len[found].mean()),
            "tri_z": float(tz[found].mean()),
            "earth_el": e_el, "earth_el_max_edge": float(emax[e_el]), "earth_el_depth": float(P[e_el, :, 2].max() - z0),
            "air_el": a_el, "air_el_max_edge": float(emax[a_el]), "air_el_height": float(z0 - P[a_el, :, 2].min()),
            "earth_cell": int(cell[e_el]),
        })
    per.append(rec)
out["per_site"] = per
okfound = [r for r in per if r["tri"] >= 0]
out["sites_summary"] = {
    "sites_in_a_surface_triangle": len(okfound), "sites": nsite,
    "nearest_surface_node_km": q([r["nearest_surface_node_km"] for r in per]),
    "tri_max_edge": q([r["tri_max_edge"] for r in okfound]),
    "tri_mean_edge": q([r["tri_mean_edge"] for r in okfound]),
    "earth_el_depth": q([r["earth_el_depth"] for r in okfound]),
    "earth_el_max_edge": q([r["earth_el_max_edge"] for r in okfound]),
    "air_el_height": q([r["air_el_height"] for r in okfound]),
    "air_el_max_edge": q([r["air_el_max_edge"] for r in okfound]),
    "site_triangle_z_minus_surface": float(max(abs(r["tri_z"] - z0) for r in okfound)) if okfound else None,
    "distinct_site_triangles": len({r["tri"] for r in okfound}),
}

# ------------------------------------------------------------------ parameter cells
ce = cell[earth]
nc = ncell
cnt = np.bincount(cell, minlength=nc)
cvol = np.bincount(cell, weights=vol, minlength=nc)
ccen = np.stack([np.bincount(cell, weights=vol * cen[:, k], minlength=nc) for k in range(3)], 1) / np.maximum(cvol, 1e-300)[:, None]
lo = np.full((nc, 3), np.inf); hi = np.full((nc, 3), -np.inf)
pmin = P.min(1); pmax = P.max(1)
for k in range(3):
    np.minimum.at(lo[:, k], cell, pmin[:, k]); np.maximum.at(hi[:, k], cell, pmax[:, k])
ext = hi - lo
hext = np.maximum(ext[:, 0], ext[:, 1])
eqs = np.cbrt(cvol)
ec = np.arange(1, nc)
cdepth = ccen[ec, 2] - z0
cd_site = dsite(ccen[ec, :2])
cells = {"earth_cells": int(len(ec)),
         "elements_per_cell": q(cnt[ec]),
         "cells_with_1_element": int((cnt[ec] == 1).sum()),
         "cells_with_le_5_elements": int((cnt[ec] <= 5).sum()),
         "equiv_size_all": q(eqs[ec])}
csh = []
for k in range(len(lab)):
    m = (cdepth >= edges_sh[k]) & (cdepth < edges_sh[k + 1])
    csh.append({"shell_km": lab[k], "cells": int(m.sum()), "equiv_size": q(eqs[ec][m]),
                "horiz_extent": q(hext[ec][m]), "vert_extent": q(ext[ec][m, 2]), "elements_per_cell": q(cnt[ec][m])})
cells["by_depth"] = csh
near = (cd_site <= 0.5) & (cdepth < 1.0)
cells["near_sites_0.5km_top1km"] = {"cells": int(near.sum()), "equiv_size": q(eqs[ec][near]),
                                    "horiz_extent": q(hext[ec][near]), "vert_extent": q(ext[ec][near, 2]),
                                    "elements_per_cell": q(cnt[ec][near])}
foot = in_hull(ccen[ec, :2]) & (cdepth < 1.0)
cells["footprint_top1km"] = {"cells": int(foot.sum()), "equiv_size": q(eqs[ec][foot]),
                             "horiz_extent": q(hext[ec][foot]), "vert_extent": q(ext[ec][foot, 2])}
sc = np.array([r["earth_cell"] for r in okfound])
cells["cell_under_site"] = {"distinct_cells": int(len(set(sc.tolist()))), "equiv_size": q(eqs[sc]),
                            "horiz_extent": q(hext[sc]), "vert_extent": q(ext[sc, 2]), "elements_per_cell": q(cnt[sc])}
cells["air_cell_elements"] = int(cnt[0])
small = cnt[ec] <= 5
rc_ = np.hypot(ccen[ec, 0], ccen[ec, 1])
cells["small_cells_le5_elements"] = {"cells": int(small.sum()), "depth": q(cdepth[small]), "dist_to_site": q(cd_site[small]),
                                     "radius_from_centre": q(rc_[small]), "equiv_size": q(eqs[ec][small])}
# ratio of cell size to the local element size (mean over the cell's elements of the tet mean edge)
cel_L = np.bincount(cell, weights=emean, minlength=nc) / np.maximum(cnt, 1)
ratio = eqs[ec] / cel_L[ec]
cells["cell_equiv_size_over_mean_tet_edge"] = q(ratio)
out["parameter_cells_km"] = cells

# ------------------------------------------------------------------ skin depth vs size
xyw = max(np.abs(st_xy[:, 0]).max(), np.abs(st_xy[:, 1]).max())
dist_side = float(min(dom[0, 1] - np.abs(st_xy[:, 0]).max(), dom[1, 1] - np.abs(st_xy[:, 1]).max()))
dist_bottom = float(dom[2, 1] - z0)
fl = sorted(set([a.fmax] + freqs + [1.0 / a.tmax]), reverse=True)
ss = out["sites_summary"]
near_surf_p = lambda r: te_len[d_te <= r]                                  # noqa: E731
sd = []
d_el_site = dsite(cen[:, :2])
for f_ in fl:
    T = 1.0 / f_
    for rho in a.rho:
        dl = 0.503 * math.sqrt(rho * T)
        ring = near_surf_p(dl)
        Lz, Lz90 = L_at_depth(dl, prof2)
        loc = earth & (np.hypot(d_el_site, depth) <= dl)
        loc_emax = emax[loc] / dl
        loc_emean = emean[loc] / dl
        sd.append({"f_hz": f_, "T_s": T, "rho": rho, "delta_km": dl,
                   "site_tri_max_edge_over_delta_max": ss["tri_max_edge"]["max"] / dl,
                   "site_tri_max_edge_over_delta_median": ss["tri_max_edge"]["median"] / dl,
                   "earth_el_depth_over_delta_max": ss["earth_el_depth"]["max"] / dl,
                   "surface_edges_within_delta_of_site_max_over_delta": (float(ring.max()) / dl) if ring.size else None,
                   "surface_edges_within_delta_of_site_median_over_delta": (float(np.median(ring)) / dl) if ring.size else None,
                   "local_earth_tets_within_delta_of_site": int(loc.sum()),
                   "local_emax_p90_over_delta": float(np.percentile(loc_emax, 90)) if loc.any() else None,
                   "local_emax_max_over_delta": float(loc_emax.max()) if loc.any() else None,
                   "local_emean_median_over_delta": float(np.median(loc_emean)) if loc.any() else None,
                   "L_at_depth_delta_median_over_delta": Lz / dl, "L_at_depth_delta_p90max_over_delta": Lz90 / dl,
                   "side_distance_over_delta": dist_side / dl, "bottom_distance_over_delta": dist_bottom / dl})
out["skin_depth"] = sd
out["domain"] = {"box": dom.tolist(), "site_to_side_km": dist_side, "surface_to_bottom_km": dist_bottom,
                 "air_thickness_km": float(z0 - dom[2, 0])}

# ------------------------------------------------------------------ print
print(f"nodes {nn}  elements {ne} (air {out['counts']['air_elements']}, earth {out['counts']['earth_elements']})  "
      f"edges {out['counts']['edges']}")
print(f"parameter cells {ncell} (incl. air cell 0); earth-surface faces {len(es)}; outer faces {out['counts']['outer_faces']}")
print(f"surface face list: {out['surface_face_owner']}")
print("\nearth-surface triangle edges (km):")
for k, v in surf.items():
    print(f"  {k:32s} {fq(v)}")
print("\ntets with a face on the surface (km):")
for side in tt:
    for k, v in tt[side].items():
        print(f"  {side:5s} {k:30s} {fq(v)}")
print("\ntets touching the surface with >= 1 node (km):")
for side in tch:
    for k, v in tch[side].items():
        print(f"  {side:5s} {k:30s} {fq(v) if isinstance(v, dict) else v}")
print("\nshells (centroid depth for earth, height for air):")
for r in sh:
    print(f"  {r['shell_km']:>7s} earth {r['earth_elements']:>8d} (under footprint {r['earth_elements_under_footprint']:>7d}, r<=10.5 {r['earth_elements_r_le_10.5']:>7d})"
          f"  air {r['air_elements']:>8d}  earth mean-edge median {r['earth_mean_edge_all'].get('median', float('nan')):.3f}"
          f"  under footprint {r['earth_mean_edge_under_footprint'].get('median', float('nan')):.3f}")
print("\nsize profile, core column (r <= max(10.5, z/2) km): z range, n, median mean-edge, p90 max-edge")
for r in prof2:
    print(f"  {r['z_lo']:9.4f}-{r['z_hi']:9.4f}  {r['n']:>8d}  {r['median_mean_edge']:.4f}  {r['p90_max_edge']:.4f}")
print("\nsites:")
for k, v in out["sites_summary"].items():
    print(f"  {k:32s} {fq(v) if isinstance(v, dict) else v}")
print("\nparameter cells:")
for k, v in cells.items():
    if k == "by_depth":
        for r in v:
            print(f"  depth {r['shell_km']:>7s}: {r['cells']:>6d} cells; equiv size {fq(r['equiv_size'], nd=3)}")
            print(f"  {'':15s} horiz extent {fq(r['horiz_extent'], nd=3)}")
    elif isinstance(v, dict) and "n" not in v:
        print(f"  {k}: " + "; ".join(f"{kk} {fq(vv, nd=3) if isinstance(vv, dict) else vv}" for kk, vv in v.items()))
    else:
        print(f"  {k}: {fq(v, nd=3) if isinstance(v, dict) else v}")
print("\nskin depth vs size (ratios are size/delta):")
print("   f(Hz)      rho  delta(km)  siteTri/d(max)  ownerDepth/d(max)  ringMax/d ringMed/d  loc_n  locEmean/d(med) locEmax/d(p90) locEmax/d(max)  L(z=d)/d  side/d  bottom/d")
for r in sd:
    print(f"  {r['f_hz']:9.4g} {r['rho']:6g} {r['delta_km']:9.4f}  {r['site_tri_max_edge_over_delta_max']:13.3f}  "
          f"{r['earth_el_depth_over_delta_max']:16.3f}  {r['surface_edges_within_delta_of_site_max_over_delta'] or float('nan'):9.3f}"
          f" {r['surface_edges_within_delta_of_site_median_over_delta'] or float('nan'):9.3f}"
          f"  {r['local_earth_tets_within_delta_of_site']:7d}  {r['local_emean_median_over_delta'] or float('nan'):14.3f}"
          f" {r['local_emax_p90_over_delta'] or float('nan'):14.3f} {r['local_emax_max_over_delta'] or float('nan'):14.3f}"
          f"  {r['L_at_depth_delta_median_over_delta']:8.3f}  {r['side_distance_over_delta']:6.2f}  {r['bottom_distance_over_delta']:7.2f}")
if a.json:
    with open(a.json, "w", newline="\n") as f:
        json.dump(out, f, indent=1)
    print(f"\nwrote {a.json}")
