"""Faithful Python port of makeMtr (github.com/yoshiya-usui/makeMtr @df8e207; Copyright (c) 2021 Yoshiya Usui, MIT
licence: see LICENSE_makeMtr.txt in this package).

  python -m femtic_mesh.makemtr ROOT          (the C++: makeMtr ROOT)

reads makeMtr.param and obs_site.dat from the current directory and ROOT.node / ROOT.ele (tetgen output), and
writes ROOT.mtr: '%10d%10d' (nodes, 1), then one '%15.6e' edge length [km] per node, the size field tetgen -m reads.
Its stdout is the C++'s log, line for line (main.cpp:170-514, ObservationPoint.cpp:65-103, ObservationLine.cpp:112-146).

Per node (main.cpp:516-554): L = min(site spheres and observation lines, sea ellipses, the nested ellipsoids of
makeMtr.param, interpolated between shells). Kept from the C++: PI = 3.14159265359 (main.cpp:68); pow(x, 2) as x*x,
which GCC -O2 folds; the C++ order of every operation; the site interpolation quirk
val1 = sqrt(3 (r[i+1]/r[i])^2) (ObservationPoint.cpp:135); the second line end-point overwriting the first
(ObservationLine.cpp:55-74); counts missing at the end of a file read as 0 (main.cpp:298, 382).
atan2, tan and hypot come from numpy, i.e. this platform's C library, not glibc: shell nodes may differ by an ulp,
which the 7-digit text hides except at a rounding boundary (docs/dev/mesh_port_feasibility_2026-10-06.md s2.2).
Not compiled in the C++ build used by the chain: the _FINE_SURF block (main.cpp:181-222, 522-528).
Every C++ exit(1) becomes MakeMtrError with the C++ message; the CLI prints it and exits 1. Unlike the C++, the port
writes no partial .mtr on such an error, and it refuses a .node file with attributes or markers (the C++ reads four
values per node and would misread it) and non-integer counts (the C++ would read '4.0' as 4, then '.0').
"""
import math
import sys

import numpy as np

from .io import tetgen as tetgen_io
from .io.makemtr_inputs import PI, MakeMtrError, read_params, read_sites  # noqa: F401 (re-exported)

EPS = 1.0e-12                         # main.cpp:69
BIG = 1.0e+20




def _on_ellipsoid(H, V, A, B, C):
    """calculateLengthOnEllipsoid (main.cpp:800-839): centre-to-surface length along (H, V); axes A, B, C per node."""
    eps = 1.0e-9
    tH = np.tan(H)
    cv = A * B / np.hypot(B, A * tH)
    lH = np.where((np.abs(H - PI * 0.5) < eps) | (np.abs(H + PI * 0.5) < eps), B, np.hypot(cv, cv * tH))
    tV = np.tan(V)
    cv = lH * C / np.hypot(C, lH * tV)
    return np.where((np.abs(V - PI * 0.5) < eps) | (np.abs(V + PI * 0.5) < eps), C, np.hypot(cv, cv * tV))


def _ellipsoids(P, X, Y, Z):
    """The ellipsoid part of calcEdgeLength (main.cpp:534-547, 587-621, 694-797). Returns (values, error), error
    being (node index, message) of the first node outside its transition region, or None."""
    n, a, L = P["r"].size, P["r"], P["L"]
    cr, sr = math.cos(-P["rot"]), math.sin(-P["rot"])
    vxo, vyo = X - P["c"][0], Y - P["c"][1]
    vx = vxo * cr - vyo * sr
    vy = vxo * sr + vyo * cr
    vz = Z - P["c"][2]
    air = vz < 0.0                                                 # iType: AIR when vecZ < 0
    b, dE, dA = a * (1.0 - P["fh"]), a * (1.0 - P["fe"]), a * (1.0 - P["fa"])
    ins = np.empty((n, X.size), dtype=bool)
    for k in range(n):
        t1, t2, t3 = vx / a[k], vy / b[k], vz / np.where(air, dA[k], dE[k])
        ins[k] = t1 * t1 + t2 * t2 + t3 * t3 <= 1.0
    out = np.where(ins[0], L[0], L[n - 1])                         # inside sphere 0, or outside the last
    tr = np.flatnonzero(~ins[0] & ins[n - 1])
    if tr.size == 0:
        return out, None
    k = np.argmax(ins[1:, tr], axis=0) + 1                         # the first sphere k >= 1 holding the node
    tx, ty, tz, ta = vx[tr], vy[tr], vz[tr], air[tr]
    H = np.arctan2(ty, tx)
    lh = np.hypot(ty, tx)
    V = np.arctan2(tz, lh)
    ln = np.hypot(lh, tz)
    if (np.abs(H) > PI).any() or (np.abs(V) > PI).any():
        raise MakeMtrError("Horizontal angle is improper" if (np.abs(H) > PI).any() else "Vertical angle is improper")
    l0 = _on_ellipsoid(H, V, a[k - 1], b[k - 1], np.where(ta, dA[k - 1], dE[k - 1]))
    l1 = _on_ellipsoid(H, V, a[k], b[k], np.where(ta, dA[k], dE[k]))
    out[tr] = (ln - l0) / (l1 - l0) * (L[k] - L[k - 1]) + L[k - 1]
    bad = np.flatnonzero((ln <= l0 - 1.0e-10) | (ln >= l1 + 1.0e-10))
    if bad.size == 0:
        return out, None
    j, g = bad[0], "%g"
    msg = (f"Specified coordinate ( {g % X[tr[j]]}, {g % Y[tr[j]]}, {g % Z[tr[j]]} ) does't locate in the trasition "
           f"region\niSphere : {k[j]}\nvecX : {g % tx[j]}\nvecY : {g % ty[j]}\nvecZ : {g % tz[j]}\n"
           f"lengthHorizontal      : {g % lh[j]}\nangleH : {g % H[j]}\nangleV : {g % V[j]}\n"
           f"length  : {g % ln[j]}\nlength0 : {g % l0[j]}\nlength1 : {g % l1[j]}")
    return out, (int(tr[j]), msg)


def _sites(sites, X, Y, Z, best):
    """ObservationPoint::calcMaximumLengthOfPoint (ObservationPoint.cpp:107-160) for every site, folded into best with
    the C++'s 'if( length < edgeLength )'. Only nodes inside a site's bounding box (all its spheres, with a margin far
    above rounding) can be inside its sphere 0 or its last sphere; every other node gets 1e+20 from that site."""
    order = np.argsort(X, kind="stable")
    xs = X[order]
    for (sx, sy, sz), r, L, f in sites:
        m, d = r.size, r * (1.0 - f)
        R, D = r.max() * (1 + 1e-6) + 1e-12, d.max() * (1 + 1e-6) + 1e-12
        idx = order[np.searchsorted(xs, sx - R, "left"):np.searchsorted(xs, sx + R, "right")]
        idx = idx[(np.abs(Y[idx] - sy) <= R) & (np.abs(Z[idx] - sz) <= D)]
        if idx.size == 0:
            continue
        vx, vy, vz = X[idx] - sx, Y[idx] - sy, Z[idx] - sz
        q = np.empty((m, idx.size))
        for i in range(m):
            t1, t2, t3 = vx / r[i], vy / r[i], vz / d[i]
            q[i] = t1 * t1 + t2 * t2 + t3 * t3
        ins = q <= 1.0
        v = np.where(ins[0], L[0], BIG)
        sh = ~ins[0] & ins[m - 1]
        if sh.any():
            i = np.zeros(idx.size, dtype=np.intp)                  # scan m-2 .. 1: the first sphere NOT holding it
            done = np.zeros(idx.size, dtype=bool)
            for j in range(m - 2, 0, -1):
                hit = ~done & ~ins[j]
                i[hit] = j
                done |= hit
            val = np.sqrt(np.take_along_axis(q, i[None, :], axis=0)[0])
            rr = r[i + 1] / r[i]
            val1 = np.sqrt(3.0 * (rr * rr))                        # the C++ quirk, kept (ObservationPoint.cpp:135)
            v = np.where(sh, L[i] + (L[i + 1] - L[i]) * (val - 1.0) / (val1 - 1.0), v)
        cur = best[idx]
        best[idx] = np.where(v < cur, v, cur)
    return best


def _line(ends, r, L, X, Y, Z):
    """ObservationLine::calcMaximumLengthOfPoint (ObservationLine.cpp:52-109), including its overwrites: each end
    point and then the segment assign the interpolated length instead of taking a minimum."""
    def interp(rad, i):
        return L[i - 1] + (rad - r[i - 1]) / (r[i] - r[i - 1]) * (L[i] - L[i - 1])

    def layers(e, rad, act):
        h0 = act & (rad <= r[0])
        e[h0] = np.where(e[h0] < L[0], e[h0], L[0])                # std::min( L[0], edgeLeng )
        rest = act & ~h0
        for i in range(r.size - 1, 0, -1):                         # the C++ breaks at the first layer not holding it
            rest = rest & (rad <= r[i])
            e[rest] = interp(rad[rest], i)
        return h0
    e = np.full(X.size, BIG)
    stop = np.zeros(X.size, dtype=bool)
    for p in (0, 1):
        vx, vy, vz = X - ends[p, 0], Y - ends[p, 1], Z - ends[p, 2]
        stop |= layers(e, np.sqrt(vx * vx + vy * vy + vz * vz), ~stop)
    dx, dy, dz = ends[1] - ends[0]
    ll = math.sqrt(dx * dx + dy * dy + dz * dz)
    ux, uy, uz = X - ends[0, 0], Y - ends[0, 1], Z - ends[0, 2]
    ipd = (ux * dx + uy * dy + uz * dz) / ll
    w = (ipd >= 0.0) & (ipd <= ll)
    px, py, pz = ux - ipd / ll * dx, uy - ipd / ll * dy, uz - ipd / ll * dz
    layers(e, np.sqrt(px * px + py * py + pz * pz), w)
    return e


def _sea(P, X, Y, Z, tets, attr):
    """locateInTheSea and calcEdgeLengthInTheSea (main.cpp:649-692): (node in the sea, sea edge length)."""
    node_in = np.zeros(X.size, dtype=bool)
    node_in[tets[np.isin(attr, P["sea_attr"])].ravel() - 1] = True
    e = np.full(X.size, BIG)
    for sx, sy, rot, rr in P["sea"]:
        ca, sa = math.cos(-rot), math.sin(-rot)
        hit = np.zeros(X.size, dtype=bool)
        for a, Lr, f in rr:                                        # the first ellipse holding the node, per region
            vxo, vyo = X - sx, Y - sy
            t1, t2 = (vxo * ca - vyo * sa) / a, (vxo * sa + vyo * ca) / (a * (1.0 - f))
            mk = ~hit & (t1 * t1 + t2 * t2 <= 1.0)
            e[mk] = np.where(Lr < e[mk], Lr, e[mk])
            hit |= mk
    return node_in, e


def size_field(xyz, P, sites, lines=(), tets=None, attr=None):
    """calcEdgeLength for every node (main.cpp:516-554). xyz (N, 3) km; tets (M, 4) 1-based and attr (M,) are needed
    only when makeMtr.param lists sea attributes. Returns (values, error): error is None or (node index, message,
    stream) of the first node at which the C++ would stop."""
    X, Y, Z = (np.ascontiguousarray(xyz[:, k], dtype=np.float64) for k in range(3))
    with np.errstate(all="ignore"):
        mv = _sites(sites, X, Y, Z, np.full(X.size, BIG))
        for ends, r, L in lines:
            ln = _line(ends, r, L, X, Y, Z)
            mv = np.where(ln < mv, ln, mv)
        if P["sea_attr"]:
            if tets is None:
                raise ValueError("makeMtr.param lists sea attributes: the elements are needed")
            node_in, se = _sea(P, X, Y, Z, tets, attr)
            mv = np.where(node_in & ~(mv < se), se, mv)            # std::min( sea, minVal )
        e, err = _ellipsoids(P, X, Y, Z)
        val = np.where(mv < e, mv, e)                              # std::min( ellipsoid, minVal )
    short = np.flatnonzero(val < EPS)
    if err is not None and (short.size == 0 or err[0] <= short[0]):
        return val, (err[0], err[1], "stderr")
    if short.size:
        return val, (int(short[0]), "Edge length is too short %.6e" % val[short[0]], "stdout")
    return val, None


def _read_nodes(path, out):
    """readNodeData (main.cpp:396-420)."""
    try:
        open(path, "rb").close()
    except OSError:
        raise MakeMtrError(f"Cannot open file {path}") from None
    out(f"Read node data from {path}")
    try:
        nd = tetgen_io.read_node(path)
    except ValueError as exc:
        raise MakeMtrError(str(exc)) from None
    out(f"Total number of nodes : {nd.xyz.shape[0]}")
    if nd.attrs.shape[1] or nd.markers is not None:
        raise MakeMtrError(f"{path}: node attributes or markers present; makeMtr reads 4 values per node and would "
                           "misread this file")
    return nd.xyz


def _read_elems(path, n_nodes, out):
    """readElemData (main.cpp:423-479)."""
    try:
        open(path, "rb").close()
    except OSError:
        raise MakeMtrError(f"Cannot open file {path}") from None
    out(f"Read element data from {path}")
    try:
        el = tetgen_io.read_ele(path)
    except ValueError as exc:
        raise MakeMtrError(str(exc)) from None
    out(f"Total number of elements : {el.ids.size}")
    if el.attrs.shape[1] != 1:
        raise MakeMtrError("You must specify region attribute to elements.")
    if not np.array_equal(el.ids, np.arange(1, el.ids.size + 1)):
        raise MakeMtrError("Element ID must be sequence number from 1!!")
    if el.tets.size and (el.tets.min() < 1 or el.tets.max() > n_nodes):
        raise MakeMtrError(f"{path}: node id out of range (the C++ would read outside its arrays)")
    return el.tets, el.attrs[:, 0]


def make_mtr(root, param="makeMtr.param", obs_site="obs_site.dat", out=print):
    """The whole of makeMtr ROOT: reads the inputs, writes ROOT.mtr, returns the values. Raises MakeMtrError."""
    P = read_params(param, out)
    sites, lines = read_sites(obs_site, out)
    xyz = _read_nodes(root + ".node", out)
    tets, attr = _read_elems(root + ".ele", xyz.shape[0], out)
    out(f"Write mesh size to {root}.mtr")
    val, err = size_field(xyz, P, sites, lines, tets, attr)
    if err is not None:
        raise MakeMtrError(err[1], err[2])
    tetgen_io.write_mtr(root + ".mtr", val, style="makemtr")
    return val


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    for stream in (sys.stdout, sys.stderr):                        # the C++'s LF log on every platform
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(newline="\n")
    if not argv:
        print("You must specify node file name !!", file=sys.stderr)
        return 1
    try:
        make_mtr(argv[0])
    except MakeMtrError as exc:
        sys.stdout.flush()
        print(str(exc), file=sys.stdout if exc.stream == "stdout" else sys.stderr)
        return 1
    except OSError as exc:
        print(f"makeMtr port FAILED: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
