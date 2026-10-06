# Runbook: FEMTIC runs on Phoenix (Vulcan survey)

For students. You need a Phoenix account, WinSCP, and Git Bash on the PC that holds this repository
(`D:\BEN\FEMTIC_2026`, the main checkout: its PC paths assume branch claude/femtic-work-9213a4 is merged into main).
Every step is one command with one "Fails if" line. If a step fails: stop, keep the output and tell Ben. Never work
around a failure. The build, the memory model and the background are in `hpc/phoenix_plan/README_phoenix.md`. The
long 2026-09-28 runbook this one replaces is kept, with its reasoning, in `docs/dev/phoenix_runbook_2026-09-28/`.
**Rule: nothing runs on the PC or in WSL** (they process MT data). The PC makes small folders; Phoenix computes.

## How it fits together
* **PC**, Git Bash, from `cd /d/BEN/FEMTIC_2026`: `scripts/make_phoenix_kit.sh` makes the kit and
  `scripts/make_run.sh` makes one small run folder, `runs/RunNN`. Runs are Run01, Run02, ... and a name is never
  reused. Why a run exists is written in its `RUN.md` and in `runs/INDEX.md`.
* **WinSCP** moves folders. Set its transfer mode to **Binary**.
* **Phoenix**: log in to the login node (p2-log-2) and type `VF=/hpcfs/users/$USER/vulcan_femtic` at every login.
  Never run FEMTIC on the login node: `run.sh` submits it to the compute nodes. Everything lives under `$VF`:
```
$VF/bin               a link to the FEMTIC build every job uses (S1)
$VF/kit/              the kit: scripts, tools/ and VERSION (the git commit it was made from)
$VF/shared/mesh_v2/   mesh.dat and resistivity_block_iter0.dat, uploaded once (the same in mesh_v3/)
$VF/runs/Run01/       one folder per run: the job runs here and writes its output here
$VF/runs/INDEX.md     one line per run
```
* FEMTIC and the mesh tools are the build that `$VF/bin` links to (S1). Every job prints
  `KIT VERSION: <sha> (<date>)` near the top of its output: that line records which code ran. No other bookkeeping.

## Setup (once)
**S1. Phoenix: link a FEMTIC build as `$VF/bin`** (every job uses it; `BIN=<folder>` in front of a command overrides it).
Ben links his existing build. A student builds FEMTIC and the mesh tools once, under their own account, after S2 and
S3 (the kit holds `01_build_femtic.sh`): WinSCP the PC folder `D:\BEN\FEMTIC_2026\hpc\ported` into
`/hpcfs/users/<you>/FEMTIC_2026/hpc/`, then do README_phoenix.md section 3, steps 3, 4 and 5, with `PLAN=$VF/kit`
(sources and build on the login node, about 2 min; then the smoke-test job). Then, Ben and students alike:
`mkdir -p $VF/shared/mesh_v2 $VF/shared/mesh_v3 $VF/runs && ln -s /hpcfs/users/$USER/femtic/bin $VF/bin && ls $VF/bin/femtic`
Fails if: `ls` says "No such file" or "Permission denied" (a student: also if step 4 or 5 fails by its own criterion).

**S2. PC: make the kit.** `bash scripts/make_phoenix_kit.sh`
Fails if: it prints `REFUSED` (the kit is made only from committed code: Ben commits first).
It writes `export/kit` (about 0.2 MB, 13 files) and prints its sha.

**S3. WinSCP the kit, then check it on Phoenix.** Delete `$VF/kit` on Phoenix if it exists, then copy the PC folder
`D:\BEN\FEMTIC_2026\export\kit` into `$VF/`. Then: `cat $VF/kit/VERSION`. Repeat S2 and S3 whenever the kit changes.
Fails if: line 1 is not the sha that S2 printed. (Nothing gets installed into femtic/bin.)

**S4. WinSCP the two meshes (703 MB, once).** Copy `mesh.dat` and `resistivity_block_iter0.dat`
from `D:\BEN\FEMTIC_2026\mesh\vulcan_v2\inversion\` to `$VF/shared/mesh_v2/`, and
from `D:\BEN\FEMTIC_2026\mesh\vulcan_v3\inversion\` to `$VF/shared/mesh_v3/`. Then: `ls -l $VF/shared/mesh_v2 $VF/shared/mesh_v3`
Fails if: a size differs from v2 255,727,272 (mesh.dat) and 56,660,718 bytes, or v3 320,390,011 and 69,991,806 bytes.

**S5. Only if you uploaded the meshes before 2026-10-06** (to `$VF/inputs/vulcan_v2`, `vulcan_v3`): move them, then S4's `ls -l`:
```bash
mv -n $VF/inputs/vulcan_v2/mesh.dat $VF/inputs/vulcan_v2/resistivity_block_iter0.dat $VF/shared/mesh_v2/
mv -n $VF/inputs/vulcan_v3/mesh.dat $VF/inputs/vulcan_v3/resistivity_block_iter0.dat $VF/shared/mesh_v3/
```
Fails if: `mv` says "No such file". Files from the first upload list are in `$VF/inversion/v2` and `v3`: use those.

## Each run
**R1. PC: make the run folder.** `bash scripts/make_run.sh RunNN --mesh v2|v3 --data mesh/vulcan_v2_rot/inversion
--job gate|forward|t4|inversion --layout 3x24 --time HH:MM:SS --purpose "why this run"`, plus `--start-rho <ohm-m>`
for a gate, or `--iter-step N --iter-max N` for an inversion. Layouts: v2 `3x24`, v3 `2x36`. Examples below.
Optional: `--mail <your address>` (an email when each job ends; default: no email), `--niv 840` (only after F2 asks for it).
Fails if: it prints `REFUSED` (the message says what is wrong). It writes `runs/RunNN` and a line in `runs/INDEX.md`.

**R2. WinSCP the run folder** (about 0.5 MB): PC `D:\BEN\FEMTIC_2026\runs\RunNN` into `$VF/runs/`.
Fails if: `$VF/runs/RunNN/run.env` is not there afterwards.

**R3. Phoenix: submit.** `bash $VF/kit/run.sh RunNN`
Fails if: it prints `REFUSED`. Then nothing was submitted and no SU was spent; the message says what to fix.
On success it prints two lines: the job id, and the status command.

**R4. Phoenix: look.** `bash $VF/kit/status.sh RunNN` (any time: PENDING, RUNNING, then COMPLETED)
Fails if: after the job has ended, its `jobs:` line does not say `COMPLETED exit 0:0`.

**R5. WinSCP the results back.** Copy `$VF/runs/RunNN` onto the PC's `D:\BEN\FEMTIC_2026\runs\RunNN\` (overwrite) with
the WinSCP transfer setting "File mask": `| mesh.dat; resistivity_block_iter0.dat; fwd0_*/; *.vtk; Mesh.geo; *.iter*; BlockIDs; result.case`
It brings back RUN.md with its job lines, `logs/`, the job output `slurm-RunNN-<jobid>.out` (its KIT VERSION line
records the code that ran) and an inversion's models `resistivity_block_iter<N>.dat`, N >= 1 (57 MB each on v2; the
GUI's Results view opens them). It leaves out the shared mesh and model 0, FEMTIC's work folder (about 370 MB per gate
run) and its EnSight and VTK files. Fails if: `runs\RunNN\RUN.md` on the PC has no `job <id> submitted` line.

**R6. PC: record it.** In `runs/INDEX.md`, fill the run's line: job id(s) and verdict (PASS or FAIL, a few words).
Then commit the run: `git add runs/RunNN runs/INDEX.md && git commit -m "RunNN: PASS"` (or FAIL, a few words).
The models `resistivity_block_iter<N>.dat` stay on the PC for the GUI, never in git: .gitignore keeps them out.
Fails if: the line still has `-` in the job id or verdict column, or `git status runs` still lists changes.

## The first runs
Run01 to Run05 already exist in `runs/` (made 2026-10-06; Run01-03 from the rotated v2 data): skip R1 for them.

**F1. Run01 and Run02: is mesh v2 accurate enough?** Half-space gates on v2 at 100 and at 3 ohm-m: 3x24, 2 h, at
most 172.8 SU each; submit both. Each job solves one uniform model and compares it with the exact half-space at all
120 sites x 21 bands (5 % rho_a, 1.5 deg phase, 2 % diagonal). The data values in observe.dat do not matter here.
Fails if: status.sh does not show `GATE (half-space, START_RHO=100): PASS` for Run01 and `... START_RHO=3): PASS` for Run02.
Both PASS: v2 is the mesh. Either FAIL: v2 is out; make Run06 and Run07, the same gates on v3 (at most 345.6 SU each;
if v3 fails too, stop: the mesh needs work, tell Ben):
```bash
bash scripts/make_run.sh Run06 --mesh v3 --data mesh/vulcan_v2_rot/inversion --job gate --start-rho 100 --layout 2x36 --time 04:00:00 --purpose "Half-space gate at 100 ohm-m on mesh v3 (v2 failed Run01/Run02)"
bash scripts/make_run.sh Run07 --mesh v3 --data mesh/vulcan_v2_rot/inversion --job gate --start-rho 3 --layout 2x36 --time 04:00:00 --purpose "Half-space gate at 3 ohm-m on mesh v3 (v2 failed Run01/Run02)"
```

**F2. Run03: the memory test (T4).** One inversion iteration on v2 (3x24, 12 h, at most 1,036.8 SU), only after Run01
and Run02 both PASS: the sensitivity step has never run on a Vulcan mesh. If v3 is the mesh, make and submit Run08:
```bash
bash scripts/make_run.sh Run08 --mesh v3 --data mesh/vulcan_v2_rot/inversion --job t4 --layout 2x36 --time 12:00:00 --purpose "T4 on mesh v3: one inversion iteration, sensitivity-step memory and time"
```
After the job: `grep -E '^OUTCOME|^N_iv|^WARNING: measured N_iv|^predicted per rank|^peak summed RSS' $VF/runs/Run03/slurm-Run03-*.out`
On v2 the job plans for `predicted per rank (layout rule): 31322 forward + 43147 sensitivity-step = 74469 MiB`
(Run08 on v3: `39283 forward + 53820 sensitivity-step = 93103 MiB`). The `peak summed RSS` line is for Ben.
Fails if: status.sh does not show `COMPLETED exit 0:0` (`OUT_OF_MEMORY`: the memory model is wrong), or a `WARNING: measured N_iv` line appears.
A pass looks like: `COMPLETED exit 0:0`, an `N_iv` line saying `measured 480; the layout rule used 480`, no WARNING.
Send Ben the grep output in both cases: it sets the layout of the real inversion (and `--niv 840` if it measured 840).

**F3. Run04, then Run05 once Run04 shows OK: the meshes built on Phoenix** (Run05 takes about 10 min). Each run:
R2 (upload the folder), R3, R4; R5: add `; intermediates/` to the mask, then copy the folder again, unmasked, to
`D:\BEN\FEMTIC_2026\mesh\phoenix_<RunNN>\` (Run05 about 2 GB; what matters: mesh.dat and the last round's
`intermediates/output.6.{node,ele,face,neigh}`); R6. Fails if: status.sh has no `MESH CHAIN DONE: OK` line.
Then compare its `MESH COUNTS` line with WSL's (Run04 4,705 nodes, 27,501 tets; Run05 401,334 nodes, 2,446,095 tets)
and `md5sum $VF/runs/RunNN/mesh.dat` with RUN.md's WSL md5. A difference is not a failure (the study predicts it:
Phoenix's libm is not WSL's; Phoenix's mesh becomes the reference): write it in R6's verdict, tell Ben, go on to Run05.

## What if
* **`run.sh: REFUSED: ...`** Nothing was submitted. Typical messages: `no FEMTIC at` (do S1); `shared mesh file ...
  is missing or empty` (do S4); `run.env has no TIME` (the run folder is broken: make a new one with R1);
  `already has job(s)` (look with status.sh; resubmit with `bash $VF/kit/run.sh RunNN --again` only if Ben says
  so); `layout rule` (too many ranks per node for the memory: use the layouts above).
* **The job's exit code** (status.sh, `exit N:0`):

| exit | gate or forward run (06_forward_only) | t4 or inversion run (04_inversion) |
|---|---|---|
| 0 | passed | passed: reached the iteration end, converged, or stopped after a new model |
| 1 | T6 (the forward solve) failed, or the job stopped before FEMTIC (layout refused, a file missing) | the job stopped before FEMTIC, or FEMTIC failed (also any other code) |
| 2 | - | STALLED: FEMTIC reached its maximum number of retrials |
| 3 | - | stopped before any new model: one iteration takes longer than `--time` |
| 4 | T6 passed but the half-space gate FAILED (or could not be evaluated) | - |

* **`Failed to modify UD QP to INIT on mlx5_0: Operation not permitted`** (up to 4 per rank at the start): harmless.
* **The job sits in PD (pending).** `squeue -u $USER` shows the reason. `Priority` or `Resources`: it is waiting
  for a whole free node, which took about 22 h at the 2026-09-25 survey; just wait. `QOSMaxCpuPerNode`: it asks for
  more cpus per node than the partition allows. Cancel it with `scancel <jobid>` and make a new run folder whose
  layout uses at most 72 cpus (ranks x threads).
* **`bad interpreter: ^M`** or `$'\r': command not found`: a file was copied in text mode. Set WinSCP to Binary and copy it again.
* **Where to ask:** Ben first (ben.kay@adelaide.edu.au), with the run name, the job id and the status.sh output.
  Phoenix accounts, quota or queue problems: the university's Phoenix HPC support (see the Phoenix wiki).

## What gets copied
| What | From | To | When | Size |
|---|---|---|---|---|
| kit | PC `export\kit` | `$VF/kit` (replace the folder) | once, and again when it changes | about 0.2 MB |
| mesh v2 | PC `mesh\vulcan_v2\inversion\`: mesh.dat, resistivity_block_iter0.dat | `$VF/shared/mesh_v2/` | once | 312 MB |
| mesh v3 | PC `mesh\vulcan_v3\inversion\`: the same two files | `$VF/shared/mesh_v3/` | once | 390 MB |
| run folder | PC `runs\RunNN` | `$VF/runs/` | per run | about 0.5 MB |
| results | `$VF/runs/RunNN`, with the R5 file mask | PC `runs\RunNN\` (overwrite; then R6 commits it) | per run | about 1 MB (gate); 57 MB per model (v2) |
