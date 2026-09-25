#!/bin/bash
# gen_v2.sh -- (re)generate the ported build files. Run INSIDE WSL (GNU sed/tr, LF heredocs).
# OBJS blocks are copied verbatim (CR-stripped) from the reference makefiles.
# Recipe lines are written with a '@@' placeholder that fixtabs turns into a real TAB.
set -euo pipefail
S=/mnt/c/Users/joint/AppData/Local/Temp/claude/D--BEN-FEMTIC-2026/4e858f54-ea4e-47a8-9815-7766aca9830d/scratchpad
P=$S/ported

rm -rf "$P"
mkdir -p "$P"/femtic "$P"/makeTetraMesh "$P"/makeMtr "$P"/TetGen2Femtic "$P"/makeDHexaMesh "$P"/mergeResultOfFEMTIC "$P"/tetgen

objs()    { tr -d '\r' < "$1" | sed -n '/^OBJS/,/^PROGRAM/p' | sed '$d'; }
fixtabs() { sed -i 's/^@@/\t/' "$1"; }

# Common rule block shared by every makefile ($1 = program name)
rules() {
cat <<EOF
PROGRAM       = $1

.PHONY: all clean

all:            \$(PROGRAM)

\$(PROGRAM):     \$(OBJS)
@@\$(CXX) \$(CXXFLAGS) \$(OBJS) \$(LDFLAGS) \$(LIBS) -o \$(PROGRAM)

# The upstream makefiles track no header dependencies; rebuild every object
# when any header changes (cheap for projects of this size, and always correct).
\$(OBJS): \$(wildcard *.h)

# Pattern rule so that "make -j N" compiles translation units in parallel.
%.o: %.cpp
@@\$(CXX) \$(CXXFLAGS) -c \$< -o \$@

clean:
@@rm -f *.o *~ \$(PROGRAM)
EOF
}

############################################################################
# femtic / (A) GCC + OpenMPI + Intel MKL
############################################################################
F=$P/femtic/Makefile.gcc_openmpi_mkl
cat > "$F" <<'EOF'
# ---------------------------------------------------------------------------
# FEMTIC v5.0 -- Makefile for GCC + OpenMPI + Intel MKL
# Target: EasyBuild foss/2023a (GCC 12.3.0, OpenMPI 4.1.5) + imkl/2023.1.0
#
#   module load foss/2023a imkl/2023.1.0      # imkl exports MKLROOT
#   cd femtic/src
#   make -f Makefile.gcc_openmpi_mkl -j 8
#
# Ported from Makefile_IntelMPI (mpiicpc -O3 -qopenmp -D_LINUX -DMKL_ILP64
# -D_USE_OMP -DNDEBUG, linking mkl_intel_ilp64 mkl_intel_thread mkl_core
# mkl_blacs_intelmpi_ilp64 iomp5 pthread m dl).  What changed, and why:
#   * mpicxx (the OpenMPI wrapper around g++) replaces mpiicpc.
#   * -fopenmp replaces -qopenmp.  The MKL threading layer must match the
#     OpenMP runtime, so it is mkl_gnu_thread + libgomp here.  Never link
#     mkl_intel_thread/libiomp5 into a -fopenmp binary: two OpenMP runtimes in
#     one process give wrong thread counts, oversubscription or deadlocks.
#   * -lmkl_blacs_intelmpi_ilp64 is dropped.  No BLACS/ScaLAPACK symbol is
#     referenced anywhere in the sources (grep-verified: blacs, scalapack,
#     descinit, p?gemm all absent), and an Intel-MPI BLACS would not be
#     ABI-compatible with OpenMPI anyway.
#   * -Wl,--no-as-needed is placed before the MKL libraries.  Toolchains that
#     link with --as-needed otherwise drop MKL's mutually dependent layers and
#     the link fails with unresolved mkl_* symbols.
#   * -L$(MKLROOT)/lib is given as well as -L$(MKLROOT)/lib/intel64: imkl 2023
#     uses lib/intel64, imkl 2024+ dropped the intel64 subdirectory.
#   * -std=c++11: the sources are C++98-style (no auto, nullptr, override,
#     lambdas, smart pointers or range-for; the one shrink_to_fit() call in
#     ResistivityBlock.cpp:132 is inside #ifndef _LINUX and compiled out) but
#     use 'long long' throughout, which is standard only from C++11.  GCC 12/13
#     default gnu++17 also works.
#   * -m64: MKL is x86-64 only, so the flag is always valid on a host that has
#     MKL.
#   * Pattern rule %.o: %.cpp so that "make -j N" builds in parallel.
#
# ILP64 is mandatory -- the code does not compile against the LP64 interface:
#   PARDISOSolver.h:87-102 declares m_maxfct, m_mnum, m_mtype, m_numEquations,
#   m_iparm[64] and m_msglvl as 'long long int'.  PARDISOSolver.cpp:100 passes
#   them to pardisoinit(void*, MKL_INT*, MKL_INT*), which only type-checks when
#   MKL_INT is 64-bit, i.e. under -DMKL_ILP64.  Every factorisation and solve
#   goes through pardiso_64() with 'long long' row/column arrays
#   (ComplexSparseMatrix.cpp:184,207; DoubleSparseMatrix.cpp:180,203).
#   Inversion*.cpp pass MKL_INT to cblas_dgemm/cblas_dgemv and lapack_int
#   (== MKL_INT) to LAPACKE_dpptrf/dpptrs/dsptrf/dsptrs; RougheningSquareMatrix
#   calls LAPACKE_dgebrd/dbdsdc/dsptrd/dsterf the same way.  There is no
#   #ifdef MKL_ILP64 fallback anywhere.  Hence -DMKL_ILP64 at compile time and
#   libmkl_intel_ilp64 at link time; do not substitute lp64.
# ---------------------------------------------------------------------------

CXX           = mpicxx
CC            = mpicc

# MKLROOT is taken from the environment (EasyBuild's imkl module exports it).
# Fail early with a clear message instead of a cryptic "mkl.h: No such file";
# "make clean" is allowed without MKL.
ifeq ($(filter clean,$(MAKECMDGOALS)),)
ifeq ($(strip $(MKLROOT)),)
$(error MKLROOT is not set. Load the MKL module (e.g. "module load imkl") or run "make MKLROOT=/path/to/mkl -f Makefile.gcc_openmpi_mkl")
endif
endif

CXXFLAGS      = -O3 \
                -fopenmp \
                -m64 \
                -std=c++11 \
                -D_LINUX \
                -DMKL_ILP64 \
                -D_USE_OMP \
                -DNDEBUG \
                -I$(MKLROOT)/include
DEST          = ./
LDFLAGS       =
LIBS          = -L$(MKLROOT)/lib/intel64 -L$(MKLROOT)/lib \
                -Wl,--no-as-needed \
                -lmkl_intel_ilp64 -lmkl_gnu_thread -lmkl_core \
                -lgomp -lpthread -lm -ldl
EOF
objs "$S/femtic/src/Makefile_IntelMPI" >> "$F"
rules femtic >> "$F"
fixtabs "$F"

############################################################################
# femtic / (B) Intel oneAPI 2023 (icpx + Intel MPI + MKL)
############################################################################
F=$P/femtic/Makefile.intel_oneapi
cat > "$F" <<'EOF'
# ---------------------------------------------------------------------------
# FEMTIC v5.0 -- Makefile for Intel oneAPI 2023 (icpx + Intel MPI + MKL)
# Target: EasyBuild intel/2023a (intel-compilers 2023.1, impi 2021.9, imkl 2023.1)
#
#   module load intel/2023a                   # exports MKLROOT and I_MPI_ROOT
#   cd femtic/src
#   make -f Makefile.intel_oneapi -j 8
#
# Compiler wrapper:
#   mpiicpx           LLVM-based icpx (Intel MPI >= 2021.7; recommended).
#   mpiicpc           classic icpc on oneAPI <= 2023.  The classic compilers
#                     were removed in oneAPI 2024.  Use this with the upstream
#                     Makefile_IntelMPI flags if bit-for-bit parity with the
#                     original build matters.
#   mpiicpc -cxx=icpx (or I_MPI_CXX=icpx mpiicpc) drives icpx through the
#                     classic wrapper on Intel MPI versions without mpiicpx.
#
# Changes vs. the upstream Makefile_IntelMPI:
#   * The hard-coded INTEL_DIR (/opt/intel/composer_xe_2015...) is replaced
#     by $(MKLROOT) from the environment.
#   * -lmkl_blacs_intelmpi_ilp64 is dropped: no BLACS/ScaLAPACK symbol is used
#     anywhere in the sources (grep-verified).
#   * -L$(MKLROOT)/lib added next to lib/intel64 (imkl 2024+ layout).
#   * Pattern rule %.o: %.cpp so that "make -j N" works.
#
# One-flag alternative: with icpx/icpc the -I/-L/-l MKL lines below can be
# replaced by a single "-qmkl-ilp64=parallel" on both the compile and the link
# line.  It selects mkl_intel_ilp64 + mkl_intel_thread + mkl_core + iomp5 and
# adds the include path.  -DMKL_ILP64 is still required so that the headers
# declare MKL_INT as 64-bit.  (The classic "-mkl=..." spelling is icpc-only.)
#
# Floating point: icpx defaults to -fp-model=fast (as classic icpc did), GCC
# -O3 does not reassociate.  Add -fp-model=precise to CXXFLAGS if results must
# be comparable with the GCC build.  Never use -ffast-math/-Ofast.
#
# ILP64 is mandatory: see the note in Makefile.gcc_openmpi_mkl (pardiso_64,
# pardisoinit with long long*, MKL_INT in cblas/LAPACKE calls).
# ---------------------------------------------------------------------------

CXX           = mpiicpx
CC            = mpiicx

ifeq ($(filter clean,$(MAKECMDGOALS)),)
ifeq ($(strip $(MKLROOT)),)
$(error MKLROOT is not set. Load the oneAPI/MKL module (e.g. "module load intel/2023a") or source setvars.sh)
endif
endif

CXXFLAGS      = -O3 \
                -qopenmp \
                -D_LINUX \
                -DMKL_ILP64 \
                -D_USE_OMP \
                -DNDEBUG \
                -I$(MKLROOT)/include
DEST          = ./
LDFLAGS       =
LIBS          = -L$(MKLROOT)/lib/intel64 -L$(MKLROOT)/lib \
                -lmkl_intel_ilp64 -lmkl_intel_thread -lmkl_core \
                -liomp5 -lpthread -lm -ldl
EOF
objs "$S/femtic/src/Makefile_IntelMPI" >> "$F"
rules femtic >> "$F"
fixtabs "$F"

############################################################################
# makeTetraMesh / GCC (+ optional MKL)
############################################################################
F=$P/makeTetraMesh/Makefile.gcc_mkl
cat > "$F" <<'EOF'
# ---------------------------------------------------------------------------
# makeTetraMesh -- Makefile for GCC (EasyBuild GCC/GCCcore or foss toolchain)
#
#   module load foss/2023a              # imkl only needed with WITH_MKL=1
#   cd makeTetraMesh/src
#   make -f Makefile.gcc_mkl -j 8
#
# Ported from the upstream Makefile (icpc -O3 -qopenmp -D_USE_OMP
# -D_THICKNESS_FUNC -DNDEBUG, LIBS = -mkl=parallel).
#
# MKL interface decision.  The upstream makefile links "-mkl=parallel", but
# the sources make NO MKL call at all: there is no mkl*.h include, no
# cblas_*/LAPACKE_*/pardiso* symbol, no MKL_INT, and -DMKL_ILP64 is not
# defined (grep-verified).  The only external runtime the code touches is
# OpenMP (omp_set_num_threads and one "omp parallel for" in TriangleList.cpp).
# "-mkl=parallel" was therefore a no-op, and linking MKL here would only add
# a run-time dependency on three MKL shared objects the binary never calls.
# MKL is NOT linked by default.
#
# If MKL is ever wanted (e.g. a future version adds a LAPACK call), the code's
# integer type is plain 'int' everywhere, which is the 32-bit LP64 interface:
# libmkl_intel_lp64 (NOT ilp64 -- that is what FEMTIC itself needs because it
# uses long long / MKL_INT).  "make WITH_MKL=1" enables the matching
# GNU-threaded LP64 link line; MKLROOT must then be set (imkl module does it).
# ---------------------------------------------------------------------------

CXX           = g++
CC            = gcc
CXXFLAGS      = -O3 \
                -fopenmp \
                -D_USE_OMP \
                -D_THICKNESS_FUNC \
                -DNDEBUG
DEST          = ./
LDFLAGS       =
LIBS          =

WITH_MKL     ?= 0
ifeq ($(WITH_MKL),1)
ifeq ($(strip $(MKLROOT)),)
$(error WITH_MKL=1 but MKLROOT is not set. Load the imkl module or pass MKLROOT=/path/to/mkl)
endif
CXXFLAGS     += -I$(MKLROOT)/include
LIBS          = -L$(MKLROOT)/lib/intel64 -L$(MKLROOT)/lib -Wl,--no-as-needed \
                -lmkl_intel_lp64 -lmkl_gnu_thread -lmkl_core -lgomp -lpthread -lm -ldl
endif
EOF
objs "$S/makeTetraMesh/src/Makefile" >> "$F"
rules makeTetraMesh >> "$F"
fixtabs "$F"

############################################################################
# makeTetraMesh / Intel oneAPI (icpx)
############################################################################
F=$P/makeTetraMesh/Makefile.intel_oneapi
cat > "$F" <<'EOF'
# ---------------------------------------------------------------------------
# makeTetraMesh -- Makefile for Intel oneAPI (icpx)
#
#   module load intel/2023a       (or: source /opt/intel/oneapi/setvars.sh)
#   cd makeTetraMesh/src
#   make -f Makefile.intel_oneapi -j 8
#
# Ported from the upstream Makefile (icpc, LIBS = -mkl=parallel).  icpx spells
# the MKL flag -qmkl=parallel; the classic -mkl=... form is icpc-only and is
# gone in oneAPI 2024.  It selects the LP64 interface with the Intel OpenMP
# threading layer (mkl_intel_lp64 + mkl_intel_thread + mkl_core + iomp5),
# consistent with -qopenmp.
#
# NOTE: the sources make no MKL call (see Makefile.gcc_mkl), so -qmkl=parallel
# is kept only for parity with upstream and can be removed without effect.
# For classic icpc on oneAPI <= 2023:  make CXX=icpc LIBS=-qmkl=parallel
# ---------------------------------------------------------------------------

CXX           = icpx
CC            = icx
CXXFLAGS      = -O3 \
                -qopenmp \
                -D_USE_OMP \
                -D_THICKNESS_FUNC \
                -DNDEBUG
DEST          = ./
LDFLAGS       =
LIBS          = -qmkl=parallel
EOF
objs "$S/makeTetraMesh/src/Makefile" >> "$F"
rules makeTetraMesh >> "$F"
fixtabs "$F"

############################################################################
# Plain C++ tools: makeMtr, TetGen2Femtic, makeDHexaMesh, mergeResultOfFEMTIC
############################################################################
simple() {  # name  reference-makefile(or "")  CXXFLAGS  program
  local name=$1 ref=$2 flags=$3 prog=$4
  local F=$P/$name/Makefile.gcc
  local origin="Ported from the upstream Makefile (icpc $flags)."
  [ -n "$ref" ] || origin="Upstream ships no makefile for this tool (single translation unit); flags follow the sibling tools (icpc $flags)."
  cat > "$F" <<EOF
# ---------------------------------------------------------------------------
# $name -- Makefile for GCC (any EasyBuild GCC/GCCcore/foss toolchain)
#
#   module load GCC/12.3.0        (or foss/2023a)
#   cd $name/src
#   make -f Makefile.gcc -j 4
#
# $origin
# Plain single-threaded C++98-compatible code: no MKL, no OpenMP, no MPI,
# no Intel-only flags or headers (grep-verified).  Only the compiler name
# changed; the optimisation level and -DNDEBUG are the upstream ones.
# ---------------------------------------------------------------------------

CXX           = g++
CC            = gcc
CXXFLAGS      = $flags
DEST          = ./
LDFLAGS       =
LIBS          =
EOF
  if [ -n "$ref" ]; then objs "$ref" >> "$F"; else printf 'OBJS          = mergeResult.o\n' >> "$F"; fi
  rules "$prog" >> "$F"
  fixtabs "$F"
}
simple makeMtr             "$S/makeMtr/src/Makefile"        "-O2 -DNDEBUG" makeMtr
simple TetGen2Femtic       "$S/TetGen2Femtic/src/Makefile"  "-O2 -DNDEBUG" TetGen2Femtic
simple makeDHexaMesh       "$S/makeDHexaMesh/src/Makefile"  "-O3 -DNDEBUG" makeDHexaMesh
simple mergeResultOfFEMTIC ""                               "-O2 -DNDEBUG" mergeResultOfFEMTIC

############################################################################
# tetgen: note only (upstream makefile is used as-is)
############################################################################
cat > "$P/tetgen/BUILD.txt" <<'EOF'
cd tetgen && sed -i 's/\r$//' makefile && make tetgen CXX=g++ CXXFLAGS=-O3 PREDCXXFLAGS=-O0
# These are the upstream makefile defaults.  PREDCXXFLAGS=-O0 MUST stay: predicates.cxx is Shewchuk's exact-arithmetic code and breaks under optimisation or fast-math.  Never add -ffast-math/-Ofast (icpx: add -fp-model=precise to both flag sets).
# The sed strips the CRLF that a Windows clone (core.autocrlf=true) adds; harmless on an LF file.  GNU make 4.3 was observed to drop the CR itself, older make versions pass "-lm<CR>" to the linker; the sed is cheap insurance.
# CMake alternative (cmake -S . -B build -DBUILD_EXECUTABLE=ON -DBUILD_LIBRARY=OFF -DCMAKE_BUILD_TYPE=Release && cmake --build build) compiles predicates.cxx with the same -O flags as tetgen.cxx, so prefer make.
EOF

############################################################################
# README
############################################################################
cat > "$P/README.md" <<'EOF'
# FEMTIC v5.0 + mesh tools: EasyBuild toolchain port (build files only)

Nothing here has been compiled. These are drop-in makefiles for a later build stage,
written after a static audit of the sources. Copy each file next to the sources it
belongs to (e.g. `femtic/src/`) and run `make -f <name> -j N`.

| Project | File | Toolchain | Compiler | Notes |
|---|---|---|---|---|
| femtic | `femtic/Makefile.gcc_openmpi_mkl` | foss/2023a + imkl/2023.1.0 | `mpicxx` | GNU OpenMP + `mkl_gnu_thread`, ILP64 |
| femtic | `femtic/Makefile.intel_oneapi` | intel/2023a | `mpiicpx` | Intel OpenMP + `mkl_intel_thread`, ILP64 |
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
CXX      = mpiicpx     # "mpiicpc" = classic icpc (oneAPI <= 2023); "mpiicpc -cxx=icpx" also works
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
8. **`mpiicpx` availability.** Present in Intel MPI >= 2021.7 (intel/2023a ships 2021.9).
   On older stacks use `mpiicpc -cxx=icpx` or `I_MPI_CXX=icpx mpiicpc`.
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
EOF

echo "generated:"; find "$P" -type f | sort
