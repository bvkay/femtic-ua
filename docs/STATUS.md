<!--
docs/STATUS.md - the living "where we are" page for the Vulcan FEMTIC project.
Rewrite it at every milestone or end of session. History goes in docs/journal/.
This version: 2026-09-30, after the Phoenix B2 smoke evidence was filed (docs/journal/2026-09-30_phoenix_smoke.md),
with the runbook/README citations that drifted in the 09-29 cleanup re-read. Every claim cites a file; the "memory
vs repo" table at the end records where the memory note (vulcan-femtic-project.md) is still behind the repo.
Path keys: bare paths are repo-relative. MAIN/ = D:/BEN/FEMTIC_2026 gitignored run outputs.
WSL/ = //wsl.localhost/Ubuntu/home/tara/femtic_wsl (local build and mesh runs); PHX/ = validation/phoenix_2026-09-28/.
-->

# Vulcan FEMTIC - project status (2026-09-30, after the Phoenix B2 smoke)

Line numbers hold for the files as of 2026-09-30 (md5: femtic_lib.sh 34230ad0, 01 ab3659c7, 03 a462751a,
04 22d1c061, 05 225156ab, 06 a39506a1, README_phoenix.md f79d7db7, RUNBOOK 7f7284a5, UPLOAD_LIST 07689a12;
scripts/prep_vulcan.py sha256 328932c2). Several agents edit these files, so re-read a cited line before acting on
it. Kit paths below are relative to hpc/phoenix_plan/.

## 1. Where we are

### 1.1 Compute state
- **FEMTIC has run on Phoenix; B2 passed on its criteria 1 and 3.** Job 16153670 (`femtic_smoke`, icelake node
  p2-cpu-14), 2026-09-28 21:13:08-21:13:54 ACST by 01's own date lines: `SMOKE_ONLY DONE T1=PASS T2=PASS T5=PASS`
  (PHX/slurm-femtic_smoke-16153670.out:1,28,55,57). Kit: the **committed 55bbf44** (femtic_lib.sh 19,992 B,
  version 2; femtic_env.sh 732 B, with the /apps remap), not version 4. Binary: the 09-28 21:10 login-node rebuild
  (femtic 26c8606, 1,494,008 B; PHX/build_foss_20260928_211021.log:3,250-252,263). Record: PHX/README.md.
- **Phoenix matches WSL on FEMTIC's example** (INV_MT_01/Tetra, 36 stations, N_eq 39,254, 2 ranks x 2 threads):
  femtic.cnv rows 0-2 equal both WSL builds in all 8 columns, 7 of 7 digits; row 0 is Misfit 5.752642e+03, RMS
  2.234639e+00 (criterion 3, RUNBOOK:181-183; PHX/README.md 4a). T5: the cnv rows are string-identical, but the
  final model differs in 29 of 288 blocks by 1 in the 7th digit. FEMTIC is not bitwise reproducible (iteration 0 run
  twice: 16 of 4,608 responses differ, 1.1e-9 of |Z|) and a restart re-reads a 7-digit model (4b, F1, F2). Harmless
  (4e-7 of |Z|), but no criterion may require byte identity, and a PARDISO memory figure carries about 0.5 % jitter.
- **B2 criterion 2 confirmed 2026-09-30** (PHX/sacct_16153670.txt, rcstat_16153670.txt): COMPLETED 0:0, Elapsed 48 s,
  TotalCPU 79 % of 4 cores (both threads per rank busy), max RSS 829 MB, 0.05 core-hours. **Not shown by B2:** Vulcan scale (PARDISO 0.2 GiB here, 22-26 GiB per rank on the meshes); the production
  launch line (the smoke used `--bind-to none`); the version-4 kit, 04 and 06. Phoenix still holds library
  version 2, which every amended script refuses (1.3), so B1 comes first; RUNBOOK:85-86 still names fa58604.
- **No inversion iteration has run on a Vulcan mesh** (only the example: 2 on Phoenix, 5 on WSL). Every Vulcan run
  used ITERATION 0 0 (e.g. MAIN/mesh/vulcan_v2/halfspace/acc_3/b1/control.dat:24); prep writes `0 10` (mesh/vulcan_v2/
  inversion/control.dat:25) and 06 resets it to 0 0 (06:172). The sensitivity step's memory and time are unmeasured.
- **Rule (Ben, 09-28): no modelling on the PC or in WSL; MT processing runs there** (RUNBOOK_first_inversion.md:11-12).
  The PC agents ran only light Python/bash; femtic, mpirun and Slurm appear only as fakes in the kit tests.

### 1.2 Meshes and the WSL gate (unchanged since 09-25)
- **Three meshes**, identical except for site refinement: v1 1,534,902, v2 2,446,095, v3 3,068,130 tets, each
  check_mesh 17/17 (mesh/vulcan_v*/mesh_logs/mesh_stats.txt:1).
- **WSL gate** (5 % rho_a, 1.5 deg phase, 2 % diagonal; 3 and 100 ohm-m; 8 bands 200-0.0063 Hz):
  - v1 fails at 20 Hz and above in 3 ohm-m;
  - v2 fails one diagonal, 2.09 % at 200 Hz, site G7 (mesh/vulcan_v2/halfspace/acc_3/acc_eval_v2_3.txt), and passes 100 Hz;
  - v3 passes with thin margins: 4.25 % (200 Hz, 3 ohm-m) and 4.37 % (0.0019947 Hz, 100 ohm-m, Vul24-19).
- **v2 has never run at 100 ohm-m** (validation/mesh_2026-09-25/halfspace_accuracy.md:103, marker
  WSL/mesh_runs/SKIP_acc_v2_100). v1 and v3 do not bracket v2: each build meshes the deep shells anew
  (halfspace_accuracy.md:101). The gate now runs on Phoenix as runbook step B4a, on all 21 observe.dat bands.
- **10 of the 21 observe.dat bands were never run on any mesh** (docs/mesh_tetra_pipeline.md:842).
- **Forward cost** (WSL, 1 rank x 8 threads): peak RSS 19.7 / 28.3 / 33.7 GB for v1 / v2 / v3
  (MAIN/mesh/vulcan_v*/halfspace/*/b*/time_v.log). Slowest single frequency: 418 s on v2, 755 s on v3
  (06_forward_only.slurm:60-63). A 21-band forward took 1.0-1.2 h on v2 and 1.7-1.9 h on v3
  (halfspace_accuracy.md:306). v3 costs 1.4-1.9x the CPU of v2 (halfspace_accuracy.md:21-22).
- **Parameter cells** 55,992 / 65,341 / 68,654 against about 21,000 designed (mesh_stats.txt:103). INV_METHOD 1
  (data space) is right: the model-space matrix would be 25 / 34 / 38 GB against 3.3 GB (mesh/vulcan_v2/README.md:268).

### 1.3 Phoenix kit: what the fixes enforce (uncommitted; femtic_lib.sh:27 `FEMTIC_LIB_VERSION=4`)
- **Version gates: >= 4 everywhere.** 01 SMOKE_ONLY, 03, 04, 05 and 06 need version >= 4 (01:154, 03:65, 04:120,
  05:62, 06:113; round 3 raised 01 and 03 from 3), so all of them refuse the installed version-2 library.
- **PARDISO parser** reads scientific notation (femtic_pardiso_kb). The old code read 2.5e+07 KB as 0.0 GiB.
- **Memory rule.** R x (FWD_MB + NONPARDISO_MB) + extra <= 95 % of --mem (femtic_layout_check). 04 and 06 refuse
  a failing layout before launch: exit 1, no SU. The extra is the sensitivity files when $TMPDIR is tmpfs (04).
  The old 8 x 9 layout is refused; the headers are 2 x 36, and v2 runs 3 x 24 (README_phoenix.md:480-481).
- **06 is also the half-space gate.** START_RHO=<ohm-m> writes a uniform model into fwd0_<jobid>/, and
  tools/halfspace_eval.py judges all 120 x 21 (site, band) pairs; exit 4 = T6 PASS but gate FAIL
  (README_phoenix.md:218-222). Header walltime 04:00:00, rule `--time >= ceil(21/R) x T_f + 6 min` (06:8,60-72);
  v2 at 3 x 24 needs `--time=02:00:00`. The job_outcomes.tsv exit column now equals the exit code (06:355-363).
- **LAYOUT hand-over.** A 06 job that passes T6 under LAYOUT_CHECK=full writes $INV_DIR/LAYOUT (06:310-324).
  05_chain.sh refuses to submit without it or an explicit SBATCH_EXTRA layout, and refuses half a layout
  (05:87-129; README_phoenix.md:230-232,677).
- **N_iv count** (femtic_niv_measured, femtic_lib.sh:317-336) survives FEMTIC's DIV_NUM_RHS_FWD warning lines.
  That is the reason for version 4.
- **Python 3.6.** halfspace_eval.py opens its files with encoding='utf-8' and reduces site names to ASCII.
  Phoenix's /usr/bin/python3 is 3.6.8, which uses the locale encoding; the old evaluator crashed on a non-ASCII name.
- **station_map.csv** is in the copy lists (README_phoenix.md:198-206), so the gate report names sites (G7, Vul24-19).
- **Kit tests** (fakes, Git Bash 5.2): tests/c1c2_test.sh 129/129 on the PC and 128/128 in Phoenix mode (fresh run,
  round 3); tests/portability_test.sh 10/10 with two interpreters (RUNBOOK:134-137); tests/halfspace_eval_test.sh
  31/31. No kit test has run under Phoenix's bash 4.4, gawk 4.2 or Python 3.6.8 (B1.4 will); only HEAD's 01 ran there.
- **Phoenix folders (round 3).** Inputs in /hpcfs/users/a1690074/vulcan_femtic/inputs/vulcan_v2 and vulcan_v3, never
  written after B3; each job in its own vulcan_femtic/work/<mesh>/<gate100|gate3|t4|inv01>, with a copy of
  control.dat and relative links to the inputs (RUNBOOK:19-38; README_phoenix.md:198-206; 06:43-44).
- **Runbook and upload list.** RUNBOOK_first_inversion.md (783 lines) gives every Phoenix step with its failure
  criterion. UPLOAD_LIST_2026-09-28.txt (UPLOAD_LIST:64): part A (kit) 15 measured files, 426,826 B; B (v2)
  312,893,416 B; C (v3) 390,887,243 B; D (rotated v2 data) 505,628 B; tests/gen_upload_list.sh writes it.
  tests/runbook_check.sh (PC only, about 3 min) runs the runbook's own blocks in a sandbox: 391 passed / 0 failed in
  33 checks, 54/54 mutants caught, reproduced by the round-3 verifier (the round-2 files give 268 / 110).

### 1.4 Memory: predicted, not measured
- **N_iv: expected 480, bound 840.** From ObservedData.cpp: 4 right-hand sides per MT site, i.e. the station's
  Ex,Ey plus the dummy VTF station's Hx,Hy; the dummy adds no Hz because it has no data. 4 x 120 = 480. FEMTIC's
  own INV_MT_01 example logs 144 for 36 stations (on Phoenix: PHX/straight/femtic_0_straight.log.txt:138).
  840 = 4 x 120 + 3 x 120 is the bound (README_phoenix.md:408-447;
  MAIN/mesh/vulcan_v3/halfspace/acc_100/b1/femtic_0.log:286-288). B5 measures it.
- **Per rank** (WSL forward peak + two-array sensitivity step at the logged N_eq): **v2 70,754 MiB, v3 86,652 MiB**;
  with N_iv 840: 102,727 / 126,611 MiB (README_phoenix.md:453-454). Unmeasured.
- In `$WK/<mesh>/t4`, 04 takes N_eq from mesh.dat and FWD_MB from 06's logs/fwd_rank_mb, so it will print Z = 71,776
  (v2) / 87,372 (v3) MiB. B5's PASS band is 0.8 Z - 1 to 1.2 Z + 1 MiB: 57,420-86,132 / 69,897-104,847 MiB
  (RUNBOOK:584-590), judged on 04's ps peak / N (femtic_watch, femtic_lib.sh:542); sacct MaxRSS(.batch) / N is a
  cross-check (RUNBOOK:665-674). Both are node sums: a correct model reads 0.7996 Z if only 2 of 3 v2 ranks peak
  together, so a reading above the band is conclusive and one below it is not (RUNBOOK:679-687; D7).
- Layouts: v2 3 x 24 = 212,262 MiB and v3 2 x 36 = 173,304 MiB fit under 242,204 MiB (95 % of 254,952;
  README_phoenix.md:480-481). At N_iv 840, v3 needs 1 x 72 or highmem.

### 1.5 Data: D2 settled, rotated observe.dat written (C5), EDI frame guard (round 3)
- **Decided (Ben, 09-28): the sensors were aligned to geomagnetic north** (validation/rotation_2026-09-28/README.md:3-5).
  The EDIs carry DECLINATION 0 and ZROT 0, so Z is in the magnetic frame; the mesh x axis is UTM 53 grid north.
- **alpha = D - gamma = 7.42 deg: magnetic north is 7.42 deg clockwise of grid north.** At the real epochs (2022.83,
  2024.29, 2025.21) the per-site alpha is 7.362-7.488 deg, all within 0.068 deg of 7.42
  (validation/rotation_2026-09-28/README.md:151-166; alpha_per_site.csv). The single 7.42 is used.
- **prep does the rotation.** Config block `data.rotation`, which needs `schema: prep_vulcan/2`: an older prep then
  refuses the config instead of silently writing unrotated data. Z' = R(-a) Z R(-a)^T, with variances via (M o M),
  before the error floor (scripts/prep_vulcan.py:117; applied at :1771-1783). prep runs 18 checks: C08/C09 against
  an independent rotation (:819), C15 sign/strike/variance, C16 isotropic invariance, C17 mesh reuse, and C18 (round
  3, :894-950), which fails if an EDI records a rotation: ZROT != 0, a Z-block ROT= other than ZROT, an HX/EX azimuth
  other than 0 or HY/EY other than 90, or DECLINATION != 0 under frame_in magnetic or grid; an EDI copy with ZROT 7.42
  now fails it (validation/rotation_2026-09-28/README.md:250-254). `auto` takes only the column of its frame_in (:107).
- **Product: mesh/vulcan_v2_rot/inversion/observe.dat** (sha256 d501abcf5a7dde5f), upload part D (UPLOAD_LIST:60-64),
  only in this worktree (untracked). control.dat and files/* equal v2's (C17); mesh.dat and the model come from v2
  (mesh/vulcan_v2/mesh_logs/products.md5). Regenerated in round 3 with the same observe.dat; its READMEs and
  manifest header now record prep_vulcan.py's sha256 (validation/rotation_2026-09-28/README.md:255-258).
- **v2 uses the rotated observe.dat everywhere**: gate100, gate3, t4 and inv01 (RUNBOOK:237-243). The unrotated
  pair (sha256 f4678d05) stays as observe_unrotated.dat and station_map_unrotated.csv. Only data values differ
  (runbook_check.sh K3.6), so the gate and memory figures are the same with either file.
- **v3's rotated pair is part D too** (RUNBOOK:244-249, from the 09-29 cleanup). It replaced a refuted v3_rot prep
  recipe, which fails C17 on v2's 4 m site refinement (config/vulcan_mesh_v2_rot.yml:132 against
  config/vulcan_mesh_v3.yml:145,155). The unrotated observe.dat and station_map.csv are byte-identical in
  MAIN/mesh/vulcan_v2/inversion/ and MAIN/mesh/vulcan_v3/inversion/. For v3: B3.2 and B3.3 with vulcan_v3, and B3.4's
  v3 lines with 6f1e579e (observe.dat) and eecf20d9 (station_map.csv).

### 1.6 prep: behaviour change of the delete guard
- `--force` deletes a run directory only if every file in it is listed in its prep_manifest.sha256 with an unchanged
  sha256. Foreign or edited files also need `--force-delete-foreign`. The v1-v3 directories predate the manifest,
  so `--force` refuses them: re-prep into a new `--out`.
- New in round 2: prep refuses to delete any directory reached through a symlinked or junctioned path component,
  whatever the flags (link_components, scripts/prep_vulcan.py:1920; inside() compares realpath, :1991). The error
  prints the real path to pass instead. The round-1 guard deleted a fixture's config and EDIs through a junction
  (validation/prep_checks_2026-09-28/README.md, tests J1-J3 on mutant M11).
- A run stopped by the late CR scan or the re-inventory keeps its marked RUN.staging, and the next run clears it.
  C06/C08/C09 report N/A when nothing was compared. The prep harness expects 18 check lines (N_CHECKS,
  validation/prep_checks_2026-09-28/inject_and_check.py:40): 85/85 on Windows, and its controls C1-C4 fail with the
  old count 14 (validation/rotation_2026-09-28/run_followups.log Part C). --check-only: no FAIL on v1-v3, v2_rot (Part F).

### 1.7 Verifier verdicts

| Item | Round | Ready for Ben | Upheld / refuted | State |
|---|---|---|---|---|
| kit C1+C2 | 1 | yes | 28 / 0 | 7 misses fixed in the kit follow-ups (unverified) |
| runbook B1-B6, runbook2 | 1, 2 | no | 31 / 4, 22 / 2 | superseded by runbook round 3 |
| prep C3/C4/C7 | 1 | no | 40 / 2 | junction hole etc. fixed in prep round 2 (unverified) |
| docs C6 | 1 | yes | 46 / 3 | fixed in docs round 2 (unverified) |
| C5 rotation | 2 | yes | 66 / 2 | all 40,320 values recomputed from the EDIs; open points fixed in round 3 (unverified) |
| runbook round 3 | 3 | **yes, B1-B6** | 21 / 2 | open items below; none blocks B1-B6 |
| Phoenix B2 evidence | 09-30 | **yes** | 64 / 4 | PHX/README.md not yet corrected (below) |
| kit follow-ups, prep round 2, docs round 2, C5 follow-ups, 09-29 cleanup | 2-3 | no verdict | - | not yet verified |

**Runbook round 3: ready for B1-B6.** The verifier reproduced the checker (391/0) and the 54/54 mutants, and matched
all 27 measured upload rows. Fixed from round 2: the Never list allows 04 in t4 (RUNBOOK:777-783); the N_iv 840
rerun stores J4b and a ledger line (:701-704); B5 states the node-sum limit (:679-687); no `--dependency` on B2
(:221-223); one gate job per directory in README_phoenix.md:218-219 and 06:43-44. Its open items:
- **Closed by the 09-29 cleanup** (docs/journal/2026-09-28_pickup.md, last section; no verdict): the refuted v3_rot
  recipe (now RUNBOOK:244-249; 1.5); the old folder names (README_phoenix.md:147-157 tree, steps 8-10 at :207-234;
  01:529-531, 03:57, 04:17-18, 05:6, 06:49-52); recovery of the round-2 upload folders (B3.0, RUNBOOK:251-261);
  LAYOUT under NIV=840 (:558, :709-715); the nits (:32-34, :280-282). **Still open:** three verifier mutants survive
  the checker at 391/0 (B4b's SF line, B5's --time, B5's v3 comment line); the current values are right.

**Phoenix B2 evidence: ready for Ben** (64 upheld, 4 refuted, 8 missed; docs/journal/2026-09-30_phoenix_smoke.md).
PHX/README.md still carries the 4 refuted points (e.g. 4e cites README_phoenix.md:186-187; the line is :191-192)
and overstates "B2 passed": criterion 2 is unverified; its 46 s is 01's date lines, its 0.06 SU also assumes 4 cpus.

**C5 follow-ups (round 3, no verdict yet)** close the C5 open points: C18, the `auto` column, the reuse README and
the script sha256 (1.5), and the harness count (1.6); scripts/edi_inventory.py now writes the dates/frame section of
Vulcan/edi_inventory.md (validation/rotation_2026-09-28/README.md:262-265). Left: C18 cannot test the E axes; the
mesh/vulcan_v{1,2,3} READMEs' check tables predate C15-C18; the regenerated v2_rot was not rechecked in WSL.

## 2. Decisions

### D1. Mesh v2 or v3: the rule is now stricter
- **Rule: v2 only if both the 100 and the 3 ohm-m gate pass on Phoenix, on all 21 observe.dat bands.** Each is one
  3 x 24 job, at most 172.8 SU (RUNBOOK:348-352,456-463). Otherwise run the v3 gates (2 x 36, at most 345.6 SU each);
  if v3 fails too, stop before B5 (RUNBOOK:465-486).
- Why stricter than the morning rule (v2 if 100 ohm-m passes): the WSL 3 ohm-m gate covered 8 bands, 10 production
  bands were never tested, and 3 ohm-m is the high-frequency stress case. Cost: one more job.
- This came from the runbook agent (RUNBOOK:348 still says "Ben confirms before submitting"). Ben: confirm once. If
  you keep the morning rule, leave out the gate3 lines.

### D2. Sensor frame: DECIDED, geomagnetic north (1.5)
- Left open: the single 7.42 deg (in use) or per-site `auto` (one config line; at most 6.5e-4 |Z|_F difference;
  validation/rotation_2026-09-28/README.md:166). Recommendation: keep 7.42. Confirm C18's DECLINATION rule: 0 is
  required under frame_in magnetic or grid, information only under true (prep_vulcan.py:894-950); the 120 EDIs pass.

### D3. Parameter cells (56-69k): unchanged
- Accept for the first inversion; fix before the regularisation trade-off study. Any rebuild now also needs a
  proven Phoenix mesh route and site triangles near delta_min/20 (4).

### D4. Flat topography: unchanged. Accept for the first inversion (docs/mesh_tetra_pipeline.md section 8).

### D5. Error floors 5 % / 20 %: unchanged. Keep them for the first inversion. After rotation the floor still sets
100/97/96/100 % of the xx/xy/yx/yy errors (validation/rotation_2026-09-28/README.md, 'How much the rotation moves').

### D6 (new). Config comment edits broke byte identity with config_used.yml
- The docs agent edited comments in config/vulcan_mesh_v{1,2,3}.yml. The parsed YAML is unchanged and
  `prep --check-only` passes, but the files now hash 75d550b2 / bd49fc77 / 7fed3c79 against config_used.yml's
  5d00fe5e / 9a83b22a / a2ee2fc7. The generated READMEs name both shas (mesh/vulcan_v2/README.md:3);
  mesh/vulcan_v1/REPORT.md:31 still names only the old one.
- Options: accept (config_used.yml stays the exact record of what built each mesh) or revert the three configs.
- Recommendation: accept, and fix REPORT.md:31. config_used.yml is the provenance record by design.

### D7 (new). B5's memory reading: change femtic_watch before B5?
- Both B5 readings are node sums (1.4), so a low T4 reading is inconclusive and the 1,036.8 SU job can end in "tell
  Fable". About 5 lines in femtic_watch (femtic_lib.sh:542: keep the largest RSS per femtic pid, or read VmHWM)
  would give a true per-rank peak; it needs a library version bump, a new upload list and a checker rerun.
- Recommendation (runbook agent and verifier): do it before B5. B1-B4b do not depend on it.

## 3. Next steps

### Ben can do now (runbook round 3 and the 09-29 cleanup: ready for B1-B6; B2 ran on 09-28)
1. ~~Paste sacct/rcstat for 16153670~~ DONE 2026-09-30 (PHX/sacct_16153670.txt, rcstat_16153670.txt): B2 passed on all
   three criteria.
2. **B3, upload the inputs** (RUNBOOK:225-329, no job): WinSCP parts B and C of UPLOAD_LIST_2026-09-28.txt (704 MB,
   from D:/BEN/FEMTIC_2026/mesh/vulcan_v{2,3}/) to /hpcfs/users/a1690074/vulcan_femtic/inputs/vulcan_v2 and
   vulcan_v3 (B3.0 moves an earlier round-2 upload); B3.2 renames the unrotated v2 pair; B3.3 WinSCPs part D (2
   files, 505,628 B, from the worktree's mesh/vulcan_v2_rot/inversion/); B3.4: 12 `: OK` and `d501abcf5a7dde5f`.
3. **B1 without the rebuild, then B4a**, as in (b); B2 need not be repeated. Confirm D1, D6, D7 and C18's rule (D2).
4. **No `git add -A` in D:/BEN/FEMTIC_2026** while MAIN/hpc/smoke_foss_20260928_211308/ (17 MB) is there: .gitignore
   (:18, :21) covers only its *.geo and femtic_N.log files.
5. If not done yet: delete C:/Users/joint/anaconda3/Library/c/ by hand (18 files, a prep fixture output that an agent
   created by mistake at 21:30 on 09-28 through Anaconda's cygpath; its own delete was blocked).

### (a) Local (PC, light only)
- L1. Verify the kit follow-ups, prep round 2, docs round 2, the C5 follow-ups and the 09-29 cleanup (no verdicts).
- L2. After any kit or runbook edit: `bash hpc/phoenix_plan/tests/gen_upload_list.sh`, then
  `bash hpc/phoenix_plan/tests/runbook_check.sh` (about 3 min, PC only).
- L3. Commit this worktree when Ben says so (author bvkay only). L4. Update the memory note (table at the end).

### (b) Phoenix with the amended kit (library version 4), in runbook order
- **B1** (RUNBOOK:75-174): B1.1 md5 manifest of 16 files on the PC; B1.2 WinSCP part A (17 files, Binary); B1.3
  16 `: OK` and 16 `:0`; B1.4 c1c2 `SUMMARY: 128 passed, 0 failed` and portability `SUMMARY: 10 passed, 0 failed`
  (14 with python3.6 on PATH) with `PASS R1 python 3.6.8 RESULT (PASS)`; B1.4's `expect =2` holds (55bbf44's lib).
  **B1.5: skip the rebuild** (PHX/README.md 7: the 09-28 build wrote the 732 B femtic_env.sh with the remap, and the
  version-4 01 builds what HEAD built); run only its `install` line and checks (:149-153). If you rebuild, save
  `md5sum $BIN/femtic $BIN/femtic_env.sh` first and compare after: a changed femtic means repeating B2 (<= 2.4 SU).
- **B2** (:175-224): **passed on 09-28 with the HEAD kit on all three criteria** (1.1; criterion 2 confirmed 09-30). The lib functions its
  SMOKE_ONLY path calls are byte-identical in version 4; 06 runs the version-4 gate first in B4a (06:112-113).
- **B4a** (:330-504): v2 gate100 and gate3 in $WK/v2/gate100 and gate3; binding and CPU-efficiency checks; the D1
  table (:456-463); the v3 gates only if v2 is out.
- **B4b** (:505-564): forward time and memory from gate100, its LAYOUT, and the B5 layout preview.
- **B5** (:565-735): T4 in $WK/<mesh>/t4, ITERATION 0 1, 12 h, at most 1,036.8 SU. Fails if the ps peak per rank is
  outside the band (1.4), 04 warns that the measured N_iv differs, or CPU efficiency is under 50 % (:567-575).
- **B6** (:736-760), after 10-01: rcquota, Q4 grant, `sbatch --test-only`, billing basis.
- **Then (no runbook step yet):** inv01 in $WK/<mesh>/inv01, set up like a gate directory, with gate100's LAYOUT
  copied in (RUNBOOK:556-558), then 05_chain.sh (README_phoenix.md:229-234).

### (c) Code and docs
- **K1 runbook (round 4):** the three checker gaps (1.7); B1's "Why" (RUNBOOK:85-86) and B1.4's comment (:123) still
  describe the fa58604 kit, and B1.5/B2 should say that the 09-28 smoke stands while $BIN/femtic is unchanged.
- **K2 kit docs:** README_phoenix.md steps 4-5 (:175-192) still ask for the rebuild and record only the failed 09-25
  smokes; list tests/runbook_check.sh, runbook_mutate.py and gen_upload_list.sh in README section 0 (:16).
  tests/portability_test.sh's B1 scan flags `${VAR:-$(cd ... && pwd)}` as a `${var/pat/rep}` (a false positive
  the round-3 agent worked around). **K4:** correct PHX/README.md's refuted and missed points (1.7).
- **K3 per-rank peak (D7):** femtic_watch (femtic_lib.sh:542) sums RSS over the node; keep a per-pid maximum.
- **P1 and P2: done in round 3** (unverified; 1.5, 1.6).
- **P3 docs leftovers:** halfspace_accuracy.md:271 still says v1 and v3 bracket v2; mesh/vulcan_v{1,2,3}/README.md:134
  still says "copy of files/ on ext4"; REPORT.md:31 (D6).
- **P4 J6_BxRepaced** (optional rename): every file carrying it is listed in validation/prep_checks_2026-09-28/README.md;
  alpha_per_site.csv row 98 must change too, or `auto` refuses the site.
- **C7 (deferred):** reduce the parameter cells, then re-gate; an observe.dat-to-mesh binding check.
  DISTORTION != 0 is now rejected by load_config.

## 4. Risks

**Memory and HPC**
- The sensitivity step is unmeasured (1.4); MKL's multi-RHS workspace is unknown. Only the rank count prevents an
  OOM kill: FEMTIC runs in core, and MEM_LIMIT applies only to FWD_SOLVER 1/2 (README_phoenix.md section 6).
- N_iv 840 would leave v3 at 1 rank per icelake node (126,611 MiB per rank).
- The production launch line (`mpirun --map-by ppr:R:node:PE=T`) has never run. B4a's binding check assumes the
  OpenMPI 4.1 `--report-bindings` format, never seen on Phoenix. B5 decides on 04's ps peak, because sacct's .batch
  MaxRSS depends on JobAcctGatherType, which discovery did not record (RUNBOOK:665-670).
- tmpfs: if $TMPDIR is RAM-backed, the sensitivity files (20,101 MiB v2, 21,120 MiB v3) count against --mem. v2 at
  3 x 24 then fits only if FWD_MB <= 30,887 MiB (3 x (FWD_MB + 43,147) + 20,101 <= 242,204; expected FWD_MB 28,629;
  RUNBOOK:533-537,553).
- Phoenix's bash 4.4, gawk 4.2 and Python 3.6.8 are inferred from RHEL 8.4, not printed by discovery.
- Vulcan wall times are WSL speed (on the example Phoenix matched WSL, ratio 1.03; PHX/README.md 4d). Billing on
  elapsed or requested time is unknown (B2's rcstat was not copied); jobs before 10-01 bill to Q3.

**Mesh and gate**
- **No tested Phoenix mesh-build route** (docs/mesh_tetra_pipeline.md:809-815; hpc/ported/README.md:14-16).
  run_mesh_chain.sh has run only in WSL; 03_mesh.slurm is a different, ungated chain (reads files/regions.txt);
  the Phoenix mesh tools were installed but never run. Before any rebuild (D3), rebuild v2 or v3 on Phoenix,
  compare with its products.md5, and re-gate.
- **Site-size rule delta_min/20** (docs/mesh_tetra_pipeline.md:570-575): 39 results at h/delta <= 0.048 passed,
  2 at >= 0.114 failed, 3 at 0.0645-0.0683 went 2 fail / 1 pass. A safe bound, not an optimum: about 3.1 m at
  200 Hz and 4.4 m at 100 Hz in 3 ohm-m. v2 (4.1-4.2 m) meets it at 100 Hz; neither mesh meets it at 200 Hz.
- **v3/v2 CPU ratio is 1.4-1.9**, not a single number (per batch 0.91-2.06; halfspace_accuracy.md:21-22,291-294). Only the
  16 % memory saving of v2 is solid.
- **The v3 long-period excess is one site (Vul24-19) at 0.0063 and 0.0020 Hz, but not at 797 s,** where site 64
  (1.26 %) is close behind (1.30 %) (halfspace_accuracy.md:249). v2 can have an outlier of its own.
- 1000 s is untested (lowest band run 797 s); v3's domain is about 3.1 skin depths at 1000 s in 100 ohm-m
  (mesh_stats.txt:174).
- The WSL gate was not the guide's: 100 not 60 ohm-m, an added 2 % diagonal limit, OWNER_ELEMENT -1 only. v2's
  only WSL failure rests on the added limit. WSL/mesh_runs/ACC_CHAIN.DONE's "rc=1" is the deliberate v2 skip.

**Data and prep**
- C18 checks ZROT, DECLINATION and the H azimuths, but not the E axes (1.5); J6_BxRepaced is still misspelt (3c, P4).
  The 20 infill EDIs lack EY, RX and RY in DEFINEMEAS/MTSECT; their Z blocks are complete.
- Rotation mixes variances: unfloored SEs change by up to 50 %, but the floor sets 96-100 % of the errors. Z
  covariances are not rotated (the EDIs carry none). `--check-only` does not verify prep_manifest.sha256.

**Process**
- **Line references in this file drift.** Up to four agents edited the kit today, and verdicts found stale
  citations twice (prep round 1; the C5 verdict cited prep_vulcan.py:289 for what was at :286). Re-read before acting.
- Git Bash's grep strips CR, so `grep -c $'\r'` prints 0 on the PC whatever the file holds. Use
  `tr -cd '\r' < f | wc -c`; on Phoenix grep counts CRs correctly.
- Everything since 55bbf44 is uncommitted (20 modified tracked files, 11 untracked paths, this file included).

### Memory note vs repo (vulcan-femtic-project.md, modified 09-30 07:56)

| Memory says | Repo says |
|---|---|
| Kit at "FEMTIC_LIB_VERSION 3" (round-1 paragraph) | 4 (femtic_lib.sh:27), as its rounds 2-3 paragraph says; 01 SMOKE_ONLY, 03-06 refuse 3 (01:154, 04:120) |
| "FEMTIC has never executed on Phoenix"; restart "identical"; UD QP warning "on every rank start" | Ran 09-28 (1.1); final model differs at the 7th digit in 29/288 blocks; 4 per rank in straight and leg 2, none in leg 1 (PHX/README.md 4b, F3) |
| "C5 adds data.rotate_to_grid_deg" | Block `data.rotation`, `schema: prep_vulcan/2` (config/vulcan_mesh_v2_rot.yml) |
| delta_min/20 = "3 m @200 Hz, 4.3 m @100 Hz" | 3.1 / 4.4 m (docs/mesh_tetra_pipeline.md:570-575) |
| "Only the elements within ~12 m of each site mattered" | A +1.0-1.4 % core-driven bias remains on all meshes (halfspace_accuracy.md:217) |
| "3-18 min per frequency ... v2 ~half the time" | Slowest frequency 418 s v2 / 755 s v3 (06:60-63); CPU ratio 1.4-1.9 |
| "take site elevations from a DEM"; "Build coordinates from INFO block" | Flat mode ignores elevations (prep_vulcan.py:981); coordinates come from HEAD (scripts/edi_inventory.py:4-9) |
| RHO/PHS hand check; "Verified by an affine fit" | No artefact of either in the repo |
