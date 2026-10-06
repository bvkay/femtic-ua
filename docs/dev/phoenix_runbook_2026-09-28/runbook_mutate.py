"""runbook_mutate.py -- mutants of RUNBOOK_first_inversion.md, UPLOAD_LIST_2026-09-28.txt and the kit files they name,
for tests/runbook_check.sh.

    python runbook_mutate.py RUNBOOK LIST OUT_RUNBOOK OUT_LIST NAME [NAME ...]   (runbook/list mutations; 'all' = all of them)
    python runbook_mutate.py --kit KIT_DIR OUT_DIR NAME [NAME ...]              (copies the kit, then mutates the copy;
                                                                                 any mutation, including kit files)
    python runbook_mutate.py --list                                             (name, file, group it must fail)

Each mutation puts back one defect found in review, or switches off one guard of a runbook command. The check
group named in the table must FAIL on it (runbook_check.sh prints 'failed groups: ...'). A kit-file mutant runs as
WT=<worktree> bash OUT_DIR/tests/runbook_check.sh, so the checker reads the mutated copy of the kit. Exit 2 if an
anchor is not found exactly once, so a mutant never silently equals the original.
Not a mutant: the B1.3 CR command without its '*' strip (awk '{print $2}'). Git Bash's md5sum writes
'<md5> *<file>', but the unquoted $(...) is glob-expanded and '*hpc/...' matches 'hpc/...' again, so the
command behaves the same (checked 2026-09-28: runbook_check.sh passes it). The strip stays for clarity.
"""
import os
import shutil
import sys

BS = chr(92)
FILES = {"rb": "RUNBOOK_first_inversion.md", "ul": "UPLOAD_LIST_2026-09-28.txt"}
M = [  # name, file ('rb', 'ul' or a path in the kit), group(s) that must fail, anchor, replacement
    ("b1_lastline", "rb", "K1", "grep -cE '^== .*  BUILD DONE  T1=PASS  ' \"$BL\"", "tail -1 \"$BL\" | grep -cE '^== .*  BUILD DONE  T1=PASS  '"),
    ("b1_install", "rb", "K1", "install -m 644 $PLAN/femtic_lib.sh $BIN/\ngrep '^FEMTIC_LIB_VERSION=' $BIN/femtic_lib.sh\ncmp", "grep '^FEMTIC_LIB_VERSION=' $BIN/femtic_lib.sh\ncmp"),
    ("b2_t5", "rb", "K1", "T5=(PASS|INCONCLUSIVE)   log: ' slurm-femtic_smoke-$JS.out", "T5=PASS   log: ' slurm-femtic_smoke-$JS.out"),
    ("b3_header", "rb", "K1", "sha256sum observe.dat | cut -c1-16\necho $(head -2 mesh.dat) / $(head -1 resistivity_block_iter0.dat)\n", "sha256sum observe.dat | cut -c1-16\necho \"$(head -2 mesh.dat) / $(head -1 resistivity_block_iter0.dat)\"\n"),
    ("b3_guard", "rb", "K1", "echo \"599109ca5e809c5f474011006595baac  observe.dat\" | md5sum -c --status - && [ ! -e observe_unrotated.dat ]", "[ ! -e observe_unrotated.dat ]"),
    ("b3_md5", "rb", "K1 K4", "6f1e579e818bc9bafa64bc4c091f3ba4  observe.dat", "599109ca5e809c5f474011006595baac  observe.dat"),
    ("gate_link", "rb", "K1", "mkdir -p $WK/$M/$G && cd $WK/$M/$G || break\ncp ../../../inputs/vulcan_$M/control.dat .\n", "mkdir -p $WK/$M/$G && cd $WK/$M/$G || break\nln -sfn ../../../inputs/vulcan_$M/control.dat control.dat\n"),
    ("link_depth", "rb", "K1 K7", "do ln -sfn ../../../inputs/vulcan_$M/$f $f; done\nls -L", "do ln -sfn ../../inputs/vulcan_$M/$f $f; done\nls -L"),
    ("bind_overlap", "rb", "K1", "if (i in own) dup++; ", ""),
    ("eff_threshold", "rb", "K1", "(e >= 50 ? \"PASS\" : \"FAIL\") }'\n```\nPASS looks like this (your values", "(e >= 0 ? \"PASS\" : \"FAIL\") }'\n```\nPASS looks like this (your values"),
    ("b4b_job", "rb", "K1", "($2 == j ? \"PASS\"", "(1 ? \"PASS\""),
    ("b4b_fwd", "rb", "K1", "FWD_MB=$F femtic_mem_model .", "femtic_mem_model ."),
    ("b5_zguard", "rb", "K1", "(z > 0 && p > 0 && p >= lo", "(p >= lo"),
    ("b5_slack0", "rb", "K1", "lo = 0.8 * z - 1; hi = 1.2 * z + 1;", "lo = 0.8 * z; hi = 1.2 * z;"),
    ("b5_slack2", "rb", "K1", "lo = 0.8 * z - 1; hi = 1.2 * z + 1;", "lo = 0.8 * z - 2; hi = 1.2 * z + 2;"),
    ("b5_primary", "rb", "K1", "p = k / 1024 / n; q = r / n", "p = r / n; q = k / 1024 / n"),
    ("b5_cross", "rb", "K1", "q >= 0.9 * p && q <= 1.1 * p", "q >= 0.5 * p && q <= 1.5 * p"),
    ("b5_jt", "rb", "K1", "cd $WK/$M/t4 && JT=${J4b:-$J4} && echo \"judging job", "cd $WK/$M/t4 && JT=$J4 && echo \"judging job"),
    ("b5_copyjt", "rb", "K1", "cd $WK/$M/t4 && JT=${J4b:-$J4} && mkdir -p $P/export/B5_$JT", "cd $WK/$M/t4 && JT=$J4 && mkdir -p $P/export/B5_$JT"),
    ("niv_ledger", "rb", "K1", " | tee -a $LEDGER; else echo \"no job id", "; else echo \"no job id"),
    ("niv_env", "rb", "K1", "--export=ALL,WATCH_S=10,NIV=840 $PLAN/04_inversion.slurm", "--export=ALL,WATCH_S=10 $PLAN/04_inversion.slurm"),
    ("cr_glob", "rb", "K1", "grep -c $'" + BS + "r' $(awk '{f = $2; sub(/^[*]/, \"\", f); print f}' hpc/phoenix_plan/UPLOAD_2026-09-28.md5)", "grep -c $'" + BS + "r' hpc/phoenix_plan/*.sh"),
    ("quote_drift", "rb", "K2", "frequency rows over all ranks: N (must equal F = 21)", "frequency rows over ranks: N (must equal F = 21)"),
    ("port_count", "rb", "K2", "`SUMMARY: 10 passed, 0 failed`", "`SUMMARY: 6 passed, 0 failed`"),
    ("neq", "rb", "K3", "(nodes + elements: 2,847,429", "(nodes + elements: 2,844,872"),
    ("prelaunch", "rb", "K3", "(31322 forward", "(31323 forward"),
    ("band", "rb", "K3", "PASS band 57,420-86,132 MiB", "PASS band 57,421-86,131 MiB"),
    ("pardiso_fmt", "rb", "K3", "`22.4 GiB (23452200 KB)`", "`22.4 GiB (2.34522e+07 KB)`"),
    ("time_v2", "rb", "K3 K7", "-J v2_gate100 --ntasks-per-node=3 --cpus-per-task=24 --time=02:00:00", "-J v2_gate100 --ntasks-per-node=3 --cpus-per-task=24"),
    ("timev_count", "rb", "K3", "20 of the 21", "21 of the 21"),
    ("list_size", "ul", "K4", " 255727272 ", " 255727273 "),
    ("partA", "rb", "K4", " hpc/phoenix_plan/tests/portability_test.sh hpc/phoenix_plan/tests/halfspace_eval_test.sh", " hpc/phoenix_plan/tests/halfspace_eval_test.sh"),
    ("notuploaded", "ul", "K4", "only README.md changed (documentation, read by no script)", "unchanged"),
    ("notup_partA", "ul", "K4", "  * tools/__pycache__/ (Python's byte-code cache).", "  * tests/runbook_check.sh (PC only) and tools/__pycache__/ (Python's byte-code cache)."),
    ("list_stale", "ul", "K4", "# Part D: the rotated v2 data", "# Part D: the rotated data"),
    ("syntax", "rb", "K5", "tail -1 $P/export/B1/c1c2_test_$T.txt", "tail -1 \"$P/export/B1/c1c2_test_$T.txt"),
    ("cite", "rb", "K6", "s6_foss2023a.log:34", "s6_foss2023a.log:35"),
    ("cite_ps", "rb", "K6", "femtic_lib.sh:542", "femtic_lib.sh:541"),
    ("dep", "rb", "K7", "J100=$(sbatch --parsable -J v2_gate100", "J100=$(sbatch --parsable --dependency=afterok:$JS -J v2_gate100"),
    ("dep_text", "rb", "K7", "**Submit B4a after reading B2's output.**", "**Submit B4a after B2.**"),
    ("samedir", "rb", "K7", "cd $WK/v2/gate3\nJ3=", "cd $WK/v2/gate100\nJ3="),
    ("usr1", "rb", "K7", "stops femtic about 10 min before the limit", "stops femtic 5 min before the limit"),
    ("fwdsrc", "rb", "K7", "cp $WK/$M/gate100/logs/fwd_rank_mb logs/", "cp $WK/$M/gate3/logs/fwd_rank_mb logs/"),
    ("never_t4", "rb", "K7", "from a `gate*` directory (04 runs", "from a `gate*` directory or `t4` (04 runs"),
    ("never_gate", "rb", "K7", "* run 04 or `05_chain.sh` from a `gate*` directory (04 runs in `$WK/<mesh>/t4` for B5, and later in `inv01`);\n", ""),
    ("never_inputs", "rb", "K7", "* run a job in `$IN/vulcan_v2` or `$IN/vulcan_v3` (the immutable inputs; jobs run in `$WK/<mesh>/<name>`);\n", ""),
    ("job_in_inputs", "rb", "K7", "cd $WK/v2/gate100\nJ100=", "cd $IN/vulcan_v2\nJ100="),
    ("conv_in", "rb", "K7", "IN=$VF/inputs\n", "IN=$VF/inversion\n"),
    ("list_folder", "ul", "K7", "/hpcfs/users/a1690074/vulcan_femtic/inputs/vulcan_v2/mesh.dat", "/hpcfs/users/a1690074/vulcan_femtic/inversion/v2/mesh.dat"),
    ("readme_inv01", "README_phoenix.md", "K7", "into the input folders `vulcan_femtic/inputs/vulcan_v2` and `.../inputs/vulcan_v3`. They", "into `vulcan_femtic/inversion/inv01`. They"),
    ("readme_gate", "README_phoenix.md", "K7", "and in `work/v2/gate3` the same with `START_RHO=3`", "and again with `START_RHO=3`"),
    ("s06_inv01", "06_forward_only.slurm", "K7", "work/v2/gate100 && sbatch --export=ALL,START_RHO=100", "inversion/inv01 && sbatch --export=ALL,START_RHO=100"),
    ("v01_gate3", "01_build_femtic.sh", "K2", "[ \"${FEMTIC_LIB_VERSION:-0}\" -ge 4 ] || die \"SMOKE_ONLY:", "[ \"${FEMTIC_LIB_VERSION:-0}\" -ge 3 ] || die \"SMOKE_ONLY:"),
    ("v03_gate3", "03_mesh.slurm", "K2", "[ \"${FEMTIC_LIB_VERSION:-0}\" -ge 4 ] || { echo", "[ \"${FEMTIC_LIB_VERSION:-0}\" -ge 3 ] || { echo"),
]


def mutate(paths, names):
    """paths: file key -> (input path, output path). Returns 0, or 2 on an unknown name or a bad anchor."""
    unknown = set(names) - {m[0] for m in M} - {"all"}
    if unknown:
        print("unknown mutation(s): %s" % " ".join(sorted(unknown)))
        return 2
    pick = [m for m in M if "all" in names or m[0] in names]
    txt = {}
    for n, f, g, old, new in pick:
        if f not in paths:
            print("mutation %s changes %s: run it with --kit" % (n, f))
            return 2
        if f not in txt:
            txt[f] = open(paths[f][0], encoding="utf-8", newline="").read()
        c = txt[f].count(old)
        if c != 1:
            print("mutation %s: anchor found %d times, want 1: %r" % (n, c, old))
            return 2
        txt[f] = txt[f].replace(old, new)
        print("mutation %s (%s, must fail %s): %r -> %r" % (n, f, g, old, new))
    for f, (src, dst) in paths.items():
        t = txt[f] if f in txt else open(src, encoding="utf-8", newline="").read()
        open(dst, "w", encoding="utf-8", newline="").write(t)
    return 0


def main(a):
    if a[:1] == ["--list"]:
        for n, f, g, _, _ in M:
            print("%-14s %s  must fail: %s" % (n, f, g))
        return 0
    if a[:1] == ["--kit"]:
        kit, out, names = a[1], a[2], a[3:] or ["all"]
        if os.path.exists(out):
            shutil.rmtree(out)
        shutil.copytree(kit, out, ignore=shutil.ignore_patterns("__pycache__"))
        keys = set(FILES) | {m[1] for m in M}
        paths = {}
        for k in keys:
            p = os.path.join(out, FILES.get(k, k))
            paths[k] = (p, p)
        return mutate(paths, names)
    rb, ul, orb, oul = a[:4]
    return mutate({"rb": (rb, orb), "ul": (ul, oul)}, a[4:] or ["all"])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
