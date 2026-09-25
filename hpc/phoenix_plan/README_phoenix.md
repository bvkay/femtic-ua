# FEMTIC on Phoenix: deployment plan for the Vulcan MT survey

FEMTIC v5.0: 3-D MT inversion in C++ with MPI, OpenMP and Intel MKL PARDISO.
Target: University of Adelaide Phoenix (Slurm, Lmod, EasyBuild software stack). User `a1690074`, account `physci`.
Survey: 120 sites over about 13 x 15 km (UTM zone 53S), **impedance only (no tipper)**, tetrahedral mesh, target under 500k elements.

Nothing here has been run on Phoenix. The cluster facts in section 1 were verified with `sinfo`, `sacctmgr`
and `module avail` on 2026-09-25 (Ben's census in `3D_Joint_Inversion_2026/benchmarks/phoenix/`) and replace
the university wiki, which is stale in places. The toolchain module names (VERIFY on Phoenix: foss/2023a, imkl/2023.1.0,
intel/2023a and their parts) are **not** verified and are marked **VERIFY on Phoenix** wherever they appear.
Run `00_discover.sh` first; section 12 lists what it must confirm.

## 0. Files

| File | Where it runs | Purpose |
|---|---|---|
| `00_discover.sh` | login node | Read-only survey: toolchain modules (`module avail foss imkl intel GCC OpenMPI impi`, `module spider imkl`), load tests, per-partition memory caps, billing weights, git/curl/internet, micromamba. Validates the planned requests with `sbatch --test-only`, which submits nothing. |
| `01_build_femtic.sh` | login node (`FETCH_ONLY=1`), then an interactive session | Gets the 7 sources pinned to audited commits (git clone, pre-copied git-free trees, or GitHub tarballs; never inside a compute job), builds them with the ported Makefiles, installs to `$BIN`, writes `femtic_env.sh`. Runs tests T1, T2 and T5. |
| `femtic_lib.sh` | sourced | Shared helpers: control.dat edits, restart-model integrity check and fallback, the wall-limit watcher, launch command, log parsing. Installed to `$BIN`. |
| `02_env_femticpy.sh` | login node or interactive job | micromamba under `/hpcfs/users/$USER/micromamba` and the env `femticpy` from `environment_femticpy.yml` (written next to the script). Self-test includes a UTM 53S check. |
| `03_mesh.slurm` | icelake (8 cpus) or interactive | The 7-step meshGen, then test T3 (mesh consistency) and sizing inputs. |
| `06_forward_only.slurm` | icelake, 1 node, 2 h | **First Phoenix job on the real mesh (T6).** One forward solve (`ITERATION 0 0`) in the production layout: forward time per frequency, PARDISO memory per rank, peak node RSS, and a short report. |
| `04_inversion.slurm` | icelake, 1 node (a100cpu / highmem optional) | Hybrid MPI/OpenMP inversion: control.dat rewrite, validated restart, safe-point stop before the wall limit, COMPLETED marker, sizing report. |
| `05_chain.sh` | login node | Submits K dependent 3-day jobs that continue from the last valid iteration. |

The ported Makefiles are in `D:\BEN\FEMTIC_2026\hpc\ported\` and are copied to `$SRC/ported/`. `01` uses
`femtic/Makefile.gcc_openmpi_mkl` or `femtic/Makefile.intel_oneapi`, `makeTetraMesh/Makefile.gcc_mkl` or
`makeTetraMesh/Makefile.intel_oneapi`, and `Makefile.gcc` for makeMtr, TetGen2Femtic, makeDHexaMesh and
mergeResultOfFEMTIC. tetgen builds with its upstream makefile, keeping `PREDCXXFLAGS=-O0`.

## 1. Phoenix facts this plan relies on (verified 2026-09-25)

| partition | nodes | cpus / node | RAM / node (MiB) | RAM / cpu (MiB) | walltime | SU per cpu-hour | use here |
|---|---:|---:|---:|---:|---|---:|---|
| `batch` | **0** | - | - | - | - | - | **never use** (`batch up infinite 0 0 0`) |
| `icelake` | 93 | 72 | 255,000 | 3541 | 3 days | 1.2 | default for 03, 04, 06 |
| `newicelake` | 5 | 72 | 255,000 | 3541 | 3 days | 1.2 | same as icelake |
| `a100cpu` | 43 | 72 | 515,000 | 7152 | 3 days | 1.2 | memory-heavy 04 at the same price; CPU-only jobs allowed (the wiki's "36 cpus" is stale) |
| `highmem` | 7 | 72 | 1,990,000 | not recorded (VERIFY) | 3 days | 2.5 | only if a job needs more than about 490 GB |
| `interactive` | 2 (`p2-dmv-*`) | 72 | 255,000 | oversubscribed | 21 days | free | build, smoke tests, mesh; max 8 cpus per job and 24 per user; has internet |
| `dm` | 2 | 72 | 255,000 | - | - | free | transfers |

* **RAM is granted per cpu.** `--mem` is capped at cpus x (MiB per cpu) of the partition, so memory is bought
  with cpus. A whole icelake node is 72 cpus and at most 72 x 3541 = **254,952 MiB** (`--mem=254952M`);
  a whole a100cpu node is 72 x 7152 = **514,944 MiB** (`--mem=514944M`). `--mem=250G` means 256,000 MiB
  (Slurm's G is 1024 MiB), which is over the icelake cap. For a partial node, cpus = ceil(MiB needed / MiB per cpu).
  The older "DefMemPerCPU or MaxMemPerCPU 2413 MiB on batch" question is moot.
* **Whole nodes are allowed:** QoS `normal`, account `physci`, no MaxJobs or MaxTRES limits.
* **Budget is not the constraint; walltime is.** `rcquota` showed about 980k unused SU this quarter. Every
  CPU partition has a 3-day limit, which is why 04 restarts and 05 chains.
* **Modules:** Lmod; `/gpfs/apps/icl/modules/all` uses full EasyBuild names with toolchain suffixes
  (`CMake/3.26.3-GCCcore-12.3.0`, `Python/3.11.3-GCCcore-12.3.0`, `Boost.Python-NumPy/1.82.0-gfbf-2023a`,
  `SuiteSparse/5.10.1-foss-2021b-METIS-5.1.0`, `Anaconda3/2025.06-1` (default)). So the 2021b, 2023a and
  2025a EasyBuild generations exist, but (VERIFY on Phoenix) whether `foss/2023a`, `imkl/2023.1.0` and `intel/2023a` exist
  was not in the census: `00_discover.sh` checks.
* **CPUs:** the login node p2-log-2 is an Icelake Xeon Platinum 8360Y with SMT on (144 logical cpus);
  compute nodes have SMT off, so 72 cpus = 72 cores.
* **Internet:** login node and the interactive partition have it; compute nodes may not. `git clone`,
  downloads, micromamba and conda-forge therefore run on the login node or in an interactive job only.

## 2. Workflow and directory layout

Ben's established Phoenix workflow, which these scripts follow:

* Files go to `/hpcfs/users/a1690074/<project>` by **WinSCP**. There is **no git** on the Phoenix tree, and
  every script tolerates a git-free tree (01 reads `COMMIT_SHA.txt` or GitHub tarballs instead).
* **LF line endings.** All files here are LF. If a copied script fails at the shebang (`bad interpreter: ^M`),
  run `dos2unix *.sh *.slurm`. `05` refuses a CRLF job script.
* **Python via micromamba** under `/hpcfs/users/$USER/micromamba` (not the Anaconda module).
* **Job conventions** (03, 04, 06): `#SBATCH -o slurm-%x-%j.out`; `--mail-type=END,FAIL` to
  `ben.kay@adelaide.edu.au`; `--signal=B:USR1@600` with a trap that writes `logs/WALLTIME_<jobid>` and a
  `job_outcomes.tsv` row; knobs such as `THREADS` and `RANKS` through `--export=ALL,...`; a
  `logs/COMPLETED_<jobid>` marker only on a verified normal end, so a silent exit-0 death counts as FAIL;
  and `rcstat <jobid>` at the end of every job.

```
/home/$USER/                          10 GB cap: nothing from this plan
/hpcfs/users/$USER/                   1 TB: all builds and all jobs
  phoenix_plan/                       these scripts (00..06, femtic_lib.sh, environment_femticpy.yml)
  micromamba/                         MAMBA_ROOT_PREFIX (also holds Ben's gjoint env)
  femticPy/                           femticPy tree (WinSCP copy or clone; notebooks and prep scripts)
  femtic_src/                         $SRC: the 7 upstream sources (build objects land here)
    ported/<tool>/Makefile.*          copied from hpc/ported/
    tarballs/                         optional GitHub archives <repo>-<sha>.tar.gz (git-free route)
    build_<toolchain>_<date>.log      build logs; smoke_<toolchain>_<date>/ holds the T2/T5 runs
  femtic/bin/                         $BIN: femtic makeTetraMesh tetgen makeMtr TetGen2Femtic
                                      makeDHexaMesh mergeResultOfFEMTIC femtic_env.sh femtic_lib.sh
  easybuild/                          EASYBUILD_PREFIX, only if the fallback (section 8) is needed
  vulcan_femtic/
    input_data/                       topography.dat bathymetry.dat coast_line.dat ...
    meshGen/files/                    control.dat analysis_domain.dat observing_site.dat obs_site.dat
                                      makeMtr.param resistivity_attr.dat [regions.txt]; logs/ job_outcomes.tsv
    inversion/inv01/                  control.dat observe.dat mesh.dat resistivity_block_iter0.dat
                                      [distortion_iter0.dat] logs/ fwd0_<jobid>/ job_outcomes.tsv chain_jobs.txt
    scratch/                          shared sensitivity scratch, multi-node jobs only
```

## 3. Order of work

1. From Windows, copy `hpc/phoenix_plan/` and `hpc/ported/` with WinSCP to `/hpcfs/users/a1690074/`. On Phoenix:
   `mkdir -p femtic_src && mv ported femtic_src/`. Run `dos2unix` only if a shebang fails.
2. `cd /hpcfs/users/$USER/phoenix_plan && bash -l 00_discover.sh`. Read the KEY FINDINGS block and fix the
   module names in `01_build_femtic.sh` if needed (or pass `MODS="..."`).
3. Sources, on the **login node**: `FETCH_ONLY=1 bash -l 01_build_femtic.sh`. Without git it downloads the
   GitHub archives of the pinned commits with curl. Alternatively download
   `https://github.com/<owner>/<repo>/archive/<sha>.tar.gz` on Windows and WinSCP the files to `femtic_src/tarballs/`.
4. Build in an interactive session: `srun -p interactive -N 1 -n 8 --mem=16GB --time=04:00:00 --pty bash`,
   then `TOOLCHAIN=foss bash -l 01_build_femtic.sh`. It must end with `T1=PASS T2=PASS T5=PASS`, or
   `T5=INCONCLUSIVE` (see section 10).
5. `bash 02_env_femticpy.sh` (login node), then prepare the Vulcan inputs with the femticPy notebooks.
   Site coordinates come only from `Vulcan/site_coords_femticpy.txt` (section 11).
6. Mesh: `cd .../vulcan_femtic/meshGen && sbatch ../../phoenix_plan/03_mesh.slurm` (19.2 SU), or
   `sbatch -p interactive ../../phoenix_plan/03_mesh.slurm` (free). T3 must pass.
7. **Forward-only job (T6), the first thing to run on Phoenix after the build and the mesh:**
   `cd .../inversion/inv01 && sbatch ../../../phoenix_plan/06_forward_only.slurm` (at most 172.8 SU).
   Read `logs/fwd0_report_<jobid>.txt`: forward time per frequency, PARDISO per rank, peak node RSS,
   predicted sensitivity-step and rank-0 memory. Change the layout (ranks x threads, partition) here, before
   any inversion is submitted.
8. **Test inversion (T4):** set `ITERATION` to `0 1` in `inversion/inv01/control.dat` and run
   `sbatch --time=12:00:00 ../../../phoenix_plan/04_inversion.slurm` (at most 1,036.8 SU). Read the sizing
   report and `rcstat`, then choose ranks, threads and ITER_STEP (section 6).
9. Production: `bash -l ../../../phoenix_plan/05_chain.sh $PWD 3 <ITER_STEP> <ITER_MAX>`.

After every job: `rcstat <jobid>` (also printed at the end of `slurm-<jobname>-<jobid>.out`).

## 4. Build path per toolchain

| | `TOOLCHAIN=foss` (default, recommended first) | `TOOLCHAIN=intel` |
|---|---|---|
| Modules (VERIFY on Phoenix) | `foss/2023a imkl/2023.1.0` (or `imkl/2023.1.0-gompi-2023a`) | `intel/2023a` |
| Contents (EasyBuild v4.9.4 easyconfigs; VERIFY on Phoenix) | GCC 12.3.0, OpenMPI 4.1.5, FlexiBLAS 3.3.1, FFTW 3.3.10, ScaLAPACK 2.2.0 + oneMKL 2023.1.0 | intel-compilers 2023.1.0, impi 2021.9.0, imkl 2023.1.0, imkl-FFTW, GCCcore 12.3.0 |
| FEMTIC compiler | `mpicxx` (g++) | `mpiicpx` if present, else `mpiicpc -cxx=icpx` (auto-detected) |
| MKL link | `-lmkl_intel_ilp64 -lmkl_gnu_thread -lmkl_core -lgomp`, `-Wl,--no-as-needed` | `-lmkl_intel_ilp64 -lmkl_intel_thread -lmkl_core -liomp5` |
| Launch | `mpirun --map-by ppr:R:node:PE=T --bind-to core` | `mpirun -np N -ppn R`, `I_MPI_PIN_DOMAIN=omp` |

Points that matter:

* **ILP64 is mandatory.** FEMTIC calls `pardiso_64` and passes `long long` to `pardisoinit`
  (ported/README.md). BLACS was in the upstream link line but is never called, so OpenMPI is fine.
  The CSIRO reference run also used OpenMPI, with Intel compilers.
* **mpiicpx may or may not exist in impi 2021.9; 01 auto-detects and falls back to `mpiicpc -cxx=icpx`.**
  `00_discover.sh` reports which wrappers the module provides. `ported/femtic/Makefile.intel_oneapi` says
  `CXX = mpiicpx`; `01` always passes the detected wrapper as `CXX=...`. For the classic compiler, which is
  still present in intel-compilers 2023.1.0 and removed in oneAPI 2024.0, use `INTEL_MPICXX=mpiicpc`.
* **Build foss first, and build intel only if foss fails or you want to benchmark.** Run time
  is dominated by MKL's PARDISO factorisation and BLAS-3 calls, which are the same MKL library
  in both toolchains. This is an engineering judgment, not a measurement.
* If neither 2023a toolchain exists, use the generation `module avail` shows (2021b or 2025a) with
  `MODS="..."`, keeping an MKL module that sets `MKLROOT`; T1 checks the result.
* The plain tools (makeMtr, TetGen2Femtic, makeDHexaMesh, mergeResultOfFEMTIC, tetgen) always
  build with `g++`, because icpx defaults to a value-unsafe floating-point model and TetGen's
  predicates must not be optimised.
* **Pinning.** `PIN=1` requires the exact commits the ported Makefiles' OBJS lists were copied from:
  femtic `26c8606`, makeTetraMesh `92a9a32`, makeMtr `df8e207`, TetGen2Femtic `ceb8bfb`,
  makeDHexaMesh `66afbfc`, mergeResultOfFEMTIC `4fe54e1`, tetgen `e05aca7`. In a git-free tree the commit
  is read from `<repo>/COMMIT_SHA.txt` (written automatically for tarballs); without it the version is
  reported as UNKNOWN. A later upstream commit that adds a source file would fail at link time.

## 5. SU cost of candidate configurations

SU = cpus x hours x rate: icelake and a100cpu 1.2 SU per cpu-hour, highmem 2.5. The figures assume the job
runs to its full walltime. Whether Phoenix charges elapsed or requested time, and whether billing is
memory-weighted, are VERIFY items (`TRESBillingWeights` in the discovery output); with CPU-only billing a
memory-heavy job costs the same on a100cpu as on icelake and gets twice the RAM.

| Configuration | cpus | Hours | Rate | SU |
|---|---:|---:|---:|---:|
| forward-only T6 (06): icelake, 1 node, 2 h | 72 | 2 | 1.2 | 172.8 |
| test inversion T4: icelake, 1 node, 12 h | 72 | 12 | 1.2 | 1,036.8 |
| icelake, 1 node, 24 h | 72 | 24 | 1.2 | **2,073.6** |
| icelake, 1 node, 72 h (one chain link) | 72 | 72 | 1.2 | **6,220.8** |
| a100cpu, 1 node (515 GB), 72 h | 72 | 72 | 1.2 | **6,220.8** |
| icelake, 2 nodes, 72 h | 144 | 72 | 1.2 | **12,441.6** |
| highmem, 1 node (1.99 TB), 72 h | 72 | 72 | 2.5 | **12,960.0** |
| chain of 3 x 72 h on 1 icelake node | 72 | 216 | 1.2 | 18,662.4 |
| mesh job (03): icelake, 8 cpus, 2 h (free on interactive) | 8 | 2 | 1.2 | 19.2 |
| CSIRO AusLAMP run, re-priced (2 x 56 cores, 144 h) | 112 | 144 | 1.2 | 19,353.6 |

Reading the table:

* **Memory-heavy jobs go to a100cpu:** same price per cpu-hour as icelake, 514,944 MiB per node instead of
  254,952 MiB. highmem costs about twice as much per cpu-hour; use it only if a100cpu's 515 GB is not enough.
* The SU budget (about 980k unused this quarter) is not the constraint. The 3-day walltime is, so the plan
  optimises time to solution and restart safety, not SU.
* A rough time scale, which is not a measurement: CSIRO's 1.45M-element AusLAMP inversion reached
  iteration 13 (14 forward evaluations, `femticPy/projects/auslamp/inversion/inv01/femtic.cnv`) on
  2 nodes x 14 ranks x 4 threads within a 144 h request, so at most about 10 h per iteration.
  Direct-solver cost grows faster than linearly with mesh size, so a mesh under 500k elements on
  72 cores should need a few hours per iteration. 06 and T4 replace the guess with numbers.
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
254,952 MiB (icelake) or 514,944 MiB (a100cpu). With `HOLD_FWD_MEM` the two add up.

**Per-rank forward memory is more than PARDISO.** The log line "Total memory consumed by in-core
forward solver for internal float point arrays" (in KB, summarised by `04` and `06`) covers PARDISO's
factors only. For each frequency the sensitivity step also allocates (Inversion.cpp, Forward3D.cpp):

* `N_eq x N_iv x 16 B` for the solutions of the interpolator right-hand sides. N_eq is "Number of equation
  after degeneration" in the log, roughly the edge count (about 600k for 500k tetrahedra). N_iv is
  4 per MT station (Ex, Ey, Hx, Hy) plus 3 per tipper (VTF) station. Vulcan has no tipper, so
  N_iv = 4 x 120 = **480** (FEMTIC's example log confirms 4 per station: 144 right-hand sides for 36 stations).
  Example: 600,000 x 480 x 16 B = 4.6 GB. `DIV_NUM_RHS_FWD` does **not** shrink this array; it only splits
  the PARDISO solve calls.
* `2 x N_iv x M x 16 B` for the field derivatives of both polarisations: 1.5 GB at M = 100k.
* `Nd_f x M x 8 B` for the frequency's sensitivity block before it is written to SENSE_MAT_DIRECTORY:
  Nd_f = 8 x 120 = 960, so 0.77 GB at M = 100k.

Sum for Vulcan: 5.2 GB at M = 25k, 6.9 GB at M = 100k, 9.2 GB at M = 200k per rank, on top of PARDISO's
figure. `NONPARDISO_MB` (default 10240 MiB = 10.7 GB) is this allowance in the automatic MEM_LIMIT; `06`
recomputes it from the real N_eq and M and warns if it is too small. The reliable number is the measured
peak (`06` samples the node's femtic RSS; T4 adds `sacct MaxRSS` and `rcstat`), not the PARDISO line.

**Number of data for Vulcan.** The Vulcan data are impedance only: 8 real data per site per frequency
(real and imaginary parts of Zxx, Zxy, Zyx, Zyy) at 120 sites, so **Nd = 960 x F**. F, the number of
inversion frequencies, is not chosen yet. Candidates: the 53 bands common to all sites (200 Hz to about 800 s;
`Vulcan/frequency_table.csv`), subsampled to about 4 per decade between about 100 Hz and 1000 s, which gives
F in the 24 to 32 range, so Nd = 23,040 to 30,720. Note that past about 800 s not every site has data
(116 of 120 at 998 s), so Nd is slightly below 960 x F if those periods are kept.

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
| 24 | 23,040 | 200,000 | 73.7 / 196.9 GB (icelake only if nothing else is resident; a100cpu) | 4.2 GB | 36.9 / 73.7 GB |
| 32 | 30,720 | 25,000 | 12.3 / 8.6 GB | 7.5 GB | 6.1 / 12.3 GB |
| 32 | 30,720 | 100,000 | 49.2 / 64.6 GB | 7.5 GB | 24.6 / 49.2 GB |
| 32 | 30,720 | 200,000 | 98.3 / 209.2 GB (a100cpu) | 7.5 GB | 49.2 / 98.3 GB |

**Recommendation:** use `INV_METHOD 1` (data space), as CSIRO did, whenever Nd is much smaller
than M, which is the Vulcan case for any M above a few tens of thousands. Data space rejects "free and
isolated" cells (type 3 in `resistivity_block_iter0.dat`), so FEMTIC exits with an error if the mesh has
any. `--gres=tmpfs:200G` holds data-space sensitivity files up to about M = 540k at F = 24 and M = 400k at
F = 32 (200 GB / (2 x Nd x 8 B)), before any headroom.

**Starting layout for 1 node (72 cores):** pick the largest R_per_node that divides F and passes
the memory rule, then threads = 72 / R. 8 x 9 (the default) divides both F = 24 and F = 32; other options
are 12 x 6 or 24 x 3 for F = 24, and 16 x 4 (64 cores used) for F = 32. `RANKS=` and `THREADS=` run fewer
ranks or threads than the cpus bought for memory. Go to 2 nodes only if one node cannot hold enough ranks;
multi-node jobs also move the sensitivity files to /hpcfs (below).

**In-core or out-of-core:**

* `FWD_SOLVER 0` is in-core and is FEMTIC's default. It is fastest, but a job that exceeds `--mem`
  is killed.
* `FWD_SOLVER 1` picks per factorisation, going out-of-core when the need exceeds `MEM_LIMIT`
  (MB per rank, passed to MKL as `MKL_PARDISO_OOC_MAX_CORE_SIZE`). **FEMTIC's default MEM_LIMIT
  is 3000 MB**, which would push any realistic mesh out-of-core. `04` and `06` therefore set
  `MEM_LIMIT = (0.85 x --mem - RANK0_RESERVE_MB) / R_per_node - NONPARDISO_MB`, where `RANK0_RESERVE_MB`
  is subtracted **only when control.dat has `HOLD_FWD_MEM`** (without it the rank-0 dense phase does not
  overlap the forward phase) and `NONPARDISO_MB` (default 10240) reserves each rank's sensitivity-step
  arrays listed above. For 8 ranks on icelake (254,952 MiB) that is 16,848 MB per rank; on a100cpu
  (514,944 MiB) 44,472 MB. Below 1 GB per rank `04` refuses to start.
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
Whether `$TMPDIR` is RAM-backed is a VERIFY item (the `df -hT` line in the first 04 or 06 output).

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
* Each restart costs one repeated forward solve (model N is re-evaluated). The step-length damping
  also restarts at its `STEP_LENGTH` initial value, so a restarted run can differ slightly from an
  uninterrupted one. Test T5 measures this on FEMTIC's example.
* FEMTIC truncates `femtic.cnv` and `femtic_<rank>.log` at every start. `04` moves them into
  `logs/run_<timestamp>/` first. To get the full history, run
  `cat logs/run_*/femtic.cnv femtic.cnv | awk '$1!="Iter#"'`.
* Choose ITER_STEP as roughly (72 h - 0.5 h - T_forward) / T_iteration, from 06 and T4. Too large is safe:
  the watcher stops the job at a safe point and it hands on. Too small wastes queue time.

## 8. EasyBuild fallback (only if discovery finds no usable MKL or toolchain)

Filenames verified in `easybuilders/easybuild-easyconfigs` at tag `easybuild-easyconfigs-v4.9.4`:
`imkl-2023.1.0.eb` (SYSTEM toolchain), `imkl-2023.1.0-gompi-2023a.eb`, `intel-2023a.eb`,
`foss-2023a.eb`, `intel-compilers-2023.1.0.eb` and `impi-2021.9.0-intel-compilers-2023.1.0.eb`
(which depends on UCX 1.14.1). Which EasyBuild module Phoenix provides is not in the census:
`00_discover.sh` lists it (VERIFY on Phoenix).

```bash
module load EasyBuild/4.9.4            # VERIFY on Phoenix: use the version 00_discover.sh lists
export EASYBUILD_PREFIX=/hpcfs/users/$USER/easybuild
export MODULEPATH=$EASYBUILD_PREFIX/modules/all:$MODULEPATH
eb imkl-2023.1.0.eb --robot -Dx     # dry run
eb imkl-2023.1.0.eb --robot         # binary installer l_onemkl_p_2023.1.0.46342_offline.sh, no compile
module load foss/2023a imkl/2023.1.0   # VERIFY on Phoenix (name may carry a toolchain suffix)
# whole toolchains if missing (hours): eb intel-2023a.eb --robot   |   eb foss-2023a.eb --robot
```

The EasyBuild imkl module (VERIFY on Phoenix) sets `MKLROOT=<prefix>/software/imkl/2023.1.0/mkl/2023.1.0` and prepends
`LD_LIBRARY_PATH`, `LIBRARY_PATH`, `CPATH`, `CMAKE_PREFIX_PATH` and `PKG_CONFIG_PATH`. It also sets
`MKL_EXAMPLES`. `01` and `femtic_env.sh` run `module use` on the prefix automatically when it exists.
EasyBuild downloads run on the login node or in an interactive job (internet); otherwise pre-place the
installer in `$EASYBUILD_PREFIX/sources/i/imkl/`.

## 9. What was verified, and how

| Item | Status |
|---|---|
| Phoenix partitions, cpus, RAM per node and per cpu, walltimes, SU rates, QoS/account limits, Lmod naming, SMT | `sinfo`, `sacctmgr`, `module avail`, `lscpu` on 2026-09-25 (Ben's census and PRISM README) |
| Toolchain module names (foss/2023a, imkl/2023.1.0, intel/2023a, parts) | **Not verified** (VERIFY on Phoenix); `00_discover.sh` queries them |
| Easyconfig filenames and contents (5 files) | Read from GitHub at the v4.9.4 tag |
| imkl module sets MKLROOT | Read in `easyblocks/i/imkl.py` at v4.9.4 (`make_module_extra`) |
| intel-compilers 2023.1.0 has icpc | `easyblocks/i/intel_compilers.py` v4.9.4 sanity-checks icc, icpc and ifort for versions below 2024. Removal in oneAPI 2024.0 comes from Intel's notice (search result). |
| mpiicpx in impi 2021.9 | **Not verified.** Two earlier write-ups disagreed, so no release is claimed here; 01 auto-detects and falls back to `mpiicpc -cxx=icpx`, and 00 reports what exists |
| OpenMPI 4.1 `--map-by ...:PE=n` syntax | open-mpi.org v4.1 mpirun man page (upper-case `PE`) |
| rdp, pyproj, shapely, pyvista on conda-forge | anaconda.org API (rdp 0.8) |
| UTM 53S self-test values in 02 | pyproj on Windows: (135 E, 30 S) -> 500,000.00 E, 6,681,214.65 N; Vulcan A1 within 1 m of `edi_inventory.md` |
| FEMTIC runtime behaviour (control.dat parsing, defaults, restart files and their write order, log strings, rank-0 reads, OOC file location, frequency split, cell types, no stop hook, `ITERATION 0 0` skips sensitivities, `HOLD_FWD_MEM` is a bare keyword) | Read in `femtic/src` at commit 26c8606 |
| Script logic | WSL (GNU bash 5.2, sed 4.9, gawk 5.2) harnesses in `validation/wsl_2026-09-25/scripts/`, run 2026-09-25 against these files: `libtest_v2.sh` 48/48 checks (library, incl. restart check and fallback, trapped-signal wait, TERM-to-KILL stop); `chaintest_v2.sh` 22 scenarios, 89/89 checks (mock Slurm for 04, 05, 06: chaining, restart fallback and quarantine, DISTORTION fallback, silent exit-0 death, COMPLETED marker, SIGUSR1 trap, safe-point stop, T6 pass and fail); `unit2_v2.sh` 12/12 (T5 comparator, 03 region/poly/ele logic); `fetchtest_v2.sh` 14/14 (01 tarballs, git-free tree, pin mismatch, no fetch in compute jobs). Each harness was shown able to fail: 8 deliberately broken copies of the scripts were all caught. `bash -n` clean; shellcheck 0.11 clean at warning level. The v1 harnesses are kept unchanged as the record of the earlier run |
| Anything that needs Phoenix | **Not verified**. See section 12. |

## 10. Validation tests and their failure criteria

| Test | Where | Fails if |
|---|---|---|
| T1 linkage | 01 | `ldd femtic` lacks libmkl_core or libmkl_intel_ilp64, shows "not found", or mixes OpenMP runtimes (foss: must have libgomp and mkl_gnu_thread and no libiomp5; intel: the reverse) |
| T2 smoke | 01, inside an allocation | FEMTIC example INV_MT_01/Tetra (2 ranks x 2 threads, ITERATION 0 2) exits non-zero or does not write `resistivity_block_iter2.dat` |
| T5 restart equivalence | 01, inside an allocation | The 0 to 1 then 1 to 2 restart through `femtic_ctl_set` and `femtic_last_iter` does not start at iteration 1, or its misfit differs from the straight run by more than 1e-4 (iteration 1) or 1e-3 (iteration 2) relative. Reported INCONCLUSIVE, not PASS, if a retrial or damping change occurred. The tolerance covers the 7-digit `%15e` model file. A wrong-model restart differs by tens of percent. |
| Cross-platform check | manual | The iteration-0 row of the Phoenix smoke run disagrees with the WSL build's run of the same example in the first 6 significant digits |
| T3 mesh | 03 | `resistivity_block_iter0.dat` line counts disagree with its header, or a region-seed attribute is missing from `resistivity_attr.dat` |
| T6 forward only | 06 | femtic exits non-zero; no FEMTIC end line in femtic_0.log; the per-frequency times over all ranks do not number exactly F; or the sampled peak node RSS exceeds 90 % of `--mem` |
| T4 test inversion | 04 with ITERATION 0 1 | Non-zero exit, no `logs/COMPLETED_<jobid>`, a warning that PARDISO went out-of-core, a rank-count warning, or rcstat CPU efficiency under about 50%. Record time per iteration, peak PARDISO per rank, peak node RSS, sensitivity scratch and MaxRSS. |
| Restart integrity | 04 / 05 at every start | Neither the highest model nor the one before passes `femtic_restart_pick` |

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

## 12. What Ben must confirm from `phoenix_discovery_<host>.txt`

1. **Module names (VERIFY on Phoenix):** do `foss/2023a imkl/2023.1.0` load and set MKLROOT (else `imkl/2023.1.0-gompi-2023a`,
   another generation from `module avail`, or section 8)? VERIFY whether `intel/2023a` loads. Pass `MODS="..."` accordingly.
2. **mpiicpx:** informational only; `01` uses it if present and `mpiicpc -cxx=icpx` otherwise.
3. **Requests:** the `sbatch --test-only` lines. Expected: the 04/06 default (`-p icelake`, 72 cpus,
   `--mem=254952M`, `--gres=tmpfs:200G`) accepted; `--mem=250G` rejected; the a100cpu line (`--mem=514944M`)
   accepted; the highmem line tells whether `--mem=1900G` fits its per-cpu cap.
4. **`$TMPDIR`:** is it disk-backed? Check the `df -hT` line in the first 06 or 04 output. If it is `tmpfs`,
   the sensitivity files count against `--mem`.
5. **Billing:** CPU-only or memory-weighted (`TRESBillingWeights`)? Charged on elapsed or requested time?
6. **srun:** do `srun --mpi=list` and `ompi_info` show pmix or Slurm support? Only matters for `USE_SRUN=1`.
   Also confirm the `I_MPI_PMI_LIBRARY` path for Intel MPI under srun.
7. **git and curl on the login node** (01 `FETCH_ONLY=1` needs one of them; otherwise use tarballs).
8. **Quota:** room on /hpcfs for builds (about 2 GB), the femticpy env (about 3 GB), meshes, results, and
   multi-node sensitivity scratch (tens of GB per job)?
9. **Interconnect** (UCX/OFI) for OpenMPI or Intel MPI across nodes. Only relevant if 2 nodes are needed.
10. **Vulcan choices** that decide the layout: F (section 6), M from the 03 report, INV_METHOD, DISTORTION.

## Sources

* Phoenix facts: `D:\BEN\3D_Joint_Inversion_2026\benchmarks\phoenix\README.md` and `node_census_p2-log-2_2026-09-25.txt`
* easyconfigs v4.9.4: https://github.com/easybuilders/easybuild-easyconfigs/tree/easybuild-easyconfigs-v4.9.4/easybuild/easyconfigs (`i/imkl`, `i/intel`, `i/intel-compilers`, `i/impi`, `f/foss`)
* easyblocks v4.9.4: https://github.com/easybuilders/easybuild-easyblocks/tree/easybuild-easyblocks-v4.9.4/easybuild/easyblocks (`i/imkl.py`, `i/intel_compilers.py`, `i/impi.py`, `generic/intelbase.py`)
* Intel C++ Compiler Classic removal notice: https://community.intel.com/t5/Intel-oneAPI-DPC-C-Compiler/REMOVAL-NOTICE-Intel-C-Compiler-Classic/m-p/1545804
* OpenMPI 4.1 mpirun: https://www.open-mpi.org/doc/v4.1/man1/mpirun.1.php
* conda-forge rdp: https://anaconda.org/conda-forge/rdp
* micromamba: https://micro.mamba.pm (static binary, as in Ben's `bootstrap_env.sh`)
