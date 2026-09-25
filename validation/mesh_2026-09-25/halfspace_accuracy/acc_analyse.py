#!/usr/bin/env python3
"""acc_analyse.py -- evaluate one FEMTIC half-space forward run against the analytic answer.

    python acc_analyse.py RUN_DIR RHO_OHMM [--json OUT.json] [--use-obs]

Failure criterion (halfspace_accuracy.md), checked at every site and frequency found in the run:
  |rho_a/rho - 1| > 0.05 for Zxy or Zyx, or |phase - 45 deg| > 1.5 deg for Zxy or Zyx,
  or max(|Zxx|, |Zyy|) > 0.02 |Zxy|; also FAIL if femtic did not exit 0 or any of the 120 x 8
  site-frequency rows is missing from result_*_iter0.csv.
rho_a = |Z|^2 / (omega mu0), Z in ohm. The time convention is DETERMINED from the Cal columns (sign of the
median arg Zxy); the phase is then taken in that convention's quadrant (Zxy: -arg Z for exp(-i omega t),
Zyx: -arg(-Z)), so a quadrant or sign error shows up as a phase error of ~90-180 deg instead of passing.
--use-obs evaluates the Obs columns instead of Cal (analysis self-test: the Obs columns hold the analytic
10 ohm-m half-space written by make_acc_inputs.py, so with RHO 10 it must PASS and with any other RHO FAIL).
Also reconciles the misfit recomputed from the CSVs with femtic.cnv, and extracts per-frequency forward
times and solver memory from femtic_<rank>.log, and wall time / peak memory from time_v.log and
rss_samples.log.
"""
import glob
import json
import math
import os
import re
import sys

import numpy as np

MU0 = 4e-7 * math.pi
TOL_RHO, TOL_PH, TOL_DIAG = 0.05, 1.5, 0.02
N_SITES, N_FREQ = 120, 8


def read_csv_mt(path):
    rows, block, hdr = [], None, None
    for line in open(path):
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
        if block == "MT":
            vals = [v for v in s.split(",") if v.strip()]
            rows.append(dict(zip(hdr, [float(v) for v in vals])))
    return rows


def parse_log(path):
    txt = open(path, errors="replace").read().split("\n")
    sec = lambda l: int(re.search(r"\(\s*(\d+)\s*sec\s*\)", l).group(1))
    out = {"freqs": {}}
    for i, l in enumerate(txt):
        m = re.search(r"Start forward calculation\. Frequency : ([0-9.eE+-]+) \[Hz\], Polarization : (\S+)", l)
        if m:
            f = float(m.group(1))
            t = None
            for l2 in txt[i + 1:i + 6]:
                if re.search(r"\(\s*\d+\s*sec\s*\)", l2):
                    t = sec(l2)
                    break
            d = out["freqs"].setdefault(f, {})
            d.setdefault("t_start", t)
        if "Calculate response functions." in l:
            f_last = max(out["freqs"]) if out["freqs"] else None
            # the response functions belong to the frequency whose forward runs precede this line
            for f, d in out["freqs"].items():
                if "t_end" not in d:
                    d["t_end"] = sec(l)
        m = re.search(r"Total memory consumed by in-core forward solver for internal float point arrays\s*:\s*([0-9.eE+]+)", l)
        if m:
            out.setdefault("incore_kB", []).append(float(m.group(1)))
        m = re.search(r"Total peak memory required during the analysis and symbolic factorization phase\s*:\s*([0-9.eE+]+)", l)
        if m:
            out.setdefault("analysis_peak_kB", []).append(float(m.group(1)))
        m = re.search(r"Number of equation = (\d+), Number of equation after degeneration = (\d+)", l)
        if m and "neq" not in out and int(m.group(1)) > 10000:
            out["neq"] = [int(m.group(1)), int(m.group(2))]
        if "End femtic" in l:
            out["t_total"] = sec(l)
        if re.search(r"error|warning", l, re.I):
            out.setdefault("errors", []).append(l.strip())
    return out


def parse_timev(path):
    d = {}
    if not os.path.exists(path):
        return d
    for l in open(path):
        k, _, v = l.strip().partition(": ")
        if k.startswith("Elapsed (wall clock)"):
            t = [float(x) for x in v.split(":")]
            s = 0.0
            for x in t:
                s = s * 60 + x
            d["wall_s"] = s
        elif k == "Maximum resident set size (kbytes)":
            d["maxrss_single_kB"] = int(v)
        elif k == "Exit status":
            d["exit"] = int(v)
        elif k == "User time (seconds)":
            d["user_s"] = float(v)
        elif k == "Percent of CPU this job got":
            d["cpu_pct"] = v
    return d


def main():
    args = sys.argv[1:]
    use_obs = "--use-obs" in args
    js = None
    if "--json" in args:
        js = args[args.index("--json") + 1]
        del args[args.index("--json"):args.index("--json") + 2]
    args = [a for a in args if a != "--use-obs"]
    run, rho = args[0], float(args[1])
    col = "Obs" if use_obs else "Cal"

    files = sorted(glob.glob(os.path.join(run, "result_*_iter0.csv")))
    rows = []
    for fn in files:
        rk = int(re.search(r"result_(\d+)_iter0", fn).group(1))
        for r in read_csv_mt(fn):
            r["rank"] = rk
            rows.append(r)
    key = lambda r: (int(r["StaID"]), float(f"{r['Freq[Hz]']:.6e}"))
    seen = {}
    for r in rows:
        seen.setdefault(key(r), []).append(r)
    freqs = sorted({k[1] for k in seen}, reverse=True)
    sites = sorted({k[0] for k in seen})
    dup = [k for k, v in seen.items() if len(v) > 1]
    missing = [(s, f) for s in range(1, N_SITES + 1) for f in freqs if (s, f) not in seen]
    complete = (len(freqs) == N_FREQ and sites == list(range(1, N_SITES + 1)) and not missing and not dup)

    Z = lambda r, c: complex(r[f"Re({c})_{col}"], r[f"Im({c})_{col}"])
    zxy_all = np.array([Z(r, "Zxy") for r in rows])
    zyx_all = np.array([Z(r, "Zyx") for r in rows])
    med_arg_xy = float(np.degrees(np.median(np.angle(zxy_all))))
    med_arg_yx = float(np.degrees(np.median(np.mod(np.angle(zyx_all), 2 * np.pi))))
    conv = "exp(-i omega t)" if med_arg_xy < 0 else "exp(+i omega t)"
    sgn = -1.0 if med_arg_xy < 0 else 1.0
    convention = {
        "median_arg_Zxy_deg": med_arg_xy, "median_arg_Zyx_deg_0_360": med_arg_yx,
        "frac_ReZxy_pos": float(np.mean(zxy_all.real > 0)), "frac_ImZxy_neg": float(np.mean(zxy_all.imag < 0)),
        "frac_ReZyx_neg": float(np.mean(zyx_all.real < 0)), "frac_ImZyx_pos": float(np.mean(zyx_all.imag > 0)),
        "convention": conv,
    }

    per_f = {}
    all_ok = complete
    for f in freqs:
        w = 2 * math.pi * f
        rr = sorted([seen[(s, f)][0] for s in sites if (s, f) in seen], key=lambda r: int(r["StaID"]))
        st = np.array([int(r["StaID"]) for r in rr])
        zxx = np.array([Z(r, "Zxx") for r in rr]); zxy = np.array([Z(r, "Zxy") for r in rr])
        zyx = np.array([Z(r, "Zyx") for r in rr]); zyy = np.array([Z(r, "Zyy") for r in rr])
        e_xy = np.abs(zxy) ** 2 / (w * MU0) / rho - 1
        e_yx = np.abs(zyx) ** 2 / (w * MU0) / rho - 1
        # phase in FEMTIC's convention quadrant: Zxy ~ |Z| exp(sgn*i*45deg), Zyx ~ -Zxy
        ph_xy = sgn * np.degrees(np.angle(zxy))
        ph_yx = sgn * np.degrees(np.angle(-zyx))
        p_xy, p_yx = ph_xy - 45, ph_yx - 45
        diag = np.maximum(np.abs(zxx), np.abs(zyy)) / np.abs(zxy)
        erho = np.maximum(np.abs(e_xy), np.abs(e_yx))
        eph = np.maximum(np.abs(p_xy), np.abs(p_yx))
        bad_r, bad_p, bad_d = erho > TOL_RHO, eph > TOL_PH, diag > TOL_DIAG
        bad = bad_r | bad_p | bad_d
        ok = bool(not bad.any()) and len(rr) == N_SITES
        all_ok &= ok
        worst = np.argsort(-erho)[:3]
        per_f[f"{f:g}"] = {
            "freq_hz": f, "n_sites": len(rr), "skin_depth_km": 0.503 * math.sqrt(rho / f),
            "rho_err_xy_pct": [float(100 * e_xy.min()), float(100 * np.median(e_xy)), float(100 * e_xy.max())],
            "rho_err_yx_pct": [float(100 * e_yx.min()), float(100 * np.median(e_yx)), float(100 * e_yx.max())],
            "max_abs_rho_err_pct": float(100 * erho.max()),
            "signed_rho_err_at_max_pct": float(100 * np.concatenate([e_xy, e_yx])[np.argmax(np.abs(np.concatenate([e_xy, e_yx])))]),
            "phase_err_xy_deg": [float(p_xy.min()), float(np.median(p_xy)), float(p_xy.max())],
            "phase_err_yx_deg": [float(p_yx.min()), float(np.median(p_yx)), float(p_yx.max())],
            "max_abs_phase_err_deg": float(eph.max()),
            "signed_phase_err_at_max_deg": float(np.concatenate([p_xy, p_yx])[np.argmax(np.abs(np.concatenate([p_xy, p_yx])))]),
            "max_diag_ratio_pct": float(100 * diag.max()), "median_diag_ratio_pct": float(100 * np.median(diag)),
            "n_fail_rho": int(bad_r.sum()), "n_fail_phase": int(bad_p.sum()), "n_fail_diag": int(bad_d.sum()),
            "n_fail_any": int(bad.sum()),
            "worst_sites_by_rho": [[int(st[k]), float(100 * e_xy[k]), float(100 * e_yx[k]), float(p_xy[k]), float(p_yx[k])] for k in worst],
            "pass": ok,
        }

    # misfit reconciliation with femtic.cnv
    mis = 0.0
    for r in rows:
        for c in ("Zxx", "Zxy", "Zyx", "Zyy"):
            for p in ("Re", "Im"):
                mis += ((r[f"{p}({c})_Obs"] - r[f"{p}({c})_Cal"]) / r[f"{p}({c})_SD"]) ** 2
    cnv = None
    cp = os.path.join(run, "femtic.cnv")
    if os.path.exists(cp):
        ln = [l.split() for l in open(cp) if l.strip() and not l.strip().startswith("Iter")]
        if ln:
            cnv = float(ln[0][5])

    logs = {}
    for lp in sorted(glob.glob(os.path.join(run, "femtic_*.log"))):
        rk = int(re.search(r"femtic_(\d+)\.log", lp).group(1))
        logs[rk] = parse_log(lp)
    fwd = {}
    for rk, d in logs.items():
        for f, t in d["freqs"].items():
            fwd[f"{f:g}"] = {"rank": rk, "forward_s": (t.get("t_end", float("nan")) - t.get("t_start", float("nan"))),
                             "incore_MB": max(d.get("incore_kB", [0])) / 1024,
                             "analysis_peak_MB": max(d.get("analysis_peak_kB", [0])) / 1024,
                             "rank_total_s": d.get("t_total")}
    neq = next((d["neq"] for d in logs.values() if "neq" in d), None)
    log_errors = sorted({e for d in logs.values() for e in d.get("errors", [])})

    tv = parse_timev(os.path.join(run, "time_v.log"))
    rc = None
    dp = os.path.join(run, "FEMTIC.DONE")
    if os.path.exists(dp):
        rc = int(open(dp).read().strip().split("=")[1])
    peak_sum_kB, min_avail_kB, max_swap_kB, nsamp = None, None, None, 0
    sp = os.path.join(run, "rss_samples.log")
    if os.path.exists(sp):
        a = np.array([[float(x) for x in l.split()] for l in open(sp) if len(l.split()) == 5])
        if len(a):
            nsamp = len(a)
            peak_sum_kB = float(a[:, 2].max())
            min_avail_kB = float(a[:, 3].min())
            max_swap_kB = float(a[:, 4].max())
    if not use_obs:
        all_ok &= (rc == 0)

    res = {
        "run": run, "rho": rho, "columns": col, "complete": complete, "n_rows": len(rows), "n_csv": len(files),
        "missing": missing[:10], "duplicates": [list(k) for k in dup[:10]],
        "convention": convention, "per_freq": per_f, "pass": bool(all_ok),
        "misfit_csv": mis, "misfit_cnv": cnv,
        "misfit_rel_diff": (abs(mis - cnv) / cnv if cnv else None),
        "forward": fwd, "n_equations": neq, "log_error_lines": log_errors[:20],
        "femtic_rc": rc, "time_v": tv, "peak_sum_rss_GB": (peak_sum_kB / 1048576 if peak_sum_kB else None),
        "min_mem_available_GB": (min_avail_kB / 1048576 if min_avail_kB else None),
        "max_swap_used_GB": (max_swap_kB / 1048576 if max_swap_kB is not None else None), "rss_samples": nsamp,
    }

    print(f"run {run}  rho {rho:g} ohm-m  columns {col}  csv files {len(files)}  rows {len(rows)}  complete {complete}")
    print(f"convention: median arg Zxy {med_arg_xy:.2f} deg, median arg Zyx {med_arg_yx:.2f} deg (0-360) -> {conv}; "
          f"Re Zxy>0 {convention['frac_ReZxy_pos']:.3f}, Im Zxy<0 {convention['frac_ImZxy_neg']:.3f}, "
          f"Re Zyx<0 {convention['frac_ReZyx_neg']:.3f}, Im Zyx>0 {convention['frac_ImZyx_pos']:.3f}")
    print(f"{'f (Hz)':>10} {'delta km':>9} {'rho_a err xy % min/med/max':>28} {'yx min/med/max':>24} {'|max|%':>7} "
          f"{'ph err xy deg':>22} {'ph err yx deg':>22} {'|max|':>6} {'diag%':>6} {'fail r/p/d':>11} {'fwd s':>6} {'incore MB':>9}")
    for k, d in per_f.items():
        fw = fwd.get(k, {})
        print(f"{d['freq_hz']:>10g} {d['skin_depth_km']:>9.3f} "
              f"{'%+.2f/%+.2f/%+.2f' % tuple(d['rho_err_xy_pct']):>28} {'%+.2f/%+.2f/%+.2f' % tuple(d['rho_err_yx_pct']):>24} "
              f"{d['max_abs_rho_err_pct']:>7.2f} {'%+.2f/%+.2f/%+.2f' % tuple(d['phase_err_xy_deg']):>22} "
              f"{'%+.2f/%+.2f/%+.2f' % tuple(d['phase_err_yx_deg']):>22} {d['max_abs_phase_err_deg']:>6.2f} "
              f"{d['max_diag_ratio_pct']:>6.2f} {'%d/%d/%d' % (d['n_fail_rho'], d['n_fail_phase'], d['n_fail_diag']):>11} "
              f"{fw.get('forward_s', float('nan')):>6.0f} {fw.get('incore_MB', float('nan')):>9.0f}  {'PASS' if d['pass'] else 'FAIL'}")
    print(f"misfit from CSV {mis:.6e}; femtic.cnv {cnv}; rel diff {res['misfit_rel_diff']}")
    print(f"equations {neq}; femtic rc {rc}; time -v {tv}; peak summed RSS {res['peak_sum_rss_GB']} GB; "
          f"min MemAvailable {res['min_mem_available_GB']} GB; max swap used {res['max_swap_used_GB']} GB ({nsamp} samples)")
    if log_errors:
        print("log lines matching error/warning:", log_errors[:5])
    print("RESULT:", "PASS" if res["pass"] else "FAIL")
    if js:
        with open(js, "w", newline="\n") as fo:
            json.dump(res, fo, indent=1)


if __name__ == "__main__":
    main()
