# FEMTIC v5.0 + mesh tools: EasyBuild toolchain port (build files only)

Nothing here has been compiled. These are drop-in makefiles for a later build stage,
written after a static audit of the sources. Copy each file next to the sources it
belongs to (e.g. `femtic/src/`) and run `make -f <name> -j N`.

| Project | File | Toolchain | Compiler | Notes |
|---|---|---|---|---|
| femtic | `femtic/Makefile.gcc_openmpi_mkl` | foss/2023a + imkl/2023.1.0 | `mpicxx` | GNU OpenMP + `mkl_gnu_thread`, ILP64 |
| femtic | `femtic/Makefile.intel_oneapi` | intel/2023a | `mpiicpc -cxx=icpx` on Phoenix, where mpiicpx is absent (see note 8) | Intel OpenMP + `mkl_intel_thread`, ILP64 |
| makeTetraMesh | `makeTetraMesh/Makefile.gcc_mkl` | GCC/foss | `g++` | OpenMP only; MKL off by default (`WITH_MKL=1` adds an LP64 link) |
| makeTetraMesh | `makeTetraMesh/Makefile.intel_oneapi` | intel/2023a | `icpx` | `-qopenmp -qmkl=parallel` |
| makeMtr | `makeMtr/Makefile.gcc` | GCC | `g++` | `-O2 -DNDEBUG` |
| TetGen2Femtic | `TetGen2Femtic/Makefile.gcc` | GCC | `g++` | `-O2 -DNDEBUG` |
| makeDHexaMesh | `makeDHexaMesh/Makefile.gcc` | GCC | `g++` | `-O3 -DNDEBUG` |
| mergeResultOfFEMTIC | `mergeResultOfFEMTIC/Makefile.gcc` | GCC | `g++` | upstream ships no makefile; single TU |
| tetgen | `tetgen/BUILD.txt` | GCC | `g++` | upstream makefile, `PREDCXXFLAGS=-O0` kept |

Every `OBJS` list is copied programmatically from the reference makefile (CR-stripped)
and diffed back by the verifier. Each makefile adds a `%.o: %.cpp` pattern rule (so
`make -j` works), a `$(OBJS): $(wildcard *.h)` dependency (upstream tracked no header
dependencies) and `.PHONY: all clean`. All files are LF with real TAB recipe lines; the
verifier (`verify_v2.sh`, log `verify_v2.log` beside this directory) fails if any ported
file contains a CR byte or a space-indented recipe.

## Flags per toolchain

### A. GCC + OpenMPI + Intel MKL (`foss/2023a` + `imkl/2023.1.0`)

```
CXX      = mpicxx
CXXFLAGS = -O3 -fopenmp -m64 -std=c++11 -D_LINUX -DMKL_ILP64 -D_USE_OMP -DNDEBUG -I$(MKLROOT)/include
LIBS     = -L$(MKLROOT)/lib/intel64 -L$(MKLROOT)/lib -Wl,--no-as-needed \
           -lmkl_intel_ilp64 -lmkl_gnu_thread -lmkl_core -lgomp -lpthread -lm -ldl
```

* `MKLROOT` is read from the environment (the `imkl` module exports it); the makefile
  stops with `$(error MKLROOT is not set ...)` if it is unset, except for `make clean`.
* `-std=c++11` is the floor: the code is C++98-style (no `auto`, `nullptr`, `override`,
  lambdas, smart pointers, range-for) but uses `long long`, which is standard only from
  C++11. The single `vector::shrink_to_fit()` (`ResistivityBlock.cpp:132`) is inside
  `#ifndef _LINUX` and compiled out. GCC 12/13 default `gnu++17` works too. g++ predefines
  `_GNU_SOURCE` for C++, so `setenv`, `getrusage`, `M_PI` etc. stay visible under strict
  `-std=c++11`.
* Threading layer must be `mkl_gnu_thread` + `libgomp` to match `-fopenmp`. Do not add
  `-liomp5` on this toolchain.
* `-Wl,--no-as-needed` precedes the MKL libraries so `--as-needed` toolchains keep MKL's
  mutually dependent layers.
* `-lmkl_blacs_intelmpi_ilp64` from the upstream makefile is dropped (see audit).
* Both `-L$(MKLROOT)/lib/intel64` (imkl 2023) and `-L$(MKLROOT)/lib` (imkl 2024+) are given.

### B. Intel oneAPI 2023 (`intel/2023a`)

```
CXX      = mpiicpx     # absent on Phoenix's intel/2023a: use "mpiicpc -cxx=icpx" (same icpx); "mpiicpc" = classic icpc (oneAPI <= 2023)
CXXFLAGS = -O3 -qopenmp -D_LINUX -DMKL_ILP64 -D_USE_OMP -DNDEBUG -I$(MKLROOT)/include
LIBS     = -L$(MKLROOT)/lib/intel64 -L$(MKLROOT)/lib \
           -lmkl_intel_ilp64 -lmkl_intel_thread -lmkl_core -liomp5 -lpthread -lm -ldl
```

One-flag alternative for icpx/icpc: replace the `-I/-L/-l` MKL lines with
`-qmkl-ilp64=parallel` on both compile and link lines (`-DMKL_ILP64` is still needed
for the headers). The classic `-mkl=...` spelling is icpc-only and gone in oneAPI 2024.
icpx defaults to `-fp-model=fast`; add `-fp-model=precise` for comparability with GCC.

### Mesh tools

* makeTetraMesh: `g++ -O3 -fopenmp -D_USE_OMP -D_THICKNESS_FUNC -DNDEBUG` (GCC) /
  `icpx -O3 -qopenmp -D_USE_OMP -D_THICKNESS_FUNC -DNDEBUG` + `-qmkl=parallel` (Intel).
* makeMtr, TetGen2Femtic, mergeResultOfFEMTIC: `g++ -O2 -DNDEBUG`. makeDHexaMesh: `g++ -O3 -DNDEBUG`.
* tetgen: upstream makefile, `g++ -O3` for `tetgen.cxx`, `-O0` for `predicates.cxx`.

## Why ILP64 for FEMTIC (verified in source)

FEMTIC hard-codes MKL's 64-bit integer interface; the LP64 interface does not compile:

* `PARDISOSolver.h:87-102`: `m_maxfct`, `m_mnum`, `m_mtype`, `m_numEquations`,
  `m_iparm[64]`, `m_msglvl` are all `long long int`.
* `PARDISOSolver.cpp:100`: `pardisoinit(m_pt, &m_mtype, m_iparm)`. `pardisoinit` takes
  `MKL_INT*`; with `long long*` arguments this only type-checks when `MKL_INT` is
  `long long`, i.e. under `-DMKL_ILP64` (`mkl_types.h`: `MKL_INT` = `MKL_INT64` =
  `long long int` on Linux).
* `PARDISOSolver.cpp:160,194`, `PARDISOSolverComplex.cpp:63,85`,
  `PARDISOSolverDouble.cpp:63,85`: every factorisation/solve goes through `pardiso_64(...)`
  with `long long` row/column arrays (`ComplexSparseMatrix.cpp:184,207`,
  `DoubleSparseMatrix.cpp:180,203` allocate them as `long long int`).
* `InversionGaussNewtonDataSpace{,Isotropic,Anisotropic}.cpp` declare `MKL_INT` locals
  and pass them to `cblas_dgemm`, `cblas_dgemv`, `LAPACKE_dpptrf/dpptrs/dsptrf/dsptrs`
  with `long long` sizes (`numDataTotal_64`); `InversionGaussNewtonModelSpace.cpp` and
  `RougheningSquareMatrix.cpp` call `LAPACKE_dpptrf/dsptrf/dsptrs/dgebrd/dbdsdc/dsptrd/dsterf`
  the same way. Under ILP64 `lapack_int == MKL_INT == long long`, matching the code.
* There is no `#ifdef MKL_ILP64` fallback anywhere; the macro is assumed on.

Hence `-DMKL_ILP64` + `libmkl_intel_ilp64` on both toolchains.

## MKL interface for makeTetraMesh

The upstream makefile links `-mkl=parallel`, but the sources contain no MKL call at all:
no `mkl*.h` include, no `LAPACKE_*`, `cblas_*`, `pardiso*`, `MKL_INT`, `long long` or
`MKL_ILP64` (only `<omp.h>` under `#ifdef _USE_OMP`, `omp_set_num_threads` and one
`omp parallel for` in `TriangleList.cpp:2073-2082`). The GCC makefile therefore links
nothing but OpenMP; linking MKL would only add a run-time dependency on libraries the
binary never calls. If MKL is ever needed, the code's plain `int` indices mean the LP64
interface (`mkl_intel_lp64`), which `make WITH_MKL=1` enables with the GNU threading
layer. The Intel makefile keeps `-qmkl=parallel` for parity; it is harmless.

## Audit summary (what was grepped, what was found)

| Check | Result |
|---|---|
| `mkl.h`, `mkl_pardiso.h`, `mkl_types.h` | `PARDISOSolver*.cpp` (3 files), `AnalysisControl.cpp` |
| `mkl_lapacke.h`, `mkl_cblas.h` | `Inversion.cpp`, `InversionGaussNewton*.cpp` (4), `RougheningSquareMatrix.cpp` |
| `pardiso_64`, `pardisoinit`, `pardiso_setenv(PARDISO_OOC_FILE_NAME)` | used; all-`long long` (see above). No 32-bit `pardiso()` call. |
| `mkl_set_num_threads` | `AnalysisControl.cpp:1152` (works with either threading layer) |
| `MKL_PARDISO_OOC_MAX_CORE_SIZE` via `setenv()` | `AnalysisControl.cpp:1178`, inside `#ifdef _LINUX` |
| BLACS / ScaLAPACK / `p?gemm` / `descinit` / `Cblacs` | **no reference in any source**; upstream `-lmkl_blacs_intelmpi_ilp64` was dead weight and would be wrong with OpenMPI |
| `__INTEL_COMPILER`, `__ICC`, `_MSC_VER`, `_WIN32` | none |
| Intel intrinsics (`immintrin`, `_mm_*`), `__assume`, `__declspec`, `-qopt*` | none |
| `#pragma` | only `omp parallel for / critical / single / for` (no `ivdep`, `simd`, `vector`, `unroll`) |
| `omp_*` calls | `omp_set_num_threads`, `omp_get_num_threads`, `omp_get_thread_num`; `<omp.h>` guarded by `_USE_OMP` |
| `_LINUX` | selects `setenv`, `<sys/time.h>` + `<sys/resource.h>` (`getrusage`), `/` path separator, log banner; `#else` branches are Windows. Keep `-D_LINUX`. |
| MSVC-only functions (`sprintf_s`, `strtok_s`, `_snprintf`, `__int64`, `<windows.h>`) | none in femtic or makeTetraMesh |
| MPI | C API only (`MPI_Init/Finalize/Comm_rank/Comm_size/Bcast/Reduce/Allreduce/Gather(v)/Scatterv/Allgather/Barrier`); no `MPI::` C++ bindings, so OpenMPI 4/5 (which dropped them) are fine |
| C++ standard | C++98-style + `long long`; `-std=c++11` is the floor |
| Source files not in OBJS | `Forward2D*NodeBased.cpp` (5) and `InversionGaussNewtonDataSpace.cpp` are not built upstream; no compiled file includes their headers (grep-verified). Left out on purpose. |
| Mesh tools (makeMtr, TetGen2Femtic, makeDHexaMesh, mergeResultOfFEMTIC) | standard headers only; no MKL/OpenMP/MPI/Intel-specific code |

## Verification performed (no compilation)

`verify_v2.sh` (run inside WSL Ubuntu 24.04, GNU make 4.3) with these failure criteria:

1. Fails if any ported file contains a CR byte (`tr -cd '\r' | wc -c` != 0).
2. Fails if a makefile has fewer than 3 TAB-indented recipe lines or any space-indented one.
3. Fails if the `OBJS` block differs from the CR-stripped reference makefile.
4. Fails if `make -n` errors, or the number of compile commands differs from the number of
   objects (59 femtic, 23 makeTetraMesh, 3 makeMtr, 3 TetGen2Femtic, 10 makeDHexaMesh,
   1 mergeResultOfFEMTIC), or the link line lacks the expected MKL interface library.
5. Fails if `make -n` without `MKLROOT` does not stop with the MKLROOT message, or if
   `make -n clean` without `MKLROOT` fails.

`make -n` exercises makefile syntax, variable expansion and rule selection only; it does
not prove the sources compile (see risk 1).

## Risks and things the build stage should watch

1. **Not compiled.** Only a static audit and `make -n` were done. The most likely g++
   failure is a missing standard `#include` that icpc/MSVC headers provided transitively
   (e.g. `<cstring>` for `memcpy`, `<cstdlib>` for `exit`, `<algorithm>` for `std::min`).
   Fix is a one-line include in the offending file, not a flag change.
2. **CRLF line endings in the clones.** All repos were cloned on Windows with
   `core.autocrlf=true` (`git ls-files --eol`: `i/lf w/crlf`), so checked-out `.cpp/.h`
   and makefiles carry CRLF. g++ accepts CRLF sources. GNU make 4.3 was observed to drop
   the CR from the CRLF `tetgen/makefile` (verifier step 6: `-lm$`, no `^M`), but older
   make versions pass `<CR>` as part of the last token of a recipe line (`-lm<CR>`) and
   fail. The ported files are LF (verified). For `tetgen/makefile` the `BUILD.txt`
   command strips CR first; on the HPC, clone with `git -c core.autocrlf=false clone`
   or run `dos2unix`.
3. **OpenMP runtime mixing.** The GCC build must never pick up `libiomp5` (e.g. via
   `-qmkl`, `-liomp5` or `MKL_THREADING_LAYER=INTEL` at run time), and the Intel build
   must not link `libgomp`. One runtime per binary.
4. **`--as-needed`.** If the GCC link fails with unresolved `mkl_*` symbols,
   `-Wl,--no-as-needed` is missing or was moved after the libraries.
5. **MKL library directory.** imkl 2023 installs to `$MKLROOT/lib/intel64`, imkl 2024+
   to `$MKLROOT/lib`. Both `-L` paths are given; the wrong one is silently ignored.
6. **Floating-point model.** icpx/icpc default to `-fp-model=fast`; g++ `-O3` does not
   reassociate. Expect small numerical differences between the two builds. Never add
   `-ffast-math`/`-Ofast`: PARDISO pivoting and TetGen's predicates are sensitive to it.
7. **Warnings that are not errors.** `m_iparm[i] = NULL` on a `long long`
   (`PARDISOSolver.cpp:50,69,97`) triggers `-Wconversion-null` on g++; `MKL_INT incx = 1.0`
   (`InversionGaussNewtonDataSpace.cpp`, 12 sites, file not built) is a silent
   double-to-integer conversion. Harmless.
8. **`mpiicpx` availability.** mpiicpx (and mpiicx) are absent on Phoenix's intel/2023a (impi 2021.9.0):
   `phoenix_plan/00_discover.sh` on p2-log-2, 2026-09-25, found only `mpiicpc`. The wrapper to use there is
   `mpiicpc -cxx=icpx` (the same icpx through the classic wrapper; `I_MPI_CXX=icpx mpiicpc` is equivalent).
   `phoenix_plan/01_build_femtic.sh` passes it as `make ... CXX="mpiicpc -cxx=icpx"`, which overrides the
   makefile's `CXX = mpiicpx`.
9. **Thread counts at run time.** The control file drives `omp_set_num_threads` and
   `mkl_set_num_threads` (`AnalysisControl.cpp:1150-1152`), overriding `OMP_NUM_THREADS`
   from the scheduler. Not a build issue, but relevant when validating scaling.
10. **PARDISO out-of-core** relies on `MKL_PARDISO_OOC_MAX_CORE_SIZE` set via `setenv`
    and on `pardiso_setenv(PARDISO_OOC_FILE_NAME)`; both exist in imkl 2023 for both
    threading layers.
11. **tetgen with CMake** compiles `predicates.cxx` with the same optimisation as
    `tetgen.cxx`; use the makefile (kept `PREDCXXFLAGS=-O0`) instead.
12. **makeTetraMesh `-mkl=parallel` was a no-op.** The GCC build links no MKL by default;
    if a downstream check expects `libmkl` in `ldd makeTetraMesh`, build with `WITH_MKL=1`.
