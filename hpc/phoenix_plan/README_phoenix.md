# FEMTIC on Phoenix: deployment plan for the Vulcan MT survey

FEMTIC v5.0: 3-D MT inversion in C++ with MPI, OpenMP and Intel MKL PARDISO.
Target: University of Adelaide Phoenix (Slurm, Lmod, EasyBuild software stack). User `a1690074`, account `physci`.
Survey: 120 sites over about 13 x 15 km (UTM zone 53S), **impedance only (no tipper)**, tetrahedral mesh. The candidate meshes that passed or nearly passed the half-space gate are v2 (2,446,095 elements) and v3 (3,068,130), far above the 500k first planned (section 6). <!-- src: mesh/vulcan_v2/mesh_logs/mesh_stats.txt:1; mesh/vulcan_v3/mesh_logs/mesh_stats.txt:1; gate validation/mesh_2026-09-25/halfspace_accuracy.md:9-14 -->

**Discovery is done.** `00_discover.sh` ran on the login node **p2-log-2 on 2026-09-25**, from Ben's copy of
the project at `/hpcfs/users/a1690074/FEMTIC_2026`. Its full output is kept next to these scripts in
`discovery/phoenix_discovery_p2-log-2_2026-09-25.txt`; the module names, partition limits, billing weights,
srun plugins, login-node tools and storage facts below are taken from it (summary in section 12). The GCC
route (`foss/2023a` + `imkl/2023.1.0`) is load-tested and is the primary route. The build ran on p2-log-2 on
2026-09-25 (all 7 tools, T1 PASS; `discovery/phoenix_build_foss_2026-09-25.log`) and again on 2026-09-28 with the
committed kit 55bbf44. The smoke job on icelake reported T1, T2 and T5 PASS on 2026-09-28 (job 16153670; section 3,
step 5); the two attempts of 2026-09-25 had stopped before FEMTIC ran. What is still unverified is
listed at the end of section 10; VERIFY tags remain only on those items.

## 0. Files

| File | Where it runs | Purpose |
|---|---|---|
| `00_discover.sh` | login node | Read-only survey: toolchain modules (`module avail foss imkl intel GCC OpenMPI impi`, `module spider imkl`), load tests, per-partition memory caps, billing weights, git/curl/internet, micromamba. Validates the planned requests with `sbatch --test-only`, which submits nothing. **Ran 2026-09-25 on p2-log-2**; re-run only to re-check after a Phoenix change. |
| `discovery/phoenix_discovery_p2-log-2_2026-09-25.txt` | - | The full output of that run: the evidence for every "verified 2026-09-25" statement in this README and the scripts. |
| `01_build_femtic.sh` | login node only (`FETCH_ONLY=1`, then the build); `SMOKE_ONLY=1` as a batch job | Gets the 7 sources pinned to audited commits (git clone, pre-copied git-free trees, or GitHub tarballs; never inside a compute job), builds them with the ported Makefiles, installs to `$BIN`, writes `femtic_env.sh`, runs test T1. `SMOKE_ONLY=1` runs T1, T2 and T5 on the installed build in a batch job, with no git, make or compiler. |
| `femtic_lib.sh` | sourced | Shared helpers: control.dat edits, restart-model integrity check and fallback, the wall-limit watcher, launch command, log parsing. Installed to `$BIN`. |
| `02_env_femticpy.sh` | login node or interactive job | Reuses the micromamba 2.9.0 already under `/hpcfs/users/$USER/micromamba` (envs base, gjoint) and adds only the env `femticpy` from `environment_femticpy.yml` (written next to the script). Self-test includes a UTM 53S check. **Not used for Vulcan:** it sets up an unpatched upstream femticPy copy (`FEMTICPY_SRC`); the Vulcan inputs come from `scripts/prep_vulcan.py` with the vendored, patched copy (section 3, step 6). <!-- src: hpc/phoenix_plan/02_env_femticpy.sh:49 --> |
| `03_mesh.slurm` | icelake (8 cpus) or interactive | The 7-step meshGen, then test T3 (mesh consistency) and sizing inputs. **Not used for Vulcan:** a different, ungated chain (section 3, step 7). |
| `06_forward_only.slurm` | icelake, 1 node, 4 h (header; section 5) | **First Phoenix job on the real mesh (T6).** One forward solve (`ITERATION 0 0`) in the production layout: forward time per frequency, PARDISO memory per rank, peak node RSS, and a short report. Refuses a layout that breaks the memory rule (section 6). With `START_RHO=<ohm-m>` it is also the half-space accuracy gate. |
| `tools/halfspace_eval.py` | inside 06 (`START_RHO`), or by hand | The half-space gate: compares `result_*_iter0.csv` at every site and band of observe.dat with the analytic half-space (5 % rho_a, 1.5 deg, 2 % diagonal) and prints PASS/FAIL per limit with the worst site and band. Python 3.6+, standard library only. Adapted from `validation/mesh_2026-09-25/halfspace_accuracy/acc_eval.py`. |
| `tests/c1c2_test.sh`, `tests/halfspace_eval_test.sh`, `tests/portability_test.sh` | login node, WSL or Git Bash (the second needs the WSL gate runs under `D:/BEN/FEMTIC_2026/mesh`) | Self-tests of the 2026-09-28 changes (section 9): PARDISO parser, memory model, layout rule, version gates, the half-space gate, the LAYOUT hand-over to 05, N_iv parsing; the third checks the kit for bash > 4.4 and Python > 3.6 features (Phoenix's bash 4.4 and python3 3.6.8). Fake femtic, mpirun and Slurm; nothing heavy runs. |
| `04_inversion.slurm` | icelake, 1 node (highmem only if more than about 255 GB per node is needed) | Hybrid MPI/OpenMP inversion: control.dat rewrite, validated restart, safe-point stop before the wall limit, COMPLETED marker, sizing report. |
| `05_chain.sh` | login node | Submits K dependent 3-day jobs that continue from the last valid iteration. Refuses to start without a layout: the `LAYOUT` file 06 writes when T6 passes, or `SBATCH_EXTRA` with both `--ntasks-per-node` and `--cpus-per-task` (section 7). |

The ported Makefiles are in `D:\BEN\FEMTIC_2026\hpc\ported\`, on Phoenix in `/hpcfs/users/a1690074/FEMTIC_2026/hpc/ported/`.
`01` reads them from `$PORTED` (default `$SRC/ported/`), so pass `PORTED=/hpcfs/users/$USER/FEMTIC_2026/hpc/ported`
or copy that directory to `$SRC/ported/` (section 3). `01` uses
`femtic/Makefile.gcc_openmpi_mkl` or `femtic/Makefile.intel_oneapi`, `makeTetraMesh/Makefile.gcc_mkl` or
`makeTetraMesh/Makefile.intel_oneapi`, and `Makefile.gcc` for makeMtr, TetGen2Femtic, makeDHexaMesh and
mergeResultOfFEMTIC. tetgen builds with its upstream makefile, keeping `PREDCXXFLAGS=-O0`.

## 1. Phoenix facts this plan relies on (verified 2026-09-25)

Sources: `sinfo`, `scontrol show partition|config|node`, `sacctmgr`, `sshare`, `rcquota` and `sbatch --test-only`
in the discovery output (p2-log-2, 2026-09-25), plus Ben's earlier node census for the `batch` and `dm` rows.

| partition | nodes | cpus / node | RAM / node (MiB) | MaxMemPerCPU (MiB) | most one job gets per node | walltime | SU per cpu-hour | use here |
|---|---:|---:|---:|---:|---|---|---:|---|
| `batch` | **0** | - | - | - | - | - | - | **never use** (`batch up infinite 0 0 0`, census) |
| `icelake` | 93 | 72 | 255,000 | 3541 | 72 cpus, **254,952 MiB** (`--mem=254952M`) | 3 days | 1.2 | default for 03, 04, 06 |
| `newicelake` | 5 | 72 | 255,000 | not queried | not queried | 3 days | not queried | not used by the kit |
| `a100cpu` | 43 (GPU nodes) | 72, but **MaxCPUsPerNode=36** | 515,000 | 7152 | **36 cpus, 257,472 MiB** | 3 days | 1.2 | **not used**: icelake's RAM with half the cores at the same price, so no advantage for FEMTIC (the wiki's "36 cpus" was right) |
| `highmem` | 7 | 72 | 1,990,000 | 27126 | 72 cpus, **1,953,072 MiB** (`--mem=1900G` accepted) | 3 days | 2.5 | the only route above about 255 GB per node |
| `interactive` | 2 (`p2-dmv-*`) | 72 | 255,000 | - (OverSubscribe=FORCE:2) | 8 cpus per job, 24 per user (QoS) | 21 days | free (wiki; VERIFY) | smoke test (`SMOKE_ONLY=1`), mesh; **never the build**: its data-mover nodes `p2-dmv-*` have no git and no `/apps` (2026-09-25; `femtic_env.sh` remaps to `/gpfs/apps`); has internet (wiki); cores can be shared 2-way, so take no timings here |
| `dm` | 2 | 72 | 255,000 | - | 8 cpus per job, 24 per user (QoS) | infinite | free (wiki) | transfers |

* **RAM is granted per cpu.** `--mem` is capped at cpus x MaxMemPerCPU, so memory is bought with cpus.
  Tested with `sbatch --test-only`: one icelake node with 8 x 9 cpus and `--mem=254952M` (72 x 3541) was
  **accepted**; `--mem=250G` (256,000 MiB; Slurm's G is 1024 MiB) was **rejected** ("Requested node
  configuration is not available"); highmem 72 cpus with `--mem=1900G` was **accepted**; a100cpu 72 cpus with
  `--mem=514944M` was **rejected** ("Job violates accounting/QOS policy"), because a job gets at most 36 cpus
  there. For a partial node, ask for cpus = ceil(MiB needed / MiB per cpu) explicitly: a 36-cpu icelake
  request with `--mem=254952M` was accepted (test-only reported 36 processors), and whether Slurm then
  allocates and bills more cpus is not verified.
* **highmem is the only route above about 255 GB per node:** 72 x 27126 = 1,953,072 MiB, at 2.5 SU per
  cpu-hour (about twice icelake), and its QoS allows at most 432 cpus (6 nodes) per job.
* **Limits:** account `physci`, QoS `normal` (no limits). The icelake partition QoS allows **1200 cpus per
  user (16 whole nodes)** and 7416 per job, MaxWall 3 days; 2 icelake nodes x 8 x 9 x `--mem=254952M` for
  3 days was accepted.
* **Billing is CPU-only:** `TRESBillingWeights=CPU=1.20` (icelake, a100cpu) and `CPU=2.5` (highmem); memory
  is not charged. Whether elapsed or requested time is charged is not verified (section 10).
* **Walltime, not budget, is the constraint.** `rcquota` (2026-09-25): physci grant 1,299,444 SU for the
  quarter, 320,879 used (24.7 %), with 94.5 % of the quarter lapsed; a1690074 has used 40 SU. The unused
  SU presumably lapse at the quarter's end, and next quarter's grant is not known; at 6,220.8 SU per 3-day
  node-job, budget is still not the constraint. Every CPU partition has a 3-day MaxTime, which is why 04
  restarts and 05 chains.
* **Fair-share and the long QoS:** `sshare` FairShare = 0.593, above the 0.25 threshold for the `long`
  QoS (threshold as Ben has it; `long` has MaxWall 7 days in `sacctmgr show qos`). But the association
  lists only QoS `normal`, and icelake's MaxTime and partition-QoS MaxWall are 3 days, so whether
  `--qos=long` actually gives more than 3 days on icelake is not verified (section 10). The kit keeps
  3-day jobs and chaining.
* **Slurm settings:** SelectTypeParameters=CR_CORE_MEMORY and TaskPlugin=task/cgroup,task/affinity (memory
  is a per-job consumable enforced by cgroups: a job over `--mem` is killed); KillWait=30 s; MpiDefault=none.
  `srun --mpi=list` gives **pmi2, none, cray_shasta (no pmix)**: with `USE_SRUN=1` the kit uses
  `srun --mpi=pmi2`. The default launcher is `mpirun`: OpenMPI 4.1.5 is built `--with-slurm --with-pmi` and
  has the `ess slurm` component, so it needs nothing.
* **Modules:** Lmod 8.2.10, `MODULEPATH=/opt/ohpc/pub/modulefiles:/gpfs/apps/icl/modules/all`, full
  EasyBuild names with toolchain suffixes. Generations 2021b, 2023a and 2025b. Load-tested:
  `foss/2023a imkl/2023.1.0` and `intel/2023a` (section 4). Also present: GCC/14.3.0,
  OpenMPI/5.0.8-GCC-14.3.0, foss/2025b, CMake/3.26.3-GCCcore-12.3.0, git/2.41.0-GCCcore-12.3.0-nodocs,
  Python/3.11.3-GCCcore-12.3.0, Anaconda3 (2023.03, 2024.06-1, 2025.06-1), EasyBuild 4.5.5 to 5.3.0.
* **CPUs:** the login node p2-log-2 is a Xeon Platinum 8360Y with SMT on (144 logical cpus, AVX-512). The
  icelake compute node p2-cpu-1: 2 sockets x 36 cores, ThreadsPerCore=1 (SMT off, so 72 cpus = 72 cores),
  RealMemory=255000, Gres=tmpfs:2400G, TmpDisk=0.
* **Login node tools:** system gcc 8.4.1 (RHEL 8.4; never build with it, `01` refuses g++ < 9), git 2.27.0,
  curl 7.61.1 with internet (github HTTP 200, micro.mamba.pm 307, conda-forge 200), `ulimit -s` 8192
  (04 raises it in jobs), `TMPDIR` unset outside jobs (in jobs it exists only with `--gres=tmpfs:<N>G`).
  `rcquota` and `rcstat` are in `/usr/local/bin`.
* **Node differences (seen 2026-09-25 in two failed smoke jobs):** icelake compute nodes have no `make` and no
  `git`, so **building is login-node only** (`01` stops with "make not found" elsewhere; `module avail` also lists
  `make/4.4.1-GCCcore-12.3.0`, untested and not needed). The interactive-partition data-mover nodes `p2-dmv-*`
  have no git and **no `/apps` at all**, only `/gpfs/apps` (owner root, group phoenix-hpc-support). The modules
  still load there but set `/apps/icl/...` paths (`MKLROOT`, `LD_LIBRARY_PATH`), so `ldd femtic` found 3 MKL
  libraries "not found" on p2-dmv-1. The login node and the icelake nodes have both trees: imkl is under
  `/apps/icl/software`, GCC and OpenMPI under `/gpfs/apps/icl/software`. `femtic_env.sh` therefore calls
  `femtic_apps_remap` (`femtic_lib.sh`): on a node without `/apps` it rewrites `/apps/` to `/gpfs/apps/` in the
  exported module paths and prints `femtic_env.sh: /apps absent on <host>; remapped to /gpfs/apps`. 03, 04 and
  06 source `femtic_env.sh` before they run any tool, so they get the remap too.
* **Internet:** verified on the login node. The interactive partition has it according to the wiki;
  compute nodes were not tested. `git clone`, downloads, micromamba and conda-forge therefore run on the
  login node or in an interactive job only.
* **Storage:** `/hpcfs/users/a1690074` resolves to `/scratchdata1/users/a1690074` on gpfs-2-1 (1.9 PB,
  82 % used, 366 TB free). `rcquota` printed only SU, so the per-user quota is not verified.

## 2. Workflow and directory layout

Ben's established Phoenix workflow, which these scripts follow:

* Files go to `/hpcfs/users/a1690074/<project>` by **WinSCP**; this project is at
  `/hpcfs/users/a1690074/FEMTIC_2026`. There is **no git** on the Phoenix tree, and every script tolerates
  a git-free tree (01 reads `COMMIT_SHA.txt` or GitHub tarballs instead). The login node does have git 2.27,
  so `FETCH_ONLY=1` clones the upstream sources and records each checked-out commit in `<repo>/COMMIT_SHA.txt`.
  On a node without git, `01` reads a checkout's commit from `.git/HEAD` (and `.git/refs/` or `.git/packed-refs`).
* **LF line endings.** All files here are LF. If a copied script fails at the shebang (`bad interpreter: ^M`),
  run `dos2unix *.sh *.slurm`. `05` refuses a CRLF job script.
* **Python via micromamba** under `/hpcfs/users/$USER/micromamba` (not the Anaconda module).
* **Job conventions** (03, 04, 06): `#SBATCH -o slurm-%x-%j.out`; `--mail-type=END,FAIL` to
  `ben.kay@adelaide.edu.au`; `--signal=B:USR1@600` with a trap that writes `logs/WALLTIME_<jobid>` and a
  `job_outcomes.tsv` row; knobs such as `THREADS` and `RANKS` through `--export=ALL,...`; a
  `logs/COMPLETED_<jobid>` marker only on a verified normal end, so a silent exit-0 death counts as FAIL;
  and `rcstat <jobid>` at the end of every job.

```
/home/$USER/                          10 GB cap (NFS): nothing from this plan (EasyBuild's defaults point here)
/hpcfs/users/$USER/                   = /scratchdata1/users/$USER (gpfs-2-1): all builds and all jobs
  FEMTIC_2026/                        Ben's WinSCP copy of this project (00_discover.sh ran here)
    hpc/phoenix_plan/                 $PLAN: these scripts (00..06, femtic_lib.sh, environment_femticpy.yml)
      discovery/                      phoenix_discovery_p2-log-2_2026-09-25.txt
    hpc/ported/<tool>/Makefile.*      the ported Makefiles (PORTED=... for 01, or copy to femtic_src/ported)
  micromamba/                         MAMBA_ROOT_PREFIX: micromamba 2.9.0, envs base and gjoint; 02 adds femticpy
  femticPy/                           femticPy tree (WinSCP copy or clone; notebooks and prep scripts)
  femtic_src/                         $SRC: the 7 upstream sources (build objects land here)
    ported/<tool>/Makefile.*          optional copy of FEMTIC_2026/hpc/ported (01's default $PORTED)
    tarballs/                         optional GitHub archives <repo>-<sha>.tar.gz (git-free route)
    build_<toolchain>_<date>.log      build logs (fetch_<date>.log for FETCH_ONLY=1)
    smoke_<toolchain>_<date>.log      SMOKE_ONLY=1 logs; smoke_<toolchain>_<date>/ holds that run's T2/T5 files
  femtic/bin/                         $BIN: femtic makeTetraMesh tetgen makeMtr TetGen2Femtic
                                      makeDHexaMesh mergeResultOfFEMTIC femtic_env.sh femtic_lib.sh
  easybuild/                          EASYBUILD_PREFIX, only if the fallback (section 8) is ever needed (absent now)
  vulcan_femtic/                      $VF (RUNBOOK_first_inversion.md section 0), with jobs_ledger.txt
    inputs/vulcan_v{2,3}/             $IN: the gated inputs (RUNBOOK B3), never written afterwards; no job runs here:
                                      control.dat observe.dat station_map.csv mesh.dat resistivity_block_iter0.dat
                                      products.md5 [observe_unrotated.dat station_map_unrotated.csv] (B3.2)
    work/v{2,3}/<name>/               $WK: one directory per job: gate100, gate3 (06, B4a), t4 (04, B5), inv01 (05);
                                      each: a copy of control.dat, links ../../../inputs/vulcan_<mesh>/<file>, logs/
                                      fwd0_<jobid>/ LAYOUT job_outcomes.tsv [chain_jobs.txt in inv01]
    input_data/                       topography.dat bathymetry.dat coast_line.dat ... (03_mesh.slurm only)
    meshGen/files/                    control.dat analysis_domain.dat observing_site.dat obs_site.dat
                                      makeMtr.param resistivity_attr.dat [regions.txt]; logs/ job_outcomes.tsv
                                      (03 copies its mesh to work/meshgen/inv01; not used for Vulcan)
    scratch/                          shared sensitivity scratch, multi-node jobs only
```

## 3. Order of work

In every step, `PLAN=/hpcfs/users/$USER/FEMTIC_2026/hpc/phoenix_plan`.

1. **Done:** the project is at `/hpcfs/users/a1690074/FEMTIC_2026` (WinSCP). `01` needs the ported Makefiles in
   `$PORTED`: either pass `PORTED=/hpcfs/users/$USER/FEMTIC_2026/hpc/ported` to every `01` call, or once
   `mkdir -p /hpcfs/users/$USER/femtic_src && cp -r /hpcfs/users/$USER/FEMTIC_2026/hpc/ported /hpcfs/users/$USER/femtic_src/`.
   Run `dos2unix` only if a shebang fails.
2. **Done:** `00_discover.sh` ran on p2-log-2 on 2026-09-25 (output in `$PLAN/discovery/`). The module names
   in `01_build_femtic.sh` match it, so no `MODS=` is needed.
3. **Done** (2026-09-25): sources, on the **login node**: `cd $PLAN && FETCH_ONLY=1 bash -l 01_build_femtic.sh`.
   git 2.27 is there, so it clones and checks out the pinned commits (and now also writes `<repo>/COMMIT_SHA.txt`).
   Alternatively download `https://github.com/<owner>/<repo>/archive/<sha>.tar.gz` on Windows and WinSCP the
   files to `femtic_src/tarballs/`.
4. Build, on the **login node p2-log-2 only** (compute nodes have no `make` or git; the interactive nodes have no
   `/apps`): `cd $PLAN && TOOLCHAIN=foss PORTED=/hpcfs/users/$USER/FEMTIC_2026/hpc/ported bash -l 01_build_femtic.sh`.
   It ran on 2026-09-25 in 74 s and ended with `T1=PASS T2=SKIPPED T5=SKIPPED`.
   **Done; no rebuild is needed.** Ben rebuilt on 2026-09-28 21:10-21:11 with the committed kit 55bbf44
   (`BUILD DONE  T1=PASS  T2=SKIPPED  T5=SKIPPED`; `validation/phoenix_2026-09-28/build_foss_20260928_211021.log`).
   `$BIN` now holds femtic 26c8606 (1,494,008 B), a 732 B `femtic_env.sh` with the `/apps` remap, and
   `femtic_lib.sh` version 2 (19,992 B). The version-4 kit needs only its library:
   `install -m 644 $PLAN/femtic_lib.sh $BIN/`, with the version and `cmp` checks of RUNBOOK B1.5. A rebuild is
   optional (about 2 minutes). If you rebuild, record `md5sum $BIN/femtic $BIN/femtic_env.sh` before and after.
   The first line of `femtic_env.sh` holds the build date, so its md5 always changes; a changed `femtic` md5 means
   repeating step 5.
5. Smoke tests T1 + T2 + T5 on the installed build, as a batch job submitted from `/hpcfs/users/$USER/FEMTIC_2026`:
   ```
   sbatch -p icelake -N 1 -n 4 --mem=8G --time=00:30:00 -J femtic_smoke -o slurm-%x-%j.out --wrap 'TOOLCHAIN=foss SMOKE_ONLY=1 bash -l hpc/phoenix_plan/01_build_femtic.sh'
   ```
   At most 2.4 SU. `SMOKE_ONLY=1` fetches, compiles and installs nothing: it sources `$BIN/femtic_env.sh`, runs
   T1 (`ldd`; fails on any "not found") and T2/T5 on FEMTIC's example, and logs to
   `femtic_src/smoke_foss_<date>.log`. `-p interactive` instead of `-p icelake` is free (wiki) and should work now
   that `$BIN/femtic_env.sh` has the remap (untested there; the log would show the `/apps absent ... remapped to
   /gpfs/apps` line). icelake is the node type 04 and 06 run on. The job must end with `SMOKE_ONLY DONE  T1=PASS  T2=PASS  T5=PASS`, or
   `T5=INCONCLUSIVE` (section 10); exit status 3 means a test failed, 1 that the script stopped with ERROR.
   The first two attempts (`SMOKE=1`, 2026-09-25) stopped before FEMTIC ran: on `interactive` (p2-dmv-1: no git,
   no `/apps`, so no `libmkl_core` under `MKLROOT`) and on `icelake` ("make: command not found").
   **Passed on 2026-09-28** with the committed kit 55bbf44: job 16153670 on icelake p2-cpu-14 ended with
   `SMOKE_ONLY DONE  T1=PASS  T2=PASS  T5=PASS`, and the example's iterations 0-2 equal both WSL builds to all 7
   printed digits (`validation/phoenix_2026-09-28/README.md`). Its sacct ExitCode was not copied back, so RUNBOOK
   B2's criterion 2 is still open. Repeat this step only after a rebuild that changes `$BIN/femtic`: on this path
   the version-4 library changes only the version gate (RUNBOOK B2).
6. **Inputs: not 02 and the notebooks.** observe.dat, control.dat and the mesh-chain inputs come from
   `scripts/prep_vulcan.py` with the vendored femticPy (`external/femticPy/`, 9 patches). prep is light (text
   files only; no mesh tool and no FEMTIC) and runs on the PC. `02_env_femticpy.sh` sets up an env for an
   unpatched upstream femticPy copy (`FEMTICPY_SRC`, 02:49), so Vulcan does not need it.
   Site coordinates come only from `Vulcan/site_coords_femticpy.txt` (section 11).
7. **Mesh: copy the gated mesh; do not run 03.** v1-v3 were built on 2026-09-25, in WSL, by
   `scripts/run_mesh_chain.sh`, and put through the half-space test. WinSCP `mesh.dat`, `resistivity_block_iter0.dat`,
   `control.dat`, `observe.dat` and `station_map.csv` of `D:/BEN/FEMTIC_2026/mesh/vulcan_v{2,3}/inversion/`, and
   `mesh_logs/products.md5`, into the input folders `vulcan_femtic/inputs/vulcan_v2` and `.../inputs/vulcan_v3`. They
   are never written after RUNBOOK B3, which checks them. v2's data is the rotated pair of `mesh/vulcan_v2_rot/inversion/`
   (STATUS D2); the unrotated pair stays there as `observe_unrotated.dat` and `station_map_unrotated.csv`. Jobs run in
   `vulcan_femtic/work/v{2,3}/<gate100|gate3|t4|inv01>`, set up by `cp ../../../inputs/vulcan_v2/control.dat .` and
   `ln -sfn ../../../inputs/vulcan_v2/$f $f` for mesh.dat, observe.dat, resistivity_block_iter0.dat and station_map.csv
   (site names in the gate report). 03 is another, ungated chain (03:31-33); no Phoenix mesh route is tested yet.
8. **Forward-only job (T6), the first thing to run on Phoenix after the build and the mesh**, from a work directory
   (step 7), never from `inputs/`: `cd /hpcfs/users/$USER/vulcan_femtic/work/<mesh>/<name> && sbatch $PLAN/06_forward_only.slurm`.
   The header asks for 2 ranks x 36 threads (v3) and 4 h: one rank solves 11 of the 21 frequencies, up to
   11 x 755 s = 2.3 h at WSL speed. For v2 add `--ntasks-per-node=3 --cpus-per-task=24 --time=02:00:00`
   (7 x 418 s). Walltime rule: `--time` >= ceil(21 / ranks) x slowest frequency + 6 min (06 header). Cost at
   full walltime: SU = nodes x 72 cpus x hours x rate (section 5): 345.6 SU for the header, 172.8 for v2 at 2 h.
   The job refuses, before femtic starts, a layout that breaks the memory rule. Read `logs/fwd0_report_<jobid>.txt`:
   forward time per frequency, PARDISO per rank, peak node RSS, and the predicted sensitivity-step and rank-0
   memory. It also writes the measured forward memory per rank to `logs/fwd_rank_mb`, which 04 uses, and, when
   T6 passes under the full memory rule, its own layout to `LAYOUT`, which 05 uses. Change the layout (ranks x
   threads, partition) here, before any inversion is submitted.
   **The same job is the half-space accuracy gate**, one job per directory (RUNBOOK B4a): in `work/v2/gate100`,
   `sbatch --export=ALL,START_RHO=100 $PLAN/06_forward_only.slurm`, and in `work/v2/gate3` the same with `START_RHO=3`.
   It runs a uniform model, written to `fwd0_<jobid>/`, at all 21 observe.dat bands.
   `tools/halfspace_eval.py` then judges it against the analytic half-space and prints PASS/FAIL per limit with
   the worst site and band. Exit 4 means T6 passed but the gate failed.
9. **Test inversion (T4), in its own work directory `vulcan_femtic/work/<mesh>/t4`, never in the production
   directory** (RUNBOOK B5): set it up like a gate directory (step 7), copy `logs/fwd_rank_mb` from
   `work/<mesh>/gate100/logs/`, set `ITERATION` to `0 1` in its own `control.dat` and run
   `sbatch --time=12:00:00 $PLAN/04_inversion.slurm` there in the gate's layout (at most 1,036.8 SU). Nothing
   continues from `t4`. Read the sizing report (measured N_iv, predicted per-rank memory), `sacct` MaxRSS and
   `rcstat`, then choose ranks, threads and ITER_STEP (section 6).
10. Production, in `vulcan_femtic/work/<mesh>/inv01`, set up like a gate directory (step 7):
    `bash -l $PLAN/05_chain.sh $PWD 3 <ITER_STEP> <ITER_MAX>`. It takes the layout from `LAYOUT`
    (step 8), or from `SBATCH_EXTRA='--ntasks-per-node=3 --cpus-per-task=24'` (v2; both options), and refuses to
    start without one: the 04 header's 2 x 36 would silently run v2 at 2 ranks. 06 ran in another directory
    on the same mesh (`work/<mesh>/gate100`), so copy its `LAYOUT` into the production directory (RUNBOOK B4b).
    If T4 measured N_iv 840, use `SBATCH_EXTRA` with one rank fewer per node and `NIV=840` instead (RUNBOOK B5).

After every job: `rcstat <jobid>` (also printed at the end of `slurm-<jobname>-<jobid>.out`).

Messages seen on Phoenix, and what they mean:

* A Slurm `task_prolog` line ending in `Permission denied` at the top of a job's output on p2-dmv-1 (interactive
  partition): a cluster quirk, harmless; ignore it.
* `femtic_env.sh: /apps absent on p2-dmv-...; remapped to /gpfs/apps`: expected on the interactive nodes (section 1).
* `ERROR: make not found: build on the login node ...`: `01` was started without `SMOKE_ONLY=1` in a compute job.
* `T1 FAIL: unresolved libraries: libmkl_... => not found` on an interactive node: `$BIN/femtic_env.sh` predates
  the remap (`01` prints a NOTE saying so); re-run the build on the login node (step 4).
* `-- <repo>: version UNKNOWN (informational, not an error)`: neither git, `.git/HEAD` nor `COMMIT_SHA.txt` gives the
  commit; the build continues. `echo <sha> > femtic_src/<repo>/COMMIT_SHA.txt` records it.
* `bad interpreter: ^M`: CRLF line endings; `dos2unix *.sh *.slurm`.
* `p2-cpu-14:rank0.femtic: Failed to modify UD QP to INIT on mlx5_0: Operation not permitted` in FEMTIC's stdout,
  up to 4 times per rank at start on icelake (job 16153670): harmless on one node. Before any multi-node run,
  investigate the MPI transport (OpenMPI's MCA btl/pml selection or the UCX settings). No setting has been
  tested, so the kit sets none (RUNBOOK B2, "Known harmless output").

## 4. Build path per toolchain

Both module lines were load-tested by `00_discover.sh` on p2-log-2 on 2026-09-25 (load tests A and B).

| | `TOOLCHAIN=foss` (default, **the primary route**) | `TOOLCHAIN=intel` (untested fallback) |
|---|---|---|
| Modules | `module load foss/2023a imkl/2023.1.0` | `module load intel/2023a` |
| Contents (`module list` after loading) | GCC 12.3.0, OpenMPI 4.1.5 (`--with-slurm --with-pmi`, PMIx 4.2.4, UCX 1.14.1, libfabric 1.18.0), OpenBLAS 0.3.23, FlexiBLAS 3.3.1, FFTW 3.3.10, ScaLAPACK 2.2.0, imkl 2023.1.0 | intel-compilers 2023.1.0 (classic `icpc` and `icpx`), impi 2021.9.0, imkl 2023.1.0, imkl-FFTW 2023.1.0, iimpi/2023a, UCX 1.14.1, GCCcore 12.3.0 |
| MKLROOT | `/apps/icl/software/imkl/2023.1.0/mkl/2023.1.0`; `lib/` and `lib/intel64/` both exist, and `lib/intel64` has `libmkl_gnu_thread.so` and `libmkl_intel_ilp64.so` | the same imkl/2023.1.0 |
| FEMTIC compiler | `mpicxx` = the OpenMPI 4.1.5 wrapper around g++ 12.3.0 | `mpiicpc -cxx=icpx` (passed as `make CXX=...`) |
| MKL link | `-lmkl_intel_ilp64 -lmkl_gnu_thread -lmkl_core -lgomp`, `-Wl,--no-as-needed` | `-lmkl_intel_ilp64 -lmkl_intel_thread -lmkl_core -liomp5` |
| Launch | `mpirun --map-by ppr:R:node:PE=T --bind-to core` | `mpirun -np N -ppn R`, `I_MPI_PIN_DOMAIN=omp` |

Points that matter:

* **ILP64 is mandatory.** FEMTIC calls `pardiso_64` and passes `long long` to `pardisoinit`
  (ported/README.md). BLACS was in the upstream link line but is never called, so OpenMPI is fine.
  The CSIRO reference run also used OpenMPI, with Intel compilers.
* **mpiicpx and mpiicx do not exist in Phoenix's intel/2023a** (impi 2021.9.0; discovery: `mpiicpx  MISSING`,
  `mpiicx  MISSING`; `mpiicpc` is present). The intel route therefore uses **`mpiicpc -cxx=icpx`**, the LLVM icpx
  through the classic wrapper. `ported/femtic/Makefile.intel_oneapi` says `CXX = mpiicpx`; `01` passes
  `CXX=mpiicpc -cxx=icpx` to make. The classic compiler is still in intel-compilers 2023.1.0 (removed in
  oneAPI 2024.0): `INTEL_MPICXX="mpiicpc -diag-disable=10441"` builds with icpc and silences its
  "remark #10441 ... deprecated" line. The intel route has never been compiled: it stays the untested fallback.
* **Build foss first, and build intel only if foss fails or you want to benchmark.** Run time
  is dominated by MKL's PARDISO factorisation and BLAS-3 calls, which are the same MKL library
  in both toolchains. This is an engineering judgment, not a measurement.
* The load-tested imkl module is `imkl/2023.1.0` (SYSTEM toolchain). The toolchain-suffixed imkl variant that
  earlier drafts offered as an alternative does not exist on Phoenix (load test A2 printed nothing), and
  it has been removed. The only other generations are 2021b and 2025b (foss/2025b = GCC 14.3.0 +
  OpenMPI 5.0.8); neither is needed.
* **Never build with the system compiler** (gcc 8.4.1 on the login node): `01` stops if the `g++` on PATH
  after `module load` is older than 9.
* The plain tools (makeMtr, TetGen2Femtic, makeDHexaMesh, mergeResultOfFEMTIC, tetgen) always
  build with `g++`, because icpx defaults to a value-unsafe floating-point model and TetGen's
  predicates must not be optimised.
* **Pinning.** `PIN=1` requires the exact commits the ported Makefiles' OBJS lists were copied from:
  femtic `26c8606`, makeTetraMesh `92a9a32`, makeMtr `df8e207`, TetGen2Femtic `ceb8bfb`,
  makeDHexaMesh `66afbfc`, mergeResultOfFEMTIC `4fe54e1`, tetgen `e05aca7`. In a git-free tree the commit
  is read from `<repo>/COMMIT_SHA.txt`, which is written for tarballs and, wherever git runs, after every clone
  and checkout. On a node without git a checkout's commit is read from `.git/HEAD` (a SHA, or a branch through
  `.git/refs/heads/` or `.git/packed-refs`). If nothing gives the commit, the version is reported as UNKNOWN,
  as information only: the build continues. A later upstream commit that adds a source file would fail at link time.

## 5. SU cost of candidate configurations

SU = cpus x hours x rate: icelake (and a100cpu) 1.2 SU per cpu-hour, highmem 2.5. Billing is CPU-only
(`TRESBillingWeights=CPU=1.20` / `CPU=2.5`, verified 2026-09-25): memory is not charged. The figures assume
the job runs to its full walltime; whether Phoenix charges elapsed or requested time is still unverified
(section 10).

| Configuration | cpus | Hours | Rate | SU |
|---|---:|---:|---:|---:|
| forward-only T6 (06), header 2 x 36 (v3): icelake, 1 node, 4 h | 72 | 4 | 1.2 | 345.6 |
| forward-only T6 (06), v2 3 x 24 with `--time=02:00:00` | 72 | 2 | 1.2 | 172.8 |
| test inversion T4: icelake, 1 node, 12 h | 72 | 12 | 1.2 | 1,036.8 |
| icelake, 1 node, 24 h | 72 | 24 | 1.2 | **2,073.6** |
| icelake, 1 node, 72 h (one chain link) | 72 | 72 | 1.2 | **6,220.8** |
| a100cpu, the most one job gets per node: 36 cpus (257 GB), 72 h; no advantage, not used | 36 | 72 | 1.2 | 3,110.4 |
| icelake, 2 nodes, 72 h | 144 | 72 | 1.2 | **12,441.6** |
| highmem, 1 node (1.95 TB usable: 72 x 27126 MiB), 72 h | 72 | 72 | 2.5 | **12,960.0** |
| chain of 3 x 72 h on 1 icelake node | 72 | 216 | 1.2 | 18,662.4 |
| smoke test (01 `SMOKE_ONLY=1`): icelake, 4 cpus, 0.5 h (free on interactive) | 4 | 0.5 | 1.2 | 2.4 |
| mesh job (03): icelake, 8 cpus, 2 h (free on interactive) | 8 | 2 | 1.2 | 19.2 |
| CSIRO AusLAMP run, re-priced (2 x 56 cores, 144 h) | 112 | 144 | 1.2 | 19,353.6 |

The 06 walltime follows its layout. One rank solves ceil(F / R) frequencies in series, so
`--time >= ceil(21 / R) x T_f + 6 min`, with T_f the slowest single frequency: 755 s (v3) and 418 s (v2) on WSL
at 1 rank x 8 threads. That gives 11 x 755 s = 2.3 h for the header's 2 x 36, hence 4 h, and 7 x 418 s = 49 min
for v2's 3 x 24, hence 2 h (06 header, "Walltime").

Reading the table:

* **Memory-heavy jobs go to highmem**, the only partition that gives one job more than about 255 GB per node
  (up to 1,953,072 MiB), at about twice icelake's price per cpu-hour. a100cpu is not an option: a job gets at
  most 36 cpus and 257,472 MiB there, which is icelake's memory with half the cores at the same price.
* The SU budget is not the constraint (grant 1,299,444 SU for the quarter, 24.7 % used at 94.5 % lapsed;
  next quarter's grant not known). The 3-day walltime is, so the plan optimises time to solution and restart
  safety, not SU.
* A rough time scale, which is not a measurement: CSIRO's 1.45M-element AusLAMP inversion reached
  iteration 13 (14 forward evaluations, `femticPy/projects/auslamp/inversion/inv01/femtic.cnv`) on
  2 nodes x 14 ranks x 4 threads within a 144 h request, so at most about 10 h per iteration.
  Direct-solver cost grows faster than linearly with mesh size. The Vulcan candidates have 2.4-3.1 M elements,
  not the 500k first planned. In WSL one forward frequency took 139-418 s on v2 and 164-751 s on v3, on 1 rank x
  8 threads, before any sensitivity work. 06 and T4 replace the guess with Phoenix numbers.
  <!-- src: 'fwd s' columns of validation/mesh_2026-09-25/halfspace_accuracy.md:160-167 (v2) and :186-193 (v3); elements mesh/vulcan_v2/mesh_logs/mesh_stats.txt:1 and mesh/vulcan_v3/mesh_logs/mesh_stats.txt:1 -->
* The CSIRO script asked for `--mem=900g` with `--nodes=2`. Slurm's `--mem` is per node, so that
  requested 1.8 TB in total, or 64 GB per rank. It was not necessarily used.

## 6. MPI ranks, threads and memory

**How FEMTIC splits the work** (verified in source):

* Each MPI rank gets a contiguous block of frequencies (`ObservedData::calcFrequenciesCalculatedByThisPE`).
  With F frequencies and R ranks, the last `F mod R` ranks get one extra. So **R <= F**, and ideally
  R divides F. If R > F, ranks 0 to R-F-1 (including rank 0) get no frequency and their cores sit idle
  in the forward phase. The frequency count is printed in `femtic_0.log`; `04` and `06` report it.
* Within a rank, `NUM_THREADS` OpenMP and MKL threads build the matrices and run PARDISO. FEMTIC
  calls `omp_set_num_threads(NUM_THREADS)` and `mkl_set_num_threads(NUM_THREADS)`, which override
  `OMP_NUM_THREADS`. `04` therefore rewrites `NUM_THREADS` to `THREADS` (default `--cpus-per-task`).
  Without that the default of 1 thread would waste 8 of every 9 cores.
* **Rank 0 alone** runs the Gauss-Newton model update. It reads the sensitivity files of **all**
  frequencies (inside `myProcessID == 0` in both `InversionGaussNewtonModelSpace.cpp` and
  `...DataSpace.cpp`) and factorises a dense matrix, using only its own NUM_THREADS threads while
  the other ranks wait. More ranks with fewer threads speeds up the forward and sensitivity phases
  but slows this serial phase.

**Memory per node.** Every rank factorises the **full** mesh for its own frequencies (no domain
decomposition), so the forward phase needs about `R_per_node x per-rank forward memory`. By default
(no `HOLD_FWD_MEM` in control.dat) FEMTIC releases the forward matrix and PARDISO factors after the
last frequency, *before* the model update (`calcForwardComputation` in AnalysisControl.cpp). The
forward phase and the rank-0 dense phase therefore do not overlap, and the node needs roughly
`max(R_per_node x per-rank forward memory, rank-0 dense + small per-rank terms)`, under the node's
254,952 MiB (icelake) or up to 1,953,072 MiB (highmem). With `HOLD_FWD_MEM` the two add up.

**Per-rank memory is more than PARDISO.** The log line "Total memory consumed by in-core forward solver
for internal float point arrays" (in KB, read by `femtic_pardiso_kb` in `04` and `06`) covers PARDISO's factors
only. FEMTIC prints it with the default `%g` format (PARDISOSolver.cpp:218): `216125` below 10^6 KB, then
`1.23456e+06`, `2.74856e+07`, `1.5e+08`. Before FEMTIC_LIB_VERSION 3 the kit deleted every non-digit, so it read
`1.23456e+06` as 12,345,606 KB (10x high) and `1.5e+08` or `2.5e+07` as 1,508 or 2,507 KB. It was right only
for a 6-digit mantissa at e+07, which is why the v2 and v3 lines (2.34522e+07, 2.74856e+07) happened to parse.
Two terms sit on top of the factors:

* **Forward phase, `FWD_MB`** (per rank): the factors, the system matrix and the mesh. On WSL (1 rank x 8
  threads) the forward-only peak RSS was 1.17 / 1.21 / 1.22 x the PARDISO line for v1 / v2 / v3, i.e. 27,645 MiB
  for v2 and 32,869 MiB for v3 (`D:/BEN/FEMTIC_2026/mesh/vulcan_v*/halfspace/*/b*/time_v.log`). `06` measures it on Phoenix
  (peak node RSS / ranks per node, at least 1.25 x PARDISO) and writes it to `logs/fwd_rank_mb`. `FWD_MB=auto`
  (04, 06) takes that file first, else 1.25 x the largest PARDISO line in the directory's logs, else, before any
  log exists, 11,000 MiB per 10^6 equations x N_eq. The WSL ratio was 10,832 / 9,718 / 9,211 MiB per 10^6 for
  v1 / v2 / v3, so this gives 31,322 MiB for v2 and 39,283 MiB for v3, 13 % and 20 % above the WSL peaks.
* **Sensitivity step, `NONPARDISO_MB`** (per rank), for each frequency and polarisation, read in
  femtic/src at 26c8606. The PARDISO factors stay resident through it until after the last frequency.
  * `2 x N_eq x N_iv x 16 B`: the right-hand-side matrix of the interpolator vectors **and** its solution.
    Both are live during the multi-RHS solve.
    * ComplexSparseMatrix.cpp:535-536, reached through `Forward3D::initializeRhsVectors(N_iv)`:
      `const long long num = static_cast<long long>(m_numRows)*static_cast<long long>(m_numRightHandSideVectors);`
      `m_rightHandSideVector = new std::complex<double>[num];`
    * Inversion.cpp:108: `std::complex<double>* solutionForInterpolatorVectors = new std::complex<double>[static_cast<long long>(numEquationFinallySolved) * static_cast<long long>(numInterpolatorVectors)];`
    * Inversion.cpp:111 solves into it. The RHS matrix shrinks to one column only after the solve
      (Forward3D.cpp:213, `initializeRhsVectors(1)`).

    N_eq is "Number of equation after degeneration" in the log. Before version 3 the kit counted this array
    **once**: 27.4 GB on v3 instead of 54.8 GB. `DIV_NUM_RHS_FWD` does **not** shrink either array; it only
    splits the PARDISO solve calls.
  * `2 x N_iv x M x 16 B`: the field derivatives of both polarisations (Inversion.cpp:131).
  * `Nd_f x M x 8 B`: the frequency's sensitivity block before it is written to SENSE_MAT_DIRECTORY
    (Inversion.cpp:169). Nd_f = 8 x 120 = 960.

  The kit adds the three terms as if all were live at once. The strict peak is the first term plus one
  derivative array, about 1 GB less on v3. Whether MKL's multi-RHS solve adds workspace on top is not known.
  `NONPARDISO_MB=auto` (04, 06) computes this term with `femtic_mem_model`:
  * N_eq from the femtic logs of the inversion directory; before any log, from mesh.dat as nodes + elements
    (an Euler-formula bound, 2,557 above the logged N_eq on v1-v3);
  * M from `resistivity_block_iter0.dat`;
  * N_iv and Nd_f from `observe.dat`.

  `NEQ=`, `NIV=`, `NONPARDISO_MB=` and `FWD_MB=` override each quantity.

**N_iv, the interpolator right-hand sides per frequency: expected 480, bound 840.**

*Expected: N_iv = 4 per MT site = 4 x 120 = **480**, from the source* (`femtic/src/ObservedData.cpp` of the WSL
tree the other citations here use). `ObservedData::calculateEMFieldOfAllStations` (ObservedData.cpp:1024) sets
the count to 0 and then, for one frequency and polarisation:
* adds Ex, Ey for each MT station with data at that frequency (`getFreqIDsAmongThisPE( freq ) >= 0`, :1033);
* adds an MT station's own Hx, Hy only if `isUseMagneticFieldOfTheStation( freq, <its id> )` (:1038);
* adds a VTF station's Hz only if **that station** has data at the frequency (:1076-1077), and its Hx, Hy only
  if `isUseMagneticFieldOfTheStation( freq, <its id> )` (:1080).

`isUseMagneticFieldOfTheStation` (:753) is true only if a station **with data at that frequency** names the id
as its magnetic-field station (:755-758 for MT). Vulcan's control.dat has `OWNER_ELEMENT -1`, so prep writes a VTF
block of 120 dummy stations. In observe.dat each MT station s names the dummy 1000 + s (`1  1001  0 ...`), and each
dummy names itself but has no data (`1001  1001  1 ...` followed by `0` frequencies). Per site that gives:

| station | Ex, Ey | Hx, Hy | Hz | right-hand sides |
|---|---:|---:|---:|---:|
| MT station s (data at every band) | 2 | 0: nobody names s | - | 2 |
| dummy VTF station 1000 + s (no data) | - | 2: MT station s names it | 0: no data | 2 |

So a dummy adds no Hz right-hand side, and N_iv = 4 x 120 = 480 at every frequency (all 120 sites have all 21
bands). FEMTIC's example agrees with 4 per station: `run_INV_MT_01_Tetra/femtic_0.log:138` in WSL reads "Solve
phase is performed simultaneously for 144 right-hand sides" for 36 impedance stations. This is a reading of the
source, not a measurement.

*Bound: 840 = 4 x 120 + 3 x 120*, the count if every dummy added Hz, Hx and Hy. FEMTIC does count the dummies as
stations: `D:/BEN/FEMTIC_2026/mesh/vulcan_v3/halfspace/acc_100/b1/femtic_0.log:286-288` reads "Total number of
stations : 240", "Number of impedance tensor stations : 120", "Number of VTF stations : 120". At 840 the v3
sensitivity step needs 93,742 MiB per rank instead of 53,783, and v3 fits only 1 rank per icelake node (table
below).

**B5 (T4) must rule out 840.** The 04 sizing report prints the logged count, `femtic_niv_measured`: the "Solve
phase is performed simultaneously for N right-hand sides" lines after each interpolator solve, summed over the
`DIV_NUM_RHS_FWD` calls. The two "Warning : Division number of right-hand sides ..." lines that FEMTIC writes
there when `DIV_NUM_RHS_FWD` > N_iv (Forward3D.cpp:183-186) do not break the count (FEMTIC_LIB_VERSION 4).
* B5 confirms the expectation if every rank logs 480.
* If it logs 840 (or anything above 480), the source reading is wrong: pass `NIV=<measured>` to every later
  04 job and re-size (v3: 1 x 72, or highmem). 04 warns when the count differs from the N_iv its layout rule used.
* Until then `NIV=auto` sizes for 480; `NIV=840` gives the pessimistic sizing, and 06's report shows both cases.

**Predicted per rank** (Vulcan, F = 21, 120 sites). Forward phase = the WSL peak RSS; sensitivity step from the
formula. MiB; nothing here has been measured on Phoenix yet:

| mesh | N_eq | M | forward (FWD_MB) | sensitivity step, N_iv 480 | total per rank | total with N_iv 840 |
|---|---:|---:|---:|---:|---:|---:|
| v2 | 2,844,872 | 65,341 | 27,645 | 43,109 | **70,754** (74.2 GB) | 102,727 |
| v3 | 3,568,555 | 68,654 | 32,869 | 53,783 | **86,652** (90.9 GB) | 126,611 |

T4 records `sacct` MaxRSS. The prediction is wrong if MaxRSS per rank is more than 20 % off (STATUS B5).

**The layout rule.** `04` and `06` check it with `femtic_layout_check` before femtic starts:

    ranks per node x (FWD_MB + NONPARDISO_MB) + EXTRA  <=  MEM_SAFETY_PCT (95) % of --mem

* EXTRA is `RANK0_RESERVE_MB` under `HOLD_FWD_MEM`. In `04` it also includes the sensitivity files when
  `$TMPDIR` is tmpfs (below).
* **A layout that breaks the rule is refused.** The job exits 1 with a `layout_refused` row in
  `job_outcomes.tsv`, and no SU are spent on femtic. Before version 3 the kit only printed a warning.
* **`NONPARDISO_MB` does not prevent an out-of-memory kill, and neither does `MEM_LIMIT`.**
  * FEMTIC's default solver is in-core (`FWD_SOLVER 0`), and `MEM_LIMIT` only steers `FWD_SOLVER 1/2`.
  * Every rank factorises the whole mesh and keeps the factors through the sensitivity step.
  * **The number of ranks per node is the only lever.**
* **A RAM-backed `$TMPDIR` counts against `--mem`.** On Vulcan in data space that is about 22 GB of
  sensitivity files per iteration (2 x 20,160 x 68,654 x 8 B = 21,120 MiB). `04` reads the filesystem type
  with `df -PT` and adds the files to EXTRA when it is `tmpfs`.
* `06` applies the same rule by default, because the layout it approves is the one `04` runs.
  `LAYOUT_CHECK=forward` checks the forward term alone, for forward-only experiments.

**Production layouts** (1 node; F = 21, so ideally R divides 21):

| mesh | icelake (`--mem=254952M`) | rule at N_iv 480 (limit 242,204 MiB) | highmem (`--mem=1900G`, limit 1,848,320 MiB) |
|---|---|---|---|
| v2 | **3 x 24** (7 frequencies per rank) | 3 x 70,754 = 212,262 MiB | not needed |
| v3 | **2 x 36** (10 and 11 frequencies) | 2 x 86,652 = 173,304 MiB | 7 x 10 (3 frequencies per rank): 606,564 MiB |
| v3 if T4 measures N_iv 840 | 1 x 72 | 1 x 126,611 MiB | 7 x 10: 886,277 MiB |

* The old default 8 x 9 is refused for both meshes. On v3 even the forward phase alone is too big:
  8 x 32,869 = 262,952 MiB.
* The `04` and `06` headers now ask for 2 x 36, which fits both meshes. For v2 pass
  `--ntasks-per-node=3 --cpus-per-task=24`.
* 3 x 24 on v2 passes the rule even before 06 has measured anything, with N_eq from mesh.dat:
  3 x (31,322 + 43,147) = 223,407 MiB. So does 2 x 36 on v3: 2 x (39,283 + 53,820) = 186,206 MiB.

**Number of data for Vulcan.** The Vulcan data are impedance only: 8 real data per site per frequency
(real and imaginary parts of Zxx, Zxy, Zyx, Zyy). observe.dat has 120 sites x 21 bands (100 Hz to 797 s), so
**F = 21 and Nd = 20,160**. The table below also covers the F = 24-32 designs that were considered first.

The rank-0 dense terms, with M the number of free parameters (printed by 03, 04 and 06), in GB of 10^9 B:

| INV_METHOD | Rank-0 dense memory (from source) | Sensitivity files on disk per iteration |
|---|---|---|
| 0, model space (FEMTIC default) | 2 x Nd x M x 8 B transient, then Nd x M x 8 + M(M+1)/2 x 8 B | Nd x M x 8 B |
| 1, data space (CSIRO used this) | Nd^2 x 8 B, plus two per-frequency blocks of Nd_f x M x 8 B while it builds the matrix | 2 x Nd x M x 8 B (`sensMatFreq<f>` + `...Mod`) |

Worked example for Vulcan (Z only):

| F | Nd | M (free cells) | Model space, rank 0: transient / then | Data space, rank 0 | Sensitivity files (model / data space) |
|---:|---:|---:|---:|---:|---:|
| 24 | 23,040 | 25,000 | 9.2 / 7.1 GB | 4.2 GB | 4.6 / 9.2 GB |
| 24 | 23,040 | 100,000 | 36.9 / 58.4 GB | 4.2 GB | 18.4 / 36.9 GB |
| 24 | 23,040 | 200,000 | 73.7 / 196.9 GB (icelake only if nothing else is resident; else highmem) | 4.2 GB | 36.9 / 73.7 GB |
| 32 | 30,720 | 25,000 | 12.3 / 8.6 GB | 7.5 GB | 6.1 / 12.3 GB |
| 32 | 30,720 | 100,000 | 49.2 / 64.6 GB | 7.5 GB | 24.6 / 49.2 GB |
| 32 | 30,720 | 200,000 | 98.3 / 209.2 GB (icelake only if nothing else is resident; else highmem) | 7.5 GB | 49.2 / 98.3 GB |

**Recommendation:** use `INV_METHOD 1` (data space), as CSIRO did, whenever Nd is much smaller
than M, which is the Vulcan case for any M above a few tens of thousands. Data space rejects "free and
isolated" cells (type 3 in `resistivity_block_iter0.dat`), so FEMTIC exits with an error if the mesh has
any. `--gres=tmpfs:200G` holds data-space sensitivity files up to about M = 540k at F = 24 and M = 400k at
F = 32 (200 GB / (2 x Nd x 8 B)), before any headroom.

For Vulcan (F = 21, Nd = 20,160, data space): rank 0 needs Nd^2 x 8 B = 3.3 GB. The sensitivity files are
2 x Nd x M x 8 B = 21.1 GB (v2) or 22.1 GB (v3) per iteration.

**Choosing a layout for 1 node (72 cores):** pick the largest R_per_node that passes the layout rule, ideally one
that divides F, then threads = 72 / R. For Vulcan see the production layouts above. `RANKS=` and `THREADS=` run
fewer ranks or threads than the cpus bought for memory. Go to 2 nodes only if one node cannot hold enough ranks;
multi-node jobs also move the sensitivity files to /hpcfs (below).

**In-core or out-of-core:**

* `FWD_SOLVER 0` is in-core and is FEMTIC's default. It is fastest, but a job that exceeds `--mem`
  is killed.
* `FWD_SOLVER 1` picks per factorisation, going out-of-core when the need exceeds `MEM_LIMIT`
  (MB per rank, passed to MKL as `MKL_PARDISO_OOC_MAX_CORE_SIZE`). **FEMTIC's default MEM_LIMIT
  is 3000 MB**, which would push any realistic mesh out-of-core. `04` and `06` therefore set
  `MEM_LIMIT = (0.85 x --mem - RANK0_RESERVE_MB) / R_per_node - NONPARDISO_MB`. `RANK0_RESERVE_MB`
  is subtracted **only when control.dat has `HOLD_FWD_MEM`**; without it the rank-0 dense phase does not
  overlap the forward phase. `NONPARDISO_MB` (default `auto`, above) reserves each rank's sensitivity-step
  arrays. Values per rank:
  * v3, 2 ranks on icelake (254,952 MiB): 54,571 MB.
  * v2, 3 ranks on icelake: 29,127 MB.
  * v3, 7 ranks on highmem with `--mem=1900G` (1,945,600 MiB): 182,468 MB.

  Below 1 GB per rank `04` refuses to start. `MEM_LIMIT` does not bound the in-core solver: the layout rule
  does.
* `FWD_SOLVER 2` is always out-of-core.
* PARDISO's out-of-core files (`ooc_temp_3D_PE<rank>*`) are written to the **current directory**
  on /hpcfs, and no keyword moves them. Size the job to stay in-core. Use `FWD_SOLVER 1` as a
  safety valve, not as a plan. `04` warns if the logged in-core need exceeded MEM_LIMIT.
* `DIV_NUM_RHS_FWD > 1` (the manual's recommended starting value is 10) splits the multi-RHS PARDISO solve in
  the sensitivity step into that many calls. This lowers PARDISO's solve-phase workspace, at some cost in speed.
  `DIV_NUM_RHS_INV` does the same for the data-space model update only. Neither shrinks the arrays listed above.

**SENSE_MAT_DIRECTORY:** `04` points this at node-local `$TMPDIR/sense` for single-node jobs.
Because rank 0 reads every rank's files, a multi-node job must use shared storage, so `04`
switches to `/hpcfs/users/$USER/vulcan_femtic/scratch/sense_<jobid>` and deletes it afterwards.
Nothing is copied back from `$TMPDIR`, since these files are rewritten every iteration.
`$TMPDIR` exists in a job only with `--gres=tmpfs:<N>G` (04 asks for 200G; icelake, a100cpu and highmem nodes
offer tmpfs:2400G, and `TmpDisk=0`). Whether it is RAM-backed is a VERIFY item: 2,400 GB of it on a node
with 255 GB of RAM suggests disk, but read the `df -hT` line in the first 04 or 06 output. If `df -PT` reports
`tmpfs`, `04` adds the sensitivity files of one iteration to the layout rule (above).

## 7. Restart strategy and stopping before the 3-day limit

* FEMTIC writes `resistivity_block_iter<n>.dat` on rank 0 as soon as model n's forward response is
  accepted, line by line with `fprintf`, then `distortion_iter<n>.dat` when DISTORTION != 0. With
  `ITERATION "N M"` it reads `resistivity_block_iterN.dat`, plus `distortion_iterN.dat` whenever
  distortion is estimated, **including N = 0**. So `distortion_iter0.dat` must exist at the start.
* **Restart integrity (04 at job start, 05 at submission).** Before ITERATION is rewritten,
  `femtic_restart_pick` checks the highest `resistivity_block_iter<N>.dat`: its header `nElem nBlk` must equal
  iteration 0's, it must have exactly nElem element lines and nBlk block lines, and every block value must be a
  number; with DISTORTION != 0, `distortion_iter<N>.dat` must have exactly as many station lines as its count
  line (and as iteration 0). If N fails, 04 renames its files to `*.corrupt_<jobid>` and restarts from N-1
  (checked the same way); if N-1 also fails the job stops with exit 1. 05 runs the same check without renaming.
* **Stopping before the wall limit.** FEMTIC has no stop file and no signal handler (AnalysisControl.cpp),
  so any stop is a TERM from outside. `04` stops it at the safest point it can:
  1. **Safe point.** FEMTIC logs `# Start Inversion.  Iteration : N` only after it has written and closed
     model N. The watcher (`femtic_watch`, polling every 60 s) records these points in `logs/safe_points.tsv`.
     At a safe point, if the time left before the hard stop is less than 1.1 x the last iteration's duration
     (this job's or the previous job's), the next model cannot be written in time, and femtic is stopped
     at once. This loses nothing a restart from N would not redo anyway (the restart repeats model N's
     forward solve) and saves the SU of a doomed iteration.
  2. **Hard stop** `WALL_MARGIN_MIN` (20) minutes before the limit, whatever FEMTIC is doing. A model file cut
     by this is caught by the integrity check at the next start.
  3. **SIGUSR1** from Slurm 600 s before the limit (`--signal=B:USR1@600`), the last resort if the watcher had
     no deadline (squeue unavailable): the trap writes `logs/WALLTIME_<jobid>` and a `walltime_usr1` row in
     `job_outcomes.tsv`, then stops femtic; the post-run block still runs.

  At the limit itself Slurm sends TERM and, after KillWait = 30 s (verified), KILL; the three stops above
  are what keep the model files intact.
* **Outcome and exit code** (one row per job in `job_outcomes.tsv`):

| Situation | Marker | Exit | Chain (afterok) |
|---|---|---:|---|
| `# Converged.` and femtic exit 0 | `logs/COMPLETED_<jobid>`, `CONVERGED` | 0 | later jobs exit at once |
| `# Reach maximum iteration number.` and exit 0 | `logs/COMPLETED_<jobid>` | 0 | continues |
| `# Reach maximum retrial number.` and exit 0 | `logs/COMPLETED_<jobid>`, `STALLED` | 2 | cancelled |
| stopped by the script after >= 1 new valid model | `logs/stop_reason_<jobid>` | 0 | continues |
| stopped with no new valid model | `logs/stop_reason_<jobid>` | 3 | cancelled (resize) |
| femtic exit 0 but no end line in femtic_0.log (silent death) | none | 1 | cancelled |
| femtic non-zero exit, or no valid restart model | none | non-zero | cancelled |

* `05_chain.sh` submits K copies of `04` with `AUTO_RESTART=1`, chained with
  `--dependency=afterok:<previous>` and `--kill-on-invalid-dep=yes`, using `--parsable` for the ids.
  A non-zero exit cancels the rest of the chain, so failures are not repeated at thousands of SU each.
* `05_chain.sh` needs a layout and refuses to start without one. It reads `<inversion_dir>/LAYOUT`, which 06
  writes when T6 passes under the full memory rule (`sbatch=` line: `-p`, `-N`, `--ntasks-per-node`,
  `--cpus-per-task`, `--mem` of that 06 job; `export=` line: `RANKS`/`THREADS` if set). An explicit
  `SBATCH_EXTRA` with both `--ntasks-per-node` and `--cpus-per-task` takes precedence; one of the two alone is
  refused. Without this rule a v2 chain on the 04 header (2 x 36) would run 2 ranks, not 3.
* Each restart costs one repeated forward solve (model N is re-evaluated). The step-length damping
  also restarts at its `STEP_LENGTH` initial value, so a restarted run can differ slightly from an
  uninterrupted one. Test T5 measures this on FEMTIC's example.
* FEMTIC truncates `femtic.cnv` and `femtic_<rank>.log` at every start. `04` moves them into
  `logs/run_<timestamp>/` first. To get the full history, run
  `cat logs/run_*/femtic.cnv femtic.cnv | awk '$1!="Iter#"'`.
* Choose ITER_STEP as roughly (72 h - 0.5 h - T_forward) / T_iteration, from 06 and T4. Too large is safe:
  the watcher stops the job at a safe point and it hands on. Too small wastes queue time.

## 8. EasyBuild fallback (not needed: the central modules exist)

Discovery found `foss/2023a`, `imkl/2023.1.0` and `intel/2023a` centrally and all of them load, so nothing
has to be built with EasyBuild. This section is kept only in case those modules are retired.
Phoenix has EasyBuild 4.5.5 to 5.3.0 (4.9.4 among them); `00_discover.sh` loaded 5.3.0, the newest. Its robot
path `/apps/icl/software/EasyBuild/5.3.0/easybuild/easyconfigs` contains `imkl-2023.1.0.eb` (SYSTEM
toolchain) and `intel-2023a.eb` (`eb -S`, 2026-09-25). EasyBuild 5.3.0 runs on the system Python 3.6.8 with a
deprecation warning, and its default install, build and source paths are under
`/home/a1690074/.local/easybuild` (the 10 GB home), so `EASYBUILD_PREFIX` must be set.

```bash
module load EasyBuild/5.3.0
export EASYBUILD_PREFIX=/hpcfs/users/$USER/easybuild
export MODULEPATH=$EASYBUILD_PREFIX/modules/all:$MODULEPATH
eb imkl-2023.1.0.eb --robot -Dx     # dry run
eb imkl-2023.1.0.eb --robot         # binary installer l_onemkl_p_2023.1.0.46342_offline.sh, no compile
module load foss/2023a imkl/2023.1.0
# whole Intel toolchain if it is ever missing (hours): eb intel-2023a.eb --robot
```

`01` and `femtic_env.sh` run `module use` on the prefix automatically when it exists. EasyBuild downloads
run on the login node or in an interactive job (internet); otherwise pre-place the installer in
`$EASYBUILD_PREFIX/sources/i/imkl/`.

## 9. What was verified, and how

| Item | Status |
|---|---|
| Phoenix partitions, cpus, RAM per node, MaxMemPerCPU, MaxCPUsPerNode, walltimes, billing weights, QoS and account limits, fair-share, SU grant, Slurm settings, srun MPI plugins, node hardware | `00_discover.sh` on p2-log-2, 2026-09-25 (`sinfo`, `scontrol`, `sacctmgr`, `sshare`, `rcquota`, `lscpu`); `discovery/phoenix_discovery_p2-log-2_2026-09-25.txt` |
| Planned requests (04/06 default, 03 on icelake and interactive, 2 icelake nodes, highmem `--mem=1900G`; `--mem=250G` and a100cpu 72 cpus rejected) | `sbatch --test-only` in the same run (nothing submitted) |
| Toolchain modules: foss/2023a + imkl/2023.1.0 and intel/2023a load; MKLROOT and its libraries; mpicxx = OpenMPI 4.1.5 around g++ 12.3.0; mpiicpc present, mpiicpx and mpiicx absent | Load tests A and B in the same run |
| Login-node tools (gcc 8.4.1, git 2.27, curl, internet, `ulimit -s`), storage path, micromamba 2.9.0 and its envs | The same run |
| Easyconfig filenames at the v4.9.4 tag; imkl module sets MKLROOT | Read on GitHub (v4.9.4); Phoenix's EasyBuild 5.3.0 robot path also has `imkl-2023.1.0.eb` and `intel-2023a.eb` (`eb -S`) |
| intel-compilers 2023.1.0 has icpc | Seen on Phoenix (`icpc` in intel/2023a, with the #10441 deprecation remark). Removal in oneAPI 2024.0 comes from Intel's notice. |
| OpenMPI 4.1 `--map-by ...:PE=n` syntax | open-mpi.org v4.1 mpirun man page (upper-case `PE`) |
| rdp, pyproj, shapely, pyvista on conda-forge | anaconda.org API (rdp 0.8) |
| UTM 53S self-test values in 02 | pyproj on Windows: (135 E, 30 S) -> 500,000.00 E, 6,681,214.65 N; Vulcan A1 within 1 m of `edi_inventory.md` |
| FEMTIC runtime behaviour (control.dat parsing, defaults, restart files and their write order, log strings, rank-0 reads, OOC file location, frequency split, cell types, no stop hook, `ITERATION 0 0` skips sensitivities, `HOLD_FWD_MEM` is a bare keyword) | Read in `femtic/src` at commit 26c8606 |
| Script logic | WSL (GNU bash 5.2, sed 4.9, gawk 5.2) harnesses in `validation/wsl_2026-09-25/scripts/`, run 2026-09-25 against these files: `libtest_v2.sh` 48/48 checks (library, incl. restart check and fallback, trapped-signal wait, TERM-to-KILL stop); `chaintest_v2.sh` 22 scenarios, 89/89 checks (mock Slurm for 04, 05, 06: chaining, restart fallback and quarantine, DISTORTION fallback, silent exit-0 death, COMPLETED marker, SIGUSR1 trap, safe-point stop, T6 pass and fail); `unit2_v2.sh` 12/12 (T5 comparator, 03 region/poly/ele logic); `fetchtest_v2.sh` 14/14 (01 tarballs, git-free tree, pin mismatch, no fetch in compute jobs). Each harness was shown able to fail: 8 deliberately broken copies of the scripts were all caught. `bash -n` clean; shellcheck 0.11 clean at warning level. The v1 harnesses are kept unchanged as the record of the earlier run |
| Smoke-test hardening of 01 and femtic_lib.sh (2026-09-25, after the two failed smoke jobs) | WSL, runner `smokefix_run_all.sh`, outputs `test_outputs/smokefix_*.out`. The four harnesses above re-run unchanged: 48/48, 89/89, 12/12, 14/14 (chaintest: 89/89 in 3 of 4 runs; one run gave 86/89 when its timing-based S19 safe-point scenario stopped one iteration early under WSL load, in code this change did not touch: `test_outputs/smokefix_chaintest_v2_NOTE.txt`). New: `smokeonly_test.sh` 70/70 (`SMOKE_ONLY=1` with no git, make or compiler on PATH; fake femtic, mpirun and ldd; `femtic_env.sh` written by 01's own section 4; T1 "not found", T5 failure, missing inputs, a second run in the same second; a node without `/apps` with and without the remap, and an icelake-like node, in a private mount namespace), `gitfree_head_test.sh` 28/28 (commit from `.git/HEAD`, loose and packed refs, dangling ref, `COMMIT_SHA.txt` fallback and recording, never "No such file"), `build_guards_test.sh` 34/34 (make missing, versioned MKL names, `/apps` and `/gpfs/apps` fallback both ways, diagnostics), `apps_remap_test.sh` 33/33 (`femtic_apps_remap`). All four also pass under bash 4.4.12 (RHEL 8.4 ships bash 4.4). 13 broken copies (9 single-edit mutants, and the pre-change kit against each new harness) were all caught. shellcheck 0.11: no warning-level finding, no new info-level one |
| PARDISO parser, two-array memory model, layout rule, FEMTIC_LIB_VERSION 3 gates, 06 half-space gate (2026-09-28) | `tests/c1c2_test.sh` (Git Bash 5.2, gawk 5.0; fake femtic, mpirun and Slurm) on a v3-sized inversion directory: 71/71 on the edited kit. Against a copy of the pre-change kit (commit 55bbf44) it fails 53 of 71 checks, as it should, including: `1.23456e+06` KB read as 11.8 GiB and `1.5e+08` as 0.0; the one-array sum of 28.99 GB; 8 x 9 launched; the fa58604 library (version 2, 18,193 B) accepted by 03/04/05/06 and 01 `SMOKE_ONLY`. The 18 it passes are the cases the old code got right, e.g. `2.74856e+07` and plain integers. A mutant with a fixed 33,000 MiB forward fallback fails 3 (the small-mesh check). The 09-25 harnesses under Git Bash, old kit vs new: `libtest_v2.sh` 46/48 on both (the same 2 Git Bash artefacts: CRLF left by msys sed, USR1 = 30); `chaintest_v2.sh` 89/89 vs 87/89. The 2 new failures encode the old model and are intended: S1 expects MEM_LIMIT 16848 from `NONPARDISO_MB=10240` (now 26908 with `auto` on the tiny example), and S21 expects the one-array "interpolator ... = 4.61 GB" line. `tests/halfspace_eval_test.sh`: 31/31. `tools/halfspace_eval.py` reproduces all 7 stored `acc_eval_*.txt` reports of the WSL gate band for band and verdict for verdict (2 FAIL, 5 PASS; e.g. v3 100 ohm-m worst rho_a 2.91 % at Vul24-19, v2 3 ohm-m diagonal 2.09 % at G7). It FAILS a copy with one Re(Zxy) raised 10 % (worst rho_a 11.99 % at that site and band), a copy with one row missing, and the right data judged at the wrong resistivity. |
| Kit follow-ups (2026-09-28, later): 06 walltime 4 h, `LAYOUT` hand-over from 06 to 05, 06's outcome-row exit code, site names in the gate report, N_iv behind FEMTIC's `DIV_NUM_RHS_FWD` warning, FEMTIC_LIB_VERSION 4, bash 4.4 / Python 3.6 portability | `tests/c1c2_test.sh` (Git Bash 5.2, gawk 5.0; fakes): 129/129 on the edited kit, sections (d) and (f). Seven mutants of the edited kit, each with one guard switched off, fail the checks written for that guard: the version-3 `femtic_niv_measured` (f1, f2), the T6-only exit column (f3), no `--station-map` (e2), `--time=02:00:00` (f5), no "no layout" refusal (f6a), no `LAYOUT` write (f6d, f6f), no half-layout refusal (f6b, f6h). Against the pre-edit kit it fails 28 of 129, all in the new checks (d3, d4, f1-f6). `tests/portability_test.sh`: 6/6, and 10/10 with Python 3.9.23 (the oldest local interpreter) as `PYTHON_OLD`. No construct newer than bash 4.4 or gawk 4.2 in the 10 shell files. `ast.parse(feature_version=(3, 6))` passes, but that call does not reject the f-string `=` specifier, PEP 701 f-strings or `from __future__ import annotations` (probed on 3.13.5), so the test adds an AST walk; it found 11 of 11 injected constructs and 5 of 5 injected bash/gawk ones. It also found every text-mode `open()` without `encoding=` (4 in the pre-edit evaluator), and the pre-edit evaluator crashed with UnicodeEncodeError on a non-ASCII site name with ASCII stdout (Python 3.6 under `LANG=C`). `tests/halfspace_eval_test.sh`: 31/31 on Python 3.13.5 and on 3.9.23. **Not run on Phoenix's bash 4.4.19 or Python 3.6.8 itself**: run `bash tests/portability_test.sh` and `bash tests/c1c2_test.sh` on p2-log-2 after B1. |
| Building on Phoenix | Done on p2-log-2, 2026-09-25: all 7 tools, T1 PASS (`discovery/phoenix_build_foss_2026-09-25.log`) |
| Running FEMTIC on Phoenix (T2/T5 and later) | **Not done yet** (section 3, step 5). The remaining unverified items are listed at the end of section 10. |

## 10. Validation tests and their failure criteria

| Test | Where | Fails if |
|---|---|---|
| T1 linkage | 01 (after the build, and with `SMOKE_ONLY=1`) | `ldd femtic` lacks libmkl_core or libmkl_intel_ilp64, shows "not found", or mixes OpenMP runtimes (foss: must have libgomp and mkl_gnu_thread and no libiomp5; intel: the reverse) |
| T2 smoke | 01 `SMOKE_ONLY=1` batch job (or `SMOKE=1` on the login node) | FEMTIC example INV_MT_01/Tetra (2 ranks x 2 threads, ITERATION 0 2) exits non-zero or does not write `resistivity_block_iter2.dat` |
| T5 restart equivalence | as T2 | The 0 to 1 then 1 to 2 restart through `femtic_ctl_set` and `femtic_last_iter` does not start at iteration 1, or its misfit differs from the straight run by more than 1e-4 (iteration 1) or 1e-3 (iteration 2) relative. Reported INCONCLUSIVE, not PASS, if a retrial or damping change occurred. The tolerance covers the 7-digit `%15e` model file. A wrong-model restart differs by tens of percent. |
| Cross-platform check | manual | The iteration-0 row of the Phoenix smoke run disagrees with the WSL build's run of the same example in the first 6 significant digits |
| T3 mesh | 03 | `resistivity_block_iter0.dat` line counts disagree with its header, or a region-seed attribute is missing from `resistivity_attr.dat` |
| Layout rule | 04 and 06, before femtic starts | ranks per node x (FWD_MB + NONPARDISO_MB) + EXTRA > 95 % of `--mem` (section 6): the job is refused, exit 1 |
| T6 forward only | 06 | femtic exits non-zero; no FEMTIC end line in femtic_0.log; the per-frequency times over all ranks do not number exactly F; or the sampled peak node RSS exceeds 90 % of `--mem` |
| Half-space gate | 06 with `START_RHO=3` and `START_RHO=100` | At any site and band of observe.dat: \|rho_a/rho - 1\| > 5 %, \|phase - 45 deg\| > 1.5 deg, max(\|Zxx\|,\|Zyy\|)/\|Zxy\| > 2 %, or a missing row (`tools/halfspace_eval.py`; 06 exits 4, and its `job_outcomes.tsv` row has exit 4) |
| T4 test inversion | 04 with ITERATION 0 1 | Non-zero exit, no `logs/COMPLETED_<jobid>`, a warning that PARDISO went out-of-core, a rank-count warning, a measured N_iv that differs from the one the layout rule used, `sacct` MaxRSS per rank more than 20 % off the predicted total (section 6), or rcstat CPU efficiency under about 50%. Record time per iteration, peak PARDISO per rank, peak node RSS, sensitivity scratch and MaxRSS. |
| Restart integrity | 04 / 05 at every start | Neither the highest model nor the one before passes `femtic_restart_pick` |
| Chain layout | 05 before any `sbatch` | No `LAYOUT` file from a passing 06 and no explicit `SBATCH_EXTRA` layout, or only half of one: refused, exit 1, nothing submitted |

**Still unverified after the 2026-09-25 discovery** (the only VERIFY items left in the kit; each says how
it gets settled):

1. **`$TMPDIR` type** (04 header, section 6): RAM-backed or disk? The `df -hT` line in the first 06 or 04
   output answers it. 2,400 GB of `tmpfs` gres on a 255 GB node suggests disk. If it is RAM, the
   sensitivity files count against `--mem`; `04` then adds them to the layout rule.
2. **Elapsed or requested time charged** (section 5): compare `rcstat <jobid>` with the elapsed time of the
   first real job. Billing is CPU-only either way.
3. **`I_MPI_PMI_LIBRARY=/usr/lib64/libpmi2.so`** (`femtic_lib.sh`): only for `TOOLCHAIN=intel` with
   `USE_SRUN=1`. OpenMPI was configured `--with-pmi-libdir=/usr/lib64`, which suggests the library is there;
   `ls /usr/lib64/libpmi2.so` on a compute node settles it.
4. **The intel route has never been compiled.** Verified: intel/2023a loads, `mpiicpc` and `icpx` exist,
   `mpiicpx` does not. Not verified: that `mpiicpc -cxx=icpx` compiles and links FEMTIC (T1/T2 with
   `TOOLCHAIN=intel`). It is the fallback only.
5. **`--qos=long` for more than 3 days**: fair-share 0.593 is above the threshold, but the association lists
   only QoS `normal`, and icelake's MaxTime is 3 days. Test with
   `sbatch --test-only --qos=long -p icelake -N 1 --ntasks-per-node=8 --cpus-per-task=9 --mem=254952M --time=7-00:00:00 --wrap=true`.
6. **Partial-node memory:** 36 icelake cpus with `--mem=254952M` (more than 36 x 3541) was accepted. Whether
   Slurm then allocates and bills 72 cpus is unknown, so request the cpus explicitly.
7. **Per-user /hpcfs quota:** `rcquota` printed only SU. The filesystem has 366 TB free.
8. **Interactive partition cost:** "free" comes from the wiki. Slurm sets no `TRESBillingWeights` there,
   so check `rcstat` after the first interactive job. At most 8 cpus per job, so the stakes are small.
9. **Multi-node MPI** (UCX 1.14.1 / libfabric 1.18.0 in OpenMPI 4.1.5): 2 icelake nodes were accepted by
   `sbatch --test-only`, but no multi-node run has been made. Only relevant if one node is not enough.
10. **Internet on compute nodes:** not tested and not needed, because the kit never fetches inside a batch job.

## 11. Data provenance: site coordinates

Site coordinates for femticPy / FEMTIC (`observing_site.dat`, `obs_site.dat`, `observe.dat`) must come
**only** from `Vulcan/site_coords_femticpy.txt` (site, easting km, northing km, elevation km; WGS84 UTM zone 53S).
That file was made from each EDI's HEAD block with the **Geotools floor-DMS reading** (D + M/60 + S/3600),
not from the INFO block. Under the floor reading HEAD and INFO agree except at C5, D2 and E1, whose INFO
positions are 2.0 to 3.0 km off and are judged wrong; under the standard DMS reading all 120 headers disagree
with INFO (`Vulcan/edi_inventory.md`).
**Never re-derive coordinates by re-parsing EDI headers with standard tools** (mtpy or any conventional DMS
parser): a standard parser silently shifts every site. If a femticPy prep notebook takes site positions from
the EDI files, overwrite them with `site_coords_femticpy.txt` before writing `observe.dat` and the meshGen
site files. If coordinates are needed in another form, convert `site_coords_femticpy.txt` itself (EPSG:32753)
and check one site against `edi_inventory.md`.

## 12. Discovery results (`00_discover.sh`, p2-log-2, 2026-09-25)

Full output: `discovery/phoenix_discovery_p2-log-2_2026-09-25.txt` (next to these scripts). Answers to the
questions this section used to ask:

1. **Module names:** `module load foss/2023a imkl/2023.1.0` loads and sets
   `MKLROOT=/apps/icl/software/imkl/2023.1.0/mkl/2023.1.0`. `intel/2023a` loads. The gompi-suffixed imkl
   variant does not exist. `01`'s defaults match, so no `MODS=` is needed.
2. **mpiicpx:** absent (so is mpiicx); `mpiicpc` is present. The intel route uses `mpiicpc -cxx=icpx`.
3. **Requests** (`sbatch --test-only`): accepted: 04 default of the time (icelake, 8 x 9, `--mem=254952M`,
   `--gres=tmpfs:200G`, 3 days), 06 (2 h), 03 on icelake and on interactive, 2 icelake nodes, highmem
   `--mem=1900G`, and 36 icelake cpus with `--mem=254952M`. Rejected: `--mem=250G` on icelake, and a100cpu
   72 cpus with `--mem=514944M` (MaxCPUsPerNode=36).
4. **`$TMPDIR`:** unset on the login node; in jobs it exists only with `--gres=tmpfs`. Whether it is RAM or
   disk is still open (section 10, item 1).
5. **Billing:** CPU-only (`TRESBillingWeights=CPU=1.20` icelake and a100cpu, `CPU=2.5` highmem). Elapsed
   or requested time is still open (section 10, item 2).
6. **srun:** `srun --mpi=list` gives pmi2, none and cray_shasta (no pmix), with MpiDefault=none. So
   `USE_SRUN=1` means `srun --mpi=pmi2` (now the kit's default). OpenMPI 4.1.5 is built `--with-slurm --with-pmi`
   (PMIx 4.2.4; `ess slurm`, `pmix s1/s2` components), so the default `mpirun` needs nothing. The
   `I_MPI_PMI_LIBRARY` path is still open (section 10, item 3).
7. **git and curl on the login node:** git 2.27.0 and curl 7.61.1, with internet (github 200,
   micro.mamba.pm 307, conda-forge 200).
8. **Quota and storage:** `/hpcfs/users/a1690074` = `/scratchdata1/users/a1690074` on gpfs-2-1 (1.9 PB,
   82 % used, 366 TB free). The per-user quota was not reported (section 10, item 7). SU: grant 1,299,444,
   used 320,879 (24.7 %), 94.5 % of the quarter lapsed.
9. **Interconnect:** OpenMPI 4.1.5 has UCX 1.14.1 and libfabric 1.18.0, but it is untested across nodes
   (section 10, item 9).
10. **Vulcan choices** that decide the layout are still Ben's: F (section 6), M from the 03 report,
    INV_METHOD, DISTORTION.
11. **Python:** micromamba 2.9.0 is already at `/hpcfs/users/a1690074/micromamba/bin/micromamba`, with the
    envs base and gjoint; femticpy does not exist yet, and `02` creates only that env.

## Sources

* Phoenix discovery (the verified facts): `D:\BEN\FEMTIC_2026\hpc\phoenix_plan\discovery\phoenix_discovery_p2-log-2_2026-09-25.txt`
  (on Phoenix: `/hpcfs/users/a1690074/FEMTIC_2026/hpc/phoenix_plan/discovery/`)
* Earlier Phoenix census: `D:\BEN\3D_Joint_Inversion_2026\benchmarks\phoenix\README.md` and `node_census_p2-log-2_2026-09-25.txt`
* easyconfigs v4.9.4: https://github.com/easybuilders/easybuild-easyconfigs/tree/easybuild-easyconfigs-v4.9.4/easybuild/easyconfigs (`i/imkl`, `i/intel`, `i/intel-compilers`, `i/impi`, `f/foss`)
* easyblocks v4.9.4: https://github.com/easybuilders/easybuild-easyblocks/tree/easybuild-easyblocks-v4.9.4/easybuild/easyblocks (`i/imkl.py`, `i/intel_compilers.py`, `i/impi.py`, `generic/intelbase.py`)
* Intel C++ Compiler Classic removal notice: https://community.intel.com/t5/Intel-oneAPI-DPC-C-Compiler/REMOVAL-NOTICE-Intel-C-Compiler-Classic/m-p/1545804
* OpenMPI 4.1 mpirun: https://www.open-mpi.org/doc/v4.1/man1/mpirun.1.php
* conda-forge rdp: https://anaconda.org/conda-forge/rdp
* micromamba: https://micro.mamba.pm (static binary, as in Ben's `bootstrap_env.sh`)
