#!/usr/bin/env python3
"""make_acc_inputs.py -- inputs for the FEMTIC half-space forward accuracy test (halfspace_accuracy.md).

    python make_acc_inputs.py PREP_DIR MESH_RUN_DIR OUT_DIR RHO_OHMM [--batch K | --freqs F1,F2] [--threads NT]

PREP_DIR      output of scripts/prep_vulcan.py (reads inversion/observe.dat and inversion/control.dat)
MESH_RUN_DIR  ext4 mesh-chain run directory (reads mesh.dat and resistivity_block_iter0.dat)
OUT_DIR       femtic run directory to create/fill (mesh.dat is hard-linked, not copied)

Writes OUT_DIR/observe.dat   same station lines and VTF block as the prep output, 8 test frequencies,
                             dummy Z (analytic 10 ohm-m half-space, exp(-i omega t)) with 5 % errors
       OUT_DIR/resistivity_block_iter0.dat   every earth cell = RHO; air cell 0 untouched (must be fixed)
       OUT_DIR/control.dat   prep control.dat with NUM_THREADS NT (default 2), ITERATION 0 0, OUTPUT_PARAM_VTK 0
--batch K (1-4) writes only test frequencies 2K-1 and 2K of the 8 (PC resource policy: batches of 2);
without it all 8 are written. The 8 are always chosen from the full 53-band list, so a batch's two
bands are identical to the same two bands of an all-8 run. --freqs writes the given common bands instead
(supplementary checks outside the 8-band criterion runs).
Every file is re-read after writing and checked; any mismatch aborts (exit 1).
"""
import math
import os
import sys

TEST_REQ = [200, 60, 20, 6, 2, 0.6, 0.06, 0.006]
DUMMY_RHO = 10.0
MU0 = 4e-7 * math.pi


def die(msg):
    print("make_acc_inputs FAILED:", msg, file=sys.stderr)
    sys.exit(1)


def common_bands(table):
    """Bands held by all 120 sites (Vulcan/frequency_table.csv, n_sites == 120)."""
    out = []
    with open(table) as f:
        next(f)
        for line in f:
            fr, n, _ = line.strip().split(",")
            if int(n) == 120:
                out.append(float(fr))
    return out


def pick(bands):
    return [min(bands, key=lambda x: abs(math.log10(x) - math.log10(t))) for t in TEST_REQ]


def read_observe(path):
    lines = open(path).read().split("\n")
    i = 0
    hdr = lines[i].split()
    i += 1
    if hdr[0] != "MT":
        die(f"{path}: first block is {hdr[0]}, expected MT")
    nst = int(hdr[1])
    stations = []
    for _ in range(nst):
        st = lines[i].rstrip()
        i += 1
        nf = int(lines[i].split()[0])
        i += 1 + nf
        stations.append(st)
    rest = [l.rstrip() for l in lines[i:] if l.strip()]
    if not rest or not rest[0].startswith("VTF") or rest[-1] != "END":
        die(f"{path}: expected a VTF block then END after the MT block")
    return nst, stations, rest


def write_observe(path, stations, rest, freqs):
    with open(path, "w", newline="\n") as f:
        f.write(f"MT    {len(stations)}\n")
        for st in stations:
            f.write(st + "  \n")
            f.write(f"{len(freqs)}\n")
            for fr in freqs:
                w = 2 * math.pi * fr
                zm = math.sqrt(w * MU0 * DUMMY_RHO)
                zxy = zm * complex(1, -1) / math.sqrt(2)   # phase -45 deg: exp(-i omega t)
                zyx = -zxy
                vals = [0.0, 0.0, zxy.real, zxy.imag, zyx.real, zyx.imag, 0.0, 0.0]
                sd = [0.05 * zm] * 8
                f.write(f"{fr:.6e} " + " ".join(f"{v:.4e}" for v in vals + sd) + " \n")
        for l in rest:
            f.write(l + "\n")


def write_block(src, dst, rho):
    n_earth = 0
    with open(src) as fi, open(dst, "w", newline="\n") as fo:
        ne, nc = map(int, fi.readline().split())
        fo.write(f"{ne:10d}{nc:10d}\n")
        for _ in range(ne):
            fo.write(fi.readline())
        for k in range(nc):
            p = fi.readline().split()
            cid, r, lo, hi, wgt, fix = int(p[0]), float(p[1]), float(p[2]), float(p[3]), float(p[4]), int(p[5])
            if cid != k:
                die(f"{src}: cell line {k} has id {cid}")
            if k == 0:
                if fix != 1 or r < 1e6:
                    die(f"{src}: cell 0 is not fixed air (rho {r}, fixed {fix})")
            else:
                if fix != 0:
                    die(f"{src}: earth cell {k} is fixed")
                r = rho
                n_earth += 1
            fo.write(f"{cid:10d}   {r:.6e}   {lo:.6e}   {hi:.6e}   {wgt:.6e}{fix:10d}\n")
        if fi.read().strip():
            die(f"{src}: trailing content after {nc} cell lines")
    return ne, nc, n_earth


def verify_block(path, rho, ne, nc):
    with open(path) as f:
        a, b = map(int, f.readline().split())
        if (a, b) != (ne, nc):
            die(f"{path}: header {a} {b} != {ne} {nc}")
        cells = set()
        for _ in range(ne):
            cells.add(int(f.readline().split()[1]))
        rhos = []
        for _ in range(nc):
            p = f.readline().split()
            rhos.append((float(p[1]), int(p[5])))
    if cells != set(range(nc)):
        die(f"{path}: element->cell map does not use exactly cells 0..{nc - 1}")
    if rhos[0][1] != 1 or rhos[0][0] < 1e6:
        die(f"{path}: air cell changed")
    bad = [k for k, (r, fx) in enumerate(rhos[1:], 1) if abs(r / rho - 1) > 1e-6 or fx != 0]
    if bad:
        die(f"{path}: {len(bad)} earth cells not at {rho} ohm-m or fixed")


def write_control(src, dst, nthreads=2):
    lines = [l.rstrip("\r\n") for l in open(src)]
    out, i, seen = [], 0, set()
    while i < len(lines):
        l = lines[i].strip()
        if l == "NUM_THREADS":
            out += ["NUM_THREADS", str(nthreads)]
            i += 2
            seen.add(l)
        elif l == "ITERATION":
            out += ["ITERATION", "0 0"]
            i += 2
            seen.add(l)
        elif l == "OUTPUT_PARAM_VTK":
            n = int(lines[i + 1].split()[0])
            out += ["OUTPUT_PARAM_VTK", "0"]
            i += 2 + (1 if n > 0 else 0)
            seen.add(l)
        else:
            out.append(lines[i])
            i += 1
    if seen != {"NUM_THREADS", "ITERATION", "OUTPUT_PARAM_VTK"}:
        die(f"{src}: keywords not all found: {seen}")
    with open(dst, "w", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    txt = [l.strip() for l in open(dst).read().split("\n")]

    def val(k):
        return txt[txt.index(k) + 1]
    if (val("ITERATION"), val("NUM_THREADS"), val("OUTPUT_PARAM_VTK"), val("OWNER_ELEMENT")) != ("0 0", str(nthreads), "0", "-1"):
        die(f"{dst}: control values not as intended")


def main():
    args = sys.argv[1:]
    batch, nthreads = None, 2
    if "--batch" in args:
        i = args.index("--batch")
        batch = int(args[i + 1])
        del args[i:i + 2]
    explicit = None
    if "--freqs" in args:
        i = args.index("--freqs")
        explicit = [float(x) for x in args[i + 1].split(",")]
        del args[i:i + 2]
    if "--threads" in args:
        i = args.index("--threads")
        nthreads = int(args[i + 1])
        del args[i:i + 2]
    if len(args) != 4 or (batch is not None and batch not in (1, 2, 3, 4)) or not 1 <= nthreads <= 8:
        die(__doc__)
    prep, mesh_run, out, rho = args[0], args[1], args[2], float(args[3])
    root = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
    bands = common_bands(os.path.join(root, "Vulcan", "frequency_table.csv"))
    if len(bands) != 53:
        die(f"expected 53 common bands, found {len(bands)}")
    freqs = pick(bands)
    if len(set(freqs)) != 8:
        die(f"test frequencies not distinct: {freqs}")
    req = TEST_REQ
    if explicit is not None:
        # supplementary bands (not part of the 8-band criterion runs): each must be one of the 53 common bands
        freqs = []
        for x in explicit:
            b = min(bands, key=lambda y: abs(math.log10(y) - math.log10(x)))
            if abs(b / x - 1) > 1e-4:
                die(f"--freqs {x}: not a common band (nearest {b})")
            freqs.append(b)
        req = explicit
        batch = "explicit"
    elif batch is not None:
        freqs = freqs[2 * (batch - 1):2 * batch]
        req = TEST_REQ[2 * (batch - 1):2 * batch]
    os.makedirs(out, exist_ok=True)

    nst, stations, rest = read_observe(os.path.join(prep, "inversion", "observe.dat"))
    write_observe(os.path.join(out, "observe.dat"), stations, rest, freqs)
    n2, st2, rest2 = read_observe(os.path.join(out, "observe.dat"))
    if n2 != nst or [s.split() for s in st2] != [s.split() for s in stations] or rest2 != rest:
        die("observe.dat re-read: stations or VTF block differ from the prep output")
    with open(os.path.join(out, "observe.dat")) as f:
        f.readline()
        f.readline()
        nf = int(f.readline())
        wf = [float(f.readline().split()[0]) for _ in range(nf)]
    if wf != [float(f"{x:.6e}") for x in freqs]:
        die(f"observe.dat frequencies {wf} != {freqs}")

    ne, nc, n_earth = write_block(os.path.join(mesh_run, "resistivity_block_iter0.dat"),
                                  os.path.join(out, "resistivity_block_iter0.dat"), rho)
    verify_block(os.path.join(out, "resistivity_block_iter0.dat"), rho, ne, nc)

    write_control(os.path.join(prep, "inversion", "control.dat"), os.path.join(out, "control.dat"), nthreads)

    m = os.path.join(out, "mesh.dat")
    if os.path.lexists(m):
        os.remove(m)
    os.link(os.path.join(mesh_run, "mesh.dat"), m)
    with open(m) as f:
        f.readline()
        nn = int(f.readline())
    print(f"make_acc_inputs OK: {out}: rho {rho:g} ohm-m on {n_earth} earth cells ({nc} cells, {ne} elements); "
          f"{nst} MT stations x {len(freqs)} freqs; mesh.dat linked ({nn} nodes)")
    print(f"  batch {batch if batch else 'all'}; NUM_THREADS {nthreads}")
    for rq, b in zip(req, freqs):
        print(f"  requested {rq:g} Hz -> band {b:g} Hz")


if __name__ == "__main__":
    main()
