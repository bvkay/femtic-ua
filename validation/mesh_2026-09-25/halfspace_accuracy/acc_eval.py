#!/usr/bin/env python3
"""acc_eval.py -- evaluate the half-space forward test for one mesh and one resistivity, from one or more femtic
run directories (the frequency batches of acc_batch.sh, optionally plus an earlier all-8 run).

    python acc_eval.py RHO_OHMM DIR [DIR ...] [--json OUT.json] [--use-obs] [--nfreq 8]

Failure criterion (halfspace_accuracy.md, fixed before the first run), checked at every one of the 120 sites
and every test frequency:
    |rho_a / rho - 1| > 5 %  for Zxy or Zyx, rho_a = |Z|^2 / (omega mu0), Z in ohm, omega = 2 pi f, mu0 = 4e-7 pi
    |phase - 45 deg| > 1.5 deg for Zxy or Zyx, phase taken in the quadrant of FEMTIC's own convention (below)
    max(|Zxx|, |Zyy|) > 2 % of |Zxy|
The result is also FAIL if any run directory did not exit 0, its watchdog fired, or any of the 120 x nfreq
site-frequency rows is missing.

Time convention: DETERMINED from the Cal columns (sign of the median arg Zxy over all rows), not assumed.
The phase is then -arg(Zxy) and -arg(-Zyx) for exp(-i omega t) (+arg for exp(+i omega t)), so a quadrant
or sign error shows up as a phase error of 90-180 deg and cannot pass.
Merging: a (site, frequency) row present in several directories is taken from the FIRST directory listed;
the largest relative difference between the duplicates is reported (a reproducibility check across runs
with different rank/thread layouts).
Per directory it also recomputes the misfit sum(((Obs - Cal)/SD)^2) from the CSVs and reconciles it with
femtic.cnv, and extracts per-frequency forward times and PARDISO memory from femtic_<rank>.log, wall time
and the largest single-process RSS from time_v.log, and the peak summed RSS from rss_samples.log.
--use-obs evaluates the Obs columns instead (self-test: they hold an analytic 10 ohm-m half-space, so with
RHO 10 the result must be PASS and with any other RHO it must be FAIL).
"""
import glob
import json
import math
import os
import re
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from acc_analyse import parse_log, parse_timev, read_csv_mt  # noqa: E402

MU0 = 4e-7 * math.pi
TOL_RHO, TOL_PH, TOL_DIAG = 0.05, 1.5, 0.02
N_SITES = 120
COMPS = ("Zxx", "Zxy", "Zyx", "Zyy")


def fkey(f):
    return float(f"{f:.6e}")


def read_dir(d):
    info = {"dir": d}
    files = sorted(glob.glob(os.path.join(d, "result_*_iter0.csv")))
    rows = []
    for fn in files:
        rk = int(re.search(r"result_(\d+)_iter0", fn).group(1))
        for r in read_csv_mt(fn):
            r["rank"] = rk
            r["dir"] = d
            rows.append(r)
    info["n_csv"], info["n_rows"] = len(files), len(rows)
    mis = 0.0
    for r in rows:
        for c in COMPS:
            for p in ("Re", "Im"):
                mis += ((r[f"{p}({c})_Obs"] - r[f"{p}({c})_Cal"]) / r[f"{p}({c})_SD"]) ** 2
    cnv = None
    cp = os.path.join(d, "femtic.cnv")
    if os.path.exists(cp):
        ln = [l.split() for l in open(cp) if l.strip() and not l.strip().startswith("Iter")]
        if ln:
            cnv = float(ln[0][5])
    info["misfit_csv"], info["misfit_cnv"] = mis, cnv
    info["misfit_rel_diff"] = abs(mis - cnv) / cnv if cnv else None
    rc = None
    dp = os.path.join(d, "FEMTIC.DONE")
    if os.path.exists(dp):
        rc = int(open(dp).read().strip().split("=")[1])
    info["rc"] = rc
    wp = os.path.join(d, "watchdog.log")
    info["watchdog"] = open(wp).read().strip() if os.path.exists(wp) else None
    info["time_v"] = parse_timev(os.path.join(d, "time_v.log"))
    ep = os.path.join(d, "run_env.txt")
    env = open(ep).read() if os.path.exists(ep) else ""
    m = re.search(r"np=(\d+) omp=(\d+)", env)
    info["np"], info["nt"] = (int(m.group(1)), int(m.group(2))) if m else (None, None)
    ctl = os.path.join(d, "control.dat")
    if os.path.exists(ctl):
        t = [l.strip() for l in open(ctl)]
        info["NUM_THREADS"] = int(t[t.index("NUM_THREADS") + 1]) if "NUM_THREADS" in t else None
    sp = os.path.join(d, "rss_samples.log")
    info["rss"] = {}
    if os.path.exists(sp):
        lines = [l.split() for l in open(sp) if l.strip()]
        new = [l for l in lines if len(l) == 9]
        old = [l for l in lines if len(l) == 5]
        if new:
            a = np.array([[float(x) for x in l[:6]] for l in new])
            nis = sorted({x for l in new for x in l[6:8] if x != "NA"})
            info["rss"] = {"format": "5 s sampler (femtic+prterun+mpirun)", "samples": len(a),
                           "peak_job_kB": float(a[:, 3].max()), "peak_femtic_kB": float(a[:, 2].max()),
                           "max_n_femtic": int(a[:, 1].max()), "min_MemAvailable_kB": float(a[:, 4].min()),
                           "max_swap_used_kB": float(a[:, 5].max()), "nice_values": nis,
                           "max_nlwp_femtic": int(max(int(l[8]) for l in new))}
        elif old:
            a = np.array([[float(x) for x in l] for l in old])
            info["rss"] = {"format": "1 s sampler (femtic only)", "samples": len(a),
                           "peak_femtic_kB": float(a[:, 2].max()), "peak_job_kB": float(a[:, 2].max()),
                           "max_n_femtic": int(a[:, 1].max()), "min_MemAvailable_kB": float(a[:, 3].min()),
                           "max_swap_used_kB": float(a[:, 4].max())}
    logs = {}
    for lp in sorted(glob.glob(os.path.join(d, "femtic_*.log"))):
        rk = int(re.search(r"femtic_(\d+)\.log", lp).group(1))
        logs[rk] = parse_log(lp)
    fwd = {}
    for rk, lg in logs.items():
        for f, t in lg["freqs"].items():
            fwd[fkey(f)] = {"rank": rk, "forward_s": t.get("t_end", float("nan")) - t.get("t_start", float("nan")),
                            "incore_MB": max(lg.get("incore_kB", [0])) / 1024,
                            "analysis_peak_MB": max(lg.get("analysis_peak_kB", [0])) / 1024}
    info["forward"] = fwd
    info["rank_total_s"] = {rk: lg.get("t_total") for rk, lg in logs.items()}
    info["neq"] = next((lg["neq"] for lg in logs.values() if "neq" in lg), None)
    info["log_error_lines"] = sorted({e for lg in logs.values() for e in lg.get("errors", [])})[:10]
    return info, rows


def main():
    args = sys.argv[1:]
    use_obs = "--use-obs" in args
    args = [a for a in args if a != "--use-obs"]
    js, nfreq = None, 8
    if "--json" in args:
        i = args.index("--json")
        js = args[i + 1]
        del args[i:i + 2]
    if "--nfreq" in args:
        i = args.index("--nfreq")
        nfreq = int(args[i + 1])
        del args[i:i + 2]
    rho, dirs = float(args[0]), args[1:]
    col = "Obs" if use_obs else "Cal"

    def Z(r, c):
        return complex(r[f"Re({c})_{col}"], r[f"Im({c})_{col}"])

    infos, merged, dup_diff = [], {}, {}
    for d in dirs:
        info, rows = read_dir(d)
        infos.append(info)
        for r in rows:
            k = (int(r["StaID"]), fkey(r["Freq[Hz]"]))
            if k in merged:
                if merged[k]["dir"] != d:
                    ref = merged[k]
                    dd = max(abs(Z(r, c) - Z(ref, c)) / abs(Z(ref, "Zxy")) for c in COMPS)
                    dup_diff[f"{k[1]:g}"] = max(dup_diff.get(f"{k[1]:g}", 0.0), dd)
                else:
                    dup_diff["same_dir_duplicates"] = dup_diff.get("same_dir_duplicates", 0) + 1
            else:
                merged[k] = r
    freqs = sorted({k[1] for k in merged}, reverse=True)
    sites = sorted({k[0] for k in merged})
    missing = [(s, f) for s in range(1, N_SITES + 1) for f in freqs if (s, f) not in merged]
    complete = len(freqs) == nfreq and sites == list(range(1, N_SITES + 1)) and not missing

    allr = list(merged.values())
    zxy_all = np.array([Z(r, "Zxy") for r in allr])
    zyx_all = np.array([Z(r, "Zyx") for r in allr])
    med_xy = float(np.degrees(np.median(np.angle(zxy_all))))
    conv = "exp(-i omega t)" if med_xy < 0 else "exp(+i omega t)"
    sgn = -1.0 if med_xy < 0 else 1.0
    convention = {"median_arg_Zxy_deg": med_xy,
                  "median_arg_Zyx_deg_0_360": float(np.degrees(np.median(np.mod(np.angle(zyx_all), 2 * np.pi)))),
                  "frac_ReZxy_pos": float(np.mean(zxy_all.real > 0)), "frac_ImZxy_neg": float(np.mean(zxy_all.imag < 0)),
                  "frac_ReZyx_neg": float(np.mean(zyx_all.real < 0)), "frac_ImZyx_pos": float(np.mean(zyx_all.imag > 0)),
                  "convention": conv}

    per_f, ok_all = {}, complete
    for f in freqs:
        w = 2 * math.pi * f
        rr = [merged[(s, f)] for s in sites if (s, f) in merged]
        st = np.array([int(r["StaID"]) for r in rr])
        zxx = np.array([Z(r, "Zxx") for r in rr])
        zxy = np.array([Z(r, "Zxy") for r in rr])
        zyx = np.array([Z(r, "Zyx") for r in rr])
        zyy = np.array([Z(r, "Zyy") for r in rr])
        e_xy = np.abs(zxy) ** 2 / (w * MU0) / rho - 1
        e_yx = np.abs(zyx) ** 2 / (w * MU0) / rho - 1
        p_xy = sgn * np.degrees(np.angle(zxy)) - 45
        p_yx = sgn * np.degrees(np.angle(-zyx)) - 45
        diag = np.maximum(np.abs(zxx), np.abs(zyy)) / np.abs(zxy)
        erho = np.maximum(np.abs(e_xy), np.abs(e_yx))
        eph = np.maximum(np.abs(p_xy), np.abs(p_yx))
        br, bp, bd = erho > TOL_RHO, eph > TOL_PH, diag > TOL_DIAG
        ok = bool(not (br | bp | bd).any()) and len(rr) == N_SITES
        ok_all &= ok
        both = np.concatenate([e_xy, e_yx])
        bothp = np.concatenate([p_xy, p_yx])
        worst = np.argsort(-erho)[:5]
        src = sorted({os.path.basename(os.path.normpath(r["dir"])) for r in rr})
        per_f[f"{f:g}"] = {
            "freq_hz": f, "n_sites": len(rr), "skin_depth_km": 0.503 * math.sqrt(rho / f), "source_dirs": src,
            "max_abs_rho_err_pct": float(100 * erho.max()),
            "signed_rho_err_at_max_pct": float(100 * both[np.argmax(np.abs(both))]),
            "rho_err_mean_pct": float(100 * both.mean()), "rho_err_std_pct": float(100 * both.std()),
            "rho_err_xy_pct_min_med_max": [float(100 * e_xy.min()), float(100 * np.median(e_xy)), float(100 * e_xy.max())],
            "rho_err_yx_pct_min_med_max": [float(100 * e_yx.min()), float(100 * np.median(e_yx)), float(100 * e_yx.max())],
            "max_abs_phase_err_deg": float(eph.max()),
            "signed_phase_err_at_max_deg": float(bothp[np.argmax(np.abs(bothp))]),
            "phase_err_mean_deg": float(bothp.mean()), "phase_err_std_deg": float(bothp.std()),
            "max_diag_ratio_pct": float(100 * diag.max()), "median_diag_ratio_pct": float(100 * np.median(diag)),
            "n_fail_rho": int(br.sum()), "n_fail_phase": int(bp.sum()), "n_fail_diag": int(bd.sum()),
            "n_fail_any": int((br | bp | bd).sum()),
            "worst_sites_by_rho": [[int(st[k]), round(float(100 * e_xy[k]), 3), round(float(100 * e_yx[k]), 3),
                                    round(float(p_xy[k]), 3), round(float(p_yx[k]), 3), round(float(100 * diag[k]), 3)]
                                   for k in worst],
            "pass": ok,
        }
    runs_ok = all(i["rc"] == 0 and not i["watchdog"] for i in infos)
    if not use_obs:
        ok_all &= runs_ok
    fwd = {}
    for i in infos:
        for f, v in i["forward"].items():
            fwd.setdefault(f"{f:g}", dict(v, dir=os.path.basename(os.path.normpath(i["dir"])), np=i["np"], nt=i["nt"]))
    res = {"rho": rho, "columns": col, "dirs": dirs, "complete": complete, "n_rows": len(merged),
           "missing": missing[:10], "convention": convention, "per_freq": per_f, "pass": bool(ok_all),
           "runs_ok": runs_ok, "duplicate_max_rel_diff": dup_diff, "runs": infos, "forward": fwd}

    print(f"rho {rho:g} ohm-m, columns {col}, {len(dirs)} run dir(s), {len(merged)} site-frequency rows, complete {complete}")
    print(f"convention from {col}: median arg Zxy {med_xy:.2f} deg -> {conv}; Re Zxy>0 {convention['frac_ReZxy_pos']:.3f}, "
          f"Im Zxy<0 {convention['frac_ImZxy_neg']:.3f}, Re Zyx<0 {convention['frac_ReZyx_neg']:.3f}, "
          f"Im Zyx>0 {convention['frac_ImZyx_pos']:.3f}")
    print(f"{'f Hz':>10} {'delta km':>8} {'max|rho|%':>9} {'mean%':>6} {'std%':>5} {'max|ph|':>7} {'mean':>6} {'std':>5} "
          f"{'diag%':>6} {'fail r/p/d':>10} {'fwd s':>6} {'np x nt':>7} {'PARDISO MB':>10}  source")
    for k, d in per_f.items():
        fw = fwd.get(k, {})
        print(f"{d['freq_hz']:>10g} {d['skin_depth_km']:>8.3f} {d['max_abs_rho_err_pct']:>9.2f} {d['rho_err_mean_pct']:>+6.2f} "
              f"{d['rho_err_std_pct']:>5.2f} {d['max_abs_phase_err_deg']:>7.2f} {d['phase_err_mean_deg']:>+6.2f} "
              f"{d['phase_err_std_deg']:>5.2f} {d['max_diag_ratio_pct']:>6.2f} "
              f"{'%d/%d/%d' % (d['n_fail_rho'], d['n_fail_phase'], d['n_fail_diag']):>10} "
              f"{fw.get('forward_s', float('nan')):>6.0f} {str(fw.get('np')) + 'x' + str(fw.get('nt')):>7} "
              f"{fw.get('incore_MB', float('nan')):>10.0f}  {','.join(d['source_dirs'])}  {'PASS' if d['pass'] else 'FAIL'}")
    for i in infos:
        tv, rs = i["time_v"], i["rss"]
        print(f"run {i['dir']}: rc {i['rc']} watchdog {'FIRED' if i['watchdog'] else 'no'}; np {i['np']} x nt {i['nt']} "
              f"(NUM_THREADS {i.get('NUM_THREADS')}); wall {tv.get('wall_s')} s, user {tv.get('user_s')} s, CPU {tv.get('cpu_pct')}; "
              f"max single RSS {tv.get('maxrss_single_kB')} kB; peak summed RSS {rs.get('peak_job_kB')} kB ({rs.get('format')}), "
              f"min MemAvailable {rs.get('min_MemAvailable_kB')} kB, swap {rs.get('max_swap_used_kB')} kB, "
              f"NI {rs.get('nice_values')}; misfit csv {i['misfit_csv']:.6e} cnv {i['misfit_cnv']} "
              f"rel {i['misfit_rel_diff']}; neq {i['neq']}")
        if i["log_error_lines"]:
            print("   log lines matching error/warning:", i["log_error_lines"][:3])
    if dup_diff:
        print("duplicates across dirs, max |dZ|/|Zxy| per frequency:",
              {k: (f"{v:.2e}" if isinstance(v, float) else v) for k, v in dup_diff.items()})
    print("RESULT:", "PASS" if res["pass"] else "FAIL")
    if js:
        with open(js, "w", newline="\n") as fo:
            json.dump(res, fo, indent=1, default=str)


if __name__ == "__main__":
    main()
