<!-- PAUSED 2026-10-07 by Ben after the mesh-build Local|Phoenix slice. Resume order, in this sequence:
  1. Phoenix (Ben): S1-S4 with kit abbee8a, then Run04 -> Run05 (mesh references; copy back intermediates/ to
     mesh/phoenix_RunNN), then Run01 -> Run02 (v2 gates, decides D1), then Run03 (T4 memory test).
  2. GUI (Ben): M5 demo on screen and over Remote Desktop; decide Save-as-only and the repo licence.
  3. Port P2 fixes before any GUI M7 work (verdict 2026-10-07, not ready): reconcile gui_design section 9 with the
     femtic_mesh code (doctor is `python -m femtic_mesh.doctor`, exit 2 when incomplete; output layout; env vars);
     chain.py earlier-build guard must refuse prep-layout folders (mesh/vulcan_vN); add the makeTetraMesh ITER_MAX
     log check; refuse UNC/WSL paths in backends; doctor must not advise Local at Vulcan size until a v2-size
     conda-forge tetgen run is timed somewhere allowed. Then B4: cmp the makeMtr port against Run04's .mtr files.
  4. Decisions B1 (how students get the repo, EDIs and env onto their machines) and B3 (Windows backends: per-OS
     makeTetraMesh binaries vs the Gmsh route, TD6 on a student-class Windows machine) before GUI phase 2 beyond M6.
  5. Open GUI cosmetics: axis '(x0.001)' SI prefix, misfit colour scale from min, integer iteration axis.
  Tetgen on this PC during 2026-10-06/07: 19 runs, all on the 4,705-node chain_proof case, never on v2. -->

<!--
docs/STATUS.md - the living "where we are" page for the Vulcan FEMTIC project.
Rewrite it at every milestone or end of session. History goes in docs/journal/.
This version: 2026-10-06 evening, after the folder model and the KISS kit (docs/journal/2026-10-06_folder_model.md).
Every claim cites a file. Path keys: bare paths are repo-relative; kit files (01-06, run.sh, status.sh, femtic_lib.sh,
README_phoenix.md, RUNBOOK.md) are in hpc/phoenix_plan/. MAIN/ = D:/BEN/FEMTIC_2026, the main checkout (gitignored
meshes and outputs); PHX/ = validation/phoenix_2026-09-28/; ARCH/ = docs/dev/phoenix_runbook_2026-09-28/.
Line numbers hold for the uncommitted working tree of branch claude/femtic-work-9213a4 on 2026-10-06 21:55.
-->

# Vulcan FEMTIC - project status (2026-10-06, folder model and KISS kit)

## 1. Where we are

### 1.1 The student workflow (built 2026-10-06, uncommitted)
- **KISS rule (Ben, 10-06): no checksum or md5 step anywhere in the student workflow.** No kit manifest, no mesh or
  run md5, no .verified caches, no jobs ledger. The only provenance mark is the kit's VERSION file (git short sha,
  commit date, branch, export date); every job prints `KIT VERSION: <sha> (<date>)` near its start (femtic_lib.sh:42-46;
  01:159, 03:72, 04:129, 05:67, 06:119). File integrity rests on FEMTIC's own reader and the kit's existing input
  checks (present and not empty, control.dat END, resistivity-block structure). Rigorous tests stay on the PC
  (hpc/phoenix_plan/tests/) and are never a student step. No git and no tokens on Phoenix.
- **Phoenix layout** (VF=/hpcfs/users/$USER/vulcan_femtic; RUNBOOK.md:18-23): `$VF/kit/` (the exported kit and
  VERSION); `$VF/shared/mesh_v2/` and `mesh_v3/` (mesh.dat, resistivity_block_iter0.dat; uploaded once);
  `$VF/runs/RunNN/` (control.dat, observe.dat, station_map.csv, run.env, RUN.md, logs/, and links to
  `../../shared/mesh_vN/`); `$VF/runs/INDEX.md`, one line per run. FEMTIC stays in /hpcfs/users/$USER/femtic/bin.
  Obsolete: /hpcfs/users/$USER/FEMTIC_2026 and the 09-28 `inputs/` + `work/<mesh>/<name>` folders. No script defaults
  to them (the only FEMTIC_2026 left is a history comment, 00_discover.sh:16).
- **Run names are plain Run01, Run02, ...** and never reused; the purpose lives in RUN.md and runs/INDEX.md.
- **RUNBOOK.md (139 lines) replaces the 09-28 runbook:** one command and one "Fails if" per step. Once: S1 check
  femtic/bin and make the folders; S2 `bash scripts/make_phoenix_kit.sh`; S3 WinSCP export/kit to $VF, then
  `cat $VF/kit/VERSION`; S4 the two meshes (703 MB; S5 moves an earlier upload out of `inputs/`). Per run: R1
  `scripts/make_run.sh` (PC), R2 WinSCP runs/RunNN, R3 `bash $VF/kit/run.sh RunNN`, R4 `bash $VF/kit/status.sh RunNN`,
  R5 WinSCP back with a file mask that skips the linked mesh, models, VTK and fwd0_*/, R6 fill the INDEX.md line.
  F1 and F2 are the first runs (1.3). The 848-line 09-28 runbook, its upload list and its checker are archived
  unchanged in ARCH/ (ARCH/README.md: what was kept, what was dropped). README_phoenix.md stays the developer
  reference, not exported; its "RUNBOOK B<n>" now means the archive (README_phoenix.md:17).

### 1.2 The kit, version 5 (femtic_lib.sh:31 `FEMTIC_LIB_VERSION=5`)
- **Exported from a commit.** scripts/make_phoenix_kit.sh refuses (exit 1, names the files) while
  `git status --porcelain -- hpc/phoenix_plan` is not empty. Otherwise `git archive HEAD hpc/phoenix_plan` goes into
  export/kit/ (replaced every time) with VERSION, and it prints one WinSCP instruction. .gitattributes export-ignores
  tests/, README_phoenix.md, RUNBOOK*, UPLOAD_LIST*, build_*.log, discovery/, __pycache__; .gitignore covers export/
  and the Phoenix-only files of a run folder (runs/*/mesh.dat, resistivity_block_iter0.dat, fwd0_*/). Kit: 12 files,
  201,638 B. It has not been exported yet: it refuses this dirty tree, as designed.
- **The library comes from the kit, not from femtic/bin.** 01 SMOKE_ONLY, 03, 04, 05, 06 and run.sh source
  $KIT/femtic_lib.sh after $BIN/femtic_env.sh and need version >= 5 (01:158, 03:71, 04:128, 05:66, 06:118, run.sh:55).
  Uploading the kit is the only install step: no `install -m 644` into femtic/bin, and the version-2 library there no
  longer matters. Batch scripts default KIT=${KIT:-${PLAN:-$VF/kit}} (04:102, 06:93); run.sh and status.sh use their
  own folder (run.sh:36). 03 writes to $MESHDIR/inversion (03:61).
- **Provenance in outputs:** a last `kit` column in job_outcomes.tsv (femtic_lib.sh:590-594); `kit=<sha>` in 05's
  chain_jobs.txt (05:154); the kit sha in each RUN.md job line (run.sh:148); the banner again in 06's fwd0_report (06:247).
- **run.sh (160 lines, bash 4.4, no python)** reads the nine run.env keys (MESH JOB START_RHO RANKS THREADS TIME
  PARTITION ITER_STEP ITER_MAX; all required, `none` where one does not apply), checks control.dat, observe.dat and
  the two shared mesh files (present, not empty), links them (run.sh:113), applies the layout rule (:116-122) and
  submits with `-J RunNN` (:127-142): gate and forward to 06 (a gate passes START_RHO), t4 to 04 with WATCH_S=10,
  inversion to 05_chain.sh with ceil((ITER_MAX - last)/ITER_STEP) jobs; highmem adds --mem=1900G. It appends the job
  line to RUN.md, fills the INDEX.md line and prints two lines. It refuses an unknown run or key, a missing key, a
  missing or empty shared mesh, a refused layout, a run whose RUN.md lists a job (unless `--again`), a t4 whose
  control.dat is not ITERATION 0 1, and a real file where a mesh link belongs.
- **status.sh (36 lines, read-only):** sacct state of each RUN.md job (squeue if sacct is silent), the last
  T6/GATE/RESULT lines of the newest fwd0_report, the last job_outcomes.tsv and femtic.cnv rows, the INDEX.md line.
- **scripts/make_run.sh (PC, 120 lines):** `make_run.sh RunNN --mesh v2|v3 --data DIR --job gate|forward|t4|inversion
  --layout RxT --time T --purpose "..."` (+ --start-rho, --iter-step/--iter-max, --partition, default icelake). It
  copies control.dat, observe.dat, station_map.csv (t4: sets ITERATION 0 1), writes run.env and RUN.md and appends
  the INDEX.md line; it refuses a used name or INDEX line, missing data files and bad options.
- **Unchanged from version 4:** the PARDISO parser; the memory rule R x (FWD_MB + NONPARDISO_MB) + extra <= 95 % of
  --mem, enforced before launch by 04 and 06 (exit 1, no SU); 06 as the half-space gate (START_RHO,
  tools/halfspace_eval.py over 120 x 21 site-band pairs, exit 4 = T6 PASS but gate FAIL); 06's LAYOUT hand-over to
  05; the N_iv count; the Python 3.6-safe evaluator. The kit scripts never checked md5, so nothing was removed there.

### 1.3 Runs made (runs/INDEX.md), none submitted yet
| run | job | mesh, layout, --time | purpose |
|---|---|---|---|
| Run01 | gate, START_RHO=100 | v2, 3x24, 02:00:00 | D1 (RUNBOOK F1) |
| Run02 | gate, START_RHO=3 | v2, 3x24, 02:00:00 | D1, the high-frequency stress case (F1) |
| Run03 | t4, ITERATION 0 1 | v2, 3x24, 12:00:00 | sensitivity-step memory, N_iv, time; only after Run01 and Run02 pass (F2) |

- All three copy mesh/vulcan_v2_rot/inversion (observe.dat and station_map.csv byte-identical; control.dat too, except
  Run03's ITERATION line). The gate RUN.md files say the data values do not matter, only sites and frequencies.
- **Their RUN.md say `kit: 06d044f (2026-10-06 19:59), plus uncommitted changes ...`** (runs/Run01/RUN.md:8), and
  RUNBOOK F1 tells students to use them as they are. Re-make all three after the commit (3).
- Read-only check on the real v2 mesh (awk, no FEMTIC): run.sh's rule gives 3 x (31,322 + 43,147) = 223,407 MiB
  <= 242,204 for 3x24 (N_eq 2,847,429, M 65,341, N_iv 480); 4 ranks are refused at 297,876 MiB.

### 1.4 Compute state on Phoenix (unchanged since 09-30)
- **FEMTIC has run on Phoenix once:** job 16153670, SMOKE_ONLY, icelake p2-cpu-14, 2026-09-28: T1/T2/T5 PASS on
  FEMTIC's INV_MT_01 example; femtic.cnv rows 0-2 equal both WSL builds to 7 digits; COMPLETED 0:0, 48 s, 79 % of
  4 cores, max RSS 829 MB (PHX/README.md; PHX/sacct_16153670.txt). Kit then: committed 55bbf44, library version 2.
  FEMTIC is not bitwise reproducible (16 of 4,608 responses differ by 1.1e-9 of |Z| when iteration 0 runs twice), so
  no criterion may require byte identity (PHX/README.md 4b).
- **Not yet on Phoenix:** Vulcan scale (PARDISO 22-26 GiB per rank), the production launch line (the smoke used
  `--bind-to none`), any version-5 script, run.sh or status.sh, and any kit test under Phoenix's bash 4.4, gawk 4.2 or
  Python 3.6.8. **No inversion iteration has run on a Vulcan mesh** (only on the example: 2 on Phoenix, 5 on WSL).
- **Rule (Ben, 09-28): no modelling on the PC or in WSL** (RUNBOOK.md:9). Breach on record: the 10-06 mesh-
  alternatives study ran tetgen.exe and gmsh on sub-second toys on the PC (docs/journal/2026-10-06_mesh_port_study.md).

### 1.5 Meshes and the WSL gate (unchanged since 09-25)
- Three meshes, identical except for site refinement: v1 1,534,902, v2 2,446,095, v3 3,068,130 tets, each
  check_mesh 17/17 (mesh/vulcan_v*/mesh_logs/mesh_stats.txt:1). Parameter cells 55,992 / 65,341 / 68,654 against about
  21,000 designed (mesh_stats.txt:103); INV_METHOD 1 (data space) is right (mesh/vulcan_v2/README.md:268).
- WSL gate (5 % rho_a, 1.5 deg phase, 2 % diagonal; 3 and 100 ohm-m; 8 bands 200-0.0063 Hz): v1 fails at 20 Hz and
  above in 3 ohm-m; v2 fails one diagonal, 2.09 % at 200 Hz, site G7 (mesh/vulcan_v2/halfspace/acc_3/acc_eval_v2_3.txt);
  v3 passes with thin margins, 4.25 % and 4.37 % (Vul24-19).
- **v2 has never run at 100 ohm-m** (validation/mesh_2026-09-25/halfspace_accuracy.md:103), and 10 of the 21
  observe.dat bands never ran on any mesh (docs/mesh_tetra_pipeline.md:842). Run01 and Run02 gate v2 on all 21.
- Forward cost (WSL, 1 rank x 8 threads): peak RSS 19.7 / 28.3 / 33.7 GB for v1 / v2 / v3; slowest frequency 418 s on
  v2, 755 s on v3 (06:64-67); v3 costs 1.4-1.9x the CPU of v2 (halfspace_accuracy.md:21-22).

### 1.6 Memory: predicted, not measured
- **N_iv: expected 480, bound 840** (4 right-hand sides per MT site, from ObservedData.cpp; README_phoenix.md section 6).
- **Per rank** (WSL forward peak + two-array sensitivity step): v2 70,754 MiB, v3 86,652 MiB; with N_iv 840 102,727 /
  126,611 MiB (README_phoenix.md:480). Layouts v2 3 x 24 and v3 2 x 36 fit under 242,204 MiB (README_phoenix.md:507-508);
  at N_iv 840, v3 needs 1 x 72 or highmem.
- **Run03 has no gate's logs/fwd_rank_mb** (its own folder), so 04 falls back to 11,000 MiB per 10^6 equations
  (femtic_lib.sh:364,381) and prints `predicted per rank (layout rule): 31322 forward + 43147 sensitivity-step = 74469
  MiB` on v2 (93,103 MiB on v3, verifier's walk). RUNBOOK F2 instead quotes "about 69 GB per rank on v2 (70,754 MiB)"
  and "about 85 GB" on v3 (RUNBOOK.md:100-101): GiB labelled GB, and not the figure the job prints (3, K2).
- **KISS dropped from the student steps** the T4 band (0.8 Z to 1.2 Z), the `--report-bindings` check and the
  CPU-efficiency check (ARCH/README.md:21-25). F2 fails only on OUT_OF_MEMORY or `WARNING: measured N_iv`
  (RUNBOOK.md:103). The F2 reading is a node sum / ranks (femtic_watch), so a low reading is inconclusive (D7).
- tmpfs: if $TMPDIR is RAM-backed, the sensitivity files (about 20-21 GiB) count against --mem (README_phoenix.md:498).

### 1.7 Data: rotated to grid north (D2 settled)
- **Sensors aligned to geomagnetic north** (Ben, 09-28; validation/rotation_2026-09-28/README.md:3-5). The EDIs carry
  DECLINATION 0 and ZROT 0. alpha = 7.42 deg (magnetic north clockwise of UTM 53 grid north); the per-site alpha is
  7.362-7.488 deg at the real epochs (README.md:151-166 there).
- prep does the rotation (config block `data.rotation`, `schema: prep_vulcan/2`; scripts/prep_vulcan.py:117, applied
  at :1771-1783) and runs 18 self-checks, among them C18, which fails if an EDI records a rotation (:894-950).
- **mesh/vulcan_v2_rot/inversion/observe.dat is the data of every run, v2 and v3** (the unrotated v2 and v3 files are
  byte-identical, so the rotated pair serves both; RUNBOOK.md:88-89,97 use it for v3). Its mesh is v2's: files/* are
  identical (C17).
- **prep still writes the old ceremony into its generated READMEs:** "check their md5 against products.md5" and
  "Upload and run on Phoenix: hpc/phoenix_plan/RUNBOOK_first_inversion.md" (prep_vulcan.py:1546,1569,1686,1691,1701;
  mesh/vulcan_v2/README.md:297; mesh/vulcan_v2_rot/README.md:304-307; the same in v1 and v3). products.md5 stays a
  developer record of what built each mesh; it is no student step (3, K1).

### 1.8 prep: delete guard
- `--force` deletes only files its manifest lists unchanged (else `--force-delete-foreign`; v1-v3 predate the manifest:
  re-prep into a new `--out`), never through a symlink or junction (prep_vulcan.py:1920, :1991).

### 1.9 Developer tests (PC only, fakes for sbatch/sacct/mpirun/femtic) and verdicts
Rerun for this file on 2026-10-06 at 21:55 on the uncommitted tree, each in its own scratch WORK (the worktree's git
status was unchanged by the runs):

| test | result | fails if (short) |
|---|---|---|
| tests/c1c2_test.sh | 129 passed, 0 failed | the library is not version 5, a version-4 library runs, or any C1/C2/f check fails |
| tests/run_sh_test.sh (new) | 86 / 0 | run.sh reaches sbatch on a refusal case, or sends wrong flags, links, RUN.md/INDEX.md lines |
| tests/pc_scripts_test.sh (new) | 78 / 0 | make_phoenix_kit.sh exports a dirty tree or a wrong kit; make_run.sh accepts a bad run |
| tests/runbook_walk_test.sh (new) | 30 cases / 0 (293 assertions) | a RUNBOOK.md command or path does not work on a fake Phoenix |
| tests/halfspace_eval_test.sh | 31 / 0 | the evaluator differs from the 7 stored reports or misses its fail cases |
| tests/portability_test.sh | 6 / 0 (15 kit shell files) | bash > 4.4 or gawk > 4.2 in the kit, or Python > 3.6 in tools/ |

Each new check showed its failing case before passing; 11 run.sh mutants, 4 PC-script mutants and 4 external RUNBOOK
mutants were all caught (docs/journal/2026-10-06_folder_model.md). The archived runbook_check.sh fails 26 of 395 checks
against the version-5 kit, as expected; rerun it only at 06d044f (ARCH/README.md:27-30).

| Item | Date | Ready for Ben | Upheld / refuted | State |
|---|---|---|---|---|
| folder model: kit v5 + RUNBOOK.md | 10-06 | **yes** | 30 / 0, 8 missed | missed items in 2 (D8, D9) and 3 (K1-K7) |
| Phoenix B2 evidence | 09-30 | yes | 64 / 4 | PHX/README.md still carries the 4 refuted points |
| runbook round 3 | 09-29 | yes, B1-B6 | 21 / 2 | superseded by RUNBOOK.md (archived in ARCH/) |
| C5 rotation | 09-28 | yes | 66 / 2 | follow-ups (round 3) unverified |
| kit C1+C2, docs C6, prep C3/C4/C7 | 09-28 | mixed | 28/0, 46/3, 40/2 | later rounds unverified |

### 1.10 GUI phase 1 (built 2026-10-07, uncommitted; docs/journal/2026-10-06_gui_phase1.md)
**Scope confirmed by Ben in chat (2026-10-06 night): Results tab in phase 1, no network ever (design finding 14 closed).**

- **Exists:** src/femtic_gui (22 files, 3,393 lines; PySide6 + pyqtgraph, VTK only in viewer3d.py), a thin shell over
  prep_vulcan.py and make_run.sh (docs/dev/gui_design_2026-10-06.md s8). Tabs Data (bands, floors with C09's counts,
  Check, Run prep), Mesh (counts, 3D), FEMTIC (16 keys, 4 editable), Runs (New-run form, Record result), Results.
  Comments survive edits; Save as only; one job at a time through Git Bash (never WSL's bash); no git, no network.
- **Launch** (env femtic_gui; pins in environment-gui.yml), from the worktree root: `femtic-gui config/vulcan_mesh_v2_rot.yml`;
  tests `python tests/gui/run_all.py`. Not from MAIN until the merge and `pip install -e . --no-deps` there.
- **Verdict:** 44 PASS, 0 FAIL, 0 NOT RUN (19 s); verifier 22 upheld, 0 refuted, 9 missed, ready for Ben. Its
  offscreen walk ran real Check (16 PASS, 2 N/A), Run prep (18/18) and make_run.sh. Never seen on a real screen (M5).
- **Open:** confirm Results (relayed scope, design finding 14) and Save-as-only; licence (MIT headers, none chosen); the
  form lacks `--job mesh` (in abbee8a); G1, G6 (G4 closed by abbee8a's R5 mask); the verifier's nits (journal).

### 1.11 Mesh builds: Local | Phoenix (D12, Ben 2026-10-07; uncommitted; docs/journal/2026-10-07_local_or_hpc_p2.md)
- **Decided: students may build meshes on their own machines if resources allow; the GUI gets "Build mesh: Local | Phoenix"** with tool detection and a resource estimate (docs/dev/gui_design_2026-10-06.md s9, design only; G2's cut rested on Ben's PC only). FEMTIC and the half-space gate stay on Phoenix; the gate accepts any mesh (D11), and the gated mesh is the file uploaded to shared/.
- **P2 first slice exists (src/femtic_mesh: makemtr, backends, doctor, checks, chain):** `python -m femtic_mesh.doctor` exits 0 only with designer, tetgen, sizing and convert, else 2 (this PC: 2; no makeTetraMesh, tetgen only via --tetgen); `python -m femtic_mesh.chain RUN_DIR [--from-poly P] [--dry-run]` builds. Real conda-forge tetgen on chain_proof: 4,798 / 28,039 vs WSL 4,705 / 27,501 (+2.0 %), check_mesh 17/17; tests 27 / 0 / 2 skip.
- **Not ready (verifier 34 upheld, 3 refuted, 9 missed):** gui_design s9.0/9.2 contradict the code (doctor command and exits, output layout); no Windows/macOS makeTetraMesh, so Local is --from-poly only; a prep-layout folder is not guarded (chain.py:39); no ITER_MAX check (N3); no UNC/WSL path refusal (backends.py:96).

## 2. Decisions

### D0. Decided 2026-10-06 (Ben): KISS and the folder model (1.1)
- No checksums in the student path; the kit VERSION line is the only provenance; plain run names; the kit is
  exported from a commit; no git or tokens on Phoenix; the least possible copied by WinSCP. Rigour stays in tests/.

### D1. Mesh v2 or v3 (proposed 09-28, now RUNBOOK F1)
- **v2 only if both Run01 (100 ohm-m) and Run02 (3 ohm-m) PASS on all 21 bands.** Each 3x24, 2 h, at most
  172.8 SU. Otherwise Run04/Run05 on v3 (2x36, at most 345.6 SU each); if v3 fails too, stop (RUNBOOK.md:82-91).
- Stricter than the morning rule of 09-28 (v2 if 100 ohm-m passes) because the WSL 3 ohm-m gate covered 8 bands and
  3 ohm-m is the high-frequency stress case. Ben: confirm once, or drop Run02.

### D2. Sensor frame: decided, geomagnetic north (1.7)
- Left open: the single 7.42 deg (in use) or per-site `auto` (at most 6.5e-4 |Z|_F difference). Recommendation: keep 7.42.

### D3-D5. Unchanged: accept 56-69k parameter cells, flat topography and the 5 % / 20 % error floors for the first
inversion; fix the cell count (D3) before the regularisation study (docs/mesh_tetra_pipeline.md section 8).

### D6. Config comment edits broke byte identity with config_used.yml
- config/vulcan_mesh_v{1,2,3}.yml parse the same but hash differently from config_used.yml. Recommendation: accept
  (config_used.yml is the record of what built each mesh) and fix mesh/vulcan_v1/REPORT.md:31.

### D7. Per-rank memory peak (femtic_watch sums RSS over the node)
- The KISS runbook dropped the T4 band, so a low Run03 reading no longer fails F2; it only leaves the true per-rank
  peak unknown. Recommendation: run Run03 as is; change femtic_watch (keep the largest RSS per pid, about 5 lines,
  library version 6) only if the inversion layout needs a tighter number.

### D8 (new, blocks student use). Whose femtic/bin and $VF?
**DECIDED (Ben, 2026-10-06): students build FEMTIC once under their own account with 01_build_femtic.sh (README_phoenix.md section 3) and link it as $VF/bin (RUNBOOK S1).**

- FEMTIC is built only under Ben's account. BIN defaults to /hpcfs/users/$USER/femtic/bin (03:55, 04:100, 05:62,
  06:91) and VF to /hpcfs/users/$USER/vulcan_femtic, so a student logging in as themselves fails S1 (as designed:
  "ask Ben"), and each student would upload 703 MB of meshes. run.sh does not set BIN and nothing documents an override.
- Options: (a) one shared project folder (BIN and VF pointing at Ben's or a group path; needs read permission and a
  documented `BIN=`/`VF=`), or (b) each student builds once with 01 (needs hpc/ported/, which is not in the kit).
  Recommendation: (a) if Phoenix group permissions allow it; one build to maintain. Decide before handover.

### D9 (new). Student jobs email Ben
- `#SBATCH --mail-user=ben.kay@adelaide.edu.au` is in 03:12, 04:13 and 06:12, and run.sh does not override it. Keep, or
  have run.sh pass `--mail-type=NONE` or the student's address.

### D10 (new, other session). Mesh tools for students
- The 10-06 port study (docs/dev/mesh_port_feasibility_2026-10-06.md; docs/journal/2026-10-06_mesh_port_study.md):
  a pure-Python chain is not reachable (tetgen stays compiled). Its question for Ben: is "passes the D1 half-space
  gate" enough for a student mesh (keeps a Gmsh prototype, GPL), or must meshes match Usui's chain byte for byte?

### D11 (DECIDED, Ben, 2026-10-06). "Gate is good enough"

The half-space gate on Phoenix is the acceptance test for any Python mesh toolchain; byte-identity is a developer test for the TetGen2Femtic and makeMtr ports only (docs/dev/mesh_port_feasibility_2026-10-06.md).

## 3. Next steps

### What Ben does next
1. Review and commit this worktree as bvkay (4, "Uncommitted"), then merge it to main: MAIN/ is on main at abbee8a (GUI commit follows) and has no scripts/make_*.sh or runs/, which RUNBOOK.md's PC paths assume.
2. Re-make Run01-03 on the committed tree (delete runs/, rerun the three make_run.sh lines in the 10-06 journal) and commit runs/.
3. PC: `bash hpc/phoenix_plan/tests/runbook_walk_test.sh` (about 50 s, 30/0 expected), then S2 `bash scripts/make_phoenix_kit.sh`.
4. Phoenix: RUNBOOK S1, S3 (kit, check VERSION), S4 or S5 (meshes into $VF/shared/).
5. Run01 and Run02 (R2-R6, F1); Run03 only after both PASS, and send back F2's grep output.
6. D8 decided 2026-10-06 (students build once); D9 default no e-mail.
7. GUI (1.10): confirm Results and Save-as-only, then try it on screen before any student does (worktree root, `conda activate femtic_gui`, `femtic-gui config/vulcan_mesh_v2_rot.yml`: Data, Runs, Mesh > 3D, once over Remote Desktop); commit it with pyproject.toml (src/femtic_mesh is already in abbee8a).
8. Mesh builds (1.11): answer B1 (student machines) and B3 (Windows backends) first; meanwhile build M6 only (design editor + Phoenix route). Before M7: reconcile gui_design s9 with the P2 code, fix the chain.py:39 guard, N3 and the path refusal, and time one v2-size conda-forge tetgen run on Phoenix or a student's Linux machine.

### (a) PC, light only
- L1. After any kit or RUNBOOK edit, rerun the five kit tests (walk, run_sh, pc_scripts, c1c2, portability; 1.9). Worth
  a slash command if this repeats.
- L2. Unverified older rounds: prep round 2, docs round 2, the C5 follow-ups.
- L3. Memory note: vulcan-femtic-project.md's DEPLOYMENT MODEL paragraph still names a kit MANIFEST.md5, shared
  products.md5 and a run.sh md5 check (table at the end).

### (b) Phoenix (RUNBOOK.md)
- S1-S4 once, then Run01/Run02 (F1), D1, Run03 (F2). After Run03: the real inversion as a new run
  (`--job inversion --iter-step N --iter-max N`), with its layout from Run03's numbers. After 10-01: rcquota, the Q4
  grant and the billing basis (ARCH/RUNBOOK_first_inversion.md, B6).

### (c) Code and docs (open items from the 10-06 agents and verifier)
- **K1** prep_vulcan.py: point its READMEs to hpc/phoenix_plan/RUNBOOK.md and drop "check md5 against products.md5"  **DONE 2026-10-06 (fix agent; developer tests green; see journal).**
  (:1546,1569,1686,1691,1701), then regenerate or hand-edit mesh/vulcan_{v1,v2,v3,v2_rot}/README.md.
- **K2** RUNBOOK F2 (RUNBOOK.md:100-101): quote the figure 04 prints, in MiB (74,469 v2 / 93,103 v3 with the  **DONE 2026-10-06 (fix agent; developer tests green; see journal).**
  11,000 MiB per 10^6 equations default), not the README's 70,754 labelled "about 69 GB".
- **K3** Copy-back (R5) goes to hpc/phoenix_out/<date>/RunNN, so the PC's runs/RunNN/RUN.md never gets the job lines,  **DONE 2026-10-06 (fix agent; developer tests green; see journal).**
  and INDEX.md exists on the PC and on Phoenix with no sync: job ids reach git only when typed in R6.
- **K4** run.sh links the mesh before the layout check (run.sh:113 vs :116-122): a refused layout leaves two harmless  **DONE 2026-10-06 (fix agent; developer tests green; see journal).**
  links in the run folder. Move the links after the check.
- **K5** runbook_walk_test.sh exits 2 ("Filename too long") when WORK is a long Windows path (a clone path under  **DONE 2026-10-06 (fix agent; developer tests green; see journal).**
  validation/wsl_2026-09-25/ hits MAX_PATH); note it in the header or set core.longpaths in its clone.
- **K6** run.env has no NIV key: if Run03 measures N_iv 840, run.sh cannot pass NIV=840 to the inversion.  **DONE 2026-10-06 (fix agent; developer tests green; see journal).**
- **K7** README_phoenix.md section 9 (:688) still says FEMTIC has not run on Phoenix, section 6 still says B5;  **DONE 2026-10-06 (fix agent; developer tests green; see journal).**
  PHX/README.md still carries its 4 refuted points.
- **P3** halfspace_accuracy.md:271 (v1 and v3 do not bracket v2), mesh/vulcan_v{1,2,3}/README.md:134 ("ext4"),
  REPORT.md:31 (D6). **P4** J6_BxRepaced rename (optional; alpha_per_site.csv row 98 too). **C7** fewer parameter
  cells, then re-gate (D3); the port study's P0 (a Phoenix reference mesh-chain run) comes first (D10).

## 4. Risks and state

**Memory and HPC**
- The sensitivity step is unmeasured (1.6); MKL's multi-RHS workspace is unknown. Only the rank count prevents an OOM
  kill: FEMTIC runs in core, and MEM_LIMIT applies only to FWD_SOLVER 1/2 (README_phoenix.md section 6).
- The production launch line (`mpirun --map-by ppr:R:node:PE=T`) has never run, and with the binding check gone from
  the student steps nobody looks at the binding unless Ben reads Run01's output once.
- Phoenix's bash 4.4, gawk 4.2 and Python 3.6.8 are inferred from RHEL 8.4; no kit test has run there.
- Vulcan wall times are WSL speed (on the example Phoenix matched WSL, ratio 1.03; PHX/README.md 4d). Whether Phoenix
  bills elapsed or requested time is unknown; jobs before 10-01 bill to Q3.

**Mesh and gate**
- **No tested Phoenix mesh-build route** (docs/mesh_tetra_pipeline.md:809-815): run_mesh_chain.sh ran only in WSL;
  03_mesh.slurm is a different, ungated chain. Any rebuild (D3) must be re-gated with a Run on Phoenix.
- Site-size rule delta_min/20 (docs/mesh_tetra_pipeline.md:570-575): about 3.1 m at 200 Hz and 4.4 m at 100 Hz in
  3 ohm-m; v2 (4.1-4.2 m) meets it at 100 Hz, neither mesh at 200 Hz. 1000 s is untested (lowest band run 797 s).
- v3's long-period excess is one site (Vul24-19); v2 can have an outlier of its own (halfspace_accuracy.md:249).

**Data and prep**
- C18 does not test the E axes; the 20 infill EDIs lack EY, RX and RY in DEFINEMEAS/MTSECT (their Z blocks are
  complete). The floor sets 96-100 % of the errors after rotation; Z covariances are not rotated (none in the EDIs).

**Process**
- Line references drift: several sessions edit this worktree at once. Re-read a cited line before acting on it.
- Git Bash pitfalls: Anaconda's cygpath maps /d/BEN into anaconda3\Library (use `pwd -W`); count CRs with
  `tr -cd '\r' < f | wc -c`, not grep; GNU tar reads `C:/...` as host:path (use --force-local).
- **Uncommitted (2026-10-06 22:00):** everything since 06d044f (pushed to origin/main and this branch earlier today).
  Modified: .gitattributes, .gitignore, 01, 03, 04, 05, 06, femtic_lib.sh, README_phoenix.md, tests/c1c2_test.sh,
  tests/portability_test.sh, this file. Moved to ARCH/ (show as deleted): RUNBOOK_first_inversion.md,
  UPLOAD_LIST_2026-09-28.txt, tests/runbook_check.sh, runbook_mutate.py, gen_upload_list.sh. New: RUNBOOK.md, run.sh,
  status.sh, tests/run_sh_test.sh, pc_scripts_test.sh, runbook_walk_test.sh, scripts/make_phoenix_kit.sh,
  scripts/make_run.sh, runs/, docs/dev/phoenix_runbook_2026-09-28/, docs/journal/2026-10-06_folder_model.md.
- **Also untracked, from other sessions:** docs/dev/mesh_port_feasibility_2026-10-06.md, docs/dev/mesh_alternatives_2026-10-06/
  (16 files with CRLF endings under toys/), docs/dev/gui_conventions_from_mt_workbench.md and
  docs/journal/2026-10-06_mesh_port_study.md. Check them before `git add docs/`.
- Still true: no `git add -A` in MAIN/ while MAIN/hpc/smoke_foss_20260928_211308/ (17 MB) is there; delete
  C:/Users/joint/anaconda3/Library/c/ by hand if not done (18 stray fixture files from 09-28).

### Memory note vs repo (vulcan-femtic-project.md, modified 10-06 21:24)

| Memory says | Repo says |
|---|---|
| DEPLOYMENT MODEL: export/kit has "VERSION + MANIFEST.md5", shared/ holds products.md5, run.sh "checks shared md5" | No manifest and no md5 in the student path (1.1); the note's own KISS paragraph agrees with the repo |
| "Ben's order: B3 upload -> B1 kit (install lib v4 ...)"; "install femtic_lib.sh v4 only"; runbook "READY" | Kit version 5 read from $VF/kit, no install step (1.2); RUNBOOK.md replaces the archived runbook |
| "restart run identical to the straight run" | Final model differs in the 7th digit in 29 of 288 blocks (PHX/README.md 4b) |
| delta_min/20 = "3 m @200 Hz, 4.3 m @100 Hz"; "only the elements within ~12 m ... mattered" | 3.1 / 4.4 m; a +1.0-1.4 % core-driven bias remains (halfspace_accuracy.md:217) |
| "3-18 min per frequency ... v2 ~half the time" | Slowest frequency 418 s v2 / 755 s v3; CPU ratio 1.4-1.9 |
| "take site elevations from a DEM"; RHO/PHS hand check; "Verified by an affine fit" | Flat mode ignores elevations (prep_vulcan.py:981); no artefact of either check in the repo |
