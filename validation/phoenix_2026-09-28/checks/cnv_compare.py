#!/usr/bin/env python3
"""Check a (and the femtic.cnv half of check b) for the Phoenix B2 smoke job 16153670.

Compares femtic.cnv rows digit by digit. FEMTIC prints each value with 7 significant digits
(%e: d.dddddd). "Equal to N significant digits" = same sign and exponent, and the first N mantissa
digits agree. All 7 digits equal means the printed rows are identical.

Check a fails if, for any iteration common to the Phoenix straight run and the WSL reference, Misfit or
RMS agree to fewer than 6 significant digits. The fail cases run first, on the same code path.

Run from the repository root:  python validation/phoenix_2026-09-28/checks/cnv_compare.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EV = os.path.dirname(HERE)                                   # validation/phoenix_2026-09-28
WSL = os.path.join(os.path.dirname(EV), "wsl_2026-09-25")
COLS = ["Iter#", "Retrial#", "Alpha", "Damp", "Roughness", "Misfit", "RMS", "ObjFunc"]
NEED = 6                                                     # significant digits required (RUNBOOK B2)


def rows_from(path, start_after=None):
    """{iter: [8 tokens]} from a femtic.cnv, or from the cnv block printed inside a log."""
    out, on = {}, start_after is None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            t = line.split()
            if not on:
                on = bool(t) and t[0] == "Iter#"
                continue
            if len(t) == 8 and t[0].isdigit() and t[1].isdigit():
                out[int(t[0])] = t                                # last row per iteration = accepted one
            elif out and t and t[0] == "Iter#":
                break
    return out


def sig_digits(a, b):
    """Number of leading significant digits two printed %e values share (7 = identical print)."""
    if a == b:
        return len(a.lstrip("-").split("e")[0].replace(".", ""))
    ma, ea = a.split("e")
    mb, eb = b.split("e")
    if int(ea) != int(eb) or ma.startswith("-") != mb.startswith("-"):
        return 0
    da, db = ma.lstrip("-").replace(".", ""), mb.lstrip("-").replace(".", "")
    n = 0
    for x, y in zip(da, db):
        if x != y:
            break
        n += 1
    return n


def rel(a, b):
    x, y = float(a), float(b)
    s = max(abs(x), abs(y))
    return 0.0 if s == 0 else abs(x - y) / s


def compare(label, A, B, pairs, verbose=True):
    """pairs = [(iterA, iterB)]; returns True (PASS) if Misfit and RMS share >= NEED digits for every pair."""
    ok = True
    if verbose:
        print(f"  {label}")
    for ia, ib in pairs:
        ra, rb = A[ia], B[ib]
        dm, dr = sig_digits(ra[5], rb[5]), sig_digits(ra[6], rb[6])
        same_row = ra[1:] == rb[1:]
        cols_diff = [COLS[k] for k in range(1, 8) if ra[k] != rb[k]]
        good = dm >= NEED and dr >= NEED
        ok &= good
        if verbose:
            print(f"    iter {ia} vs {ib}: Misfit {ra[5]} / {rb[5]} ({dm} digits, rel {rel(ra[5], rb[5]):.1e});"
                  f" RMS {ra[6]} / {rb[6]} ({dr} digits, rel {rel(ra[6], rb[6]):.1e});"
                  f" whole row {'identical' if same_row else 'differs in ' + ','.join(cols_diff)}"
                  f" -> {'ok' if good else 'BELOW ' + str(NEED)}")
    if verbose:
        print(f"    => {'PASS' if ok else 'FAIL'}")
    return ok


def main():
    ph = rows_from(os.path.join(EV, "straight", "femtic.cnv.straight"))
    ph_leg1 = rows_from(os.path.join(EV, "restart", "femtic.cnv.leg1"))
    ph_leg2 = rows_from(os.path.join(EV, "restart", "femtic.cnv.leg2"))
    wsl5 = rows_from(os.path.join(WSL, "run_logs", "femtic.cnv"))
    s6 = rows_from(os.path.join(WSL, "build_logs", "s6_foss2023a.log"), start_after="Iter#")
    print(f"rows: Phoenix straight {sorted(ph)}, WSL run_logs {sorted(wsl5)}, WSL s6_foss2023a {sorted(s6)}")
    common = sorted(set(ph) & set(wsl5))

    print("\n== Check a. This test fails if Misfit or RMS of any common iteration agree to fewer than"
          f" {NEED} significant digits.")
    print("-- fail cases first (the same comparison must say FAIL):")
    f1 = compare("F1 rows shifted by one (Phoenix iter k vs WSL iter k+1)", ph, wsl5,
                 [(k, k + 1) for k in common])
    mut = {k: list(v) for k, v in wsl5.items()}
    mut[0][5] = "5.752652e+03"                                # 6th significant digit changed (4 -> 5)
    f2 = compare("F2 WSL iteration-0 Misfit changed in the 6th digit (5.752642e+03 -> 5.752652e+03)", ph, mut,
                 [(k, k) for k in common])
    mut7 = {k: list(v) for k, v in wsl5.items()}
    mut7[0][5] = "5.752643e+03"                               # 7th digit only: still 6 equal digits
    f3 = compare("F3 boundary: 7th digit changed (5.752643e+03) -> must still PASS at 6 digits", ph, mut7,
                 [(k, k) for k in common])
    fail_cases_ok = (not f1) and (not f2) and f3
    print(f"  fail cases behave as designed: {'yes' if fail_cases_ok else 'NO'}")

    print("-- real comparison:")
    a1 = compare("A1 Phoenix straight (foss/2023a, 2 ranks x 2 threads) vs WSL run_logs/femtic.cnv"
                 " (gcc 15.3/OpenMPI 5.0.10/MKL 2026.1, 2 x 2)", ph, wsl5, [(k, k) for k in common])
    c2 = sorted(set(ph) & set(s6))
    a2 = compare("A2 Phoenix straight vs WSL build_logs/s6_foss2023a.log (gcc 12.3/OpenMPI 4.1.5/MKL 2023.1,"
                 " same versions as foss/2023a+imkl/2023.1.0; 2 x 4 per smoke_crosscheck.txt)", ph, s6,
                 [(k, k) for k in c2])

    print("\n== T5 rows (femtic.cnv half of check b). Fails if a restart row is not print-identical to the straight row.")
    t5f = compare("T5 fail case: straight iter 1 vs leg2 iter 2", ph, ph_leg2, [(1, 2)])
    t5a = compare("T5 straight vs restart leg1 (iterations 0, 1)", ph, ph_leg1, [(0, 0), (1, 1)])
    t5b = compare("T5 straight vs restart leg2 (iterations 1, 2)", ph, ph_leg2, [(1, 1), (2, 2)])
    ident = all(ph[k] == ph_leg1[k] for k in (0, 1)) and all(ph[k] == ph_leg2[k] for k in (1, 2))
    print(f"  all four restart rows string-identical to the straight rows: {ident}")

    verdict = fail_cases_ok and a1 and a2 and (not t5f) and t5a and t5b and ident
    print(f"\nSUMMARY cnv_compare: check a {'PASS' if a1 and a2 else 'FAIL'} (A1 {a1}, A2 {a2});"
          f" T5 rows identical {ident}; fail cases as designed {fail_cases_ok and not t5f}")
    return 0 if verdict else 1


if __name__ == "__main__":
    sys.exit(main())
