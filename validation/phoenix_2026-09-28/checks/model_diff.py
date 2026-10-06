#!/usr/bin/env python3
"""Check b (model half) for the Phoenix B2 smoke job 16153670: straight vs restart outputs.

Reads Ben's originals READ-ONLY under D:/BEN/FEMTIC_2026/hpc/smoke_foss_20260928_211308 (they are not
copied into the repo) after checking each file's md5 against ../MANIFEST.md5, so every number below is
tied to exact bytes.

Pre-stated criterion (check b, model): FAILS if restart/resistivity_block_iter2.dat is not byte-identical to
straight/resistivity_block_iter2.dat. If it fails, the size of the difference is measured and set against a
baseline taken BEFORE looking at the iteration-2 numbers: iteration 0 was computed twice from identical inputs
(straight, and restart leg 1: both are fresh starts with the same model), so result_*_iter0.csv straight vs
restart shows the run-to-run noise of FEMTIC on this node with no restart involved.

"ulp7" = one unit in the 7th significant digit of FEMTIC's %e print (the smallest difference a printed file
can show). A difference of 1 ulp7 is 1e-7 to 1e-6 relative, depending on the mantissa.
"""
import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EV = os.path.dirname(HERE)
BEN = os.environ.get("SMOKE_DIR", "D:/BEN/FEMTIC_2026/hpc/smoke_foss_20260928_211308")
MAN = os.path.join(EV, "MANIFEST.md5")


def manifest():
    m = {}
    with open(MAN, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            md5, size, path = line.split()[:3]
            m[path] = (md5, int(size))
    return m


def verified(rel, man):
    p = os.path.join(BEN, rel)
    with open(p, "rb") as fh:
        h = hashlib.md5(fh.read()).hexdigest()
    want = man["smoke_foss_20260928_211308/" + rel][0]
    if h != want:
        sys.exit(f"STOP: {p} md5 {h} differs from MANIFEST {want} - Ben's file changed since the manifest")
    return p, h


def ulp7(tok):
    m, e = tok.split("e")
    return 10.0 ** (int(e) - 6)


def block_file(p):
    with open(p) as fh:
        lines = fh.read().split("\n")
    ne, nb = map(int, lines[0].split())
    elem = [l.split() for l in lines[1:1 + ne]]
    blk = [l.split() for l in lines[1 + ne:1 + ne + nb]]
    return elem, blk


def cmp_blocks(pa, pb, label):
    ea, ba = block_file(pa)
    eb, bb = block_file(pb)
    assert len(ba) == len(bb) and len(ea) == len(eb)
    elem_same = ea == eb
    other_same = all(x[0] == y[0] and x[2:] == y[2:] for x, y in zip(ba, bb))  # id, bounds, weight, type
    nd, mrel, mulp, worst = 0, 0.0, 0.0, None
    for x, y in zip(ba, bb):
        if x[1] != y[1]:
            nd += 1
            a, b = float(x[1]), float(y[1])
            r = abs(a - b) / max(abs(a), abs(b))
            u = abs(a - b) / ulp7(x[1])
            if r > mrel:
                mrel, worst = r, (x[0], x[1], y[1])
            mulp = max(mulp, u)
    print(f"  {label}: {len(ba)} blocks, element->block map identical {elem_same}, ids/bounds/weights/types identical"
          f" {other_same}; resistivities differing {nd}; max rel diff {mrel:.2e}; max |diff| {mulp:.2f} ulp7"
          + (f"; worst block {worst[0]}: {worst[1]} vs {worst[2]}" if worst else ""))
    return nd, mrel, mulp


def csv_rows(p):
    """MT block of result_<rank>_iter<N>.csv: {(StaID, freq): [32 numbers as printed]}.
    Columns after StaID, Freq: 8 x Cal, 8 x Res, 8 x Obs, 8 x SD (Re/Im of Zxx, Zxy, Zyx, Zyy)."""
    out = {}
    with open(p) as fh:
        for line in fh:
            t = [x.strip() for x in line.split(",") if x.strip()]
            if len(t) == 34 and t[0].isdigit():
                out[(t[0], t[1])] = t[2:]
    return out


def cmp_csv(pa, pb, label):
    """Differences measured the way they matter: Cal relative to the row's impedance size
    |Z|_row = max(|Zxy|, |Zyx|) (complex magnitudes of the Cal values), Res in SD units (Res = (Obs-Cal)/SD).
    Obs and SD are input data and must be print-identical. Plain relative differences of single numbers are
    not used: the diagonal Zxx, Zyy of this 1-D-like example are ~1e-4 of |Z|, so their own relative change
    is large for a negligible absolute change."""
    A, B = csv_rows(pa), csv_rows(pb)
    assert A.keys() == B.keys(), "station/frequency rows differ"
    nd = sum(1 for k in A for x, y in zip(A[k], B[k]) if x != y)
    dcal = dres = 0.0
    inp_same = True
    for k in A:
        a, b = [float(v) for v in A[k]], [float(v) for v in B[k]]
        zn = max(abs(complex(a[2], a[3])), abs(complex(a[4], a[5])))
        dcal = max(dcal, max(abs(a[i] - b[i]) for i in range(0, 8)) / zn)
        dres = max(dres, max(abs(a[i] - b[i]) for i in range(8, 16)))
        inp_same &= A[k][16:32] == B[k][16:32]
    n = 32 * len(A)
    print(f"  {label}: {n} numbers, {nd} differ; max |dCal|/|Z|_row {dcal:.1e}; max |dRes| {dres:.1e} SD;"
          f" Obs and SD identical {inp_same}")
    return nd, dcal, dres, inp_same


def main():
    man = manifest()
    files = [f"{d}/{n}" for d in ("straight", "restart") for n in
             ["resistivity_block_iter1.dat", "resistivity_block_iter2.dat"]
             + [f"result_{r}_iter{i}.csv" for r in (0, 1) for i in (0, 1, 2)]]
    P, H = {}, {}
    for f in files:
        P[f], H[f] = verified(f, man)
    print(f"md5 of {len(files)} files checked against MANIFEST.md5: all equal")

    print("\n== Check b (model). This test fails if restart/resistivity_block_iter2.dat is not byte-identical to straight's.")
    print("-- fail case first: straight iteration 1 vs straight iteration 2 (a real model change must show up)")
    fnd, fmrel, _ = cmp_blocks(P["straight/resistivity_block_iter1.dat"], P["straight/resistivity_block_iter2.dat"],
                               "straight iter1 vs iter2")
    print("-- md5 identity:")
    same = {}
    for n in ["resistivity_block_iter1.dat", "resistivity_block_iter2.dat"] + \
             [f"result_{r}_iter{i}.csv" for r in (0, 1) for i in (0, 1, 2)]:
        a, b = H["straight/" + n], H["restart/" + n]
        same[n] = a == b
        print(f"  {n:30s} straight {a}  restart {b}  {'IDENTICAL' if a == b else 'differ'}")
    t_b = same["resistivity_block_iter2.dat"]
    print(f"  => check b (byte identity of the final model): {'PASS' if t_b else 'FAIL'}")

    print("-- size of the differences:")
    nd2, mrel2, mulp2 = cmp_blocks(P["straight/resistivity_block_iter2.dat"], P["restart/resistivity_block_iter2.dat"],
                                   "iter2 model straight vs restart")
    print("  responses (result_<rank>_iter<N>.csv). Fail case first: straight iteration 0 vs straight iteration 1")
    fc = cmp_csv(P["straight/result_0_iter0.csv"], P["straight/result_0_iter1.csv"], "result_0 straight iter0 vs iter1")
    print("  baseline, no restart involved (identical inputs, two fresh runs: straight and restart leg 1):")
    base = [cmp_csv(P[f"straight/result_{r}_iter0.csv"], P[f"restart/result_{r}_iter0.csv"],
                    f"result_{r}_iter0.csv straight vs restart") for r in (0, 1)]
    print("  restart: leg 2 (ITERATION 1 2) recomputes iteration 1 from the PRINTED resistivity_block_iter1.dat,")
    print("  so restart/result_*_iter1.csv and _iter2.csv both come from leg 2 (leg 1's iter1 csv was overwritten):")
    it1 = [cmp_csv(P[f"straight/result_{r}_iter1.csv"], P[f"restart/result_{r}_iter1.csv"],
                   f"result_{r}_iter1.csv straight vs restart") for r in (0, 1)]
    it2 = [cmp_csv(P[f"straight/result_{r}_iter2.csv"], P[f"restart/result_{r}_iter2.csv"],
                   f"result_{r}_iter2.csv straight vs restart") for r in (0, 1)]
    inputs_same = all(x[3] for x in base + it1 + it2)
    print()
    print(f"SUMMARY model_diff: fail cases detected {fnd > 0 and fc[1] > 1e-3}; final model byte-identical {t_b};"
          f" iter2 model: {nd2} of 288 free blocks differ, max rel {mrel2:.2e} = {mulp2:.2f} ulp7;"
          f" responses max |dCal|/|Z|: iter0 baseline {max(x[1] for x in base):.1e}, iter1 {max(x[1] for x in it1):.1e},"
          f" iter2 {max(x[1] for x in it2):.1e}; max |dRes| iter2 {max(x[2] for x in it2):.1e} SD;"
          f" Obs/SD identical {inputs_same}")
    return 0 if (fnd > 0 and fc[1] > 1e-3 and inputs_same) else 1


if __name__ == "__main__":
    sys.exit(main())
