"""The checks of hpc/phoenix_plan/mesh_chain.sh as functions, for femtic_mesh.chain: same rules, same numbers, same
wording in the messages the chain prints. Numbers that mesh_chain.sh prints through awk keep awk's look ('10', not
'10.0'); values read from a file and echoed by the shell keep the file's text.

  preflight: kw_file (control.dat's ALTITUDE / SEA_DEPTH file names), read_domain, res_attrs, seeds_used, seeds_check
  after tetgen: ele_attrs, attr_set, attr_hist, air_on_top
  products: first_field, volume_check, mesh_counts (the 'MESH COUNTS' line)
Every file is read whole except mesh.dat, which mesh_counts streams (Vulcan's is 256 MB).
"""
import os

import numpy as np

from .io import tetgen as tetgen_io


def awknum(v):
    """awk's print of a number: an integral value as an integer, else %.6g (CONVFMT)."""
    v = float(v)
    return "%d" % v if v.is_integer() and abs(v) < 1e16 else "%.6g" % v


def _awkval(tok):
    """awk's 'tok+0': the leading number of tok, or 0."""
    try:
        return float(tok)
    except ValueError:
        return 0.0


def _lines(path):
    with open(path, "r", encoding="ascii", errors="replace", newline=None) as fh:
        return fh.read().split("\n")


def kw_file(control, key):
    """The first field of the line after the first line whose first field is key ('' if none)."""
    ln = _lines(control)
    for i, s in enumerate(ln):
        f = s.split()
        if f and f[0] == key:
            g = ln[i + 1].split() if i + 1 < len(ln) else []
            return g[0] if g else ""
    return ""


def read_domain(path):
    """analysis_domain.dat: [(min_text, max_text)] for x, y, z, the first two fields of lines 1-3."""
    ln = _lines(path)
    out = []
    for i in range(3):
        f = ln[i].split() if i < len(ln) else []
        out.append(((f + ["", ""])[0], (f + ["", ""])[1]))
    return out


def res_attrs(path):
    """resistivity_attr.dat: (count, the declared attributes sorted as 'sort -n' does (repeats kept), the air's)."""
    ln = [s.split() for s in _lines(path)]
    n = int(_awkval(ln[0][0])) if ln and ln[0] else 0
    vals = [_awkval(f[0]) if f else 0.0 for f in ln[1:n + 1]]
    air = awknum(vals[0]) if vals else ""
    return n, " ".join(awknum(v) for v in sorted(vals)), air


def seeds_used(path):
    """region_seeds.dat -> the lines of region_seeds.used: every non-comment, non-blank line as 'x y z attr maxvol'
    (awk: print $1, $2, $3, $4+0, $5; a line short of fields keeps its gaps and fails seeds_check)."""
    out = []
    for s in _lines(path):
        f = s.split()
        if not f or s.lstrip().startswith("#"):
            continue
        f += [""] * (5 - len(f))
        out.append(" ".join([f[0], f[1], f[2], awknum(_awkval(f[3])) if f[3] else "0", f[4]]))
    return out


def seeds_check(used, dom):
    """mesh_chain.sh's seed rules. Returns (seed attribute set text, error message or None, offending lines)."""
    if len(used) < 2:
        return "", f"need at least 2 region seeds (air + earth), got {len(used)}", []
    if any(len(u.split()) != 5 for u in used):
        return "", "region_seeds: every line needs 5 fields: x y z attr maxvol", []
    lim = [(_awkval(a), _awkval(b)) for a, b in dom]
    bad = [u for u in used if not all(lim[k][0] < _awkval(u.split()[k]) < lim[k][1] for k in range(3))]
    if bad:
        return "", "region seed(s) outside the analysis domain", [f"seed outside analysis domain: {u}" for u in bad]
    s = sorted({_awkval(u.split()[3]) for u in used})
    return " ".join(awknum(v) for v in s), None, []


def ele_attrs(path):
    """The last field of every data line of a .ele file (its region attribute)."""
    vals = []
    for i, s in enumerate(_lines(path)):
        f = s.split()
        if i == 0 or not f or s.startswith("#"):
            continue
        vals.append(_awkval(f[-1]))
    return np.array(vals)


def attr_set(path):
    return " ".join(awknum(v) for v in np.unique(ele_attrs(path)))


def attr_hist(path):
    a = ele_attrs(path)
    u, c = np.unique(a, return_counts=True)
    return [f"  attr {awknum(v)} : {int(n)} elements" for v, n in zip(u, c)]


def _node_coords(root):
    nd = tetgen_io.read_node(root + ".node")
    ids = nd.ids.astype(np.int64)
    xyz = np.zeros((int(ids.max()) + 1 if ids.size else 1, 3))
    xyz[ids] = nd.xyz
    return xyz


def air_on_top(root, zmin, zmax, air):
    """(message, ok): every element touching the top plane z = zmin carries the air attribute, and none touching the
    bottom plane z = zmax does (catches swapped seeds, which every tool accepts with exit 0)."""
    zt, zb, air = _awkval(zmin), _awkval(zmax), _awkval(air)
    z = _node_coords(root)[:, 2]
    el = tetgen_io.read_ele(root + ".ele")
    eps = 1e-9 * (zb - zt)
    zz = z[el.tets]
    top = (zz - zt < eps).any(axis=1)
    bot = (zb - zz < eps).any(axis=1)
    at = el.attrs[:, -1] if el.attrs.shape[1] else el.tets[:, -1].astype(float)   # awk's $NF
    nt, bt, nb, bb = int(top.sum()), int((top & (at != air)).sum()), int(bot.sum()), int((bot & (at == air)).sum())
    msg = f"{root}: {nt} elements touch the top plane ({bt} not air), {nb} touch the bottom plane ({bb} air)"
    return msg, nt > 0 and nb > 0 and bt == 0 and bb == 0


def first_field(path, line_no=1):
    """The first field of line line_no (1-based), as text ('' if none): the shell's head | awk '{print $1}'."""
    with open(path, "r", encoding="ascii", errors="replace") as fh:
        for i, s in enumerate(fh, 1):
            if i == line_no:
                f = s.split()
                return f[0] if f else ""
    return ""


def volume_check(root, dom):
    """(sum |V| text, box volume text, relative error text, zero-volume count, ok): the elements of root.ele must
    fill the analysis box to 1e-6 with no zero-volume element. Formats as mesh_chain.sh prints them."""
    xyz = _node_coords(root)
    el = tetgen_io.read_ele(root + ".ele")
    a, b, c, d = (xyz[el.tets[:, k]] for k in range(4))
    u, v, w = b - a, c - a, d - a
    vol = (u[:, 0] * (v[:, 1] * w[:, 2] - v[:, 2] * w[:, 1]) - u[:, 1] * (v[:, 0] * w[:, 2] - v[:, 2] * w[:, 0])
           + u[:, 2] * (v[:, 0] * w[:, 1] - v[:, 1] * w[:, 0])) / 6
    vol = np.abs(vol)
    tot = float(np.cumsum(vol)[-1]) if vol.size else 0.0         # awk's running sum, in element order
    lim = [(_awkval(p), _awkval(q)) for p, q in dom]
    box = (lim[0][1] - lim[0][0]) * (lim[1][1] - lim[1][0]) * (lim[2][1] - lim[2][0])
    rel = abs((tot - box) / box)
    zero = int((vol == 0).sum())
    return "%.9e" % tot, "%.9e" % box, "%.2e" % rel, zero, float("%.2e" % rel) < 1e-6 and zero == 0


def mesh_counts(d):
    """'nodes N  tets N  cells N  surface_faces N  outer_faces N' from d/mesh.dat and line 1 of
    d/resistivity_block_iter0.dat (mesh_chain.sh mesh_counts). Raises ValueError if mesh.dat does not end exactly
    after its 7th face list or the two files disagree on the elements."""
    mp, bp = os.path.join(d, "mesh.dat"), os.path.join(d, "resistivity_block_iter0.dat")
    if not (os.path.getsize(mp) if os.path.exists(mp) else 0) or not (os.path.getsize(bp) if os.path.exists(bp) else 0):
        raise ValueError(f"mesh_counts: no mesh.dat or resistivity_block_iter0.dat in {d}")
    err, nn, ne, hasne, at, last, c = "", 0, 0, False, -1, 0, []
    with open(mp, "r", encoding="ascii", errors="replace") as fh:
        for i, s in enumerate(fh, 1):
            f = s.split()
            if f:
                last = i
            if i == 1:
                err = "" if f and f[0] == "TETRA" else "mesh.dat line 1 is not TETRA"
            elif i == 2:
                nn = int(_awkval(f[0])) if f else 0
                at = nn + 3
            elif i == at:
                if len(f) != 1 or not f[0].isdigit():
                    err = err or f"mesh.dat line {i} is not a count"
                elif not hasne:
                    ne, hasne, at = int(f[0]), True, i + int(f[0]) + 1
                else:
                    c.append(int(f[0]))
                    at = i + c[-1] + 1
    bf = first_field(bp, 1), _second(bp)
    if not err and (nn < 1 or ne < 1):
        err = "mesh.dat has no node or element count"
    if not err and len(c) != 7:
        err = f"mesh.dat has {len(c)} face lists, not 7"
    if not err and last != at - 1:
        err = f"mesh.dat ends at line {last}, its 7th face list at line {at - 1}"
    if not err and int(_awkval(bf[0])) != ne:
        err = f"resistivity_block_iter0.dat lists {int(_awkval(bf[0]))} elements, mesh.dat {ne}"
    if err:
        raise ValueError("mesh_counts: " + err)
    return (f"nodes {nn}  tets {ne}  cells {int(_awkval(bf[1]))}  surface_faces {c[6]}  "
            f"outer_faces {sum(c[:6])}")


def _second(path):
    with open(path, "r", encoding="ascii", errors="replace") as fh:
        f = fh.readline().split()
    return f[1] if len(f) > 1 else "0"


class CheckFailed(Exception):
    """A preflight check failed; the message is mesh_chain.sh's."""


def preflight(fd, wd, out=print):
    """mesh_chain.sh's preflight, on a copy: every file of fd is copied into wd; the inputs control.dat names must
    exist; CRLF becomes LF (noted in logs/preflight.txt); input_md5.txt records them; the domain's z range must
    straddle 0; region_seeds.used is written and the seeds checked. Returns (domain, seed attribute set text,
    resistivity_attr.dat attribute text, air attribute text, seed lines); raises CheckFailed."""
    import hashlib
    import re
    import shutil
    for f in sorted(os.listdir(fd)):
        if os.path.isfile(os.path.join(fd, f)):
            shutil.copy2(os.path.join(fd, f), os.path.join(wd, f))
    w = lambda f: os.path.join(wd, f)                              # noqa: E731
    alt, sea = kw_file(w("control.dat"), "ALTITUDE"), kw_file(w("control.dat"), "SEA_DEPTH")
    inputs = ["control.dat", "analysis_domain.dat", "observing_site.dat", "coast_line.dat", "obs_site.dat",
              "makeMtr.param", "resistivity_attr.dat"] + [f for f in (alt, sea) if f]
    inputs += (["lake.dat"] if os.path.isfile(w("lake.dat")) else []) + ["region_seeds.dat"]
    miss = [f for f in inputs if not os.path.isfile(w(f))]
    if miss:
        raise CheckFailed(f"missing input file(s) named by control.dat: {' '.join(miss)}")
    for f in inputs:
        with open(w(f), "rb") as fh:
            raw = fh.read()
        if b"\r" in raw:
            with open(w(f), "wb") as fh:
                fh.write(re.sub(rb"\r(?=\n|$)", b"", raw))
            out(f"note: converted CRLF -> LF in {f}")
            with open(w("logs/preflight.txt"), "a", newline="\n") as fh:
                fh.write(f"note: converted CRLF -> LF in {f}\n")
    with open(w("input_md5.txt"), "w", newline="\n") as fh:
        for f in inputs:
            with open(w(f), "rb") as b:
                fh.write(f"{hashlib.md5(b.read()).hexdigest()}  {f}\n")
    dom = read_domain(w("analysis_domain.dat"))
    if not (_awkval(dom[2][0]) < 0 < _awkval(dom[2][1])):
        raise CheckFailed(f"analysis_domain z range ({dom[2][0]}, {dom[2][1]}) must straddle 0")
    _, res, air = res_attrs(w("resistivity_attr.dat"))
    used = seeds_used(w("region_seeds.dat"))
    with open(w("region_seeds.used"), "w", newline="\n") as fh:
        fh.write("".join(u + "\n" for u in used))
    seed, why, lines = seeds_check(used, dom)
    for ln in lines:
        out(ln)
    if why:
        raise CheckFailed(why)
    if seed != res:
        raise CheckFailed(f"seeded attributes {{{seed}}} != resistivity_attr.dat attributes {{{res}}}")
    out("region seeds (x y z attr maxvol):\n" + "\n".join("  " + u for u in used))
    return dom, seed, res, air, used
