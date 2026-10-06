# 2026-10-06 - Folder model and the KISS student workflow (kit version 5, RUNBOOK.md)

**Who/what:** Ben asked to "get rid of all this checksum checking" and "follow the KISS way". A workflow ran three
Opus agents on worktree claude/femtic-work-9213a4: the kit agent (kit version 5, make_phoenix_kit.sh, make_run.sh,
run.sh, status.sh, Run01-03), the runbook agent (RUNBOOK.md, the archive, runbook_walk_test.sh) and an adversarial
verifier; this agent then rewrote docs/STATUS.md and wrote this entry. Limits: no femtic, tetgen, mpirun or WSL; light
bash/awk/python on the PC only; nothing committed. Paths in hpc/phoenix_plan/ are written without that prefix.

## Decisions (Ben, 2026-10-06)
- **No checksum or md5 checking anywhere in the student workflow:** no kit MANIFEST, no mesh md5 step, no run md5, no
  .verified caches, no jobs_ledger. The only provenance mark is the kit's VERSION text file (git short sha, commit
  date, branch, export date), printed by every job into its log as `KIT VERSION: <sha> (<commit date>)`. File
  integrity rests on FEMTIC's own input reader. Rigorous testing stays on the developer side (tests/ on the PC).
- **Plain run names** Run01, Run02, ...; the purpose lives in each RUN.md and in runs/INDEX.md.
- **The kit is exported from a commit** (`git archive HEAD hpc/phoenix_plan`), never from a dirty tree.
- **No git and no tokens on Phoenix; copy the least possible by WinSCP:** the kit (once, and when it changes), one
  small RunNN folder per run, and the meshes once into `$VF/shared/mesh_vN/`.
- **Layout** under VF=/hpcfs/users/$USER/vulcan_femtic: kit/, shared/mesh_v2|v3/, runs/RunNN/ (links to
  ../../shared/mesh_vN/), runs/INDEX.md. FEMTIC stays in /hpcfs/users/$USER/femtic/bin. The old Phoenix copy
  /hpcfs/users/$USER/FEMTIC_2026 and the 09-28 inputs/ + work/ folders are obsolete.
- **Kit agent's design choice, for Ben to confirm:** every job sources `$KIT/femtic_lib.sh` after `$BIN/femtic_env.sh`
  and gates on version >= 5, so uploading the kit is the only install step. The runbook agent therefore left out the
  computed task's `install -m 644 femtic_lib.sh $BIN/` step (it would do nothing). Its second deliberate departure:
  R5 copies the whole run folder back with a WinSCP mask, not only logs/, because the job output with the KIT
  VERSION line and 04's sizing report, and RUN.md's job lines, live outside logs/.

## What was built (uncommitted)
- **scripts/make_phoenix_kit.sh** (Git Bash, 47 lines): refuses (exit 1, lists the files) when
  `git status --porcelain -- hpc/phoenix_plan` is not empty; else `git archive HEAD hpc/phoenix_plan | tar -x
  --force-local --strip-components=2` into export/kit/ (replaced each run), writes VERSION (4 lines), prints one WinSCP
  instruction. It deletes export/kit and exits 1 if export-ignore did not apply, a key file is missing or a CR is
  found. Measured kit: 12 files, 201,638 B. .gitattributes export-ignores tests/, README_phoenix.md, RUNBOOK*,
  UPLOAD_LIST*, build_*.log, discovery/, __pycache__; .gitignore adds export/, runs/*/mesh.dat,
  runs/*/resistivity_block_iter0.dat, runs/*/fwd0_*/.
- **femtic_lib.sh version 5:** femtic_kit_version (line 1 of $KIT/VERSION or `unknown`), femtic_kit_banner,
  a final `kit` column in job_outcomes.tsv. 01 SMOKE_ONLY, 03, 04, 05, 06 and run.sh read the library from KIT and
  print the banner; 05 writes `kit=<sha>` into chain_jobs.txt; 06 also puts the banner into fwd0_report. Defaults:
  VF=/hpcfs/users/$USER/vulcan_femtic; batch scripts KIT=${KIT:-${PLAN:-$VF/kit}}; login-node scripts their own
  folder; 03 writes to $MESHDIR/inversion. No default names FEMTIC_2026, inputs/ or work/ any more. The kit scripts
  never checked md5, so nothing was removed there; FEMTIC's needed checks stay (files present and not empty,
  control.dat END, resistivity-block structure).
- **run.sh** (Phoenix, 160 lines, bash 4.4, no python): nine required run.env keys, shared-mesh checks, links
  `../../shared/mesh_vN/`, the layout rule (silent unless it refuses), sbatch with -J RunNN, RUN.md and INDEX.md
  records, two output lines. Refusals: unknown run; missing, unknown or bad key; missing or empty shared mesh; refused
  layout; a job already in RUN.md (unless --again); t4 without ITERATION 0 1; a real file where a mesh link belongs.
  sbatch's stderr goes straight to the terminal. **status.sh** (36 lines, read-only).
- **scripts/make_run.sh** (PC, 120 lines): copies control.dat, observe.dat, station_map.csv, sets ITERATION 0 1 for
  t4, writes run.env, RUN.md and the INDEX.md line; refuses a used name, a used INDEX line, missing data, bad options.
- **runs/Run01** (v2 gate 100 ohm-m), **Run02** (v2 gate 3 ohm-m), both 3x24, 02:00:00, and **Run03** (v2 t4,
  ITERATION 0 1, 3x24, 12:00:00), all from mesh/vulcan_v2_rot/inversion, plus runs/INDEX.md.
- **hpc/phoenix_plan/RUNBOOK.md** (139 lines): S1-S5 setup, R1-R6 per run, F1 (Run01/Run02, with Run04/Run05 on v3
  as fall-back) and F2 (Run03, Run06 on v3), What if, What gets copied. Measured sizes: v2 255,727,272 + 56,660,718 B,
  v3 320,390,011 + 69,991,806 B (312 / 390 / 703 MB).
- **Archive:** RUNBOOK_first_inversion.md, UPLOAD_LIST_2026-09-28.txt, tests/runbook_check.sh, runbook_mutate.py and
  gen_upload_list.sh moved by plain mv into docs/dev/phoenix_runbook_2026-09-28/ with a README.md; each file's git
  hash-object equals its HEAD blob, so nothing in them changed. README_phoenix.md: "How to use this file" points to
  RUNBOOK.md; sections 0, 2 and 3 now describe kit/, shared/, runs/ and the version-5 steps.
- Read-only check on the real v2 mesh (awk only): run.sh's layout rule gives 3 x (31,322 + 43,147) = 223,407 MiB <=
  242,204 for 3x24, and refuses 4 ranks at 297,876 MiB.
- Git Bash bugs found and fixed in the scripts: Anaconda's cygpath (first on PATH) turned /d/BEN into
  C:\Users\joint\anaconda3\Library\d\BEN, so the scripts use `pwd -W`; a grep CR check inside `$(...)` flagged every LF
  file, so CRs are counted with tr; GNU tar read `C:/...` as host:path, so it runs with --force-local.

## Tests (PC only, fakes for sbatch, sacct, mpirun and femtic)
Each check states "fails if" and showed its failing case before the passing one.

| Test | Fails if | Failing case shown | Result |
|---|---|---|---|
| c1c2_test.sh (updated: d3 wants 5, d4 uses a version-4 library in KIT) | the library is not version 5, a version-4 library runs, or a C1/C2/f check fails | new test on the old kit (clone of 06d044f): 124 passed, 5 failed | 129 / 0 (old test, old kit: 129 / 0) |
| run_sh_test.sh R1-R6 (new) | run.sh reaches sbatch on a refusal case | each refusal: exit 1, message, 0 sbatch calls; control 2x36 accepted | in 86 / 0 |
| run_sh_test.sh P1-P5, S1 (new) | wrong sbatch strings, links, RUN.md/INDEX.md ids, banner not in the first 5 log lines, kit column, 05 chain | first run 2 failed (the fake femtic lacked FEMTIC's frequency header; the fake was fixed, not the kit) | 86 / 0; 11 mutants all killed |
| pc_scripts_test.sh K1-K3 (new) | make_phoenix_kit.sh exports a dirty tree, a tree without export-ignore or a CRLF file; or a wrong file list, byte, VERSION, stale file, missing WinSCP line, `md5` in the output | first run 43 / 21: the grep CR check flagged every LF file (a real bug, fixed with tr; K2b still catches a real CRLF file) | in 78 / 0 |
| pc_scripts_test.sh M1-M4, E1-E2 (new) | make_run.sh accepts a bad name, option, layout 9x9, missing station_map.csv or a used name; wrong files; the exported run.sh does not submit made and real runs | 66 / 1 before Run01-03 existed (E2) | 78 / 0; 4 mutants killed |
| runbook_walk_test.sh C1-C14 (new) | a RUNBOOK.md command, flag, size, grep pattern or path does not work on a fake Phoenix VF | 16 failing cases, each caught; C14's first version used compgen -G, which calls any path ending in `/` existing; replaced by `[ -e ]` and the mutants split | 30 cases / 0, 293 assertions; external mutants M1/M3/M4/M5 caught |
| halfspace_eval_test.sh (unchanged) | the evaluator differs from 7 stored reports or misses E0/E2/E3/E4 | its own E cases | 31 / 0 |
| portability_test.sh (scans every kit *.sh) | bash > 4.4 or gawk > 4.2 in the kit, Python > 3.6 in tools/ | none new (only the scope grew) | 6 / 0 over 15 shell files |
| bash -n, LF | a syntax error or a CR byte | - | 20 scripts clean; 0 CR bytes in every changed path |

c1c2_test first gave 128/1 after the README rewrite: its f4 anchors on README step 7's heading "Mesh: copy the gated
mesh"; the heading was restored, not the test. The archived runbook_check.sh gives 369 passed, 26 failed against the
version-5 kit (version gates, library from KIT, new defaults, md5 rows): expected; rerun it only at 06d044f.
**Rerun by this agent at 21:55 on the uncommitted tree** (each test in its own scratch WORK; the worktree's git status
was unchanged except for this agent's STATUS.md edit): c1c2 129/0, run_sh 86/0, pc_scripts 78/0, runbook_walk 30/0
(293 assertions), halfspace_eval 31/0, portability 6/0.

## Verdict tally (adversarial verifier)
- **Upheld 30, refuted 0. Ready for Ben: yes.** No claim was dropped.
- **Missed (8):**
  1. Students cannot run under their own accounts: BIN defaults to /hpcfs/users/$USER/femtic/bin (03, 04, 05, 06),
     so S1 fails for anyone but Ben, and run.sh documents no BIN override (STATUS D8).
  2. Student jobs email Ben: `#SBATCH --mail-user=ben.kay@adelaide.edu.au` in 03, 04, 06, not overridden (STATUS D9).
  3. Run01-03's RUN.md say "kit: 06d044f ... plus uncommitted changes ... commit them and re-export", while F1 tells
     students to use the folders as they are: re-make them after the commit (required, not optional).
  4. F2's figures do not match the job: "about 69 GB per rank (70,754 MiB)" is GiB labelled GB, and 04 in Run03's own
     folder prints 74,469 MiB on v2 (93,103 on v3), not 70,754 / 86,652.
  5. RUNBOOK.md's PC paths assume D:\BEN\FEMTIC_2026, which is on main at 06d044f without scripts/make_*.sh or runs/:
     the branch must be merged (or the steps run from the worktree).
  6. R5 copies results to hpc/phoenix_out/<today>/RunNN, so the PC's runs/RunNN/RUN.md never gets the job lines; the
     kit agent's "RUN.md travels both ways" does not hold. Job ids reach git only through R6, by hand.
  7. runbook_walk_test.sh exits 2 ("Filename too long") with a long WORK path (MAX_PATH on a validation/wsl_2026-09-25
     file in the clone); a short WORK gives 30/0.
  8. run.sh links mesh.dat and the start model before the layout check, so a refused layout (4x18 on v2, 297,876 MiB)
     leaves two harmless links in the run folder.
- **Out-of-remit edits seen (other sessions, not the kit or runbook agents):** docs/journal/2026-10-06_mesh_port_study.md
  and docs/dev/mesh_port_feasibility_2026-10-06.md, mesh_alternatives_2026-10-06/ (16 CRLF files under toys/; their
  toys ran tetgen.exe and gmsh on the PC, against the 09-28 rule), gui_conventions_from_mt_workbench.md.
- Lessons for the tests (Invariant 10): run_sh_test's first banner check missed a mutant of 06 without its banner,
  because the banner also appears in the report printed at the end; it now requires the banner in the first 5 log
  lines. runbook_walk_test's compgen -G existence test passed any path ending in `/`; each mutation now fails alone.

## Git state
- **Commit 06d044f** (bvkay, 2026-10-06 19:59 +0800, "Pickup 2026-09-28 to 10-06: ...", 97 files) was pushed earlier
  today; origin/main and origin/claude/femtic-work-9213a4 both contain it. It holds the version-4 kit, the 09-28
  runbook, the rotation and prep work and the B2 smoke evidence.
- **Uncommitted now (22:00):** modified .gitattributes, .gitignore, 01, 03, 04, 05, 06, femtic_lib.sh,
  README_phoenix.md, tests/c1c2_test.sh, tests/portability_test.sh and docs/STATUS.md; the five archived files show as
  deleted; untracked RUNBOOK.md, run.sh, status.sh, tests/{run_sh,pc_scripts,runbook_walk}_test.sh,
  scripts/make_phoenix_kit.sh, scripts/make_run.sh, runs/, docs/dev/phoenix_runbook_2026-09-28/ and this file. Also
  untracked, from other sessions: the docs/dev/ mesh studies, gui_conventions_from_mt_workbench.md and
  docs/journal/2026-10-06_mesh_port_study.md. make_phoenix_kit.sh refuses this tree, so export/kit does not exist yet.

## Re-making Run01-03 after the commit
From the repo root, with runs/ deleted first (make_run.sh refuses a used name or INDEX line):
```bash
bash scripts/make_run.sh Run01 --mesh v2 --data mesh/vulcan_v2_rot/inversion --job gate --start-rho 100 --layout 3x24 --time 02:00:00 --purpose "Half-space gate at 100 ohm-m on mesh v2, all 21 bands (STATUS D1: v2 only if Run01 and Run02 both pass)"
bash scripts/make_run.sh Run02 --mesh v2 --data mesh/vulcan_v2_rot/inversion --job gate --start-rho 3 --layout 3x24 --time 02:00:00 --purpose "Half-space gate at 3 ohm-m on mesh v2, all 21 bands (the high-frequency stress case; STATUS D1 with Run01)"
bash scripts/make_run.sh Run03 --mesh v2 --data mesh/vulcan_v2_rot/inversion --job t4 --layout 3x24 --time 12:00:00 --purpose "T4 on mesh v2: one inversion iteration, measures sensitivity-step memory, N_iv and time per iteration (submit after Run01 and Run02 pass)"
```
Checked in a scratch clone (this check fails if any copied file, run.env below its comment line, RUN.md apart from
its `made:` and `kit:` lines, or INDEX.md differs from the current runs/): the three lines reproduce all of them. The
failing case first: Run01 made with `--start-rho 10` differs in run.env and RUN.md.

## Open for Ben (details in docs/STATUS.md 2 and 3)
- Confirm the design: jobs read femtic_lib.sh from $VF/kit; student steps are kit once, make RunNN, WinSCP RunNN,
  `bash $VF/kit/run.sh RunNN`, `bash $VF/kit/status.sh RunNN`, WinSCP back.
- D8 (whose femtic/bin and $VF: shared project folder or a build per student) and D9 (mail-user) before handover.
- Copy-back excludes about 370 MB per gate run (mesh 256 + model 57 + fwd0_<id> about 56 MB). For a real inversion,
  say which resistivity_block_iterN.dat files to bring back: the R5 mask skips all models.
- KISS trade-offs accepted: the binding check, the CPU-efficiency check and the T4 memory band (0.8 Z to 1.2 Z) are
  gone from the student steps; F2 fails only on OUT_OF_MEMORY or `WARNING: measured N_iv`. Read Run01's output once
  yourself if the binding of the production layout matters.
- No NIV key in run.env; no INDEX.md sync between the PC and Phoenix; no test has run on Phoenix itself (bash 4.4,
  Python 3.6.8); prep_vulcan.py still writes the md5 sentence and the old runbook path into its mesh READMEs.
- Memory notes to update (agents could not): kit version 5 with the library read from KIT; RUNBOOK.md as the student
  entry point and the archive in docs/dev/phoenix_runbook_2026-09-28/; runbook_walk_test.sh as its PC check; the Git
  Bash pitfalls (cygpath, grep with CR, tar with C:/); the DEPLOYMENT MODEL paragraph's MANIFEST.md5/products.md5 text.

## Late evening: fix round for the 8 verifier misses, licences, decision D11
- One Opus agent closed K1-K7 (run.sh: layout rule before links, optional NIV and MAIL keys, BIN=$VF/bin default
  with the S1 'ln -s' line and the D8 note; no e-mail by default; RUNBOOK F2 quotes 74,469 / 93,103 MiB as 04 prints;
  R5/R6 copy RUN.md + logs back into runs/RunNN and commit; prep_vulcan.py README template points to RUNBOOK.md, md5
  sentence dropped, 5 generated READMEs hand-edited; README_phoenix section 6/9 fixed; runbook_walk_test uses
  core.longpaths; 16 toy logs CRLF->LF; new LICENSES.md). Tests after: c1c2 129/0, run_sh 129/0 (was 86), pc_scripts
  91/0 (was 78), runbook_walk 32/0, halfspace_eval 31/0, portability 6/0. Side effect: mesh/vulcan_v2_rot's
  prep_manifest.sha256 no longer matches its two edited READMEs (prep --force there will refuse; re-prep to a new --out).
- LICENSES.md: makeTetraMesh, makeMtr, TetGen2Femtic are MIT (c) 2021 Yoshiya Usui (read from the study's scratch
  clones); FEMTIC MIT; femticPy MIT (CSIRO); TetGen dual AGPL-3/commercial; Gmsh GPL-2+ (not adopted). makeDHexaMesh
  and mergeResultOfFEMTIC still unread. This repo has no licence file yet: Ben's choice.
- **D11 (Ben): "gate is good enough"** - the half-space gate on Phoenix is the acceptance test for any Python mesh
  toolchain; byte-identity is a developer test for the faithful ports only. Recorded in STATUS section 2.
- GitHub DNS failed for the fix agent (clones and WebFetch) although git push worked earlier today: intermittent.
