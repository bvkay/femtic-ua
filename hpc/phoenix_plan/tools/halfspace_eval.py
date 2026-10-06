#!/usr/bin/env python3
"""halfspace_eval.py -- the half-space accuracy gate for a FEMTIC forward run (06_forward_only.slurm START_RHO=...).

    python3 halfspace_eval.py RHO_OHMM DIR [DIR ...] [--station-map station_map.csv] [--json OUT.json]

Reads every DIR/result_*_iter0.csv (one per rank; FEMTIC's MT block) and compares the calculated impedances with
the analytic response of a uniform half-space of RHO_OHMM ohm-m. The gate FAILS if, at any site and band:
    |rho_a / rho - 1| > 5 %     for Zxy or Zyx, rho_a = |Z|^2 / (omega mu0), omega = 2 pi f, mu0 = 4e-7 pi
    |phase - 45 deg| > 1.5 deg  for Zxy or Zyx, in the quadrant of FEMTIC's own time convention (below)
    max(|Zxx|, |Zyy|) > 2 % of |Zxy|
or if a (site, band) listed in DIR/observe.dat (MT block) has no row in the csv files. Without an observe.dat
the expected set is every site x every band seen in the csv files.
Output: one line per band (as acc_eval.py prints it), one line per limit with the worst value and where it
occurs (site id, site name from --station-map, band, component), a completeness line and "RESULT: PASS|FAIL".
Exit status 0 = PASS, 1 = FAIL, 2 = no usable input.

Time convention: DETERMINED from the data (sign of the median arg Zxy over all rows), not assumed. The phase is
then -arg(Zxy) and -arg(-Zyx) for exp(-i omega t) (+arg for exp(+i omega t)), so a quadrant or sign error shows
up as a 90-180 deg phase error and cannot pass.
Several DIRs: a (site, band) row present in more than one is taken from the FIRST DIR listed.

Adapted from validation/mesh_2026-09-25/halfspace_accuracy/acc_eval.py (the evaluator behind
mesh/vulcan_v*/halfspace/acc_*/acc_eval_*.txt), with the same limits and formulas. Differences: standard library
only (Phoenix's python3 has no numpy), completeness from observe.dat instead of a fixed 120 sites x 8 bands,
per-limit worst site and band, and none of the WSL run bookkeeping (rc files, watchdog, time_v, RSS samplers).
Python >= 3.6 (Phoenix's system python3 is 3.6.8; tests/portability_test.sh checks the grammar and library calls).
Python 3.6 takes the default file and stdout encoding from the locale, which is ASCII under LANG=C (3.7 switched to
UTF-8, PEP 538/540). So every file is opened as UTF-8 with errors="replace", and site names from station_map.csv are
reduced to ASCII before printing: a non-ASCII byte cannot stop the gate.
"""
import cmath
import glob
import json
import math
import os
import re
import statistics
import sys

MU0 = 4e-7 * math.pi
TOL_RHO, TOL_PH, TOL_DIAG = 0.05, 1.5, 0.02
COMPS = ("Zxx", "Zxy", "Zyx", "Zyy")


def fkey(f):
    return float("%.6e" % f)


def read_csv_mt(path):
    """Rows of the MT block of a FEMTIC result_<rank>_iter<n>.csv as dicts of floats (acc_analyse.read_csv_mt)."""
    rows, block, hdr = [], None, None
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
    for line in lines:
        s = line.strip()
        if not s:
            continue
        first = s.split(",")[0].strip()
        if re.fullmatch(r"[A-Za-z_0-9]+", first) and not re.fullmatch(r"[0-9]+", first) and s.endswith(","):
            if first == "StaID":
                hdr = [h.strip() for h in s.split(",") if h.strip()]
            else:
                block = first
            continue
        if block == "MT" and hdr:
            vals = [v for v in s.split(",") if v.strip()]
            rows.append(dict(zip(hdr, [float(v) for v in vals])))
    return rows


def read_observe_mt(path):
    """(station id, band) pairs of the MT block of a FEMTIC observe.dat."""
    pairs = set()
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = [l.split() for l in f]
    i = 0
    while i < len(lines):
        t = lines[i]
        if len(t) >= 2 and t[0] == "MT" and t[1].isdigit():
            nst, i = int(t[1]), i + 1
            for _ in range(nst):
                sid = int(lines[i][0])
                nf = int(lines[i + 1][0])
                for k in range(nf):
                    pairs.add((sid, fkey(float(lines[i + 2 + k][0]))))
                i += 2 + nf
            return pairs
        i += 1
    return pairs


def read_station_map(path):
    """femtic_station_id -> site_id (as ASCII: a non-ASCII character becomes '?', see the module docstring)."""
    names = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        hdr = [h.strip() for h in f.readline().split(",")]
        for line in f:
            p = [x.strip() for x in line.split(",")]
            if len(p) == len(hdr):
                d = dict(zip(hdr, p))
                names[int(d["femtic_station_id"])] = d.get("site_id", "").encode("ascii", "replace").decode("ascii")
    return names


def main():
    args = sys.argv[1:]
    js = smap = None
    for opt in ("--json", "--station-map"):
        if opt in args:
            i = args.index(opt)
            if i + 1 >= len(args):
                print(__doc__)
                return 2
            if opt == "--json":
                js = args[i + 1]
            else:
                smap = args[i + 1]
            del args[i:i + 2]
    if len(args) < 2:
        print(__doc__)
        return 2
    try:
        rho = float(args[0])
    except ValueError:
        print("halfspace_eval: RHO '%s' is not a number" % args[0])
        return 2
    if not rho > 0:
        print("halfspace_eval: RHO must be > 0")
        return 2
    dirs = args[1:]
    names = read_station_map(smap) if smap else {}

    def site(s):
        return "%d%s" % (s, " (%s)" % names[s] if s in names else "")

    merged, expected, n_csv, dup = {}, set(), 0, 0
    for d in dirs:
        files = sorted(glob.glob(os.path.join(d, "result_*_iter0.csv")))
        n_csv += len(files)
        for fn in files:
            for r in read_csv_mt(fn):
                k = (int(r["StaID"]), fkey(r["Freq[Hz]"]))
                if k in merged:
                    dup += 1
                else:
                    merged[k] = r
        ob = os.path.join(d, "observe.dat")
        if os.path.exists(ob):
            expected |= read_observe_mt(ob)
    if not merged:
        print("halfspace_eval: no MT rows in %d result_*_iter0.csv file(s) under %s" % (n_csv, " ".join(dirs)))
        print("RESULT: FAIL")
        return 1 if n_csv else 2
    exp_src = "observe.dat"
    if not expected:
        exp_src = "csv (no observe.dat)"
        expected = {(s, f) for s in {k[0] for k in merged} for f in {k[1] for k in merged}}
    missing = sorted(expected - set(merged))
    extra = sorted(set(merged) - expected)

    def Z(r, c):
        return complex(r["Re(%s)_Cal" % c], r["Im(%s)_Cal" % c])

    med_xy = math.degrees(statistics.median([cmath.phase(Z(r, "Zxy")) for r in merged.values()]))
    sgn = -1.0 if med_xy < 0 else 1.0
    conv = "exp(-i omega t)" if med_xy < 0 else "exp(+i omega t)"

    worst = {"rho": (-1.0,), "phase": (-1.0,), "diag": (-1.0,)}
    per_f = []
    ok_all = not missing
    for f in sorted({k[1] for k in merged}, reverse=True):
        w = 2 * math.pi * f
        rows = [merged[k] for k in sorted(merged) if k[1] == f]
        both, bothp, erho, eph, diag = [], [], [], [], []
        nfr = nfp = nfd = 0
        for r in rows:
            s = int(r["StaID"])
            zxx, zxy, zyx, zyy = (Z(r, c) for c in COMPS)
            e_xy = abs(zxy) ** 2 / (w * MU0) / rho - 1
            e_yx = abs(zyx) ** 2 / (w * MU0) / rho - 1
            p_xy = sgn * math.degrees(cmath.phase(zxy)) - 45
            p_yx = sgn * math.degrees(cmath.phase(-zyx)) - 45
            dg = max(abs(zxx), abs(zyy)) / abs(zxy)
            both += [e_xy, e_yx]
            bothp += [p_xy, p_yx]
            er, ep = max(abs(e_xy), abs(e_yx)), max(abs(p_xy), abs(p_yx))
            erho.append(er)
            eph.append(ep)
            diag.append(dg)
            nfr += er > TOL_RHO
            nfp += ep > TOL_PH
            nfd += dg > TOL_DIAG
            cand = [("rho", abs(e_xy), s, f, "Zxy %+.3f %%" % (100 * e_xy)), ("rho", abs(e_yx), s, f, "Zyx %+.3f %%" % (100 * e_yx)),
                    ("phase", abs(p_xy), s, f, "Zxy %+.3f deg" % p_xy), ("phase", abs(p_yx), s, f, "Zyx %+.3f deg" % p_yx),
                    ("diag", dg, s, f, "|Zxx| %.3e |Zyy| %.3e |Zxy| %.3e" % (abs(zxx), abs(zyy), abs(zxy)))]
            for lim, v, s2, f2, what in cand:
                if v > worst[lim][0]:
                    worst[lim] = (v, s2, f2, what)
        ok = not (nfr or nfp or nfd)
        ok_all &= ok
        per_f.append({"freq_hz": f, "n_sites": len(rows), "skin_depth_km": 0.503 * math.sqrt(rho / f),
                      "max_abs_rho_err_pct": 100 * max(erho), "rho_err_mean_pct": 100 * statistics.mean(both),
                      "rho_err_std_pct": 100 * statistics.pstdev(both), "max_abs_phase_err_deg": max(eph),
                      "phase_err_mean_deg": statistics.mean(bothp), "phase_err_std_deg": statistics.pstdev(bothp),
                      "max_diag_ratio_pct": 100 * max(diag), "n_fail_rho": nfr, "n_fail_phase": nfp, "n_fail_diag": nfd,
                      "pass": ok})

    print("half-space gate: rho %g ohm-m, %d dir(s), %d csv file(s), %d site-band rows (%d duplicates ignored); expected %d from %s"
          % (rho, len(dirs), n_csv, len(merged), dup, len(expected), exp_src))
    print("convention from Cal: median arg Zxy %.2f deg -> %s" % (med_xy, conv))
    print("%10s %8s %9s %6s %5s %7s %6s %5s %6s %10s %6s" % ("f Hz", "delta km", "max|rho|%", "mean%", "std%", "max|ph|",
                                                           "mean", "std", "diag%", "fail r/p/d", "sites"))
    for d in per_f:
        print("%10g %8.3f %9.2f %+6.2f %5.2f %7.2f %+6.2f %5.2f %6.2f %10s %6d  %s" % (
            d["freq_hz"], d["skin_depth_km"], d["max_abs_rho_err_pct"], d["rho_err_mean_pct"], d["rho_err_std_pct"],
            d["max_abs_phase_err_deg"], d["phase_err_mean_deg"], d["phase_err_std_deg"], d["max_diag_ratio_pct"],
            "%d/%d/%d" % (d["n_fail_rho"], d["n_fail_phase"], d["n_fail_diag"]), d["n_sites"], "PASS" if d["pass"] else "FAIL"))
    lim_txt = {"rho": ("rho_a", 100 * TOL_RHO, "%", 100), "phase": ("phase", TOL_PH, "deg", 1), "diag": ("diagonal", 100 * TOL_DIAG, "%", 100)}
    for lim in ("rho", "phase", "diag"):
        name, tol, unit, sc = lim_txt[lim]
        v, s, f, what = worst[lim]
        print("LIMIT %-8s %4g %-3s: %s  worst %.3f %s at site %s, %g Hz (%s)" % (
            name, tol, unit, "PASS" if v * sc <= tol else "FAIL", v * sc, unit, site(s), f, what))
    print("COMPLETENESS: %d expected (site, band) pairs, %d missing%s; %d rows not in observe.dat%s: %s" % (
        len(expected), len(missing), (" e.g. " + ", ".join("%d@%g" % m for m in missing[:5])) if missing else "",
        len(extra), (" e.g. " + ", ".join("%d@%g" % m for m in extra[:5])) if extra else "",
        "PASS" if not missing else "FAIL"))
    print("RESULT:", "PASS" if ok_all else "FAIL")
    if js:
        with open(js, "w", encoding="utf-8") as fo:
            json.dump({"rho": rho, "dirs": dirs, "pass": ok_all, "missing": missing[:50], "convention": conv,
                       "worst": {k: list(v) for k, v in worst.items()}, "per_freq": per_f}, fo, indent=1)
    return 0 if ok_all else 1


if __name__ == "__main__":
    sys.exit(main())
