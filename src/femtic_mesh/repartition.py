"""Re-partition an existing mesh.dat into parameter cells, without remeshing (the D3 instrument).

  python -m femtic_mesh.repartition MESH.dat --attr resistivity_attr.dat [--out BLOCK.dat] [rule options]
         [--compare resistivity_block_iter0.dat] [--report report.json]

mesh.dat does not record region attributes, so air and earth are recovered geometrically: the air is every
element reachable from the top face list (-Z) without crossing an Earth-surface face. This is valid for
two-row resistivity_attr.dat files (air + one earth row), the land-only case (Vulcan); more rows raise
NotImplementedError. Coordinates come from mesh.dat (10 significant digits), not from tetgen's .node file, so a
centroid near-tie can in principle sort differently from TetGen2Femtic; --compare reports any element whose
cell differs.
"""
import argparse
import json
import sys
import time

import numpy as np

from . import cells
from .io import femtic as femtic_io


def air_from_surface(mesh):
    """Boolean mask of air elements: flood fill from the -Z (top) face list, blocked at Earth-surface faces.
    Raises ValueError if the result contradicts the Earth-surface list."""
    neigh = mesh.neigh.astype(np.int64)
    adj = neigh.copy()
    surf = mesh.faces[femtic_io.EARTH_SURFACE].astype(np.int64)
    e, k = surf[:, 0], surf[:, 1]
    a = neigh[e, k]
    if (a < 0).any():
        raise ValueError("an Earth-surface face has no element across it")
    g = np.argmax(neigh[a] == e[:, None], axis=1)
    if not (neigh[a, g] == e).all():
        raise ValueError("neighbour lists are not symmetric across the Earth surface")
    adj[e, k] = -1
    adj[a, g] = -1
    air = np.zeros(neigh.shape[0], dtype=bool)
    front = np.unique(mesh.faces[4][:, 0].astype(np.int64))
    air[front] = True
    while front.size:
        nb = adj[front].ravel()
        nb = nb[nb >= 0]
        nb = np.unique(nb[~air[nb]])
        air[nb] = True
        front = nb
    if air[e].any() or not air[a].all():
        raise ValueError("flood fill from the top crossed the Earth surface: the face lists are inconsistent")
    if air[mesh.faces[5][:, 0]].any():
        raise ValueError("flood fill from the top reached the bottom face list (+Z)")
    return air


def repartition(mesh, attr, rule=cells.USUI, progress=None):
    """(elem2blk, blk_row, air_mask) for a two-row resistivity_attr.dat."""
    if len(attr.regions) != 2:
        raise NotImplementedError("re-partitioning from mesh.dat needs a two-row resistivity_attr.dat (air, earth)")
    air = air_from_surface(mesh)
    row = np.where(air, 0, 1)
    C = cells.centroids(mesh.nodes, mesh.tets)
    field = cells.field_for(attr, rule)
    e2b, rows = cells.partition(C, row, attr.regions, field, rule, progress=progress)
    return e2b, rows, air


def _key(r):
    g = r["group"]
    return (r["kind"], int(g.size), int(g.min()) if g.size else -1, int(g.max()) if g.size else -1, int(g.sum()))


def explain_difference(C_ref, C_alt, elem_row, regions, field, rule=cells.USUI, rule_alt=None, factor=2.0):
    """Partition with reference centroids (e.g. from tetgen's .node) and alternative ones (e.g. from mesh.dat's
    10-digit coordinates) and trace every element whose cell differs to the decision that diverged.

    A divergence is a near-tie, i.e. explained by the coordinate shift s = max |C_ref - C_alt| over its group,
    when: the elements that changed side span no more than factor * s along the cut axis; or the two widest
    spreads differ by no more than 2 * factor * s (a different axis); or |spread - B| is no more than
    2 * factor * s + |B_ref - B_alt| (a different stop/split decision). Elements inside a divergent group follow
    it. Returns a dict; all_near_ties is True only if every divergence is a near-tie and no element is left
    unexplained."""
    ta, tb = [], []
    ea, ra = cells.partition(C_ref, elem_row, regions, field, rule, trace=ta)
    eb, rb = cells.partition(C_alt, elem_row, regions, field, rule_alt or rule, trace=tb)
    diff = np.flatnonzero(ea != eb)
    res = {"elements_different": int(diff.size), "cells_ref": int(ra.size), "cells_alt": int(rb.size),
           "divergences": []}
    idx = {}
    for r in tb:
        idx.setdefault(_key(r), []).append(r)
    covered = np.zeros(C_ref.shape[0], dtype=bool)
    for r in ta:
        g = np.sort(r["group"])
        q = next((x for x in idx.get(_key(r), []) if np.array_equal(np.sort(x["group"]), g)), None)
        if q is None or covered[g].any():
            continue
        if (r["split"] == q["split"] and r["axis"] == q["axis"]
                and (not r["split"] or np.array_equal(np.sort(r["left"]), np.sort(q["left"])))):
            continue
        shift = float(np.abs(C_ref[g] - C_alt[g]).max())
        ax = r["axis"]
        d = {"kind": r["kind"], "group_size": int(g.size), "shift_m": shift}
        if r["split"] != q["split"]:
            gap = abs(r["spread"] - r["B"])
            d.update(type="split decision", gap_m=gap, near_tie=gap <= 2 * factor * shift + abs(r["B"] - q["B"]))
        elif r["axis"] != q["axis"]:
            c = C_ref[g]
            sp = np.abs(c.max(axis=0) - c.min(axis=0))
            gap = abs(float(sp[r["axis"]] - sp[q["axis"]]))
            d.update(type="axis", gap_m=gap, near_tie=gap <= 2 * factor * shift)
        else:
            moved = np.setxor1d(r["left"], q["left"])
            x = C_ref[moved, ax]
            gap = float(x.max() - x.min())
            d.update(type="cut", axis=ax, moved=moved.tolist()[:20], gap_m=gap, near_tie=gap <= factor * shift)
        res["divergences"].append(d)
        covered[g] = True
    unexplained = int((~covered[diff]).sum())
    res["unexplained_elements"] = unexplained
    res["all_near_ties"] = unexplained == 0 and all(d["near_tie"] for d in res["divergences"])
    return res


TABLE_RULES = (cells.USUI, cells.CellRule(split="midpoint"), cells.CellRule(b_at="centroid"),
               cells.CellRule(min_split=10), cells.CellRule(use_sites=False), cells.CellRule(b_scale=1.5),
               cells.CellRule(b_scale=1.94), cells.CellRule(ell_scale=2.0), cells.CellRule(ell_scale=4.0),
               cells.CellRule(split="midpoint", ell_scale=4.0), cells.CellRule(split="midpoint", b_scale=1.5))


def rule_table(mesh, attr, rules=TABLE_RULES, log=print):
    """Cell reports for several rules on one mesh (no remesh). Returns a list of reports."""
    air = air_from_surface(mesh)
    row = np.where(air, 0, 1)
    C = cells.centroids(mesh.nodes, mesh.tets)
    out = []
    for rule in rules:
        t0 = time.perf_counter()
        e2b, rows = cells.partition(C, row, attr.regions, cells.field_for(attr, rule), rule)
        rep = cells.cell_report(mesh.nodes, mesh.tets, e2b, rows != 0)
        rep.update({"rule": rule.name, "seconds": round(time.perf_counter() - t0, 1)})
        out.append(rep)
        if log:
            log(f"  {rule.name}: {rep['earth_cells']} earth cells ({rep['seconds']} s)")
    return out


def table_markdown(reps):
    """Two markdown tables: cell counts per depth band, and median cell size (cbrt of volume) per band."""
    bands = [r["depth_km"] for r in reps[0]["by_depth"]]
    lab = [f"{a:g}-{b:g}" if b != float("inf") else f">{a:g}" for a, b in bands]
    h = "| rule | earth cells | 1 element | <= 5 elements | " + " | ".join(f"{x} km" for x in lab) + " |"
    lines = [h, "|" + "---|" * (4 + len(lab))]
    for r in reps:
        lines.append(f"| {r['rule']} | {r['earth_cells']:,} | {r['cells_1_element']:,} | {r['cells_le5_elements']:,} | "
                     + " | ".join(f"{b['cells']:,}" for b in r["by_depth"]) + " |")
    lines += ["", "| rule | median elements per cell | " + " | ".join(f"size {x} km" for x in lab) + " |",
              "|" + "---|" * (2 + len(lab))]
    for r in reps:
        lines.append(f"| {r['rule']} | {r['elements_per_cell']['median']:g} | "
                     + " | ".join(f"{b['size_km']['median']:.3f}" if b["cells"] else "-" for b in r["by_depth"]) + " |")
    return chr(10).join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="python -m femtic_mesh.repartition", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mesh", help="mesh.dat")
    ap.add_argument("--attr", required=True, help="resistivity_attr.dat used to build the mesh")
    ap.add_argument("--out", help="write the new resistivity_block_iter0.dat here")
    ap.add_argument("--split", default="median", choices=["median", "midpoint"])
    ap.add_argument("--b-at", default="extremes", choices=["extremes", "centroid"])
    ap.add_argument("--b-scale", type=float, default=1.0)
    ap.add_argument("--min-split", type=int, default=2)
    ap.add_argument("--no-sites", action="store_true")
    ap.add_argument("--ell-scale", type=float, default=1.0, help="multiply the ellipsoid rows' B only")
    ap.add_argument("--compare", help="an existing resistivity_block_iter0.dat to compare with, element by element")
    ap.add_argument("--report", help="write the cell report (JSON) here")
    ap.add_argument("--table", action="store_true",
                    help="run the standard set of rules (TABLE_RULES) and print markdown tables; rule options ignored")
    a = ap.parse_args(argv)
    if a.table:
        mesh = femtic_io.read_mesh_dat(a.mesh)
        reps = rule_table(mesh, femtic_io.read_resistivity_attr(a.attr))
        print(table_markdown(reps))
        if a.report:
            with open(a.report, "w") as fh:
                json.dump(reps, fh, indent=1, default=float)
        return 0
    rule = cells.CellRule(split=a.split, b_at=a.b_at, b_scale=a.b_scale, min_split=a.min_split,
                          use_sites=not a.no_sites, ell_scale=a.ell_scale)
    t0 = time.perf_counter()
    mesh = femtic_io.read_mesh_dat(a.mesh)
    attr = femtic_io.read_resistivity_attr(a.attr)
    e2b, rows, air = repartition(mesh, attr, rule)
    rep = cells.cell_report(mesh.nodes, mesh.tets, e2b, rows != 0)
    rep.update({"rule": rule.name, "cells_incl_air": int(rows.size), "air_elements": int(air.sum()),
                "seconds": round(time.perf_counter() - t0, 1)})
    print(f"rule {rule.name}: {rows.size} cells incl. air ({rep['earth_cells']} earth), "
          f"{rep['cells_1_element']} with 1 element, {rep['cells_le5_elements']} with <= 5")
    status = 0
    if a.compare:
        old = femtic_io.read_resistivity_blocks(a.compare)
        nd = int((old.elem2blk != e2b).sum()) if old.elem2blk.size == e2b.size else -1
        rep["compare"] = {"file": a.compare, "cells": old.n_cells, "elements_different": nd}
        print(f"compare: {old.n_cells} cells in {a.compare}; elements in a different cell: {nd}")
        status = 0 if nd == 0 and old.n_cells == rows.size else 1
    if a.out:
        femtic_io.write_resistivity_blocks(a.out, femtic_io.blocks_from_partition(e2b, rows, attr))
        print(f"wrote {a.out}")
    if a.report:
        with open(a.report, "w") as fh:
            json.dump(rep, fh, indent=1)
    return status


if __name__ == "__main__":
    sys.exit(main())
