# 2026-10-07 - Mesh builds Local or Phoenix: GUI design s9 and P2's first slice

**Who/what:** Ben said "we can build the mesh on the local machine, so maybe the user has the option, depending on
their system resources on whether they run it local or on a hpc". A workflow on worktree claude/femtic-work-9213a4
(base 384968c, all uncommitted) ran a design agent, a P2 port agent and an independent verifier; this agent wrote
this entry and the STATUS.md lines (1.11, 3 item 8). Line numbers below were re-read on 2026-10-07. No femtic,
makeTetraMesh, makeMtr, TetGen2Femtic, mpirun or WSL ran on the PC. The conda-forge tetgen ran 18 times on this PC,
all on the 4,705-node chain_proof case (P2 12 calls, verifier 6; each 0.07-0.20 s); never on v2.

## Decision (D12, Ben 2026-10-07)
- Students may build meshes on their own machines if resources allow. The GUI gets "Build mesh: Local | Phoenix" with
  tool detection and a resource estimate; the earlier cut of the Build button (GUI finding G2) rested on Ben's PC only.
- FEMTIC and the half-space gate stay on Phoenix. D11: the gate is the acceptance test of any mesh, local or not.
- Consequence: a local mesh is a new mesh. conda-forge tetgen is not the chain's build (+2.0 % on chain_proof, below),
  so the gated mesh is the file uploaded to shared/, never "the same design" rebuilt on the other route.

## P2, first slice (code; docs/dev/mesh_port_progress.md "P2" from :401)
- **makeMtr port:** src/femtic_mesh/makemtr.py (270 lines) + io/makemtr_inputs.py (184); MIT notice
  src/femtic_mesh/LICENSE_makeMtr.txt (Usui, df8e207). CLI `python -m femtic_mesh.makemtr ROOT`.
- **Tool detection:** backends.py (281): per step a C++ binary (--bin, $BIN, $FEMTIC_BIN, then PATH, then conda
  prefixes), the conda-forge tetgen or a Python port; machine() (cores, RAM); estimate(); run_step() (exit, wall time,
  peak RSS on POSIX and Windows).
- **Doctor:** `python -m femtic_mesh.doctor [--bin DIR] [--tetgen EXE]` (doctor.py, 110). Exit 0 only with designer,
  tetgen, sizing and convert (doctor.py:63-65); else exit 2, `VERDICT: INCOMPLETE (exit 2): missing ...`, the Phoenix
  route (RUNBOOK F3) and, when only the designer is missing, the local `--from-poly` route (:67-74). On this PC: exit 2;
  sizing and convert resolve to the Python ports, makeTetraMesh is missing, tetgen only via --tetgen.
- **Chain driver:** `python -m femtic_mesh.chain RUN_DIR [--from-poly P] [--tetgen EXE] [--dry-run]` (chain.py 350,
  checks.py 264): mesh_chain.sh's steps, switches and checks, its intermediates/ and mesh_summary.txt lines. Without a
  designer it refuses ("designer missing: use Phoenix ... or wait for the Gmsh route"); --dry-run writes nothing.
- **Real run** (conda-forge tetgen 1.6.0, both ports, from MAIN chain_proof logs/output.poly.before_seed): DONE OK,
  4,798 nodes / 28,039 tets / 3,918 cells vs WSL 4,705 / 27,501 / 3,842 (+2.0 %; rounds up to 5.5 %), check_mesh
  17/17, 2.2 s, 49 MB. Round 0 byte-identical to P1's run. The verifier reproduced the same counts.
- environment-mesh.yml:21 adds `tetgen=1.6.0` (AGPL, run as a separate program; optional for the Python parts).

## Design (docs only, nothing removed: gui_design_2026-10-06.md s9 +248 lines from :471; feasibility s8.1 +40, :364)
- s9.1 Mesh tab: "New mesh design" (Save as, mesh.reuse_from null), a config_io row writer, previews, and prep's
  design_report with rules R1-R6 (site-triangle bound, domain in skin depths, air, growth, B/L). No tet-count predictor.
- s9.2 resource figures, checked against the WSL logs (design test V4, 9 of 9): v1 257.5 s / 584 MiB; v2 359.8 s
  (tetgen 319.5 s) / 956 MiB; v3 1,022.2 s / 1,211 MiB; about 3 GB written and 2 GB kept for a v2-class build.
- s9.3 RUNBOOK S6 (designed, not written): `mkdir $VF/shared/mesh_<name>` without -p, WinSCP two files, then two gate
  runs. Needs a kit change: make_run.sh:61 and run.sh:100 accept only v2 and v3.
- s9.5 milestones: M6 design editor + Phoenix route (no mesh tool needed), M7 Local, M8 Windows. s9.7 questions B1-B6.
- s8.1: under D11 (i) loses its fidelity edge (cost: per-OS binaries, Usui's licence); one designer serves both routes.

## Tests (each states "This test fails if ..." and showed its failing case first)
- P2: 10 tests (makeMtr vs the C++ logs, 66 and 863 lines bar two count lines; 12 hand values; an independent formula
  on 407,655 nodes + 44,000 points; 7 error paths; N5 at v2 size; chain vs mesh_chain.sh on fakes; failures; dry run
  and doctor; opt-in real tetgen). Suite 27 / 0 / 2 skip (163 s; verifier 183 s); FEMTIC_SKIP_V2=1 21 / 0 / 8.
- Design: V1 LF only, V2 additions only, V3 71 cited lines, V4 9 log figures, V5 17 paths: all pass.
- Caveat (verifier): the C++ makeMtr logs echo inputs and counts only, so log equality tests parsing, not sizes. The
  only C++-grounded size test is the study's B4/TD5 byte test, which waits for Run04's intermediates from Phoenix.

## Verdict (independent verifier): 34 upheld, 3 refuted, 9 missed; not ready for Ben
- **Refuted, all in gui_design s9, written before chain.py existed:** s9.0 and s9.2 describe a different driver and
  doctor than P2 built (the code's contract is the P2 section above). Replace before M7: :485 (driver "not in the repo
  yet"), :503 (the doctor "finds no tools" on Ben's PC), :569-583 and :619 (`chain --doctor`, exit 3, `DOCTOR:` line).
- **Design and code also disagree on** the output layout (s9.2 wants prep's inversion/ and mesh_logs/; chain.py writes
  mesh_chain.sh's run-folder root) and on counting the makeMtr port before its byte test. One reconciliation pass.
- **Prep-layout folders are not protected:** chain.py:39 checks only root mesh.dat, resistivity_block_iter0.dat,
  intermediates and mesh_summary.txt. A dry run on a copy of mesh/vulcan_v2 planned 12 steps (exit 0), so a real run
  would put an ungated mesh.dat beside the gated one; s9.6's "v1-v3 cannot be overwritten" does not hold yet.
- **No ITER_MAX check (study N3, feasibility:285-286):** a fake makeTetraMesh log with "Reach maximum interation number"
  ended `MESH CHAIN DONE: OK`; the driver only looks for "error".
- **No System32, WindowsApps or UNC refusal** in backends.find_binaries (backends.py:96): a WindowsApps fake tetgen
  on PATH was chosen as a binary (never run); a $BIN under `\\wsl$` would be probed and could start WSL.
- **The estimate says "local" on free RAM alone** (backends.py:216) at v2/v3 size, even when INCOMPLETE and with the
  conda-forge tetgen unmeasured there. v2 time: design 359.8 s (timev), doctor 348 s (timings.tsv sum); keep one.
- **Ben's PC:** an env built from environment-mesh.yml would hold tetgen, the doctor would then name only the designer
  missing and offer the local --from-poly route, which runs tetgen. Students work on Ben's PC (RUNBOOK.md:3-4) and
  nothing may run there (RUNBOOK.md:8). Extrapolated; no env was built.
- **Out of remit:** docs/dev/gui_screens_2026-10-07/ (7 PNGs, another session); cpython-311 __pycache__ in MAIN.

## For Ben
- **B1 first: student machines.** Local needs the repo, the 120 EDIs and the env on each student's machine; RUNBOOK
  assumes your PC. Without that plan phase 2 is M6 only, and M6 (design editor + Phoenix route) is useful on its own.
- **No full local build on Windows or macOS yet:** makeTetraMesh has Linux/WSL builds only, so there Local is the
  --from-poly route (re-sizing rounds, D3 cell changes). A full build needs per-OS binaries (Usui's licence terms, not
  in the repo) or Gmsh passing TD6 on a student-class Windows PC. If Gmsh wins, Phoenix needs a Python driver too.
- **No Local button at Vulcan size** until one v2-size conda-forge tetgen run has been timed on Phoenix or a student
  Linux machine; RAM is not the limit, wall time is unknown.
- **Kit:** new names `mesh_<name>` need make_run.sh:61 and run.sh:100 changed, a kit export and S6. Fable: merge the
  pyproject.toml and LICENSES.md lines in mesh_port_progress.md P2.7 (:565).
- **Advisor note:** about 1,460 lines of local driver came ahead of B1 and B3. Hold M7 until both are answered, and
  fix the four code gaps above (layout guard, N3, path refusal, estimate) before any GUI wiring.

## Not done
- No GUI code (Mesh tab, Check this PC, design_report, row writer, RUNBOOK S6, kit name change); T14-T22 specified only.
- No .mtr byte test (no C++ .mtr exists); FIX_OUTPUT1 not ported; makeMtr's sea and line paths untested; io/tetgen.py
  is 359 lines. Memory note vulcan-femtic-project.md not updated (suggested: "D12: students may build meshes locally").
