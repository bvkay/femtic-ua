"""Parameter cells (resistivity blocks): TetGen2Femtic's partition and alternative rules.

rule USUI reproduces TetGen2Femtic @ceb8bfb makeResistivityBlock (MeshData.cpp:1891-2436) exactly:
  - elements grouped by resistivity_attr.dat row; the air row (row 0) and every row with ndiv < 0 stay one cell;
  - ndiv forced rounds split every group of >= 2 elements (divideElementVecs, 1962-1982);
  - if there are ellipsoids, groups are split until the centroid spread along the widest axis is below
    min(B at the two extreme elements) (divideBlockUntilRequiredLength, 2001-2086);
  - a split sorts the group by (centroid coordinate, element) along the widest axis (ties: the higher axis) and
    cuts at ceil(n/2) (divide, 2089-2129); the cut-off part is appended to the group list;
  - centroids are ((((0 + x0) + x1) + x2) + x3) * 0.25 (2388-2436); pow(x, 2) is x*x, as GCC compiles it;
  - B is calcBlockLength (2151-2354) with PI = 3.14159265359. atan2, tan and hypot come from numpy, i.e. this
    platform's libm, so a near-tie in the ellipsoid transition zones can differ from the glibc build.
A cell's elements are numbered the C++ way: rows in resistivity_attr.dat order, groups in list order.
Rule USUI is a translation of TetGen2Femtic (Copyright (c) 2021 Yoshiya Usui, MIT licence; see
LICENSE_TetGen2Femtic.txt).
"""
from dataclasses import dataclass
import math

import numpy as np

PI = 3.14159265359
DEG2RAD = PI / 180.0


@dataclass(frozen=True)
class CellRule:
    """A partition rule. The defaults are TetGen2Femtic's (USUI)."""
    split: str = "median"       # 'median': cut at ceil(n/2) by count; 'midpoint': cut at the middle of the spread
    b_at: str = "extremes"      # 'extremes': min(B) at the two extreme elements; 'centroid': B at the mean centroid
    b_scale: float = 1.0        # multiplies B (global coarsening if > 1)
    min_split: int = 2          # groups with fewer elements are never split by the length criterion
    use_sites: bool = True      # False drops the site circles from B (ellipsoids only)
    ell_scale: float = 1.0      # multiplies the ellipsoid rows' B only (site circles unchanged)

    @property
    def name(self):
        if self == USUI:
            return "usui"
        parts = []
        if self.split != "median":
            parts.append(f"split={self.split}")
        if self.b_at != "extremes":
            parts.append(f"B@{self.b_at}")
        if self.b_scale != 1.0:
            parts.append(f"Bx{self.b_scale:g}")
        if self.min_split != 2:
            parts.append(f"min_split={self.min_split}")
        if not self.use_sites:
            parts.append("no_sites")
        if self.ell_scale != 1.0:
            parts.append(f"ellBx{self.ell_scale:g}")
        return ",".join(parts)


USUI = CellRule()


class BlockLengthField:
    """B(point): the largest allowed cell length, metres (TetGen2Femtic calcBlockLength)."""

    def __init__(self, attr, use_sites=True, ell_scale=1.0):
        sph = np.asarray(attr.spheres_km, dtype=np.float64).reshape(-1, 4)
        self.ns = len(sph)
        self.center = np.array([attr.center_km[0] * 1.0e3, attr.center_km[1] * 1.0e3, attr.center_km[2] * 1.0e3])
        rot = attr.rotation_deg * DEG2RAD
        self.cr, self.sr = math.cos(-rot), math.sin(-rot)
        self.R, self.Bm = sph[:, 0] * 1.0e3, sph[:, 1] * 1.0e3
        if ell_scale != 1.0:
            self.Bm = self.Bm * ell_scale
        self.oh, self.ov = sph[:, 2], sph[:, 3]
        self.sites = []
        if use_sites:
            for xyz, rr, ll in zip(attr.sites_xyz_km, attr.site_radii_km, attr.site_lengths_km):
                if len(rr) == 0:
                    raise ValueError("a site with no circles (TetGen2Femtic reads radius[0] of an empty list)")
                self.sites.append((xyz * 1.0e3, np.asarray(rr) * 1.0e3, np.asarray(ll) * 1.0e3))

    def _local(self, P):
        vxo = P[:, 0] - self.center[0]
        vyo = P[:, 1] - self.center[1]
        vx = vxo * self.cr - vyo * self.sr
        vy = vxo * self.sr + vyo * self.cr
        vz = P[:, 2] - self.center[2]
        return vx, vy, vz

    def _inside(self, vx, vy, vz, i):
        long_ = self.R[i]
        short = long_ * (1.0 - self.oh[i])
        depth = long_ * (1.0 - self.ov[i])
        a, b, c = vx / long_, vy / short, vz / depth
        return (a * a + b * b) + c * c <= 1.0

    def _on_ellipsoid(self, aH, aV, i):
        long_ = self.R[i]
        short = long_ * (1.0 - self.oh[i])
        vert = long_ * (1.0 - self.ov[i])
        eps = 1.0e-9
        th = np.tan(aH)
        cH = long_ * short / np.hypot(short, long_ * th)
        lenH = np.hypot(cH, cH * th)
        lenH = np.where((np.abs(aH - PI * 0.5) < eps) | (np.abs(aH + PI * 0.5) < eps), short, lenH)
        tv = np.tan(aV)
        cV = lenH * vert / np.hypot(vert, lenH * tv)
        out = np.hypot(cV, cV * tv)
        return np.where((np.abs(aV - PI * 0.5) < eps) | (np.abs(aV + PI * 0.5) < eps), vert, out)

    def ellipsoid_length(self, P):
        """(L, bad): the ellipsoid part of B; bad marks points where TetGen2Femtic exits ("does't locate in the
        trasition region"), which happens only if such a point is ever evaluated."""
        n = P.shape[0]
        L = np.full(n, 1.0e20)
        bad = np.zeros(n, dtype=bool)
        if self.ns == 0:
            return L, bad
        vx, vy, vz = self._local(P)
        ins = np.stack([self._inside(vx, vy, vz, i) for i in range(self.ns)])
        L[ins[0]] = self.Bm[0]
        out = ~ins[0] & ~ins[-1]
        L[out] = self.Bm[-1]
        todo = ~ins[0] & ins[-1]
        for i in range(1, self.ns):
            m = todo & ins[i]
            if m.any():
                x, y, z = vx[m], vy[m], vz[m]
                aH = np.arctan2(y, x)
                lH = np.hypot(y, x)
                aV = np.arctan2(z, lH)
                ln = np.hypot(lH, z)
                l0 = self._on_ellipsoid(aH, aV, i - 1)
                l1 = self._on_ellipsoid(aH, aV, i)
                bad[m] = ln < l0
                L[m] = (ln - l0) / (l1 - l0) * (self.Bm[i] - self.Bm[i - 1]) + self.Bm[i - 1]
            todo &= ~m
        return L, bad

    def site_length(self, P):
        L = np.full(P.shape[0], 1.0e20)
        for xyz, rr, ll in self.sites:
            dx, dy, dz = P[:, 0] - xyz[0], P[:, 1] - xyz[1], P[:, 2] - xyz[2]
            r = np.sqrt((dx * dx + dy * dy) + dz * dz)
            m0 = r <= rr[0]
            L = np.where(m0, np.minimum(L, ll[0]), L)
            rest = ~m0
            for i in range(len(rr) - 1, 0, -1):
                rest = rest & (r <= rr[i])
                if not rest.any():
                    break
                lt = ll[i - 1] + (r - rr[i - 1]) / (rr[i] - rr[i - 1]) * (ll[i] - ll[i - 1])
                L = np.where(rest, np.minimum(L, lt), L)
        return L

    def __call__(self, P):
        """(B, bad) at points P (n, 3), metres."""
        P = np.asarray(P, dtype=np.float64).reshape(-1, 3)
        Le, bad = self.ellipsoid_length(P)
        return np.minimum(self.site_length(P), Le), bad


def field_for(attr, rule=USUI):
    """The BlockLengthField a rule needs."""
    return BlockLengthField(attr, use_sites=rule.use_sites, ell_scale=rule.ell_scale)


def centroids(nodes, tets):
    """TetGen2Femtic's calcGravityCenter{X,Y,Z}: ((((0 + x0) + x1) + x2) + x3) * 0.25, per axis."""
    c = np.zeros((tets.shape[0], 3))
    for k in range(4):
        c += nodes[tets[:, k]]
    return c * 0.25


# ------------------------------------------------------------------------------------------------ partition
def _median_cut(n):
    """TetGen2Femtic's iMid = iEnd / 2 + iEnd % 2."""
    return n // 2 + n % 2


def _sorted_along(g, c):
    """Group order along one axis: by (coordinate, element), as std::sort on pair<double, int>."""
    return g[np.lexsort((g, c))]


def _axis(c):
    """(axis, spread): widest centroid spread; ties go to the higher axis (sorted pair<double, int>.back())."""
    d = np.abs(c.max(axis=0) - c.min(axis=0))
    axis = 2 - int(np.argmax(d[::-1]))
    return axis, float(d[axis])


def _split(g, c, axis, rule):
    if rule.split == "median":
        s = _sorted_along(g, c[:, axis])
        m = _median_cut(len(g))
        return s[:m], s[m:]
    if rule.split == "midpoint":
        x = c[:, axis]
        mid = 0.5 * (x.min() + x.max())
        left = x < mid
        return np.sort(g[left]), np.sort(g[~left])
    raise ValueError(f"unknown split rule {rule.split!r}")


def _forced_rounds(groups, ndiv, C, rule, trace=None):
    """divideElementVecs: ndiv rounds, each splitting every group of >= 2 elements."""
    for _ in range(ndiv):
        num = len(groups)
        split_any = False
        for i in range(num):
            g = groups[i]
            if len(g) < 2:
                continue
            c = C[g]
            axis, _ = _axis(c)
            g1, g2 = _split(g, c, axis, rule)
            if trace is not None:
                trace.append({"kind": "forced", "group": g, "axis": axis, "spread": None, "B": None,
                              "split": True, "left": g1})
            groups[i] = g1
            groups.append(g2)
            split_any = True
        if not split_any:
            break
    return groups


def _length_rounds(groups, C, field, rule, n_elements, progress=None, trace=None):
    """divideBlockUntilRequiredLength: passes over the group list until no group needs splitting."""
    done = [False] * len(groups)
    for icount in range(n_elements):
        pend = []
        for iv in range(len(groups)):
            if done[iv]:
                continue
            g = groups[iv]
            if len(g) < max(2, rule.min_split):
                done[iv] = True
                continue
            c = C[g]
            axis, spread = _axis(c)
            pend.append((iv, g, c, axis, spread))
        if not pend:
            return groups
        if rule.b_at == "extremes":
            ends = np.empty((len(pend), 2), dtype=np.int64)
            for j, (iv, g, c, axis, spread) in enumerate(pend):
                x = c[:, axis]
                ends[j, 0] = g[x == x.min()].min()      # front of the sorted (coordinate, element) stack
                ends[j, 1] = g[x == x.max()].max()      # back
            B, bad = field(C[ends.ravel()])
            if bad.any():
                e = int(ends.ravel()[np.flatnonzero(bad)[0]])
                raise RuntimeError(f"element {e}: centroid {C[e].tolist()} is inside a transition ellipsoid but "
                                   "inside the inner one too (TetGen2Femtic exits: does't locate in the "
                                   "trasition region)")
            B = np.minimum(B[0::2], B[1::2])
        elif rule.b_at == "centroid":
            B, bad = field(np.array([c.mean(axis=0) for (_, _, c, _, _) in pend]))
            if bad.any():
                raise RuntimeError("a group centroid fell in an inconsistent transition zone")
        else:
            raise ValueError(f"unknown b_at {rule.b_at!r}")
        if rule.b_scale != 1.0:
            B = B * rule.b_scale
        for (iv, g, c, axis, spread), b in zip(pend, B.tolist()):
            if spread < b:
                done[iv] = True
                if trace is not None:
                    trace.append({"kind": "length", "group": g, "axis": axis, "spread": spread, "B": b,
                                  "split": False, "left": None})
                continue
            g1, g2 = _split(g, c, axis, rule)
            if trace is not None:
                trace.append({"kind": "length", "group": g, "axis": axis, "spread": spread, "B": b,
                              "split": True, "left": g1})
            groups[iv] = g1
            groups.append(g2)
            done.append(False)
        if progress:
            progress(icount, len(groups), len(pend))
    raise RuntimeError(f"Loop count reach maximum value : {n_elements}")


def partition(C, elem_row, regions, field=None, rule=USUI, div_all=False, progress=None, trace=None):
    """Cells for all elements. C: (M, 3) element centroids (metres); elem_row: (M,) resistivity_attr.dat row of
    each element; regions: the rows (dicts with 'ndiv'); field: BlockLengthField (None or 0 ellipsoids = no
    length criterion). Returns (elem2blk (M,) int32, blk_row (K,) int32). If trace is a list, every split
    decision is appended to it (group, axis, spread, B, split, left part), for explain_difference."""
    M = C.shape[0]
    elem_row = np.asarray(elem_row)
    groups_all, rows = [], []
    for r, reg in enumerate(regions):
        elems = np.flatnonzero(elem_row == r).astype(np.int64)
        if r == 0 or reg["ndiv"] < 0:
            groups = [elems]
        elif div_all:
            groups = [elems[i:i + 1] for i in range(elems.size)]
        else:
            groups = _forced_rounds([elems], reg["ndiv"], C, rule, trace)
            if field is not None and field.ns > 0:
                groups = _length_rounds(groups, C, field, rule, M, progress, trace)
        groups_all += groups
        rows += [r] * len(groups)
    elem2blk = np.full(M, -1, dtype=np.int32)
    for k, g in enumerate(groups_all):
        elem2blk[g] = k
    if (elem2blk < 0).any():
        raise ValueError("some elements belong to no resistivity_attr.dat row")
    return elem2blk, np.array(rows, dtype=np.int32)


# ---------------------------------------------------------------------------------------------- cell report
DEPTH_BINS_KM = (0.0, 0.2, 1.0, 5.0, 20.0, 100.0, np.inf)


def cell_report(nodes_m, tets, elem2blk, earth_cells, surface_z_km=0.0, bins=DEPTH_BINS_KM):
    """Cell counts and size versus depth, with mesh_stats.py's definitions: cell volume = sum of element
    volumes, cell centre = volume-weighted mean of element centroids, size = cbrt(volume), depth = centre z -
    surface. earth_cells: boolean mask over cells (True = earth)."""
    P = nodes_m[tets] / 1000.0
    vol = np.abs(np.einsum("ij,ij->i", P[:, 1] - P[:, 0], np.cross(P[:, 2] - P[:, 0], P[:, 3] - P[:, 0]))) / 6.0
    cen = P.mean(axis=1)
    del P
    nc = int(earth_cells.size)
    cvol = np.bincount(elem2blk, weights=vol, minlength=nc)
    cz = np.bincount(elem2blk, weights=vol * cen[:, 2], minlength=nc) / np.maximum(cvol, 1e-300)
    nel = np.bincount(elem2blk, minlength=nc)
    ec = np.flatnonzero(earth_cells)
    eq, depth, ne = np.cbrt(cvol[ec]), cz[ec] - surface_z_km, nel[ec]

    def q(v):
        if v.size == 0:
            return {"n": 0}
        return {"n": int(v.size), "p10": float(np.percentile(v, 10)), "median": float(np.median(v)),
                "p90": float(np.percentile(v, 90))}
    rows = []
    for a, b in zip(bins[:-1], bins[1:]):
        m = (depth >= a) & (depth < b)
        rows.append({"depth_km": (a, b), "cells": int(m.sum()), "size_km": q(eq[m]), "elements": q(ne[m])})
    return {"earth_cells": int(ec.size), "cells_1_element": int((ne == 1).sum()),
            "cells_le5_elements": int((ne <= 5).sum()), "elements_per_cell": q(ne), "size_km": q(eq),
            "by_depth": rows}
