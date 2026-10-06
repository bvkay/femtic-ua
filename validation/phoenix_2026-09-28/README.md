# Phoenix B2 smoke test, job 16153670 (2026-09-28): evidence and checks

**Verdict: RUNBOOK B2 passed on all three criteria** (criterion 2 confirmed 2026-09-30 from Ben's sacct/rcstat paste,
files `sacct_16153670.txt` and `rcstat_16153670.txt` here). FEMTIC ran on an icelake compute node
for the first time. The DONE line reads T1, T2 and T5 PASS (criterion 1), and iterations 0-2 match both WSL builds
to all 7 printed digits (criterion 3). Criterion 2: sacct State COMPLETED, ExitCode `0:0` for the job and both steps
(pasted 2026-09-30; at the time of the ingest on 09-30 morning no `sacct` output had been copied). It ran with the **committed kit (HEAD 55bbf44, femtic_lib.sh version 2)**, not the version-4 kit
in this worktree. One stricter check fails and is explained below: the restarted final model is not
byte-identical to the straight run's (29 of 288 blocks differ by 1 in the 7th digit). The request allows at most
2.4 SU. The run time and cpu count are inferred, not measured: 46 s is the span between the first and last `== `
date lines that 01 itself prints, and 4 cpus is the runbook command's request, which the output does not print.
On those two figures the job cost about 0.06 SU if Phoenix bills elapsed time.

Ben copied the files from Phoenix into `D:/BEN/FEMTIC_2026/hpc` (main checkout, untracked). This folder holds the
text evidence. `MANIFEST.md5` identifies every file of the run, including those left on Ben's disk. The checks
are in `checks/` and their output is in `checks/checks_output.txt`. Rerun them with
`bash validation/phoenix_2026-09-28/checks/run_all.sh`. They are light (Python and awk) and never write to Ben's
files. Only `model_diff.py` and `lib_parsers.sh` read Ben's raw files, each after checking their md5s against
`MANIFEST.md5`. `cnv_compare.py`, `timing.sh` and `build_logs.sh` read the copies in this folder, which are
byte-identical to Ben's files (24/24 match their manifest md5s), so no number depends on which copy was read.

## 1. What ran

| | |
|---|---|
| Job | 16153670, `femtic_smoke`, partition icelake, node **p2-cpu-14**. It ran 21:13:08-21:13:54 ACST, 46 s, taken from the two `== ` date lines of the .out (not measured by Slurm: no sacct Elapsed was copied) |
| Command | the RUNBOOK B2 / 01 header line: `sbatch -p icelake -N 1 -n 4 --mem=8G --time=00:30:00 ... --wrap 'TOOLCHAIN=foss SMOKE_ONLY=1 bash -l hpc/phoenix_plan/01_build_femtic.sh'`. The resource request is not printed in the output |
| Modules | foss/2023a + imkl/2023.1.0 (24 modules: GCC 12.3.0, OpenMPI 4.1.5, imkl 2023.1.0, ...). mpirun is `/gpfs/apps/icl/software/OpenMPI/4.1.5-GCC-12.3.0/bin/mpirun` |
| Kit | **HEAD 55bbf44**: `$BIN/femtic_lib.sh` 19,992 B, FEMTIC_LIB_VERSION 2; `femtic_env.sh` 732 B, with the /apps remap (check e) |
| Binary | `$BIN/femtic` 1,494,008 B, built 21:10:38 by the login-node rebuild `build_foss_20260928_211021.log` (femtic 26c8606) |
| Case | FEMTIC's bundled example INV_MT_01/Tetra: 36 MT stations, 4 frequencies (0.001-1 Hz), 34,559 elements, 288 free parameters, N_eq 39,254 |
| Layout | 2 MPI ranks x 2 OpenMP threads: `OMP_NUM_THREADS=2 mpirun -np 2 --bind-to none` (01_build_femtic.sh:487 at 55bbf44). Rank 0 has 0.001 and 0.01 Hz, rank 1 has 0.1 and 1 Hz |
| Runs | straight: ITERATION 0 2. restart: leg 1 `0 1`, then leg 2 `1 2`, in the same directory |

## 2. Verdicts

| Test | Kit verdict (the .out) | Independent check here |
|---|---|---|
| T1 linkage | PASS | `ldd` resolves libmkl_intel_ilp64 / gnu_thread / core from imkl 2023.1.0, libgomp from GCCcore 12.3.0 and libmpi from OpenMPI 4.1.5, with no "not found" |
| T2 smoke run | PASS: exit 0, 17 s, iter2 model written | **check a PASS**: every column of rows 0-2 equals WSL to all 7 digits |
| T5 restart | PASS: relative misfit difference 0.000e+00 at iterations 1 and 2 | cnv rows print-identical (PASS). **Final model byte-identity FAILS**: 29/288 blocks differ by 1 ulp7, max rel 9.97e-7 (check b) |
| RUNBOOK B2 criterion 1 | - | `grep -cE '^== .*  SMOKE_ONLY DONE ...'` gives 1 on the .out and 0 on the build log (the fail case) |
| RUNBOOK B2 criterion 2 | sacct_16153670.txt | **PASS** (added 2026-09-30). State COMPLETED, ExitCode 0:0 (job, .batch, .extern). rcstat_16153670.txt: Elapsed 48 s (Slurm), TotalCPU 2:31.8 = 79.1 % of 4 cores over 48 s, so both threads of both ranks were busy for most of the run; max RSS 828.7 MB/node; 0.05 core-hours; queue wait 100 s (submit 21:11:34, start 21:13:14); disk read 178 MB, write 38 MB |
| RUNBOOK B2 criterion 3 | - | PASS: row 0 is Misfit `5.752642e+03` and RMS `2.234639e+00`, 7 of 7 digits equal |

"ulp7" means one unit in the 7th significant digit of FEMTIC's `%e` print. It is the smallest difference a
printed file can show.

## 3. Files

- The five logs, unrenamed. `slurm-femtic_smoke-16153670.out` and `smoke_foss_20260928_211308.log` are
  byte-identical, because 01 tees its output (md5 7f069479).
- `straight/` and `restart/` hold control.dat, femtic.cnv*, femtic_*.log*, stdout_*.txt and result.case.
- **Renamed for git.** `.gitignore:21` ignores `**/femtic_[0-9]*.log`, so the rank logs were copied under new names:
  - `femtic_0.log` became `femtic_0_straight.log.txt` (straight/) and `femtic_0_leg2.log.txt` (restart/);
  - `femtic_1.log` became `femtic_1_straight.log.txt` and `femtic_1_leg2.log.txt`.

  `git check-ignore` flags the original names and none of the 24 copies.
  - The restart directory's `femtic_0.log` and `femtic_1.log` come from leg 2.
  - Leg 1's rank-1 log was overwritten on Phoenix and is lost, and 01 keeps no copy of it.
  - `femtic_0.log.straight` equals `femtic_0.log`, and `.leg2` equals the restart `femtic_0.log`. Both
    duplicates were kept.
- Not copied: mesh.dat, Mesh.geo, observe.dat, resistivity_block_iter*.dat, the *.iter* files, BlockIDs,
  result_*_iter*.csv and obs_loc.vtk. These are the bundled example and its outputs. `MANIFEST.md5` lists md5, size
  and path for all 74 files (5 logs and 69 run files).
  - Check: `cd /d/BEN/FEMTIC_2026/hpc && grep -v '^#' <MANIFEST> | awk '{print $1"  "$3}' | md5sum -c`. Today it
    gives 74/74 OK. A manifest with one md5 swapped gives FAILED and exit 1.
  - The 24 copies match their manifest md5s (24/24).
- **What the uncopied files show** (rechecked 2026-09-30 on Ben's files, read-only):
  - The inputs are FEMTIC's bundled example, byte for byte. `mesh.dat`, `observe.dat` and
    `resistivity_block_iter0.dat` of both `straight/` and `restart/` have the same md5 as the WSL copies in
    `validation/wsl_2026-09-25/femtic_example_INV_MT_01_Tetra/`: 8f542202 (3,622,384 B), f79d91e1 (30,577 B) and
    8a5633c8 (741,077 B). `control.dat` differs from that WSL copy only in NUM_THREADS (2 here, 1 there) and
    ITERATION (`0 2` straight, `1 2` restart after leg 2, `0 5` there).
  - The EnSight binaries of the two runs differ only in uninitialised header bytes. `Mesh.geo`, `BlockIDs` and the
    five iteration-0 files (`Resistivity`, `Sensitivity`, `SensitivityDensity`, `NormalizedSensitivity` and
    `NormalizedSensitivityDensity` `.iter0`) of straight and leg 1 differ only in bytes that follow the NUL
    terminator of an 80-byte text field (189 bytes in `Mesh.geo`, 96-126 in the others). The float32 values from
    byte 245 on, including iteration 0's sensitivities, are bit-identical. So `cmp` of these files is no test of
    FEMTIC's numbers.

## 4. Checks

Each check states its failure criterion and runs its fail case before the real case. All fail cases fail as designed.

**a. Phoenix and WSL, same example.** Fails if Misfit or RMS of a common iteration agrees to fewer than 6
significant digits.
- Fail cases:
  - rows shifted by one: FAIL, 0-1 digits;
  - the WSL Misfit changed in the 6th digit: FAIL, 5 digits;
  - the 7th digit changed: PASS at 6 digits (the boundary case).
- Result: **PASS.** Every row is identical in all 8 columns to both references:

| Iter | Roughness | Misfit | RMS | ObjFunc | WSL run_logs (2x2) | WSL s6_foss2023a (2x4) |
|---:|---|---|---|---|---|---|
| 0 | 0.000000e+00 | 5.752642e+03 | 2.234639e+00 | 5.752642e+03 | identical, 7/7 digits | identical |
| 1 | 9.935719e+01 | 2.331502e+03 | 1.422629e+00 | 2.430859e+03 | identical | identical |
| 2 | 2.410951e+02 | 1.309987e+03 | 1.066369e+00 | 1.551083e+03 | identical | identical |

- **Reference A1, the task's reference:** `wsl_2026-09-25/run_logs/femtic.cnv`, 5 iterations. Main WSL build
  (conda gcc 15.3, OpenMPI 5.0.10, MKL 2026.1, with conda's default LLVM libomp behind libgomp.so.1).
  - **Same layout as Phoenix:** 2 ranks (`time_v.log`: `mpirun -np 2 --oversubscribe --bind-to none`), NUM_THREADS
    2 (`run_logs/control.dat`), OMP_NUM_THREADS=2 (`scripts/run_inv_mt01.sh`), femtic_0.log and femtic_1.log
    (VALIDATION.md; the logs are not in the repo), and the same frequency split.
  - Phoenix: 2 ranks, NUM_THREADS 2 in both control.dat files, "Number of threads is specified to be 2" in all 5
    logs, and two femtic_N.log files per directory.
- **Reference A2:** `s6_foss2023a.log:33-37`, the version-matched build (gcc 12.3, OpenMPI 4.1.5, MKL 2023.1).
  - The same versions as Phoenix, but **4 threads per rank** (smoke_crosscheck.txt header; the s6 log does not
    print its command). So its thread layout differs, yet the rows are identical anyway.
- Together the two references cover a change of toolchain at a fixed layout (A1) and a change of threads at a
  fixed toolchain (A2).

**b. T5: straight and restart.**
- femtic.cnv: the rows of leg 1 (iterations 0, 1) and leg 2 (iterations 1, 2) are string-identical to the
  straight rows. The fail case (iteration 1 against iteration 2) fails.
- Final model. Fails if `restart/resistivity_block_iter2.dat` is not byte-identical to straight's. Result:
  **FAIL**, md5 e025b5df against 709398b8.
  - The fail case, straight iteration 1 against iteration 2, finds all 288 blocks changed, max rel 0.21.
  - resistivity_block_iter1.dat is byte-identical (ea1ff241).
  - Iteration 2: 29 of 288 blocks differ, each by exactly 1 ulp7 (max rel 9.97e-7, block 51: 1.003219e+02
    against 1.003220e+02). The element map, bounds, weights and types are identical.
- Responses, result_*_iter*.csv. Cal is measured as max |dCal| / |Z|_row, with |Z|_row = max(|Zxy|, |Zyx|);
  residuals are in SD units. Plain relative differences mislead here, because the diagonals are about 1e-4 of |Z|.
  The fail case, iteration 0 against 1, gives 0.11 of |Z| and 3.5 SD. Obs and SD are identical in every
  comparison.

| Comparison | Values differing | max \|dCal\|/\|Z\| | max \|dRes\| |
|---|---|---|---|
| Iteration 0: straight and leg 1, **identical inputs, no restart** (baseline) | 16 / 4608 | 1.1e-9 | 0 |
| Iteration 1: straight (model in memory) and leg 2 (model re-read from the printed iter1 file) | 1360 / 4608 | 4.0e-7 | 3.3e-6 SD |
| Iteration 2: straight and leg 2 | 1069 / 4608 | 3.9e-7 | 2.0e-6 SD |

- **What was learned (the criterion was not loosened).** Two effects explain the failure.
  1. FEMTIC on Phoenix is not bitwise reproducible from run to run: the baseline row, and finding F1 in section 5.
  2. A restart reads the model back from a text file with 7 significant digits. That perturbs it by up to
     5e-7 relative, which gives the 4e-7 |Z| differences at iteration 1 and the 1-ulp7 model differences at
     iteration 2.
- Both effects are at print precision, far below the 5 % error floor. **Byte identity cannot be a T5 criterion on
  Phoenix.** The kit's misfit tolerance (1e-4 / 1e-3) is the right kind of test.

**c. Kit parsers (femtic_lib.sh version 4, worktree md5 34230ad0) on the real Phoenix logs.** Fails if a parser
prints nothing or a value other than the hand-read one.
- Fail cases:
  - version 2's `femtic_pardiso_max_gb` on a `2.5e+07` KB line gives 0.0, where 23.8 is right; version 4 gives 23.8;
  - `femtic_niv_measured` on the real log cut before its first sensitivity step prints nothing.
- Result: **21/21 PASS.** Each value against the hand-read lines, quoted in checks_output.txt:

| Parser | Returned | Hand-read line(s) |
|---|---|---|
| `femtic_pardiso_kb` | 206687 (rank 0), 206994 (rank 1, and both) | straight/femtic_0.log:130,272,410 `205789 / 206534 / 206687 [KByte]`; femtic_1.log:130 `206994` |
| `femtic_pardiso_max_gb straight/` | 0.2 | 206994 / 1048576 = 0.197 |
| `femtic_pardiso_log_gb` | 0.20, 0.20 | 206687 and 206674 KB |
| `femtic_log_neq` | 39254 | `Number of equation = 40919, Number of equation after degeneration = 39254` (femtic_0.log:106 and later) |
| `femtic_niv_measured` | 144 on each log (straight 0, 1; restart leg 2) | femtic_0.log:137-139: interpolator header, then `Solve phase is performed simultaneously for 144 right-hand sides`, then `# Calculate derivatives`. 144 = 36 x 4. "The same in WSL" rests on README_phoenix.md:444-445 (worktree copy, 2026-09-30), which quotes the WSL log `run_INV_MT_01_Tetra/femtic_0.log:138`; that log is not in the repo |
| `femtic_fwd_times` | `0.001 4; 0.01 3` (rank 0), `0.1 4; 1 3` (rank 1), `0.001 3; 0.01 3` (leg 2) | stamps at :98 `( 0 sec )`, :171 `( 4 sec )`, :228 `( 7 sec )` |
| `femtic_nfreq`, `femtic_last_iter`, `femtic_cnv_row`, `femtic_block_check`, `femtic_obs_counts` | 4; 2 and 2; row 0; `OK 34559 289`; `36 1152` | log lines 86-92; file names; femtic.cnv; the file header; observe.dat |

- **Limit (finding F4).** These logs do not exercise the paths that versions 3 and 4 fixed:
  - Every PARDISO value is a plain integer below 1e6 KB, so none is in `%g` form.
  - The division number is 1 (log line 10), so FEMTIC wrote no DIV_NUM_RHS_FWD warning lines.
  - Version 2 gives the same answers here (2/2 checked).
- On Vulcan the line is in `%g` form: `2.34522e+07 [KByte]` for v2 and `2.74856e+07` for v3
  (MAIN/mesh/vulcan_v2/halfspace/acc_3/b1/femtic_0.log, vulcan_v3/halfspace/acc_100/b1). The first real Phoenix
  test of those paths is B4a/B5.

**d. Timing and memory on icelake.** This is a record. Its single criterion only catches gross problems: it
fails if the WSL 2x2 time predicted from the Phoenix stamps is off by more than 2x either way.
- The fail case, a synthetic run 3x slower, fails at ratio 3.09. The real ratio is **1.03, PASS**.
- Time: FEMTIC's stamps are whole seconds, so every figure is +-1 s.
  - straight: 17 s = iteration 0 in 7 s (forward + sensitivity) + iteration 1 in 7 s + iteration 2 in 3 s
    (forward only);
  - leg 1: 10 s. Leg 2: 10 s (6 + 4);
  - the whole job spanned 46 s between the first and last `== ` date lines of the .out, including module loads,
    ldd and three mpirun starts. This is 01's own clock, not sacct's Elapsed, which was not copied.
- WSL, same example, 2x2, ITERATION 0 5: 36.9 s wall and 383 % CPU (`run_logs/time_v.log`). At the Phoenix rate
  that run would take 5 x 7 + 3 = 38 s.
- WSL 2x4, ITERATION 0 3: 15 s. At the Phoenix 2x2 rate that would take 24 s.
- **Threads.** Two threads were requested and reported. Whether both were busy is not measured: nobody copied a
  TotalCPU or efficiency figure.
- **Memory.** Only PARDISO's own report:
  - in-core 205,789-206,994 KB, one report per rank per iteration (201-202 MiB, 12 reports in the 5 logs);
  - analysis peak 42,805-42,920 KB; permanent 36,667-36,759 KB.
  - No RSS was sampled on Phoenix. The WSL 2x2 run peaked at 530,748 KB for one process (`time -v`).
- **This is the small bundled example and says nothing about Vulcan-scale cost.** N_eq is 39,254 here against
  2,844,872 (v2) and 3,568,555 (v3), 72-91x more. PARDISO uses 0.2 GiB here against 22.4 GiB (v2) and 26.2 GiB (v3)
  per rank in the WSL gate logs. N_iv is 144 against the expected 480 (and 144 in WSL according to
  README_phoenix.md:444-445; the WSL log it quotes is not in the repo).

**e. Build logs.**
- The 09-25 evening attempts ran the **fa58604 kit**. The COMMIT_SHA.txt read is on line 176 of fa58604's 01,
  and the die message has fa58604's wording.
  - **09-25 19:37**, job 16122323, `interactive` partition, p2-dmv-1, git absent: `ERROR: no libmkl_core.so under
    MKLROOT=/apps/...`. That node has no /apps, and nothing was built.
  - **09-25 19:44**, job 16122362, icelake p2-cpu-37: it passed the MKL check. The log stops at
    `=============== femtic (Makefile.gcc_openmpi_mkl ) ===============` with no error line.
    README_phoenix.md gives the cause as "make: command not found": line 198 of the worktree copy (after the
    2026-09-30 edit of steps 4-5), line 185 of the committed copy (55bbf44, which is also the main checkout's).
    That message is in the job's .out, which was not copied (finding F6).
- **09-28 21:10**, login node p2-log-2, **HEAD kit**, git 2.27.0: `T1 (linkage): PASS` and
  `BUILD DONE T1=PASS T2=SKIPPED T5=SKIPPED`.
- `femtic_env.sh` is **732 B**. Rebuilt from each commit's writer lines, the HEAD writer gives 732 B and fa58604's
  gives 613 B. The 09-25 file was 613 B. The fail case (the 09-28 file against the fa58604 writer) fails.
- `femtic_lib.sh` is 19,992 B, equal to `git show 55bbf44` (09-25: 18,193 B, equal to fa58604).
- **The seven binaries have the same sizes as in the 09-25 18:12 log**: femtic 1,494,008, makeTetraMesh 443,024,
  makeMtr 72,200, TetGen2Femtic 122,768, makeDHexaMesh 243,544, mergeResultOfFEMTIC 178,768, tetgen 903,368.
  - The fail case, the two kit files that did change, fails.
  - The smoke job's own `ls -l` two minutes later shows the same sizes.
- Same source and toolchain: the 7 commits, the 24 modules, the 107 compile and link commands and the 25 warnings
  are identical. The check compares the commands sorted; the unsorted lists are identical too (md5 f6c92cf4 for
  both), so the order did not change either. The fail case (the 19:44 log, 0 commands) fails.
- **Limit:** equal sizes are not equal bytes. No md5 of the binaries was recorded on Phoenix.

## 5. Findings

- **F1. Not bitwise reproducible.** Two fresh runs of iteration 0 with identical inputs (straight and leg 1)
  differ in 16 rank-0 response values, at the 7th digit. PARDISO also reports different memory for the same
  matrix pattern (rank 0, iteration 0, straight against leg 1): in-core memory rose 0.44 %, from 205,789 to
  206,700 KB, while the analysis peak and the permanent memory fell by about 0.01 %, from 42,893 and 36,720 KB to
  42,888 and 36,716 KB.
  - This fits a non-deterministic parallel reordering in PARDISO. That is a hypothesis: FEMTIC's iparm settings
    were not read.
  - Consequences: memory figures from a single run carry about 0.5 % jitter, and byte identity of FEMTIC's
    outputs cannot be a criterion anywhere in the kit.
- **F2. Restarts re-read a 7-digit model** (check b). The effect is negligible, but every 05 restart perturbs each
  resistivity by up to 5e-7 relative.
- **F3. Transport warning in stdout.** Both ranks printed `p2-cpu-14:rank0.femtic: Failed to modify UD QP to INIT on
  mlx5_0: Operation not permitted`, 4 times each, in straight and leg 2 but not leg 1 (empty stdout).
  - The `host:rankN.exe:` prefix looks like libfabric's PSM3 provider probing the InfiniBand card. That is
    unverified.
  - It is harmless for single-node jobs, where the ranks share memory. Expect it in the stdout of 04 and 06 runs (06 writes `stdout.txt`).
  - Look at it only before any multi-node job. The kit does not grep stdout for errors.
- **F4. The version-3/4 parser fixes are not yet exercised by real Phoenix logs** (check c).
- **F5. Compute nodes print `date` in 12-hour form** (`09:13:08 PM ACST`), the login node in 24-hour form. The B2
  DONE grep does not depend on it.
- **F6.** The .out of the 09-25 19:44 job holds the only record of its failure. The runbook's copy-back lists do
  not include sacct or rcstat, so B2's ExitCode criterion was not captured.

## 6. What this does and does not prove

**It proves** these points, on one icelake node and on FEMTIC's small example:
- The foss/2023a + imkl/2023.1.0 build of femtic 26c8606 runs under Slurm, linked to the intended MKL
  ILP64/gnu_thread and GNU libgomp.
- It reproduces both WSL builds to all printed digits for three iterations. That covers the forward solve, the
  sensitivities, the Gauss-Newton step, the misfit accounting and the MPI reduction on 2 ranks.
- A restart from iteration 1 continues the inversion at print precision.
- The HEAD kit's SMOKE_ONLY path works end to end.
- The version-4 parsers read real Phoenix logs correctly.

**It does not prove:**
- anything at Vulcan scale: memory, time, the sensitivity step at N_iv 480, or out-of-memory behaviour;
- the production launch line, `--map-by ppr:R:node:PE=T --bind-to core --report-bindings`. The smoke used
  `--bind-to none` with 2 ranks on 4 cpus;
- thread efficiency on Phoenix;
- memory as RSS;
- the version-4 kit or 04/06 on Phoenix. That is B1.4 and B4a;
- the /apps remap on an interactive node, because this ran on icelake, which has /apps;
- the forward physics at 0.1-1 Hz. The example mesh fails the analytic half-space check there on WSL
  (`wsl_2026-09-25/run_logs/VALIDATION.md`), and identical numbers carry the identical error.

**The old kit's `next:` hint is superseded.** The HEAD kit ends with "02_env_femticpy.sh, 03_mesh.slurm, then
06_forward_only.slurm". Follow RUNBOOK_first_inversion.md instead:
- B3: upload the gated WSL meshes to `vulcan_femtic/inputs/`. 03_mesh.slurm is ungated.
- B4a: then 06 in `vulcan_femtic/work/<mesh>/gate100` and `gate3`.

The version-4 01 prints this route.

## 7. Consequence for runbook B1/B2

- **B2's criteria 1 and 3 passed with the HEAD kit.** Criterion 2 (sacct ExitCode `0:0`) waits for Ben's `sacct`
  paste.
- **What version 4 changes on the SMOKE_ONLY path.** In `01_build_femtic.sh` it changes two lines against HEAD:
  the version gate (01:154, `>= 4`) and the `next:` hint. The build sections, including the `femtic_env.sh`
  writer, are unchanged.
- **The library functions it calls are byte-identical in version 4 and at HEAD.** These are femtic_ctl_get,
  femtic_ctl_set, femtic_last_iter, femtic_nfreq, femtic_cnv_row, and femtic_apps_remap, which femtic_env.sh calls.
  - This was checked function by function. The same comparison flags femtic_pardiso_max_gb as different, which
    is its fail case.
  - Outside its functions, femtic_lib.sh sets only `FEMTIC_LIB_VERSION`.
- **So a repeated B2 would test the same binary, the same femtic_env.sh and the same smoke code.** The only new
  things it would cover are the gate line and sourcing a version-4 library on a compute node. 06 does both as
  its first action in B4a (06:112-113), and B1.4 runs the version-4 library under Phoenix's bash on the login node.
- **A B1.5 rebuild adds nothing now.** The 09-28 rebuild already wrote the 732 B femtic_env.sh with the remap.
  Only the `install` line does anything new.
- **What decides whether B2 must be repeated is the femtic binary.**
  - Record `md5sum $BIN/femtic $BIN/femtic_env.sh` before B1.5. If the rebuild leaves `$BIN/femtic` identical
    (same source and toolchain, so this is expected but not yet shown), B2 carries over. The md5 of
    femtic_env.sh always changes, because its first line holds the build date.
  - If it changes, repeat B2. The request allows at most 2.4 SU. The 09-28 job spanned 46 s by 01's date lines
    and requested 4 cpus (neither figure comes from Slurm), about 0.06 SU if billed on elapsed time. It waited
    at most about 2 minutes in the queue: the build ended at 21:11:15 and the job started at 21:13:08.
  - Simplest: skip the rebuild and run only B1.5's `install` and check lines. The runbook's B1.5 and B2 say so
    since 2026-09-30.
