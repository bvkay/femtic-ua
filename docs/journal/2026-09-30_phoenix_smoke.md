# 2026-09-30 - Phoenix B2 smoke: evidence filed, checked and verified

**Who/what:** Ben copied the first Phoenix job outputs into `D:/BEN/FEMTIC_2026/hpc` (main checkout, untracked).
One Opus agent filed and checked them (`validation/phoenix_2026-09-28/`, below "PHX/"), an adversarial verifier
reviewed that work, and this agent updated `docs/STATUS.md` and wrote this entry. Limits as before: light Python/bash
on the PC only; no femtic, tetgen, mpirun or WSL; Ben's files in the main checkout were only read (md5-checked
against PHX/MANIFEST.md5 before and after); nothing was committed.

## What Ben ran on Phoenix (2026-09-28, ACST) and copied back
- **21:10:21-21:11:15, login node p2-log-2: rebuild with the committed kit** (HEAD 55bbf44, not the version-4 kit of
  this worktree). `BUILD DONE  T1=PASS  T2=SKIPPED  T5=SKIPPED`; femtic 26c8606, 1,494,008 B; femtic_env.sh 732 B
  with the /apps remap; femtic_lib.sh 19,992 B, FEMTIC_LIB_VERSION 2 (PHX/build_foss_20260928_211021.log:3,250-252,263).
- **21:13:08-21:13:54, job 16153670 (`femtic_smoke`), icelake node p2-cpu-14: SMOKE_ONLY** with the runbook B2
  command. `SMOKE_ONLY DONE  T1=PASS  T2=PASS  T5=PASS` (PHX/slurm-femtic_smoke-16153670.out:57). **First FEMTIC
  execution on a Phoenix compute node.** FEMTIC's example INV_MT_01/Tetra, 2 ranks x 2 threads, `--bind-to none`.
- Copied back: the job .out and its smoke log (byte-identical, 01 tees its output), the 09-28 build log, the two
  failed 09-25 evening build logs (19:37 and 19:44, fa58604 kit), and the work directory
  `smoke_foss_20260928_211308/{straight,restart}/` (69 files, 17 MB). A sixth file, build_foss_20260925_181212.log,
  is byte-identical to the tracked hpc/phoenix_plan copy.
- **Not copied:** `sacct`, `rcstat`, TotalCPU, and the 09-25 19:44 job's .out (the only record of its failure).

Runbook journal line (RUNBOOK:218-219 template):
`B2 2026-09-28 job 16153670 (icelake p2-cpu-14): SMOKE_ONLY DONE T1=PASS T2=PASS T5=PASS; row 0 Misfit 5.752642e+03
RMS 2.234639e+00 (WSL 5.752642e+03 / 2.234639e+00); Elapsed 46 s by 01's date lines (sacct not copied), rcstat not
copied. First FEMTIC execution on a Phoenix compute node. Kit: committed 55bbf44, library version 2.`

## Evidence filed: validation/phoenix_2026-09-28/ (33 files, 418 KB, LF only, untracked)
- 24 text copies: the 5 logs; control.dat, femtic.cnv*, femtic_*.log*, stdout_*.txt and result.case of straight/
  and restart/. `.gitignore:21` ignores `**/femtic_[0-9]*.log`, so the rank logs were copied as
  `femtic_{0,1}_straight.log.txt` and `femtic_{0,1}_leg2.log.txt`. Leg 1's rank-1 log was overwritten on Phoenix.
- MANIFEST.md5: md5, size and path of all 74 files (5 logs + 69 run files), including those left on Ben's disk.
- checks/: cnv_compare.py (a, T5 rows), model_diff.py (b), lib_parsers.sh (c), timing.sh (d), build_logs.sh (e) and
  run_all.sh, which writes checks/checks_output.txt. Rerun: `bash validation/phoenix_2026-09-28/checks/run_all.sh`.
- README.md: what ran, verdicts, checks a-e, findings F1-F6, what the run proves and does not, and section 7 (B1/B2).

## What the checks found
Each check states its failure criterion, and its fail case ran before the real case.

| Check | Fails if | Fail case | Result |
|---|---|---|---|
| Manifest | any of the 74 md5s differs | one md5 swapped: FAILED, exit 1 | 74/74 OK (rechecked at the end); copies 24/24 |
| Copies tracked | git check-ignore flags a copy | original names flagged by .gitignore:21 | none of the 24 flagged |
| a. vs WSL run_logs (2x2, gcc15/OMPI5/MKL2026) | Misfit or RMS of rows 0-2 agree to < 6 digits | shifted rows (0-1 digits); 6th digit changed (5) | PASS: all 8 columns, 7/7 digits |
| a. vs WSL s6_foss2023a (same versions, 2x4) | same | same | PASS: identical |
| a. layout | ranks/threads differ from the reference | s6 ran 4 threads per rank | run_logs is 2x2 with the same frequency split |
| b. T5 cnv rows | a restart row differs from the straight row | iter 1 vs leg-2 iter 2 | PASS: 4/4 rows identical |
| b. final model | restart iter2 model not byte-identical | iter 1 vs 2: 288/288 blocks | **FAIL**: 29/288 blocks differ by 1 in the 7th digit, max rel 9.97e-7 |
| b. responses | Obs/SD differ, or the metric misses a real change | iter 0 vs 1: 0.11 of \|Z\|, 3.5 SD | baseline (iter 0 twice): 16/4608 at 1.1e-9; iter 1: 4.0e-7, 3.3e-6 SD; iter 2: 3.9e-7 |
| c. v4 parsers on real logs | empty or not the hand-read value | v2 pardiso_max_gb on 2.5e+07 KB gives 0.0; truncated log gives no N_iv | 21/21 PASS (N_iv 144, N_eq 39,254, PARDISO 206,994 KB) |
| d. speed | WSL 2x2 time predicted from Phoenix off by > 2x | synthetic 3x slower run: 3.09 | 38 s predicted vs 36.9 s measured: 1.03 |
| e1. binary sizes | any of 7 sizes differs from 09-25 18:12 | femtic_env.sh and femtic_lib.sh (changed) | 7/7 equal (sizes, not bytes) |
| e2. env writer | 09-28 femtic_env.sh not HEAD's size | 09-28 file vs fa58604 writer (613 B) | 732 B = HEAD writer |
| e3. source/toolchain | commits, modules, commands or warnings differ | 09-25 19:44 log: 0 commands | identical: 7 commits, 24 modules, 107 commands, 25 warnings |
| B2 criterion 1 | the DONE grep does not print 1 | 09-28 build log: 0 | 1 |
| Part 4 | a lib function 01 calls differs HEAD vs v4 | femtic_pardiso_max_gb: DIFFERS | 6/6 identical |

**The one FAIL (final model byte identity) was explained, not loosened.** A no-restart baseline (iteration 0 run
twice from identical inputs) already differs in 16 of 4,608 responses, so FEMTIC on Phoenix is not bitwise
reproducible; and a restart re-reads a model printed to 7 digits. Both effects are at print precision (4e-7 of |Z|),
far below the 5 % floor. Consequence: no kit criterion may demand byte identity of FEMTIC outputs.

**Findings** (PHX/README.md section 5): F1 not bitwise reproducible (PARDISO in-core 205,789 vs 206,700 KB for the
same pattern; the parallel-reordering cause is a hypothesis). F2 every restart perturbs the model by up to 5e-7
relative. F3 `Failed to modify UD QP to INIT on mlx5_0: Operation not permitted` in stdout, 4 per rank in straight
and leg 2, none in leg 1 (recounted this session: 8, 0, 8 lines); harmless on one node, look before any multi-node
run; the libfabric PSM3 source is unverified. F4 these logs do not exercise the version-3/4 parser fixes (no `%g`
PARDISO values, no DIV_NUM_RHS_FWD warnings); B4a/B5 are their first real test. F5 compute nodes print 12-hour dates.
F6 the runbook's copy-back lists lack sacct and rcstat, so B2's ExitCode criterion was not captured.

**Scale warning:** this is the 39k-equation example (PARDISO 0.2 GiB). Vulcan is 72-91x larger in N_eq, with
PARDISO at 22.4 GiB (v2) and 26.2 GiB (v3) per rank. Nothing here measures Vulcan memory or time.

## Verifier verdict
| Item | Upheld | Refuted | Missed | Out of remit | Ready for Ben |
|---|---|---|---|---|---|
| Phoenix B2 evidence | 64 | 4 | 8 | 0 | yes |

Refuted (all in PHX/README.md or the report, none changes a number or verdict):
1. 4e cites README_phoenix.md:186-187 for "make: command not found"; it is :191-192 in the worktree (185 at 55bbf44).
2. "The check scripts md5-check Ben's files first": only model_diff.py and lib_parsers.sh do; cnv_compare.py,
   timing.sh and build_logs.sh read the worktree copies (cmp-identical, so no number changes).
3. F1: analysis-peak and permanent memory do not vary "the same way": they fall about 0.01 % while in-core rises 0.44 %.
4. 4e: sorting the 107 commands was not needed; the unsorted lists are identical too.

Missed (8): "B2 passed" goes beyond the evidence (criterion 2 unverified; 46 s and 0.06 SU are inferred from 01's
date lines and the 4-cpu request); MAIN/hpc/smoke_foss_20260928_211308/ is only partly gitignored (`.gitignore:18`
*.geo and `:21` femtic_N.log), so a `git add -A` in the main checkout would commit about 17 MB; the sixth file
(build_foss_20260925_181212.log, identical to tracked copies); "144, the same as the WSL log" rests only on
README_phoenix.md:429-431; the Phoenix inputs (mesh.dat, observe.dat, resistivity_block_iter0.dat) are byte-identical
to validation/wsl_2026-09-25's copies, and control.dat differs only in NUM_THREADS and ITERATION; the .out has no
"differs" NOTE, so on 09-28 $PLAN/femtic_lib.sh equalled the installed version-2 library; kit 55bbf44's 01 and lib
are byte-identical to f473028's; the EnSight headers differ between runs by uninitialised bytes while iteration 0's
float32 sensitivities are bit-identical.

## B1/B2 consequence (PHX/README.md section 7)
- **B2 need not be repeated after B1** while `$BIN/femtic` stays the same binary. The worktree 01 differs from HEAD
  only at the version gate (01:154) and the `next:` hint, and the six library functions the SMOKE_ONLY path calls
  are byte-identical in version 4. 06 exercises the version-4 gate and sourcing first thing in B4a (06:112-113).
- **Recommended: skip the B1.5 rebuild** and run only `install -m 644 $PLAN/femtic_lib.sh $BIN/` with its version
  and cmp checks (RUNBOOK:149-153). If rebuilding anyway: `md5sum $BIN/femtic $BIN/femtic_env.sh` before and after;
  a changed femtic means repeating B2 (at most 2.4 SU).
- Ignore the old kit's `next:` hint (02_env_femticpy.sh, 03_mesh.slurm); follow the runbook (B3, then B4a).

## STATUS.md update (this agent)
- 1.1 rewritten: FEMTIC ran on Phoenix (job, node, kit, binary, Phoenix = WSL, the T5 byte-identity finding, what B2
  did not show); "no inversion iteration anywhere" narrowed to Vulcan meshes (the example inverted on WSL and Phoenix).
- 1.7: the B2 evidence verdict row and its open points; the round-3 open items that the 09-29 cleanup closed
  (v3_rot recipe, old folder names, B3.0 recovery, LAYOUT under NIV=840, the nits) marked closed (no verdict).
- Section 3: "Ben can do now" and (b) B1/B2 per section 7 above; K1/K2 list the docs the smoke made stale
  (RUNBOOK:85-86 and :123 still describe the fa58604 kit; README_phoenix.md:175-192); K4 corrects PHX/README.md.
- All runbook/README citations moved after the 09-29 cleanup (+23 and +9 lines) and re-read; header md5s updated;
  1.3's upload total (426,826 B) and runbook length (783 lines); memory-table rows for the Phoenix milestone.
- Check (scratchpad status_b2/cite_check_b2.py). It fails if a cited text is missing from STATUS, a cited line is past
  the end of its file, one of 112 anchors is not on its cited line(s), a runbook/README citation token has no anchor,
  a stale phrase (18) remains, a header md5 differs from its file, or the file has 330+ lines, a CR or a non-ASCII
  byte. Fail cases first: the pre-edit STATUS gives 151 failures; with the pre-cleanup runbook and README as targets
  the new STATUS gives 74 anchor misses; mutants (a shifted citation, a wrong md5, 330 lines, :123 -> :124) each
  fail. First real run: 3 failures, all in the checker (two anchor texts mistyped; the refuted :186-187, quoted on
  purpose in 1.7, now carries a negative check that the phrase is not on those lines). Final: 0 failures, 329 lines.

## Next on Phoenix
1. Paste `sacct -j 16153670 --format=JobID,State,ExitCode,Elapsed,TotalCPU,NodeList` and `rcstat 16153670` here:
   B2 criterion 2, thread use and the billing basis are still unknown.
2. **B3**: upload parts B-D of UPLOAD_LIST_2026-09-28.txt into `vulcan_femtic/inputs/vulcan_v{2,3}` (B3.0-B3.4).
3. **B1**: kit upload (part A, 17 files), md5 and CR checks, c1c2 128/0 and portability 10/0 on p2-log-2, then the
   install line (rebuild optional, see above).
4. **B4a**: v2 gate100 and gate3 in `work/v2/`, then D1 -> B4b -> D7 (femtic_watch per-rank peak) -> B5 (T4) ->
   B6 after 10-01 -> inv01. Decisions still open: D1, D6, D7 and C18's DECLINATION rule.

## Uncommitted
Everything since 55bbf44: 20 modified tracked files and 11 untracked paths (git status at 09-30), now including
validation/phoenix_2026-09-28/ and this journal. In the main checkout, Ben's raw copies in `hpc/` are untracked and
only partly gitignored: do not `git add -A` there. A commit needs Ben's go-ahead (author bvkay, per git-authorship.md).

## Follow-up (same day): docs and ignore rules after the smoke ingest
- One Opus agent corrected validation/phoenix_2026-09-28/README.md for the 4 refuted points and the "B2 passed"
  overstatement (criteria 1 and 3 passed; criterion 2, sacct ExitCode, awaits Ben's paste).
- RUNBOOK B1/B2 and README_phoenix steps 4-5 now reflect what Phoenix holds (kit content 55bbf44, lib version 2,
  installed 2026-09-28 21:10): the B1.5 rebuild is optional, the library install line is required, B2 carries
  over while $BIN/femtic is unchanged. Added a "Known harmless output" note for the UD QP warning (untested for
  multi-node). runbook_check.sh: 393 passed, 0 failed (2 new checks). UPLOAD_LIST regenerated.
- .gitignore (worktree branch only, not yet in main): hpc/smoke_*/, hpc/smoke_*.log, hpc/slurm-*.out,
  hpc/build_*.log and the inbox hpc/phoenix_out/ are ignored; tested 78/78 raw paths ignored, 0 of 227 kit and
  validation files newly ignored. Convention: raw Phoenix output goes to hpc/phoenix_out/<date>/ on the PC.
- Known drift: STATUS.md header md5s and its line citations into the runbook and README_phoenix.md are stale
  again (new md5s: README_phoenix 20a18964, RUNBOOK 810d6e05). Content is unaffected; refresh at next STATUS edit.
- Nothing committed.

## Ben's sacct/rcstat paste (2026-09-30) - B2 criterion 2 PASS
- Job 16153670: State COMPLETED, ExitCode 0:0 (job, .batch, .extern), Elapsed 00:00:48, TotalCPU 02:31.789,
  node p2-cpu-14. rcstat: 4 cores, 79.06 % CPU used (76.3 % user, 2.8 % system) = both threads of both ranks busy
  for most of the 48 s; max RSS 828.71 MB/node of 8 GB reserved; 0.05 core-hours; submit 21:11:34, start
  21:13:14 (100 s queue), end 21:14:02; disk read 177.7 MB, write 38.0 MB. Filed as
  validation/phoenix_2026-09-28/sacct_16153670.txt and rcstat_16153670.txt; README, STATUS and RUNBOOK B2 updated.
- B2 is now passed on all three runbook criteria. Next on Phoenix: B3 upload, B1 (install lib v4, no rebuild), B4a.
