# FEMTIC v5.0 WSL build: GCC + OpenMPI + Intel MKL ("foss + imkl" route)

**Result: all 7 tools compile and link with the ported Makefiles unchanged, and no C++ source patches were needed.**
femtic runs a real 3-iteration inversion. The run-time traces show PARDISO and LAPACKE calls resolving to
`libmkl_intel_ilp64` + `libmkl_gnu_thread`, with one OpenMP runtime per process.

Host: WSL2 Ubuntu 24.04 (user tara), 20 cores. Sources were copied to `/home/tara/femtic_wsl/<tool>` (ext4, with `.git` excluded).
Binaries are in `/home/tara/femtic_wsl/bin/`.

## Environments (the exact commands that worked)

```bash
source /home/tara/miniforge3/etc/profile.d/conda.sh
# main env (unpinned, as specified)
mamba create -y -n femtic-build -c conda-forge compilers openmpi mkl-devel mkl-include make cmake
# version-matched cross-check env (= EasyBuild foss/2023a + imkl/2023.1.0)
mamba create -y -n femtic-foss2023a -c conda-forge gcc=12.3 gxx=12.3 openmpi=4.1.5 mkl-devel=2023.1 mkl-include=2023.1 make
conda activate femtic-build && export MKLROOT=$CONDA_PREFIX
```

| | femtic-build (main) | femtic-foss2023a (matched) |
|---|---|---|
| g++ / mpicxx backend | conda-forge gcc 15.3.0 | conda-forge gcc 12.3.0 |
| OpenMPI | 5.0.10 | 4.1.5 |
| MKL (mkl-devel/mkl-include) | 2026.1.0 (libmkl_*.so.3) | 2023.1.0 (libmkl_*.so.2) |
| make / cmake | 4.4.1 / 4.4.3 | 4.4.1 / - |
| OpenMP pkgs | llvm-openmp 23.1.2, libgomp 16.2.0, `_openmp_mutex 8_kmp_llvm` | same mutex (llvm) |

Checks:
- `mkl.h` is in `$MKLROOT/include`.
- The MKL libraries are in `$MKLROOT/lib`. There is **no** `lib/intel64` on conda. The Makefile passes both `-L` paths, and ld ignores the one that does not exist, so no edit was needed.
- `which mpicxx mpirun g++` all resolve to the env's `bin/`.
- `mpicxx --showme` gives `x86_64-conda-linux-gnu-c++ ... -Wl,-rpath <env>/lib -lmpi`.
- compilers 2.0 does **not** export `CXX`/`CXXFLAGS`/`LDFLAGS`, so plain `g++` in the Makefiles is the conda g++.

## Per-tool status (main env; the matched env gives the same results, see `foss2023a/`)

| Tool | Makefile | Build | Warnings | No-argument run (clean env, empty dir) |
|---|---|---|---|---|
| femtic | ported/femtic/Makefile.gcc_openmpi_mkl | OK (59 TUs, 4.8 s at -j16) | 25: -Wconversion-null (PARDISOSolver.cpp:50,69,97; AnalysisControl.cpp:65,1567), `unknown escape '\/'` (Inversion*.cpp) | exit 1, `femtic_0.log`: "File open error : control.dat !!" (expected) |
| makeTetraMesh | ported/makeTetraMesh/Makefile.gcc_mkl (WITH_MKL=0) | OK | 0 | usage text "makeTetraMesh -stp [Step ID]" |
| makeMtr | ported/makeMtr/Makefile.gcc | OK | 0 | "You must specify node file name !!" |
| TetGen2Femtic | ported/TetGen2Femtic/Makefile.gcc | OK | 0 | "You must specify root name of tetgen file" |
| makeDHexaMesh | ported/makeDHexaMesh/Makefile.gcc | OK | 0 | "File open error : meshgen.inp !!" |
| mergeResultOfFEMTIC | ported/mergeResultOfFEMTIC/Makefile.gcc | OK | 0 | "You must specify iteration number and process number !!" |
| tetgen | upstream makefile per ported/tetgen/BUILD.txt | OK (predicates.cxx at -O0) | 0 | usage text, exit 0 |

Build commands (WSL):
- femtic: `make -f Makefile.gcc_openmpi_mkl -j16`
- Other Makefile tools: `make -f Makefile.gcc* -j16 LDFLAGS="-Wl,-rpath,$CONDA_PREFIX/lib"`
- tetgen: `make tetgen CXX=g++ CXXFLAGS=-O3 PREDCXXFLAGS=-O0 SWITCHES="-Wl,-rpath,$CONDA_PREFIX/lib"`

The rpath is passed **on the command line only, for WSL**, so the installed binaries run without activating conda. mpicxx already adds it for femtic. On Phoenix the modules set `LD_LIBRARY_PATH`, so use the Makefiles as they are.

**Makefiles:** the files used in the build are byte-identical to `ported/...` (checked with cmp). Nothing needed to be copied back.
**Sources:** all 216 .cpp/.h/.cxx files are byte-identical to the upstream clones. `ported/patches/` has only `NO_PATCHES_REQUIRED.txt`.

## Proof

**1. Linkage** (`femtic_ldd.txt`, `ldd_all.txt`). Failure criterion: MKL ilp64/gnu_thread/core, libgomp or libmpi is missing, or libiomp5 / mkl_intel_thread / mkl_intel_lp64 / "not found" appears.
Result: PASS.
- NEEDED is `libmkl_intel_ilp64.so.3 libmkl_gnu_thread.so.3 libmkl_core.so.3 libgomp.so.1 libmpi.so.40`.
- The forbidden list is empty.
- The MKL symbols femtic imports are `pardiso_64 pardisoinit LAPACKE_{dbdsdc,dgebrd,dpptrf,dpptrs,dsptrd,dsptrf,dsptrs,dsterf} MKL_Set_Num_Threads`.

**2. Running a real inversion** (`smoke_*.log`, `smoke_crosscheck.txt`). Test case: `examples/INV_MT_01/Tetra`, ITERATION 0 3, `mpirun -np 2`, 4 threads per rank. Failure criterion: non-zero exit, RMS not decreasing, or outputs differing by more than print rounding.
Result: PASS.
- RMS: 2.2346 → 1.4226 → 1.0664 → 0.9276 in 16 s.
- CPU use was 630–735 %, so the threading really runs.

**3. OpenMP runtime, a conda-specific caveat.** conda-forge `mkl` requires `_openmp_mutex=*_llvm`. As a result, `<env>/lib/libgomp.so.1` is a **symlink to LLVM `libomp.so`**, not GNU libgomp. On Phoenix, EasyBuild foss uses real GNU libgomp. To test the Phoenix configuration, the run was repeated with `LD_PRELOAD=<env>/lib/libgomp.so.1.0.0`, which is the genuine GNU library. Reading `/proc/<pid>/maps` confirmed that each run loaded exactly one runtime: libomp.so in the default run, libgomp.so.1.0.0 in the preloaded run, and never libiomp5.
- femtic.cnv, the iteration-3 model and the responses were **identical** between the two runtimes.
- The matched build (GCC 12.3 / OpenMPI 4.1.5 / MKL 2023.1) produced the same femtic.cnv and model. 1 of 2376 printed response values differs, by 8e-7 relative (the last printed digit).
- Sensitivity float data is identical. The EnSight header bytes differ, because upstream writes an uninitialised char[80] buffer. This is harmless.

**4. ILP64 entry points actually called** (`smoke_dataspace_lapacke.log`). Test case: `INV_MT_01/TetraBoundsDataSpace` (INV_METHOD 1), run with `LD_DEBUG=bindings`. Failure criterion: pardiso or LAPACKE binds to a library other than libmkl_intel_ilp64, or the run crashes.
Result: PASS.
- `pardiso_64`, `pardisoinit`, `LAPACKE_dsptrf` / `LAPACKE_dsptrs` (plus the nancheck helpers) and `MKL_Set_Num_Threads` all bind to `libmkl_intel_ilp64.so.3`.
- RMS: 2.2346 → 1.4156 → 1.0596.

## Findings for downstream / Phoenix

- **The route is proven, including an exact version match with foss/2023a + imkl/2023.1.0.** On Phoenix the only difference is the MKL directory: EasyBuild imkl 2023 uses `$MKLROOT/lib/intel64`, which the Makefile already handles.
- **Correction to ported/README:** the `cblas_dgemm`/`cblas_dgemv` calls in Inversion*.cpp are dead code. `CommonParameters.h:171` has `static const bool IS_BLAS_USED = false;`, so -O3 removes them and the binary imports no cblas symbol. ILP64 is still mandatory because of pardiso_64/pardisoinit and LAPACKE.
- CRLF input files: `control.dat` was put through `sed 's/\r$//'` before the runs. `mesh.dat`, `observe.dat` and `resistivity_block_iter0.dat` were used with CRLF as shipped and read correctly.
- The version-matched build is in `/home/tara/femtic_wsl/foss2023a/bin/`. Its logs are in `build_logs/foss2023a/`.
- For numerical validation in WSL: the default conda run uses LLVM libomp through the libgomp.so.1 symlink. Use `-x LD_PRELOAD=$CONDA_PREFIX/lib/libgomp.so.1.0.0` for a GNU-libgomp run that matches Phoenix.

Scripts: `scratchpad/wslbuild/s1..s10`. Logs: `scratchpad/build_logs/`.
