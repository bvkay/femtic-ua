# Runbook: first FEMTIC inversion on Phoenix (STATUS B1-B6)

Written 2026-09-28 for `docs/STATUS.md` section 3, items B1-B6, and revised twice the same evening after its reviews
and the kit follow-ups. STATUS item A1 (v2 at 100 ohm-m) moved from WSL to Phoenix and is step B4a here. The commands
match the kit as it is on 2026-09-28: `femtic_lib.sh` version 4 (every script that sources it needs 4), 06 with
`START_RHO` and a 4 h header walltime, the layout rule in 04 and 06, and the `LAYOUT` file that a passing 06 writes
for 05. The third revision added the Phoenix folders (immutable inputs, one work directory per job) and the rotated
v2 data. Background: `README_phoenix.md` sections 3, 6 and 10. `tests/runbook_check.sh` checks this file against
the kit (PC only).

**Rule (Ben, 2026-09-28): nothing runs on the Windows PC or in WSL.** MT processing runs there. So no FEMTIC,
mesh tool or MPI job. The PC only moves files (WinSCP) and writes one md5 list (B1.1). Everything else runs on Phoenix.

## 0. Conventions

Log in to **p2-log-2**. Paste this block at every login. These are plain shell variables, not exported, so jobs
never inherit them:
```bash
P=/hpcfs/users/a1690074/FEMTIC_2026
PLAN=$P/hpc/phoenix_plan
BIN=/hpcfs/users/a1690074/femtic/bin
VF=/hpcfs/users/a1690074/vulcan_femtic
IN=$VF/inputs
WK=$VF/work
LEDGER=$VF/jobs_ledger.txt
mkdir -p $IN $WK $P/export
```
* **Fails if** comes first in every step. Read it before you run the step. A failure is a finding: stop, keep
  the evidence and tell Ben/Fable. Never loosen a criterion to get a PASS.
* **Folders.** `$IN/vulcan_v2` and `$IN/vulcan_v3` hold the uploaded inputs (B3) and are never written afterwards:
  no job runs there. Every job runs in a work directory `$WK/<mesh>/<name>`: `gate100` and `gate3` (B4a), `t4`
  (B5), later `inv01`. A work directory gets its own copy of control.dat, because 04 edits that copy in place
  (`femtic_ctl_set`, `sed -i`) and 06 copies it into `fwd0_<jobid>/`, where it edits only that copy (06:137); the
  other inputs are relative links. From inside `$WK/<mesh>/<name>`:
  `cp ../../../inputs/vulcan_<mesh>/control.dat .` and, for each of mesh.dat, observe.dat,
  resistivity_block_iter0.dat and station_map.csv, `ln -sfn ../../../inputs/vulcan_<mesh>/$f $f`. 06 links its
  `fwd0_<jobid>/` to these links by absolute path (06:138, 06:156) and 04 reads them in place; both resolve the
  chain (`tests/runbook_check.sh` K1.2 runs 06's link lines and 04's input checks on it).
* **Checks end in PASS or FAIL.** Where a step gives an awk check, the last word of its line decides.
* **Evidence and copy-back.** Each step copies its files into `$P/export/<step>[_<jobid>]/`. On the PC, all raw
  Phoenix output goes into the inbox `D:\BEN\FEMTIC_2026\hpc\phoenix_out\<run date>\` (e.g. `phoenix_out\2026-09-29`):
  `$P/export/` and `$LEDGER` (WinSCP), and any job `.out`, build or smoke log or run directory you copy. git ignores
  that inbox, and raw dumps left directly in `hpc\` (`smoke_*`, `slurm-*.out`, `build_*.log`), so raw output cannot
  be committed by accident (`.gitignore`). The next PC session files the text evidence into
  `validation\phoenix_<run date>\` with a `MANIFEST.md5` (md5, size and path of every raw file, including those left
  in the inbox), as in `validation\phoenix_2026-09-28\`.
* **Journal.** Fill in the step's note (templates below) and append it to `docs/journal/<run date>_phoenix.md`.
  Ben's session rewrites STATUS.md; you do not.
* **Job ids.** Each `sbatch` below stores the id in a variable (`--parsable`, or `awk '{print $NF}'` in the N_iv 840
  rerun) and appends it to `$LEDGER`. After a new login, get the ids back with `cat $LEDGER` or
  `sacct -X -u a1690074 -S 2026-09-28 --format=JobID,JobName%15,State,Elapsed`.
* **One 06 job per directory.** 06 writes `logs/fwd_rank_mb`, `LAYOUT` and `job_outcomes.tsv` in the directory
  it is submitted from, so two jobs there overwrite each other's files. B4a gives every gate job its own directory.
* **Watch and cancel.** `squeue -u a1690074` lists your jobs; `scancel <jobid>` cancels one. 04 and 06 mail
  ben.kay@adelaide.edu.au at END and FAIL.
* **Billing.** Jobs run before 10-01 bill to Q3, where about 75 % of physci's grant is unused. At discovery the
  wait for a full icelake node was about 22 h.

| Step | What | Where | Wall (expected) | SU (at most) | After |
|---|---|---|---|---|---|
| B1 | upload kit, self-tests, install the version-4 library (rebuild optional) | login node | about 10 min | 0 | - |
| B2 | SMOKE_ONLY: tests T1, T2, T5. **Passed 2026-09-28** (job 16153670); repeat only after a rebuild changes `$BIN/femtic` | icelake, 4 cpus | minutes | 2.4 | B1 |
| B3 | upload v2 and v3 inputs and the rotated v2 data, md5 check | WinSCP, login node | 704 MB transfer | 0 | - (during B1/B2) |
| B4a | half-space gate on v2 at 100 (and 3) ohm-m, 3 x 24, decides D1 | icelake, 1 node per job | 0.3-1 h per job | 172.8 per job | B1, B3 (B2 passed) |
| B4a-v3 | only if v2 is out: gate on v3, 2 x 36 | icelake, 1 node per job | 0.5-2.3 h per job | 345.6 per job | B4a |
| B4b | forward time and memory from B4a; B5 layout preview | login node | - | 0 | B4a |
| B5 | T4: 04_inversion with ITERATION 0 1 | icelake, 1 node | 1.5-5 h (unmeasured) | 1,036.8 | D1, B4b |
| B6 | Q4 SU grant, queue check | login node | - | 0 | after 10-01 |

**Where the time estimates come from:**
* The WSL runs (1 rank x 8 threads) took 139-418 s per frequency on v2 and 164-755 s on v3
  (`D:/BEN/FEMTIC_2026/mesh/vulcan_v*/halfspace/*/b*/femtic_0.log`).
* The estimates assume no speed-up from the extra threads.
* SU = 72 cpus x hours x 1.2. "At most" means the job ran to its full `--time`.
* Whether Phoenix bills elapsed or requested time is still open (README section 10, item 2).

**Order:** B1 -> B4a -> D1 -> B4b -> B5 is the critical path. B2 passed on 2026-09-28 and comes back into it
(B1 -> B2 -> B4a) only if a rebuild in B1.5 changes `$BIN/femtic`. B3 can run any time before B4a.
B6 comes after 10-01.

## B1. Refresh the kit on Phoenix

**Fails if:**
* any line of `md5sum -c` is not `OK`, or a file of this upload has a CR byte;
* `tests/c1c2_test.sh` or `tests/portability_test.sh` reports a failed check, or the portability output has no
  `PASS R1 python 3.6.8 RESULT (PASS)` line;
* after the `install` line of B1.5, `$BIN/femtic_lib.sh` is not version 4 or not byte-identical to `$PLAN/femtic_lib.sh`;
* only if you run the optional rebuild of B1.5: `01_build_femtic.sh` exits non-zero, or its build log does not hold
  exactly one `BUILD DONE  T1=PASS` line. That line is never the final one: three `next:` hint lines follow it, so the
  grep below counts it wherever it is. A rebuild that changes the md5 of `$BIN/femtic` is not a B1 failure, but then
  B2 must run again before B4a.

**Why.** Phoenix holds the committed kit 55bbf44, installed by Ben's login-node rebuild on 2026-09-28 21:10-21:11:
`$BIN/femtic_lib.sh` version 2 (19,992 B), `$BIN/femtic_env.sh` 732 B with the `/apps` remap, and femtic 26c8606
(`validation/phoenix_2026-09-28/README.md`). Every current script that sources the library (01 `SMOKE_ONLY`, 03, 04,
05 and 06) refuses one older than version 4. So B1 uploads the version-4 kit and installs its library; the 09-28
binaries and `femtic_env.sh` stay.

**B1.1 PC, Git Bash (light).** Write md5 sums of the files you will upload, from the files as they are now. This
manifest is the one B1.3 checks; the md5 column of `UPLOAD_LIST_2026-09-28.txt` only dates the list. The kit
changes are uncommitted in the worktree. If the worktree has been merged, run the same line from
`/d/BEN/FEMTIC_2026` instead.
```bash
cd /d/BEN/FEMTIC_2026/.claude/worktrees/femtic-work-9213a4
md5sum hpc/phoenix_plan/femtic_lib.sh hpc/phoenix_plan/01_build_femtic.sh hpc/phoenix_plan/06_forward_only.slurm hpc/phoenix_plan/04_inversion.slurm hpc/phoenix_plan/05_chain.sh hpc/phoenix_plan/03_mesh.slurm hpc/phoenix_plan/tools/halfspace_eval.py hpc/phoenix_plan/tests/c1c2_test.sh hpc/phoenix_plan/tests/portability_test.sh hpc/phoenix_plan/tests/halfspace_eval_test.sh hpc/phoenix_plan/tests/runbook_check.sh hpc/phoenix_plan/tests/runbook_mutate.py hpc/phoenix_plan/tests/gen_upload_list.sh hpc/phoenix_plan/README_phoenix.md hpc/phoenix_plan/RUNBOOK_first_inversion.md hpc/phoenix_plan/UPLOAD_LIST_2026-09-28.txt > hpc/phoenix_plan/UPLOAD_2026-09-28.md5
```

**B1.2 WinSCP.**
* Set the transfer settings to **Binary**.
* Upload part A of `UPLOAD_LIST_2026-09-28.txt` (17 files: the 16 above and the md5 list) to
  `/hpcfs/users/a1690074/FEMTIC_2026/hpc/phoenix_plan/`.
* Keep the `tools/` and `tests/` subfolders, and overwrite the old copies. Do not upload `tools/__pycache__/`.
* `tests/runbook_check.sh`, `runbook_mutate.py` and `gen_upload_list.sh` go up only so that the kit copy is
  complete. They read the PC's inputs and WSL logs: do not run them on Phoenix.

**B1.3 p2-log-2: check the transfer.** The CR count reads its file list from the manifest, so it covers exactly
the files of this upload. (Git Bash's md5sum writes `<md5> *<file>`; the awk drops the `*`, and `md5sum -c` reads
either form.)
```bash
mkdir -p $P/export/B1 && cd $P
md5sum -c hpc/phoenix_plan/UPLOAD_2026-09-28.md5 | tee $P/export/B1/md5_check.txt
grep -c $'\r' $(awk '{f = $2; sub(/^[*]/, "", f); print f}' hpc/phoenix_plan/UPLOAD_2026-09-28.md5) | tee $P/export/B1/cr_check.txt
```
PASS: 16 lines ending in `: OK`, and 16 lines `<file>:0`.
If a file FAILS its md5:
1. Run `dos2unix <file>`. If `dos2unix` is not found, run `sed -i 's/\r$//' <file>`.
2. Check again.
3. If it still FAILS, upload it again.

**B1.4 p2-log-2: kit self-tests, before the install.** They run against the installed version-2 library (55bbf44's)
and use a fake femtic, mpirun and Slurm, so nothing heavy runs. The second test needs a Python >= 3.8 for its static checker (the
module) and runs the gate evaluator under the system Python 3.6.8 as well, which is what 06 uses on the compute nodes.
```bash
grep '^FEMTIC_LIB_VERSION=' $BIN/femtic_lib.sh    # expect =2 (55bbf44's copy, 19,992 B, installed 2026-09-28); any other value: leave out STALE_LIB=... below
T=$(date +%Y%m%d_%H%M%S); mkdir -p /hpcfs/users/a1690074/tmp
WORK=/hpcfs/users/a1690074/tmp/c1c2_$T STALE_LIB=$BIN/femtic_lib.sh bash $PLAN/tests/c1c2_test.sh $PLAN > $P/export/B1/c1c2_test_$T.txt 2>&1; echo "exit=$?"
tail -1 $P/export/B1/c1c2_test_$T.txt
( module load Python/3.13.5-GCCcore-14.3.0 && WORK=/hpcfs/users/a1690074/tmp/port_$T PYTHON=python3 PYTHON_OLD=/usr/bin/python3 bash $PLAN/tests/portability_test.sh $PLAN ) > $P/export/B1/portability_test_$T.txt 2>&1; echo "exit=$?"
grep -E '^SUMMARY|^  (PASS|FAIL) R1 python' $P/export/B1/portability_test_$T.txt
command -v python3.6 || echo "no python3.6 on PATH"
```
PASS:
* c1c2: `exit=0` and `SUMMARY: 128 passed, 0 failed   (PLAN=...)`. On the PC the same test runs 129 checks: its
  f1 also reads a real FEMTIC log from WSL, and on Phoenix it prints `(f1 real-log case skipped: ...)` instead.
* portability: `exit=0`, `SUMMARY: 10 passed, 0 failed`, and among the R1 lines `PASS R1 python 3.6.8 RESULT (PASS)`.
  The test runs its 4 R1 checks once per interpreter: the module's python3 and `PYTHON_OLD`, plus python3.6 if
  `command -v python3.6` printed a path. Then it is `SUMMARY: 14 passed, 0 failed` and each 3.6.8 line shows twice.
  If `module load` fails, take any Python >= 3.8 from `module avail Python`.
* These are the first runs under Phoenix's bash 4.4, gawk 4.2 and Python 3.6.8; the PC has bash 5.2 and Python 3.9/3.13.
* On any FAIL, put the output of `grep -B3 '  FAIL' <file>` in the journal. Do not start B4a until Fable has
  read it. B1.5 may go ahead.

**B1.5 p2-log-2: install the version-4 library (required); the rebuild is optional.** The 09-28 rebuild already
wrote the 732 B `femtic_env.sh` with the `/apps` remap, and the version-4 01 builds the same sources the same way (it
differs from 55bbf44's only in its version gate and `next:` hint). So a rebuild adds nothing now. The one required
action is the `install` block below: it puts the version-4 library next to the 09-28 binaries, which is enough on
icelake (it has `/apps`).

*Optional rebuild* (skip it unless you have a reason; about 2 minutes, 74 s on 2026-09-25). If you run it, run it
before the `install` block, then run that block as well. It installs `femtic_lib.sh` (01:414) and writes a new
`femtic_env.sh`. The first and last `md5sum` lines record `$BIN/femtic` and `$BIN/femtic_env.sh` before and after.
```bash
md5sum $BIN/femtic $BIN/femtic_env.sh | tee $P/export/B1/bin_md5_before_rebuild.txt
cp $BIN/femtic_env.sh $P/export/B1/femtic_env.sh.before_rebuild
cd $PLAN && TOOLCHAIN=foss PORTED=$P/hpc/ported bash -l 01_build_femtic.sh; echo "exit=$?"
BL=$(ls -t /hpcfs/users/a1690074/femtic_src/build_foss_*.log | head -1); echo "$BL"
grep -cE '^== .*  BUILD DONE  T1=PASS  ' "$BL"
diff $P/export/B1/femtic_env.sh.before_rebuild $BIN/femtic_env.sh
F0=$(head -1 $P/export/B1/bin_md5_before_rebuild.txt | cut -d' ' -f1)
[ "$(md5sum < $BIN/femtic | cut -d' ' -f1)" = "$F0" ] && echo "femtic unchanged: B2 stands" || echo "femtic CHANGED: repeat B2"
md5sum $BIN/femtic $BIN/femtic_env.sh | tee $P/export/B1/bin_md5_after_rebuild.txt
cp "$BL" $P/export/B1/
```
PASS looks like this, after the build output:
```
exit=0
/hpcfs/users/a1690074/femtic_src/build_foss_<stamp>.log
1
1c1
< # generated by 01_build_femtic.sh on <the 09-28 date> -- TOOLCHAIN=foss
---
> # generated by 01_build_femtic.sh on <today> -- TOOLCHAIN=foss
femtic unchanged: B2 stands
```
The counted line reads `== <date>  BUILD DONE  T1=PASS  T2=SKIPPED  T5=SKIPPED   log: <build log>` (T2 and T5
run only inside a Slurm job, B2). On the 09-25 log (`build_foss_20260925_181212.log`) the same grep gives 1.
The first line of `femtic_env.sh` holds the build date, so its md5 always changes; the `diff` must show that line
only. `femtic CHANGED: repeat B2` is not a failure of B1, but B2 must then run again before B4a. If the build fails
and the md5 of `$BIN/femtic` is unchanged, the 09-28 binaries are intact: run the `install` block and record that
the build failed.

*Required: install and check the library.*
```bash
install -m 644 $PLAN/femtic_lib.sh $BIN/
grep '^FEMTIC_LIB_VERSION=' $BIN/femtic_lib.sh
cmp $PLAN/femtic_lib.sh $BIN/femtic_lib.sh && echo "installed lib identical"
grep -c femtic_apps_remap $BIN/femtic_env.sh
md5sum $BIN/femtic $BIN/femtic_env.sh | tee $P/export/B1/bin_md5.txt
ls -l $BIN/femtic $BIN/femtic_env.sh $BIN/femtic_lib.sh
```
PASS looks like this, followed by the two md5 lines and the `ls -l` lines:
```
FEMTIC_LIB_VERSION=4
installed lib identical
1
```
The md5 of `$BIN/femtic` is the record that B2's carry-over rests on: it must stay the binary of the 09-28 smoke
job (1,494,008 B; its md5 was not recorded on 09-28, so this is the first one).

Journal: `B1 <date> p2-log-2: kit uploaded, md5 16/16 OK, CR 0 in 16 files; c1c2_test on Phoenix <n>/128 (exit <e>);
portability_test <n> passed, <f> failed (python3.6 on PATH: <yes/no>), R1 under python 3.6.8 <PASS/FAIL>; install
done, $BIN/femtic_lib.sh version 4, identical to $PLAN; femtic_env.sh has the remap; femtic md5 <md5>; rebuild
<skipped | build log <file>: BUILD DONE T1=PASS, exit 0, femtic unchanged / CHANGED (B2 repeated)>.`

## B2. SMOKE_ONLY on icelake: the first FEMTIC run on a compute node

**Status: PASSED on 2026-09-28, all three criteria (criterion 2 confirmed 2026-09-30).** Job 16153670 (icelake p2-cpu-14,
committed kit 55bbf44, library version 2) printed `SMOKE_ONLY DONE  T1=PASS  T2=PASS  T5=PASS` (criterion 1), and
its iteration-0 row has Misfit `5.752642e+03` and RMS `2.234639e+00`, 7 of 7 digits equal to WSL (criterion 3;
`validation/phoenix_2026-09-28/README.md`). Criterion 2: sacct State COMPLETED, ExitCode `0:0`, Elapsed 48 s,
TotalCPU 2:31.8 (79 % of 4 cores), max RSS 829 MB (`validation/phoenix_2026-09-28/sacct_16153670.txt`,
`rcstat_16153670.txt`). The lines below are what produced them; keep them for any repeat of B2.
```bash
mkdir -p $P/export/B2_16153670
sacct -j 16153670 --format=JobID,State,ExitCode,Elapsed,TotalCPU,NodeList | tee $P/export/B2_16153670/sacct.txt
rcstat 16153670 | tee $P/export/B2_16153670/rcstat.txt
```
**Do not repeat B2 while `$BIN/femtic` is unchanged**, that is, if you skipped the B1.5 rebuild or it printed
`femtic unchanged: B2 stands`. The result carries over to the version-4 kit: on the SMOKE_ONLY path version 4 changes
only 01's version gate and `next:` hint, the library functions that path calls are byte-identical, and 06 sources the
version-4 library first thing in B4a (`validation/phoenix_2026-09-28/README.md` section 7). The blocks below stay for
a repeat after any rebuild that changes the binary.

**Fails if:**
* `grep -cE '^== .*  SMOKE_ONLY DONE  T1=PASS  T2=PASS  T5=(PASS|INCONCLUSIVE)   log: '` on the job's output
  does not print `1` (T5=INCONCLUSIVE is acceptable, README section 10; `next:` lines follow the DONE line);
* the `sacct` ExitCode is not `0:0` (01 exits 3 when a test failed, 1 on ERROR);
* the Misfit and RMS of the iteration-0 row differ from the WSL run in the first 6 significant digits. That run
  used the same example and toolchain versions and gave `5.752642e+03` and `2.234639e+00`
  (`validation/wsl_2026-09-25/build_logs/s6_foss2023a.log:34`).
```bash
cd $P
JS=$(sbatch --parsable -p icelake -N 1 -n 4 --mem=8G --time=00:30:00 -J femtic_smoke -o slurm-%x-%j.out --wrap 'TOOLCHAIN=foss SMOKE_ONLY=1 bash -l hpc/phoenix_plan/01_build_femtic.sh')
echo "$JS B2 femtic_smoke $(date +%F_%T)" | tee -a $LEDGER
```
The job costs at most 2.4 SU. After it ends:
```bash
cd $P
sacct -j $JS --format=JobID,State,ExitCode,Elapsed,NodeList
grep -cE '^== .*  SMOKE_ONLY DONE  T1=PASS  T2=PASS  T5=(PASS|INCONCLUSIVE)   log: ' slurm-femtic_smoke-$JS.out
grep -E 'T1 \(linkage\)|relative misfit|INCONCLUSIVE|T2 \(smoke run\)|SMOKE_ONLY DONE' slurm-femtic_smoke-$JS.out
grep -A1 'iteration-0 row' slurm-femtic_smoke-$JS.out
rcstat $JS
```
PASS looks like this (after the sacct rows, which show `COMPLETED` and `0:0`):
```
1
T1 (linkage): PASS
   relative misfit difference <x> (tolerance 1e-4)
   relative misfit difference <x> (tolerance 1e-3)
T2 (smoke run): PASS    T5 (restart equivalence): PASS    work dir: /hpcfs/users/a1690074/femtic_src/smoke_foss_<stamp>
== <date>  SMOKE_ONLY DONE  T1=PASS  T2=PASS  T5=PASS   log: /hpcfs/users/a1690074/femtic_src/smoke_foss_<stamp>.log
-- iteration-0 row (compare with the WSL build of the same example; expect >= 6 equal significant digits):
            0         0   1.000000e+00   5.000000e-01   0.000000e+00   5.752642e+03   2.234639e+00   5.752642e+03
```
The columns of that row are Iter#, Retrial#, Alpha, Damp, Roughness, Misfit, RMS and ObjFunc. For
information, WSL iterations 1 and 2 had Misfit `2.331502e+03` and `1.309987e+03`.

**Known harmless output.** `Failed to modify UD QP to INIT on mlx5_0: Operation not permitted`, prefixed
`<node>:rank<N>.femtic:`, appears in FEMTIC's stdout up to 4 times per rank at start on icelake (job 16153670: 4 per
rank in the straight run and in leg 2, none in leg 1). Expect it in 04 and 06 runs too (06 writes FEMTIC's stdout to
`fwd0_<jobid>/stdout.txt`). It is harmless on one node. Before any multi-node run, investigate the MPI transport
(OpenMPI's MCA btl/pml selection or the UCX settings). No setting has been tested, so the kit sets none.

Copy back (the `sacct` and `rcstat` lines keep criterion 2 and the billing on record):
```bash
S=$(ls -td /hpcfs/users/a1690074/femtic_src/smoke_foss_*/ | head -1); S=${S%/}
mkdir -p $P/export/B2_$JS
cp $P/slurm-femtic_smoke-$JS.out $S.log $S/straight/femtic.cnv.straight $S/straight/femtic_0.log.straight $S/restart/femtic.cnv.leg1 $S/restart/femtic.cnv.leg2 $P/export/B2_$JS/
sacct -j $JS --format=JobID,State,ExitCode,Elapsed,TotalCPU,NodeList > $P/export/B2_$JS/sacct.txt
rcstat $JS > $P/export/B2_$JS/rcstat.txt 2>&1
```
Journal: `B2 <date> job <JS> (icelake <node>), repeat after the rebuild <build log>: SMOKE_ONLY DONE T1=<> T2=<> T5=<>;
row 0 Misfit <> RMS <> (WSL 5.752642e+03 / 2.234639e+00); sacct <State> <ExitCode>, Elapsed <>, rcstat <> SU.`

**Submit B4a after reading B2's output.** Do not chain the B4a jobs to B2 with a Slurm dependency (`afterok`).
Slurm sees only B2's exit code, and 01 does not enforce the third criterion above: it prints the iteration-0 row
but compares nothing with the WSL Misfit and RMS, so a build that fails that criterion still exits 0.

## B3. Upload the v2 and v3 inversion inputs and the rotated v2 data

**Fails if:** any `md5sum -c` line of B3.4 is not `OK`, a byte count differs from parts B-D of
`UPLOAD_LIST_2026-09-28.txt`, a mesh/model header line differs from the PASS lines below, or the sha256 of
`$IN/vulcan_v2/observe.dat` does not start with `d501abcf5a7dde5f`.

* **Upload both meshes now.** Then a v2 gate failure costs no extra upload day.
* **The start model is 20 ohm-m.** `resistivity_block_iter0.dat` has every free block at 2.000000e+01
  (65,341 blocks on v2, 68,654 on v3), plus 1 air block.
* **There is no 100 ohm-m file to upload.** 06 with `START_RHO=100` writes the uniform model into
  `fwd0_<jobid>/` on Phoenix.
* **Do not run `03_mesh.slurm`.** It is a different mesh chain that was never gated.
* **v2's data is the rotated observe.dat** (STATUS D2: the sensors were aligned to geomagnetic north, and prep
  rotates Z by 7.42 deg into the mesh's grid frame): `mesh/vulcan_v2_rot/inversion/observe.dat` of the worktree
  (sha256 d501abcf5a7dde5f..., md5 6f1e579e...) and its `station_map.csv` (one more column, `rot_deg`). They
  replace the unrotated pair, which stays in the folder as `observe_unrotated.dat` and `station_map_unrotated.csv`.
  The gates, T4 and inv01 all use the rotated file. The rotation changes data values only: both files have the
  same lines, sites, bands and error columns (`tests/runbook_check.sh` K3.6), so memory, time and the half-space
  gate (which takes only its (site, band) list from observe.dat) are the same with either.
* **v3 takes the same rotated pair.** The unrotated observe.dat and station_map.csv of v2 and v3 are byte-identical
  (the same md5 in B3.4), so part D serves v3 too and no v3 prep is needed. The v3 gates (B4a) may use the unrotated
  file, as B3.4 checks it. If D1 picks v3, run B3.2 and B3.3 again with `vulcan_v3` in place of `vulcan_v2` (after
  D1, before B5). B3.4's v3 lines then expect the rotated pair, as for v2: `6f1e579e818bc9bafa64bc4c091f3ba4` for
  observe.dat and `eecf20d99a12b777faf138027a267f95` for station_map.csv, plus the unrotated md5s under the new names
  observe_unrotated.dat and station_map_unrotated.csv (use the v2 here-document for v3; then 7 `: OK` lines for v3).

**B3.0 p2-log-2, only if you uploaded to the round-2 folders** `$VF/inversion/v2` and `$VF/inversion/v3` (the
previous version of this runbook): move them to the input folders. Each `mv` runs only if the old folder exists
and the new one does not, so the block is safe to run twice and does nothing if you never used those folders.
```bash
for m in v2 v3; do
  if [ -d $VF/inversion/$m ] && [ ! -e $IN/vulcan_$m ]; then mv $VF/inversion/$m $IN/vulcan_$m && echo "moved $VF/inversion/$m to $IN/vulcan_$m"
  elif [ -d $VF/inversion/$m ]; then echo "NOT moved: $IN/vulcan_$m exists already; compare the two folders by hand and tell Ben/Fable"
  fi
done
```
PASS: a `moved` line for each folder you had uploaded there (none if you had not), and no `NOT moved` line.

**B3.1 WinSCP** (transfer settings **Binary**). If you already uploaded these into `inputs/vulcan_v2` and
`inputs/vulcan_v3` on 2026-09-28, go on to B3.2: B3.4 checks them.

| Upload list part | Files | From | To | Total |
|---|---|---|---|---|
| B (v2) | 6 | `D:\BEN\FEMTIC_2026\mesh\vulcan_v2\inversion\`, plus `...\vulcan_v2\mesh_logs\products.md5` | `/hpcfs/users/a1690074/vulcan_femtic/inputs/vulcan_v2/` | 312,893,416 B |
| C (v3) | 6 | the same under `vulcan_v3` | `.../inputs/vulcan_v3/` | 390,887,243 B |

**B3.2 p2-log-2: keep the unrotated v2 pair under new names.** Each `mv` runs only if the file is still the
unrotated one (md5) and the new name is free, so the block is safe to run twice:
```bash
cd $IN/vulcan_v2 && {
echo "599109ca5e809c5f474011006595baac  observe.dat" | md5sum -c --status - && [ ! -e observe_unrotated.dat ] && mv observe.dat observe_unrotated.dat
echo "4d4d0fb12aee9e8be2f6dc46023fb9ea  station_map.csv" | md5sum -c --status - && [ ! -e station_map_unrotated.csv ] && mv station_map.csv station_map_unrotated.csv
ls observe*.dat station_map*.csv
}
```
PASS: `observe_unrotated.dat` and `station_map_unrotated.csv` are listed. On the first run there is no `observe.dat`
or `station_map.csv`; on a later run (after B3.3) they are listed too: they are the rotated pair, which the md5 guards
leave in place and B3.4 checks.

**B3.3 WinSCP: part D** (2 files, 505,628 B): `observe.dat` and `station_map.csv` from
`D:\BEN\FEMTIC_2026\.claude\worktrees\femtic-work-9213a4\mesh\vulcan_v2_rot\inversion\` (after a merge: the same
path under `D:\BEN\FEMTIC_2026`) to `/hpcfs/users/a1690074/vulcan_femtic/inputs/vulcan_v2/`.

**B3.4 p2-log-2: check.**
```bash
mkdir -p $P/export/B3
(
cd $IN/vulcan_v2 || exit 1
echo "== vulcan_v2"
md5sum -c products.md5
md5sum -c - <<'EOF'
6f1e579e818bc9bafa64bc4c091f3ba4  observe.dat
eecf20d99a12b777faf138027a267f95  station_map.csv
599109ca5e809c5f474011006595baac  observe_unrotated.dat
4d4d0fb12aee9e8be2f6dc46023fb9ea  station_map_unrotated.csv
1ca8f744e96bd97c1725fdb0f9709861  control.dat
EOF
sha256sum observe.dat | cut -c1-16
echo $(head -2 mesh.dat) / $(head -1 resistivity_block_iter0.dat)
cd $IN/vulcan_v3 || exit 1
echo "== vulcan_v3"
md5sum -c products.md5
md5sum -c - <<'EOF'
599109ca5e809c5f474011006595baac  observe.dat
4d4d0fb12aee9e8be2f6dc46023fb9ea  station_map.csv
1ca8f744e96bd97c1725fdb0f9709861  control.dat
EOF
echo $(head -2 mesh.dat) / $(head -1 resistivity_block_iter0.dat)
wc -c $IN/vulcan_v2/* $IN/vulcan_v3/*
) 2>&1 | tee $P/export/B3/md5_check.txt
```
PASS:
* 12 lines ending in `: OK` (7 for v2, 5 for v3), and the byte counts of parts B-D of the list (the renamed files
  keep the sizes of B03 and B04);
* `d501abcf5a7dde5f`, the rotated observe.dat;
* `TETRA 401334 / 2446095 65342` for v2 (mesh.dat: TETRA and the node count; model: elements and blocks);
* `TETRA 502982 / 3068130 68655` for v3.

`products.md5` holds the sums of mesh.dat and resistivity_block_iter0.dat; the gated WSL chain wrote it on 09-25.
The other sums were measured on the PC on 2026-09-28. control.dat and the unrotated pair are identical in v2 and v3.

Journal: `B3 <date>: inputs in $IN/vulcan_v2 and $IN/vulcan_v3; md5 12/12 OK; start model 20 ohm-m; v2 observe.dat
rotated (sha256 d501abcf5a7dde5f), unrotated pair kept as observe_unrotated.dat and station_map_unrotated.csv;
v3 observe.dat unrotated.`

## B4a. The half-space gate on v2 (decides D1)

**Fails if (each job):**
* the job exits non-zero: 4 = T6 passed but the gate FAILED or was not evaluated; 1 = T6 failed or the layout
  was refused;
* `logs/halfspace_eval_<jobid>.txt` does not end in `RESULT: PASS`;
* its COMPLETENESS line does not read `2520 expected (site, band) pairs, 0 missing`;
* the binding check or the CPU-efficiency check below prints FAIL. These two do not change the gate verdict (the
  accuracy of a solve does not depend on the layout), but they block B5 and 05 at this layout: tell Fable.

A FAIL in any band row fails the gate. That includes 0.0031521 Hz, never tested on any mesh, and the two lowest
bands, 0.0019947 and 0.0012553 Hz.

Limits, as on WSL (`tools/halfspace_eval.py`), at every one of the 120 sites x 21 observe.dat bands:
* |rho_a/rho - 1| <= 5 %;
* |phase - 45 deg| <= 1.5 deg;
* max(|Zxx|,|Zyy|)/|Zxy| <= 2 %.

**Which runs D1 needs (Ben confirms before submitting).** STATUS D1 says: v2 if its 100 ohm-m run passes. This
runbook proposes a stricter rule: v2 only if a 3 ohm-m run on all 21 bands passes as well. Reasons: the WSL
3 ohm-m gate covered only 8 bands, 10 of the 21 observe.dat bands have never been tested at any resistivity, and
3 ohm-m is the high-frequency stress case. It costs one more job of the same size. If Ben keeps the STATUS rule,
leave out every `gate3` line below and read only the first column of the D1 table.

**One directory per job.** Both jobs would otherwise write `logs/fwd_rank_mb`, `LAYOUT` and `job_outcomes.tsv` in
the same place, and B4b could read the wrong job's memory. Each gate directory under `$WK/<mesh>/` gets a copy of
`control.dat` and links to the other inputs in `$IN/vulcan_<mesh>` (section 0, Folders). v2's observe.dat is the
rotated file; a half-space is isotropic, so the rotation changes no gate number. Set the mesh:
```bash
M=v2    # v3 (only if v2 is out, below): M=v3
```
Then run this block unchanged:
```bash
for G in gate100 gate3; do
mkdir -p $WK/$M/$G && cd $WK/$M/$G || break
cp ../../../inputs/vulcan_$M/control.dat .
for f in mesh.dat observe.dat resistivity_block_iter0.dat station_map.csv; do ln -sfn ../../../inputs/vulcan_$M/$f $f; done
ls -L mesh.dat observe.dat resistivity_block_iter0.dat station_map.csv control.dat > /dev/null && echo "$M $G ready: $(readlink -f observe.dat)"
done
```
PASS: `v2 gate100 ready: <...>/vulcan_femtic/inputs/vulcan_v2/observe.dat`, and the same for `gate3` (`<...>` is
the real path of `/hpcfs/users/a1690074`).

**Submit** from each gate directory. `--time=02:00:00` is set on the line: the 06 header's 4 h is sized for v3 at
2 x 36, and v2 at 3 x 24 needs 7 frequencies per rank x 418 s = 2,926 s plus about 6 min (06 header).
```bash
cd $WK/v2/gate100
J100=$(sbatch --parsable -J v2_gate100 --ntasks-per-node=3 --cpus-per-task=24 --time=02:00:00 --export=ALL,START_RHO=100 $PLAN/06_forward_only.slurm)
echo "$J100 B4a v2_gate100 3x24 $WK/v2/gate100 $(date +%F_%T)" | tee -a $LEDGER
cd $WK/v2/gate3
J3=$(sbatch --parsable -J v2_gate3 --ntasks-per-node=3 --cpus-per-task=24 --time=02:00:00 --export=ALL,START_RHO=3 $PLAN/06_forward_only.slurm)
echo "$J3 B4a v2_gate3 3x24 $WK/v2/gate3 $(date +%F_%T)" | tee -a $LEDGER
```
**Cost.** Each job should take 0.3-1 h: 7 frequencies per rank, which took 139-418 s each on WSL. That is 26-86 SU
per job if billed on elapsed time, and 172.8 at most.

**In the first minutes of a job,** check the top of its output:
```bash
cd $WK/v2/gate100 && grep -E '^half-space gate|^memory model|^layout rule|^launch' slurm-v2_gate100-$J100.out
```
Expect (both jobs print the same numbers, because each directory starts without logs):
* `half-space gate: START_RHO=100 ohm-m on 65341 blocks, 1 block(s) of >= 1e6 ohm-m (air) kept; blocks off START_RHO after re-reading: 0`;
* `layout rule: 3 ranks/node x (31322 forward + 43147 sensitivity-step MiB) + 0 extra = 223407 MiB <= 95 % of 254952 MiB (--mem) = 242204 MiB: OK ...`;
* a `launch: mpirun -np 3 --map-by ppr:3:node:PE=24 --bind-to core --report-bindings ...` line.

**After each job.** Go to its directory and set its id and layout:
```bash
cd $WK/v2/gate100 && J=$J100 && R=3 && T=24    # 3 ohm-m: cd $WK/v2/gate3 && J=$J3; v3 (below): cd $WK/v3/gate100 && J=$K100 && R=2 && T=36
```
Then run this block unchanged:
```bash
sacct -j $J --format=JobID,JobName%12,State,ExitCode,Elapsed
grep -E '^(T6|GATE|RESULT|COMPLETENESS|LIMIT)' logs/fwd0_report_$J.txt
grep -E '^ *(0\.0031521|0\.0019947|0\.0012553) ' logs/halfspace_eval_$J.txt
awk -v R=$R -v T=$T '/ MCW rank [0-9]+ / {
    r = $0; sub(/.* MCW rank /, "", r); r = r + 0; n++; seen[r]++
    m = $0; if (sub(/.*: \[/, "[", m) == 0) m = ""
    gsub(/\]\[/, "/", m); gsub(/[][]/, "", m); k = split(m, c, "/")
    for (i = 1; i <= k; i++) if (c[i] ~ /B/) { b[r]++; if (i in own) dup++; own[i] = r } }
  END { bad = (n != R) || dup
    for (r = 0; r < R; r++) if (seen[r] != 1 || b[r] != T) bad = 1
    printf "bindings: %d lines for %d ranks; cores per rank:", n, R; for (r = 0; r < R; r++) printf " %d", b[r]
    printf " (want %d); cores bound to two ranks: %d: %s\n", T, dup, (bad ? "FAIL" : "PASS") }' fwd0_$J/stdout.txt
sacct -j $J -n -P --format=JobID,Elapsed,TotalCPU,AllocCPUS | awk -F'|' -v j=$J 'function sec(t,  a, d, n) {
    d = 0; if (t ~ /-/) { split(t, a, "-"); d = a[1]; t = a[2] }
    n = split(t, a, ":"); return d * 86400 + (n == 3 ? a[1] * 3600 + a[2] * 60 + a[3] : a[1] * 60 + a[2]) }
  $1 == j { el = sec($2); nc = $4 } $1 == j ".batch" { cpu = sec($3) }
  END { e = (el * nc > 0) ? 100 * cpu / (el * nc) : 0
    printf "CPU efficiency %.1f %% = TotalCPU(.batch) %d s / (Elapsed %d s x %d cpus): %s\n", e, cpu, el, nc, (e >= 50 ? "PASS" : "FAIL") }'
```
PASS looks like this (your values will differ; the sacct rows show `COMPLETED` and `0:0`):
```
T6 (forward-only): PASS
LIMIT rho_a       5 %  : PASS  worst <x> % at site <id> (<name>), <f> Hz (...)
LIMIT phase     1.5 deg: PASS  worst ...
LIMIT diagonal    2 %  : PASS  worst ...
COMPLETENESS: 2520 expected (site, band) pairs, 0 missing; 0 rows not in observe.dat: PASS
RESULT: PASS
GATE (half-space, START_RHO=100): PASS
 0.0031521 ...                                                   PASS
bindings: 3 lines for 3 ranks; cores per rank: 24 24 24 (want 24); cores bound to two ranks: 0: PASS
CPU efficiency <e> % = TotalCPU(.batch) <c> s / (Elapsed <s> s x 72 cpus): PASS
```
* The report's `--- iteration-0 misfit` row compares the uniform model with the real data. A large RMS there is
  expected and is not part of the gate.
* **Bindings.** B4a is the first run ever of the production launch line. `mpirun ... --report-bindings`
  (`femtic_launch_cmd`) writes one `MCW rank N bound to ...: [B/B/./...][./...]` line per rank into
  `fwd0_<jobid>/stdout.txt`; each `B` marks a core. The check FAILS if a rank has no line, a rank holds other than
  T cores, or two ranks share a core. The line format is OpenMPI 4.1's and has not been seen on Phoenix yet: if the
  check finds `0 lines`, put `grep -m3 -i bound fwd0_$J/stdout.txt` in the journal and ask Fable before B5.
* **CPU efficiency** = sacct TotalCPU of the `.batch` step (with mpirun all ranks run inside it) / (Elapsed x
  allocated cpus). FAIL below 50 %, the README's T4 threshold. WSL ran at 92.5-99 % of its 8 threads: 20 of the 21
  `D:/BEN/FEMTIC_2026/mesh/vulcan_v*/halfspace/*/*/time_v.log` hold "Percent of CPU" 740-792 % (the 21st, of the
  killed run `vulcan_v1/halfspace/acc_100/killed_np4_omp4`, is empty). A broken binding
  gives about 33 % (3 ranks on the same 24 cores) or about 4 % (one core per rank); uneven frequency times and
  the single-threaded setup keep a correct run below the WSL figure. `rcstat $J` prints Phoenix's own figure;
  record it as well.

**Exit 4 with `GATE ... NOT_EVALUATED`** (for example, no python3 on the compute node): evaluate on the login
node, in the job's directory, with the same evaluator and the same files:
```bash
python3 $PLAN/tools/halfspace_eval.py 100 fwd0_$J --station-map station_map.csv > logs/halfspace_eval_${J}_login.txt; echo "exit=$?"
tail -5 logs/halfspace_eval_${J}_login.txt
```
Use 3 instead of 100 for the 3 ohm-m job. Exit 0 = PASS, 1 = FAIL, 2 = no usable input.

**D1 decision.** Write it in the journal and tell Ben/Fable.

| v2 at 100 ohm-m | v2 at 3 ohm-m (if run) | D1 |
|---|---|---|
| PASS | PASS, or not run | **v2.** B4b and B5 run on v2 at 3 x 24. |
| PASS | FAIL | v2 is out under the stricter rule: the failure is on production bands. Run the v3 gate below. |
| FAIL | any | v2 is out. Run the v3 gate below. |
| NOT_EVALUATED | | Evaluate by hand (above) before you decide. |

**v3 gate, only if v2 is out.** It uses the 06 header layout, 2 x 36, in its own directories. First run the
gate-directory block above after `M=v3` (PASS: `v3 gate100 ready: <...>/inputs/vulcan_v3/observe.dat` and the same
for `gate3`; v3's observe.dat is the unrotated one, which the gate does not mind). Then submit:
```bash
cd $WK/v3/gate100
K100=$(sbatch --parsable -J v3_gate100 --time=04:00:00 --export=ALL,START_RHO=100 $PLAN/06_forward_only.slurm)
echo "$K100 B4a v3_gate100 2x36 $WK/v3/gate100 $(date +%F_%T)" | tee -a $LEDGER
cd $WK/v3/gate3
K3=$(sbatch --parsable -J v3_gate3 --time=04:00:00 --export=ALL,START_RHO=3 $PLAN/06_forward_only.slurm)
echo "$K3 B4a v3_gate3 2x36 $WK/v3/gate3 $(date +%F_%T)" | tee -a $LEDGER
```
* `--time=04:00:00` is also the 06 header's value; it is spelled out so the line stays right if the header
  changes. One rank solves 11 frequencies, up to 11 x 755 s = 8,305 s = 2.3 h at WSL speed.
* 06 stops femtic about 10 min before the limit (`--signal=B:USR1@600`; its watcher's hard stop 5 min before the
  limit, `WALL_MARGIN_MIN`, is the backstop). A stopped run has no end line and fails T6.
* First minutes: expect `68654 blocks` and
  `layout rule: 2 ranks/node x (39283 forward + 53820 sensitivity-step MiB) + 0 extra = 186206 MiB <= 95 % of 254952 MiB (--mem) = 242204 MiB: OK ...`.
* After each job: the same block as above, with `J=$K100` (then `$K3`), `R=2`, `T=36`. Expect
  `cores per rank: 36 36`.
* Each job should take 0.5-2.3 h: 43-199 SU if billed on elapsed time, 345.6 at most.
* v3 PASS on both jobs: D1 = v3, and B5 runs at 2 x 36.
* v3 FAIL: stop, and do not run B5. Send both reports to Fable; the mesh needs work (STATUS C7).

**Copy back** each job, from its directory with `J` set as above:
```bash
mkdir -p $P/export/B4a_$J
cp slurm-*-$J.out logs/fwd0_report_$J.txt logs/halfspace_eval_$J*.txt job_outcomes.tsv $P/export/B4a_$J/
cp logs/fwd_rank_mb LAYOUT $P/export/B4a_$J/ 2>/dev/null
cp fwd0_$J/femtic_*.log fwd0_$J/femtic.cnv fwd0_$J/control.dat fwd0_$J/result_*_iter0.csv fwd0_$J/stdout.txt $P/export/B4a_$J/
sacct -j $J -P --format=JobID,State,ExitCode,Elapsed,TotalCPU,AllocCPUS,MaxRSS > $P/export/B4a_$J/sacct_$J.txt
rcstat $J > $P/export/B4a_$J/rcstat_$J.txt 2>&1
```
`logs/fwd_rank_mb` and `LAYOUT` exist only when T6 passed. Do not copy `fwd0_<jobid>/resistivity_block_iter0.dat`
(the uniform copy, reproducible) or `*.vtk`.

Journal: `B4a <date> v2 3x24: job <J100> 100 ohm-m (gate100): exit <>, T6 <>, GATE <>, pairs <>/2520, worst rho_a
<>% at <site> <f> Hz, phase <> deg at <>, diag <>% at <>, bands 0.0031521/0.0019947/0.0012553 Hz <PASS/FAIL>,
bindings <PASS/FAIL>, CPU eff <> % (rcstat <>), elapsed <>; job <J3> 3 ohm-m (gate3): <same>. D1 = <v2|v3|none>
because <...>.`

## B4b. Forward time and memory; B5 layout preview (no new job)

**Source.** Everything here comes from the B4a **100 ohm-m** job of the chosen mesh, in its own directory:
`$WK/v2/gate100` (job `$J100`) or `$WK/v3/gate100` (job `$K100`). Its `logs/fwd_rank_mb` is the file B5 copies;
06 wrote it there because T6 passed. The 3 ohm-m job has its own copy in `gate3`, which is not used: PARDISO's
memory is set by the matrix structure, not by the resistivity values.

**Fails if:**
* `logs/fwd_rank_mb` is missing, or its second field is not `job<id of the 100 ohm-m job>` (the awk line prints FAIL);
* `frequency rows over all ranks` is not 21;
* `LAYOUT` has no `sbatch=` line, or it is not `sbatch=-p icelake -N 1 --ntasks-per-node=3 --cpus-per-task=24
  --mem=254952M` (v3: `--ntasks-per-node=2 --cpus-per-task=36`);
* the first `layout rule:` line of the B5 preview (the last command) says `REFUSED`. T4 then cannot run in this
  layout: use one rank fewer per node in B5, and tell Fable that the forward term of the model is off.

Set the source, then run the block unchanged:
```bash
G=$WK/v2/gate100; J=$J100; M=v2; R=3; SF=20101    # v3: G=$WK/v3/gate100; J=$K100; M=v3; R=2; SF=21120
```
```bash
cat $G/logs/fwd_rank_mb
awk -v j=job$J 'NR == 1 {print "fwd_rank_mb: " $1 " MiB from " $2 ": " ($2 == j ? "PASS" : "FAIL (want " j ")")}' $G/logs/fwd_rank_mb
sed -n '/--- measured/,/forward memory per rank/p' $G/logs/fwd0_report_$J.txt
grep -A4 'node, sensitivity step with this layout' $G/logs/fwd0_report_$J.txt
grep '^sbatch=' $G/LAYOUT
F=$(awk 'NR == 1 {print $1}' $G/logs/fwd_rank_mb)
( cd $IN/vulcan_$M && BIN=$BIN F=$F R=$R SF=$SF bash -c 'source "$BIN/femtic_lib.sh" && FWD_MB=$F femtic_mem_model . && femtic_layout_check "$R" "$FM_FWD_MB" "$FM_NONP_MB" 254952 95 0; femtic_layout_check "$R" "$FM_FWD_MB" "$FM_NONP_MB" 254952 95 "$SF"' )
```
**The B5 preview** (the last command) evaluates 04's layout rule for B5 the way 04 will in `$WK/$M/t4`. It runs in
`$IN/vulcan_$M`, whose files `t4` links, and which holds no femtic logs, so N_eq = mesh.dat nodes + elements and NONPARDISO_MB is
43,147 MiB (v2) or 53,820 MiB (v3). The rule is R x (FWD_MB + NONPARDISO_MB) + extra <= 95 % of 254,952 MiB =
242,204 MiB. The first line has no extra term. The second adds the term 04 adds only when `$TMPDIR` is tmpfs:
the sensitivity files, Nd x M x 8 B x 2 for INV_METHOD 1 = 20,101 MiB (v2) or 21,120 MiB (v3).
06's own node check (the `grep -A4` lines) uses the N_eq logged by the gate job, so its sensitivity term is 38 MiB
(v2) or 37 MiB (v3) smaller. It is for information; the preview decides.

Record these in the journal. The expected values come from WSL, not Phoenix:

| Line | v2 expected | v3 expected |
|---|---|---|
| `frequency rows over all ranks: N (must equal F = 21)` | 21 | 21 |
| `forward phase wall time for this layout (slowest rank): T s` | 973-2,926 s (7 x 139-418 s) | 1,804-8,305 s (11 x 164-755 s) |
| `largest PARDISO in-core need per rank: X GiB (Y KB)` | `22.4 GiB (23452200 KB)` | `26.2 GiB (27485600 KB)` |
| `peak summed RSS of femtic processes on the node` | about 81 GiB (3 x 27.0) | about 64 GiB (2 x 32.1) |
| `forward memory per rank (FWD_MB for 04): W MiB` | about 28,629 (1.25 x PARDISO) | about 33,552 |
| 06's node check, first `layout rule:` line (N_iv 480) | OK | OK |
| 06's `pessimistic N_iv = ... 840` line | REFUSED at 3 ranks (information for B5) | REFUSED at 2 ranks |
| preview, no tmpfs, with the W above | `3 ranks/node x (28629 forward + 43147 sensitivity-step MiB) + 0 extra = 215328 MiB ...: OK` | `2 ranks/node x (33552 forward + 53820 ...) + 0 extra = 174744 MiB ...: OK` |
| preview, tmpfs | `... + 20101 extra = 235429 MiB ...: OK` | `... + 21120 extra = 195864 MiB ...: OK` |

* T is an input for the chain later: ITER_STEP ~ (72 h - 0.5 h - T) / T_iteration. T_iteration comes from B5.
* `LAYOUT` is the layout 05 will submit 04 with. The production directory will be `$WK/$M/inv01`, set up like a
  gate directory (section 0, Folders); it needs a copy of LAYOUT (README section 3, step 10):
  `cp $G/LAYOUT $WK/$M/inv01/`. Not after an N_iv 840 finding in B5: see "If N_iv 840 shows", item 6.

Journal: `B4b <date> from job <J> (<mesh> <R>x<T>, $G): fwd_rank_mb <> MiB from job<J> <PASS/FAIL>; F rows <>; forward
wall (slowest rank) <> s, per frequency <min>-<max> s; PARDISO per rank <> GiB (WSL <>); peak node RSS <> GiB;
06 node check N_iv 480 <OK/REFUSED>, N_iv 840 <OK/REFUSED>; LAYOUT sbatch= <...>; B5 preview <need> MiB <OK/REFUSED>,
with tmpfs <need> MiB <OK/REFUSED>.`

## B5. T4: one inversion iteration (04 with ITERATION 0 1)

**Fails if:**
* 04 exits non-zero, or writes no `logs/COMPLETED_<jobid>`;
* the `sacct` State is not `COMPLETED` (for example `OUT_OF_MEMORY`);
* the output contains `WARNING: measured N_iv`, `OUT-OF-CORE`, `oversubscribed` or `ranks > ... frequencies`;
* the per-rank memory check below prints FAIL: 04's ps peak per rank (its node sum / ranks per node) is outside
  0.8 Z - 1 MiB to 1.2 Z + 1 MiB, where Z is the per-rank prediction 04 prints in its sizing report,
  `predicted per rank (layout rule): <FWD_MB> forward + <NONPARDISO_MB> sensitivity-step = Z MiB`.
  A FAIL below the band can be a reading artefact: read "Both readings are node sums" below before concluding;
* the CPU-efficiency check below prints FAIL (under 50 %).

The cross-check line (sacct MaxRSS of the `.batch` step / ranks per node, against the ps reading) does not change
the verdict. If it prints FAIL, record both numbers and tell Fable.

**Why.** The sensitivity step has never run anywhere, so two numbers are still predictions:
* its memory: two N_eq x N_iv arrays live at once (README section 6);
* N_iv: 480 from the FEMTIC source, or 840 if the dummy VTF stations count.

**What Z will be.** `t4/` holds no femtic log, so 04 takes N_eq from mesh.dat (nodes + elements: 2,847,429
on v2, 3,571,112 on v3) and FWD_MB from the `logs/fwd_rank_mb` copied from B4b. So Z = FWD_MB + 43,147 MiB on v2
and FWD_MB + 53,820 MiB on v3, as the B4b preview printed. With the FWD_MB expected from WSL (28,629 / 33,552):
* v2: Z = 71,776 MiB; PASS band 57,420-86,132 MiB;
* v3: Z = 87,372 MiB; PASS band 69,897-104,847 MiB.

The band is 0.8 Z - 1 MiB to 1.2 Z + 1 MiB (57,419.8-86,132.2 MiB on v2). The 1 MiB on each side absorbs the
rounding of Z and of the readings to whole MiB, so a reading that rounds onto an edge does not flip the verdict;
the quoted integer edges are the band rounded inwards, and at an edge the awk line decides. N_eq from the mesh is
2,557 above the logged N_eq, which adds 38 MiB (v2) or 37 MiB (v3) to Z; that is far inside the band.

**Set up the test directory** `$WK/$M/t4` like a gate directory (section 0, Folders), plus products.md5 and the
forward memory of the 100 ohm-m gate job. The gate directories stay as they are, and nothing ever continues from `t4`.
```bash
M=v2; N=3                 # the D1 choice; v3: M=v3; N=2 (ranks per node)
mkdir -p $WK/$M/t4/logs && cd $WK/$M/t4 && {
cp ../../../inputs/vulcan_$M/control.dat .
for f in mesh.dat observe.dat resistivity_block_iter0.dat station_map.csv products.md5; do ln -sfn ../../../inputs/vulcan_$M/$f $f; done
cp $WK/$M/gate100/logs/fwd_rank_mb logs/        # from the B4a 100 ohm-m job (checked in B4b); 04 uses it (FWD_MB=auto)
md5sum -c products.md5
bash -c "source $BIN/femtic_lib.sh && femtic_ctl_set control.dat ITERATION '0 1' && femtic_ctl_get control.dat ITERATION"
}
```
PASS: two lines ending in `: OK`, then `0 1`. Copy no femtic log or `fwd0_*` directory here: Z above assumes there
is none.

**observe.dat here is the rotated file** on v2 (B3), and on v3 once B3.2 and B3.3 ran for it (B3). Memory and time do not depend on the data values. The T4
model is thrown away; the real inversion starts in `$WK/$M/inv01` with the same inputs.

**Submit.**
* The walltime is 12 h instead of the header's 3 days.
* `WATCH_S=10` makes 04's own RSS sampler read every 10 s instead of 60.
```bash
cd $WK/$M/t4
unset J4b    # set only by the N_iv 840 rerun below
J4=$(sbatch --parsable -J t4_$M --ntasks-per-node=3 --cpus-per-task=24 --time=12:00:00 --export=ALL,WATCH_S=10 $PLAN/04_inversion.slurm)
# v3 instead: J4=$(sbatch --parsable -J t4_$M --ntasks-per-node=2 --cpus-per-task=36 --time=12:00:00 --export=ALL,WATCH_S=10 $PLAN/04_inversion.slurm)
echo "$J4 B5 t4_$M $(date +%F_%T)" | tee -a $LEDGER
```
**Expected cost** (unmeasured): roughly 1.5-5 h, or 130-432 SU if billed on elapsed time, and 1,036.8 at most. The
job runs:
* 2 to 4 forward solves (model 0, model 1, and up to 2 retrials);
* one sensitivity step;
* the rank-0 update.

**Once the job runs,** check the lines it printed before launch (`JT` is the rerun's id once `J4b` is set):
```bash
cd $WK/$M/t4 && JT=${J4b:-$J4}
grep -A1 'df -hT sense dir' slurm-t4_$M-$JT.out       # filesystem type of $TMPDIR: settles README section 10 item 1
grep -E '^WARNING: .*tmpfs|^memory model|^layout rule|^launch' slurm-t4_$M-$JT.out
```
**If 04 refused the layout** (`layout REFUSED`, exit 1, no SU spent), its `layout rule:` line shows every term of
the rule as 04 evaluated it: R x (FWD_MB + NONPARDISO_MB) + extra > 95 % of 254,952 MiB = 242,204 MiB. FWD_MB is
the first field of `logs/fwd_rank_mb`; NONPARDISO_MB is 43,147 MiB (v2) or 53,820 MiB (v3); extra is 0, unless the
df line shows `tmpfs`, when it is the sensitivity-file size printed in the `WARNING: ... tmpfs` line (20,101 MiB on
v2, 21,120 MiB on v3). It should equal the matching B4b preview line. Resubmit with one rank fewer per node
(v2 `--ntasks-per-node=2 --cpus-per-task=36`, v3 `--ntasks-per-node=1 --cpus-per-task=72`, and `N` to match) and
record the refused line.

**After the job,** with `M`, `N` and `J4` (and `J4b` after an N_iv 840 rerun) set as above, run this block
unchanged. It judges `J4b` if that is set, else `J4`:
```bash
cd $WK/$M/t4 && JT=${J4b:-$J4} && echo "judging job $JT with N=$N ranks per node"
sacct -j $JT --units=M --format=JobID,State,ExitCode,Elapsed,NTasks,MaxRSS,MaxRSSTask,MaxRSSNode | tee logs/sacct_$JT.txt
grep -E '^OUTCOME|^COMPLETED' slurm-t4_$M-$JT.out
sed -n '/--- sizing report ---/,/^sensitivity scratch/p' slurm-t4_$M-$JT.out
Z=$(sed -n 's/^predicted per rank (layout rule): .* = \([0-9]*\) MiB;.*/\1/p' slurm-t4_$M-$JT.out)
PS=$(cat logs/peak_rss_kb_$JT 2>/dev/null)
RSS=$(sacct -j $JT -n -P --units=M --format=JobID,MaxRSS | awk -F'|' -v s=$JT.batch '$1 == s {sub(/M$/, "", $2); print $2}')
awk -v k="$PS" -v r="$RSS" -v n=$N -v z="$Z" 'BEGIN {lo = 0.8 * z - 1; hi = 1.2 * z + 1; p = k / 1024 / n; q = r / n
  printf "per rank, 04 ps peak / N: %.0f MiB = %.3f x Z %d MiB (PASS band %.1f-%.1f MiB): %s\n", p, (z > 0 ? p / z : 0), z, lo, hi, (z > 0 && p > 0 && p >= lo && p <= hi) ? "PASS" : "FAIL"
  printf "cross-check, sacct MaxRSS(.batch) / N: %.0f MiB = %.3f x the ps reading (agree within 10 %%): %s\n", q, (p > 0 ? q / p : 0), (p > 0 && q > 0 && q >= 0.9 * p && q <= 1.1 * p) ? "PASS" : "FAIL"}'
sacct -j $JT -n -P --format=JobID,Elapsed,TotalCPU,AllocCPUS | awk -F'|' -v j=$JT 'function sec(t,  a, d, n) {
    d = 0; if (t ~ /-/) { split(t, a, "-"); d = a[1]; t = a[2] }
    n = split(t, a, ":"); return d * 86400 + (n == 3 ? a[1] * 3600 + a[2] * 60 + a[3] : a[1] * 60 + a[2]) }
  $1 == j { el = sec($2); nc = $4 } $1 == j ".batch" { cpu = sec($3) }
  END { e = (el * nc > 0) ? 100 * cpu / (el * nc) : 0
    printf "CPU efficiency %.1f %% = TotalCPU(.batch) %d s / (Elapsed %d s x %d cpus): %s\n", e, cpu, el, nc, (e >= 50 ? "PASS" : "FAIL") }'
rcstat $JT | tee logs/rcstat_$JT.txt
```
**How to read the memory lines:**
* **Primary: 04's ps peak.** 04's sampler (`femtic_watch`, femtic_lib.sh:542) adds up `ps -C femtic -o rss=` over
  all femtic processes on the node every `WATCH_S` = 10 s and keeps the largest sum, in KiB, in
  `logs/peak_rss_kb_<jobid>`. The sizing report prints it as
  `peak summed RSS of the node's femtic processes (sampled every 10 s): X GB`. Per rank = that sum / N. It does
  not depend on how Phoenix's Slurm gathers accounting (JobAcctGatherType and its frequency were not recorded at
  discovery), and ps never counts files in `$TMPDIR`.
* **Cross-check: sacct.** The default launcher is `mpirun`. On one node, all ranks run inside the `<jobid>.batch`
  step. That row has NTasks 1, and its MaxRSS is the peak of all ranks together, so per rank = MaxRSS(`.batch`) / N.
  If `$TMPDIR` is tmpfs, Slurm's figure may include the sensitivity files (up to 20,101 or 21,120 MiB, / N): that
  explains a cross-check FAIL with sacct the higher one.
* A `<jobid>.0` row with NTasks equal to the rank count appears only with `USE_SRUN=1`. Its MaxRSS is then the
  largest per-task peak, and MaxRSSTask names the rank: a true per-rank reading.
* If `Z`, `PS` or `RSS` is empty, its line prints FAIL; read the values from the output above and run the awk line
  with them.
* **Both readings are node sums, and they under-read when the ranks' peaks do not coincide.** The kit has no
  per-rank peak. Each rank allocates and frees the N_eq x N_iv arrays per frequency inside its own frequency loop
  (AnalysisControl.cpp:2020-2041 calls the sensitivity code per frequency; the round-2 verifier found the new and
  delete at Inversion.cpp:108 and :143), with no collective call between frequencies. If only 2 of 3 v2 ranks are
  at their peak together, the sum / 3 reads (3 x 28,629 + 2 x 43,147) / 3 = 57,394 MiB = 0.7996 Z: a FAIL on a
  correct model. A reading above the band is conclusive (some rank peaked at least that high); one below it is
  not. Before concluding that the model over-predicts, tell Fable. A per-rank reading needs a rerun with
  `USE_SRUN=1` (the `.0` row; srun binds differently from the mpirun line B4a tested, up to another 1,036.8 SU)
  or a per-process peak in 04's sampler (a kit change).

**If N_iv 840 shows.** You see it either way:
* the sizing report says `WARNING: measured N_iv 840 differs from the 480 ...`;
* after an `OUT_OF_MEMORY` kill, `grep -h 'Solve phase is performed simultaneously' femtic_*.log | sort | uniq -c`
  shows 840.

Then:
1. The reading of the source in README section 6 is wrong, and the 480-based Z does not apply.
2. The layout rule then allows 2 ranks per icelake node on v2 and 1 on v3, or highmem 7 x 10.
3. Copy back this first job now (the copy-back block below, while `J4b` is still unset).
4. Re-run T4 in the same directory with `NIV=840` and 2 ranks per node on v2 (v3: 1). This block stores the new
   job id in `J4b` and in the ledger:
```bash
cd $WK/$M/t4
N=2    # v3: N=1
J4b=$(sbatch -J t4_$M --ntasks-per-node=$N --cpus-per-task=$((72 / N)) --time=12:00:00 --export=ALL,WATCH_S=10,NIV=840 $PLAN/04_inversion.slurm | awk '{print $NF}')
if [ -n "$J4b" ]; then echo "$J4b B5 t4_$M NIV=840 ${N}x$((72 / N)) $(date +%F_%T)" | tee -a $LEDGER; else echo "no job id: sbatch failed"; fi
```
5. When it has run, run the after-job block and then the copy-back block again: both take `J4b` (`JT=${J4b:-$J4}`)
   and the new `N`. 04 archives the first run's logs into `logs/run_<stamp>/` and now takes N_eq from them, so
   Z = FWD_MB + 75,082 MiB (v2) or FWD_MB + 93,742 MiB (v3): 103,711 and 127,294 MiB with the expected FWD_MB.
6. Every later 04 or 05 job needs `NIV=840`, and inv01 must not use gate100's `LAYOUT` (v2 3 x 24, v3 2 x 36):
   04 refuses that layout at NIV=840. In `$WK/$M/inv01`, replace it with an explicit layout, which 05 takes instead
   of `LAYOUT` (it then prints `LAYOUT (from 06) is not used`): `SBATCH_EXTRA='--ntasks-per-node=2 --cpus-per-task=36'`
   on v2 or `SBATCH_EXTRA='--ntasks-per-node=1 --cpus-per-task=72'` on v3, and pass `NIV=840` to every job with
   `SBATCH_EXPORT_EXTRA=NIV=840`. For example, on v2:
   `SBATCH_EXTRA='--ntasks-per-node=2 --cpus-per-task=36' SBATCH_EXPORT_EXTRA=NIV=840 bash -l $PLAN/05_chain.sh $WK/$M/inv01 3 <ITER_STEP> <ITER_MAX>`.
   Tell Fable that README section 6 and STATUS need the correction.

**If `OUT_OF_MEMORY` happens with N_iv 480,** the model underestimates:
1. Record the MaxRSS; sacct keeps it.
2. Do not retry the same layout. Re-run with one rank fewer per node.
3. Send the numbers to Fable.

Copy back (it takes `J4b` if set, else `J4`):
```bash
cd $WK/$M/t4 && JT=${J4b:-$J4} && mkdir -p $P/export/B5_$JT
cp slurm-*-$JT.out logs/sacct_$JT.txt logs/rcstat_$JT.txt logs/peak_rss_kb_$JT logs/control.dat.before_$JT logs/control.dat.used_$JT job_outcomes.tsv femtic_*.log femtic.cnv $P/export/B5_$JT/
cp logs/COMPLETED_$JT $P/export/B5_$JT/ 2>/dev/null
sacct -j $JT -P --format=JobID,State,ExitCode,Elapsed,TotalCPU,AllocCPUS,MaxRSS > $P/export/B5_$JT/sacct_cpu_$JT.txt
```
Not needed: `resistivity_block_iter1.dat`, `*.vtk` and `result_*.csv`.

Journal: `B5 <date> T4 <mesh> job <JT> <R>x<T> (NIV <auto|840>): State <>, exit <>, Elapsed <>; $TMPDIR type <>;
N_iv measured <> (rule used <>); predicted per rank Z = <> MiB; 04 ps peak <> GiB -> per rank <> MiB = <ratio> x Z
-> <PASS/FAIL>; sacct MaxRSS(.batch) <> MiB -> per rank <> MiB, cross-check <PASS/FAIL>; CPU eff <> % (<PASS/FAIL>;
rcstat <> %), <> SU (elapsed <> h: billed on elapsed|requested); RMS iter 0 -> 1: <> -> <>.`

## B6. After 10-01: Q4 SU grant and queue check

**Fails if:**
* `rcquota` shows no Q4 period for physci; or
* physci has fewer than 19,700 SU left in Q4. That is T4 at full walltime (1,036.8 SU) plus three 3-day icelake
  chain links (3 x 6,220.8 SU).

```bash
mkdir -p $P/export/B6
rcquota | tee $P/export/B6/rcquota_$(date +%F).txt
sbatch --test-only -p icelake -N 1 --ntasks-per-node=3 --cpus-per-task=24 --mem=254952M --gres=tmpfs:200G --time=3-00:00:00 --wrap=true 2>&1 | tee -a $P/export/B6/test_only_$(date +%F).txt
sbatch --test-only -p highmem -N 1 --ntasks-per-node=7 --cpus-per-task=10 --mem=1900G --gres=tmpfs:200G --time=3-00:00:00 --wrap=true 2>&1 | tee -a $P/export/B6/test_only_$(date +%F).txt
```
* `--test-only` submits nothing. Each line says `Job N to start at <time> ...`.
* At discovery (09-25) the estimates were about 5 h for highmem and about 22 h for icelake
  (`discovery/phoenix_discovery_p2-log-2_2026-09-25.txt:1037-1043`).
* highmem costs 2.5 SU per cpu-hour, against icelake's 1.2. It is worth it only if the waiting time it saves
  matters more than the SU.

Also settle README section 10, item 2: does Phoenix bill elapsed or requested time? For each B4a and B5 job,
compare the `rcstat <jobid>` SU with 72 x 1.2 x the elapsed hours.

Journal: `B6 <date>: rcquota period <>, physci grant <> SU, used <>, remaining <>; test-only start icelake <> vs
highmem <>; billing: job <J> elapsed <> h, rcstat <> SU -> billed on <elapsed|requested>.`

## Exit codes and messages

| Script | Exit | Meaning |
|---|---|---|
| 01 | 0 / 1 / 3 | every test that ran passed (T5 may be INCONCLUSIVE) / stopped with ERROR / a test failed |
| 06 | 0 / 1 / 4 | T6 PASS (and gate PASS) / T6 FAIL, layout refused or setup error / T6 PASS but gate FAIL or not evaluated |
| 04 | 0 / 2 / 3 / other | end reached or converged / STALLED (max retrials) / stopped with no new model / failure |
| 05 | 0 / 1 | jobs submitted (or nothing left to do) / refused before any `sbatch`: no `LAYOUT` and no explicit layout, half a layout, an old library, a missing input or a CONVERGED/STALLED marker |

* `needs FEMTIC_LIB_VERSION >= 4` (01 SMOKE_ONLY, 03, 04, 05, 06): B1 is not done.
  `install -m 644 $PLAN/femtic_lib.sh $BIN/` fixes it.
* `layout REFUSED`: too many ranks per node for the memory rule. Nothing ran and no SU were spent. Use fewer
  ranks: `--ntasks-per-node=R --cpus-per-task=72/R`.
* `bad interpreter: ^M`: the file has CRLF line endings; run `dos2unix <file>`.
* A `task_prolog ... Permission denied` line on the interactive nodes is harmless.

**Never:**
* run a job in `$IN/vulcan_v2` or `$IN/vulcan_v3` (the immutable inputs; jobs run in `$WK/<mesh>/<name>`);
* run `03_mesh.slurm` (an ungated chain);
* use the old 8 x 9 layout (it is refused anyway);
* submit two 06 jobs from one directory (they overwrite `logs/fwd_rank_mb` and `LAYOUT`);
* run 04 or `05_chain.sh` from a `gate*` directory (04 runs in `$WK/<mesh>/t4` for B5, and later in `inv01`);
* run femtic on the login node, the PC or WSL.
