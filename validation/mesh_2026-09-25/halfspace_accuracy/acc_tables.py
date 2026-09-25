#!/usr/bin/env python3
"""acc_tables.py -- print the per-round markdown tables of halfspace_accuracy.md from the saved evidence, so no
number in the report is typed by hand.

    python acc_tables.py [ROOT]          (ROOT default: the project root, two levels above this folder's parent)

Reads, for N = 1, 2, 3:
  mesh/vulcan_vN/mesh_logs/{mesh_stats.json, summary.txt, chain_total.timev}
  mesh/vulcan_vN/halfspace/acc_{3,100}/acc_eval_vN_{3,100}.json   (acc_eval.py output; missing -> "not run")
"""
import json
import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
RHOS = (3, 100)


def timev(path):
    d = {}
    if not os.path.exists(path):
        return d
    for l in open(path):
        k, _, v = l.strip().partition(": ")
        if k.startswith("Elapsed (wall clock)"):
            s = 0.0
            for x in v.split(":"):
                s = s * 60 + float(x)
            d["wall_s"] = s
        elif k == "Maximum resident set size (kbytes)":
            d["maxrss_kB"] = int(v)
    return d


def q(stat, key):
    v = stat.get(key)
    return v


def mesh_info(n):
    m = os.path.join(ROOT, "mesh", f"vulcan_v{n}", "mesh_logs")
    js = json.load(open(os.path.join(m, "mesh_stats.json")))
    c = js["counts"]
    ss = js["sites_summary"]
    tv = timev(os.path.join(m, "chain_total.timev"))
    return {"elements": c["elements"], "edges": c["edges"], "nodes": c["nodes"],
            "earth_cells": c["earth_parameter_cells"], "site_tri": ss["tri_max_edge"],
            "earth_depth": ss["earth_el_depth"], "air_height": ss["air_el_height"],
            "build_s": tv.get("wall_s"), "build_rss_MB": tv.get("maxrss_kB", 0) / 1024}


def acc(n, rho):
    p = os.path.join(ROOT, "mesh", f"vulcan_v{n}", "halfspace", f"acc_{rho}", f"acc_eval_v{n}_{rho}.json")
    return json.load(open(p)) if os.path.exists(p) else None


def fmt_stat(s, scale=1000.0):
    if isinstance(s, dict):
        return f"{scale * s['median']:.1f} ({scale * s['min']:.1f}-{scale * s['max']:.1f})"
    return str(s)


def main():
    for n in (1, 2, 3):
        try:
            mi = mesh_info(n)
        except FileNotFoundError:
            print(f"\n### Round {n}: mesh v{n} not built\n")
            continue
        A = {r: acc(n, r) for r in RHOS}
        print(f"\n### Round {n}: config/vulcan_mesh_v{n}.yml\n")
        print("| quantity | value |\n|---|---|")
        print(f"| tetrahedra / nodes / edges (FEMTIC unknowns) | {mi['elements']:,} / {mi['nodes']:,} / {mi['edges']:,} |")
        print(f"| earth parameter cells | {mi['earth_cells']:,} |")
        print(f"| site triangle max edge, m: median (min-max) | {fmt_stat(mi['site_tri'])} |")
        print(f"| earth element depth under site, m | {fmt_stat(mi['earth_depth'])} |")
        print(f"| air element height above site, m | {fmt_stat(mi['air_height'])} |")
        print(f"| mesh build (whole chain, 1 thread except 1 s of makeTetraMesh) | {mi['build_s']:.0f} s, peak {mi['build_rss_MB'] / 1024:.2f} GB |")
        for r in RHOS:
            a = A[r]
            if a is None:
                print(f"| {r} ohm-m run | not run |")
                continue
            runs = a["runs"]
            for x in runs:
                nm = os.path.basename(os.path.normpath(x["dir"]))
                nt = x.get("NUM_THREADS")
                pre = " (earlier run, before the PC resource policy)" if nm.startswith("old_") else ""
                fq = sorted((float(k) for k, v in a["forward"].items() if v.get("dir") == nm), reverse=True)
                inc = max((v.get("incore_MB", 0) for v in a["forward"].values() if v.get("dir") == nm), default=0)
                rs = x["rss"]
                print(f"| {r} ohm-m, run {nm}{pre}: {x['np']} rank(s) x {nt} threads, NI {rs.get('nice_values', 'n/a')}; "
                      f"bands used {', '.join(f'{f:g}' for f in fq) or 'none (all duplicated)'} | "
                      f"wall {x['time_v'].get('wall_s', 0) / 60:.1f} min, peak job RSS {rs.get('peak_job_kB', 0) / 1e6:.2f} GB, "
                      f"largest rank {x['time_v'].get('maxrss_single_kB', 0) / 1e6:.2f} GB, PARDISO in-core {inc * 1024 / 1e6:.1f} GB; "
                      f"exit {x['rc']}, watchdog {'FIRED' if x['watchdog'] else 'never fired'}, misfit vs femtic.cnv {x['misfit_rel_diff']:.1e} |")
            dd = a.get("duplicate_max_rel_diff") or {}
            if dd:
                print(f"| {r} ohm-m: same bands from two runs, max abs(dZ)/abs(Zxy) | "
                      + ", ".join(f"{k} Hz: {v:.1e}" for k, v in dd.items() if isinstance(v, float)) + " |")
        print()
        hdr = "| f (Hz) | delta 3 / 100 ohm-m (km) |"
        sep = "|---:|---|"
        for r in RHOS:
            hdr += f" {r} ohm-m: max abs rho_a err % | phase err deg | diag % | sites failing | fwd s |"
            sep += "---:|---:|---:|---:|---:|"
        hdr += " verdict |"
        sep += "---|"
        print(hdr)
        print(sep)
        freqs = None
        for r in RHOS:
            if A[r]:
                freqs = list(A[r]["per_freq"].keys())
                break
        for fk in freqs or []:
            f = float(fk)
            row = f"| {fk} | {0.503 * (3 / f) ** 0.5:.3g} / {0.503 * (100 / f) ** 0.5:.3g} |"
            states = []
            for r in RHOS:
                a = A[r]
                if a is None or fk not in a["per_freq"]:
                    row += " - | - | - | - | - |"
                    states.append(None)
                    continue
                d = a["per_freq"][fk]
                fw = a["forward"].get(fk, {})

                def b(x, lim):
                    return f"**{x:.2f}**" if x > lim else f"{x:.2f}"
                row += (f" {b(d['max_abs_rho_err_pct'], 5)} | {b(d['max_abs_phase_err_deg'], 1.5)} | "
                        f"{b(d['max_diag_ratio_pct'], 2)} | {d['n_fail_any']} | {fw.get('forward_s', float('nan')):.0f} |")
                states.append(bool(d["pass"]))
            v = "FAIL" if False in states else ("incomplete" if None in states else "PASS")
            row += f" {v} |"
            print(row)
        full = all(A[r] is not None for r in RHOS)
        rv = "PASS" if (full and all(A[r]["pass"] for r in RHOS)) else (
            "FAIL" if any(A[r] is not None and not A[r]["pass"] for r in RHOS) else "incomplete")
        print(f"\nRound {n} verdict: **{rv}**" + ("" if full else " (not every resistivity was run)"))
        for r in RHOS:
            if A[r]:
                c = A[r]["convention"]
                print(f"- {r} ohm-m: convention from Cal: median arg Zxy {c['median_arg_Zxy_deg']:.2f} deg -> {c['convention']}; "
                      f"rows {A[r]['n_rows']}, complete {A[r]['complete']}")


if __name__ == "__main__":
    main()
