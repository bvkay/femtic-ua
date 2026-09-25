#!/bin/bash
# Generates the ported build files. OBJS blocks are copied verbatim from the reference Makefiles.
set -e
S=/c/Users/joint/AppData/Local/Temp/claude/D--BEN-FEMTIC-2026/4e858f54-ea4e-47a8-9815-7766aca9830d/scratchpad
P=$S/ported
objs() { sed -n '/^OBJS/,/^PROGRAM/p' "$1" | sed '$d' | tr -d '\r'; }   # OBJS block verbatim from the reference Makefile
fixtabs() { sed -i 's/^@@/\t/' "$1"; }                                     # '@@' at line start -> real TAB (recipe lines)

########## femtic / GCC + OpenMPI + MKL ##########
F=$P/femtic/Makefile.gcc_openmpi_mkl
cat > "$F" <<'EOF'
# ---------------------------------------------------------------------------
# FEMTIC v5.0 -- Makefile for GCC + OpenMPI + Intel MKL
# Target: EasyBuild foss/2023a (GCC 12.3, OpenMPI 4.1.5) + imkl/2023.1.0
#
#   module load foss/2023a imkl/2023.1.0       # imkl exports MKLROOT
#   cd femtic/src
#   make -f Makefile.gcc_openmpi_mkl -j 8
#
# Ported from Makefile_IntelMPI (mpiicpc, -qopenmp, Intel OpenMP, BLACS).
# Differences from the Intel makefile, and why:
#   * mpicxx (OpenMPI wrapper around g++) replaces mpiicpc.
#   * -fopenmp replaces -qopenmp, so the MKL threading layer must be
#     mkl_gnu_thread + libgomp (NOT mkl_intel_thread + libiomp5: never mix
#     two OpenMP runtimes in one binary).
#   * -lmkl_blacs_intelmpi_ilp64 is dropped: no BLACS/ScaLAPACK symbol is
#     referenced anywhere in the sources (grep-verified), and an Intel-MPI
#     BLACS would not match OpenMPI anyway.
#   * -Wl,--no-as-needed: EasyBuild GCC toolchains link with --as-needed by
#     default, which silently drops MKL's mutually-dependent layers.
#   * Pattern rule %.o: %.cpp so "make -j" builds in parallel.
#   * -m64 is only added on x86_64 (it is not a valid flag on aarch64).
#
# MKL integer interface -- ILP64 is mandatory, not a choice:
#   PARDISOSolver*.cpp call pardiso_64() with long long index arrays and call
#   pardisoinit() with long long* for mtype/iparm (pardisoinit takes MKL_INT*,
#   which is 64-bit only under -DMKL_ILP64), and Inversion*.cpp pass MKL_INT
#   to cblas_dgemm/dgemv and LAPACKE_dpptrf/dsptrf/... .  Hence -DMKL_ILP64 at
#   compile time and libmkl_intel_ilp64 at link time.  Do not substitute lp64.
#
# Language level: the code uses no C++11 keywords/features (verified), so
# -std=c++11 is a safe floor; GCC 12/13 default (gnu++17) also works.
# ---------------------------------------------------------------------------

CXX           = mpicxx
CC            = mpicc

# MKLROOT must point at the MKL installation (EasyBuild's imkl module sets it).
ifeq ($(filter clean,$(MAKECMDGOALS)),)
ifeq ($(strip $(MKLROOT)),)
$(error MKLROOT is not set. Load the MKL module (e.g. "module load imkl") or run: make MKLROOT=/path/to/mkl -f Makefile.gcc_openmpi_mkl)
endif
endif

UNAME_M      := $(shell uname -m 2>/dev/null)
ifeq ($(UNAME_M),x86_64)
ARCHFLAGS     = -m64
endif

CXXSTD        = -std=c++11
CXXFLAGS      = -O3 \
                -fopenmp \
                $(ARCHFLAGS) \
                $(CXXSTD) \
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
objs $S/femtic/src/Makefile_IntelMPI >> "$F"
cat >> "$F" <<'EOF'
PROGRAM       = femtic

.PHONY: all clean

all:            $(PROGRAM)

$(PROGRAM):     $(OBJS)
@@$(CXX) $(CXXFLAGS) $(OBJS) $(LDFLAGS) $(LIBS) -o $(PROGRAM)

# Rebuild everything if any header changes (the upstream makefile tracked no header deps).
$(OBJS): $(wildcard *.h)

%.o: %.cpp
@@$(CXX) $(CXXFLAGS) -c $< -o $@

clean:
@@rm -f *.o *~ $(PROGRAM)
EOF
fixtabs "$F"

########## femtic / Intel oneAPI ##########
F=$P/femtic/Makefile.intel_oneapi
cat > "$F" <<'EOF'
# ---------------------------------------------------------------------------
# FEMTIC v5.0 -- Makefile for Intel oneAPI 2023 (icpx + Intel MPI + MKL)
# Target: EasyBuild intel/2023a (intel-compilers 2023.1, impi 2021.9, imkl 2023.1)
#
#   module load intel/2023a                    # sets MKLROOT, I_MPI_ROOT
#   cd femtic/src
#   make -f Makefile.intel_oneapi -j 8
#
# Compiler wrapper:
#   mpiicpx        -> LLVM-based icpx (oneAPI 2023 and later; recommended)
#   mpiicpc        -> classic icpc (oneAPI <= 2023; classic compilers were
#                     removed in oneAPI 2024). Use this with the original
#                     Makefile_IntelMPI flags if you need bit-for-bit parity.
#   mpiicpc -cxx=icpx   (or: I_MPI_CXX=icpx mpiicpc) -> icpx through the
#                     classic wrapper, for Intel MPI versions without mpiicpx.
#
# Changes vs. the upstream Makefile_IntelMPI:
#   * INTEL_DIR (hard-coded composer_xe_2015 path) replaced by $(MKLROOT).
#   * -lmkl_blacs_intelmpi_ilp64 dropped: no BLACS/ScaLAPACK symbol is used
#     anywhere in the sources (grep-verified).
#   * Pattern rule %.o: %.cpp so "make -j" works.
#
# One-flag alternative: with icpx/icpc you can replace the -I/-L/-l MKL lines
# below by a single "-qmkl-ilp64=parallel" on both compile and link lines
# (it selects mkl_intel_ilp64 + mkl_intel_thread + mkl_core + iomp5 and adds
# the include path).  -DMKL_ILP64 is still required for the headers.
#
# ILP64 is mandatory: see the note in Makefile.gcc_openmpi_mkl (pardiso_64 /
# pardisoinit with long long*, MKL_INT in cblas/LAPACKE calls).
# ---------------------------------------------------------------------------

CXX           = mpiicpx
CC            = mpiicx

ifeq ($(filter clean,$(MAKECMDGOALS)),)
ifeq ($(strip $(MKLROOT)),)
$(error MKLROOT is not set. Load the oneAPI/MKL module (e.g. "module load intel/2023a" or "source setvars.sh"))
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
LDFLAGS       = -L$(MKLROOT)/lib/intel64 -L$(MKLROOT)/lib
LIBS          = -lmkl_intel_ilp64 -lmkl_intel_thread -lmkl_core -liomp5 -lpthread -lm -ldl
EOF
objs $S/femtic/src/Makefile_IntelMPI >> "$F"
cat >> "$F" <<'EOF'
PROGRAM       = femtic

.PHONY: all clean

all:            $(PROGRAM)

$(PROGRAM):     $(OBJS)
@@$(CXX) $(CXXFLAGS) $(OBJS) $(LDFLAGS) $(LIBS) -o $(PROGRAM)

$(OBJS): $(wildcard *.h)

%.o: %.cpp
@@$(CXX) $(CXXFLAGS) -c $< -o $@

clean:
@@rm -f *.o *~ $(PROGRAM)
EOF
fixtabs "$F"

########## makeTetraMesh / GCC ##########
F=$P/makeTetraMesh/Makefile.gcc_mkl
cat > "$F" <<'EOF'
# ---------------------------------------------------------------------------
# makeTetraMesh -- Makefile for GCC (EasyBuild GCC/GCCcore or foss toolchain)
#
#   module load foss/2023a            # (imkl only needed if WITH_MKL=1)
#   cd makeTetraMesh/src
#   make -f Makefile.gcc_mkl -j 8
#
# Ported from the upstream Makefile (icpc -O3 -qopenmp ... LIBS=-mkl=parallel).
#
# MKL: the upstream Makefile links "-mkl=parallel", but the sources make NO
# MKL call at all -- there is no mkl*.h include, no LAPACKE_*/cblas_*/pardiso*
# symbol, no MKL_INT, and no -DMKL_ILP64 (grep-verified; the only external
# runtime it touches is OpenMP: omp_set_num_threads + one "omp parallel for").
# The -mkl=parallel was therefore a no-op, and MKL is NOT linked by default.
#
# Interface choice, should MKL ever be needed: the code uses plain "int"
# everywhere (no long long / MKL_INT), which is the 32-bit-integer LP64
# interface -> libmkl_intel_lp64 (NOT ilp64, which is what FEMTIC itself
# needs).  Enable with "make WITH_MKL=1" to get the matching GNU-threaded
# LP64 link line; MKLROOT must then be set (EasyBuild imkl module does that).
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
$(error WITH_MKL=1 but MKLROOT is not set; load the imkl module or pass MKLROOT=...)
endif
CXXFLAGS     += -I$(MKLROOT)/include
LIBS          = -L$(MKLROOT)/lib/intel64 -L$(MKLROOT)/lib -Wl,--no-as-needed \
                -lmkl_intel_lp64 -lmkl_gnu_thread -lmkl_core -lgomp -lpthread -lm -ldl
endif
EOF
objs $S/makeTetraMesh/src/Makefile >> "$F"
cat >> "$F" <<'EOF'
PROGRAM       = makeTetraMesh

.PHONY: all clean

all:            $(PROGRAM)

$(PROGRAM):     $(OBJS)
@@$(CXX) $(CXXFLAGS) $(OBJS) $(LDFLAGS) $(LIBS) -o $(PROGRAM)

$(OBJS): $(wildcard *.h)

%.o: %.cpp
@@$(CXX) $(CXXFLAGS) -c $< -o $@

clean:
@@rm -f *.o *~ $(PROGRAM)
EOF
fixtabs "$F"

########## makeTetraMesh / Intel oneAPI ##########
F=$P/makeTetraMesh/Makefile.intel_oneapi
cat > "$F" <<'EOF'
# ---------------------------------------------------------------------------
# makeTetraMesh -- Makefile for Intel oneAPI (icpx)
#
#   module load intel/2023a       (or: source /opt/intel/oneapi/setvars.sh)
#   cd makeTetraMesh/src
#   make -f Makefile.intel_oneapi -j 8
#
# Ported from the upstream Makefile (icpc, -mkl=parallel).  icpx spells the
# MKL flag -qmkl=parallel (-mkl is icpc-only and removed in oneAPI 2024).
# NOTE: the sources make no MKL call (see Makefile.gcc_mkl), so -qmkl=parallel
# is kept only for parity with upstream and can be removed without effect.
# For classic icpc on oneAPI <= 2023 use: make CXX=icpc LIBS=-qmkl=parallel
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
objs $S/makeTetraMesh/src/Makefile >> "$F"
cat >> "$F" <<'EOF'
PROGRAM       = makeTetraMesh

.PHONY: all clean

all:            $(PROGRAM)

$(PROGRAM):     $(OBJS)
@@$(CXX) $(CXXFLAGS) $(OBJS) $(LDFLAGS) $(LIBS) -o $(PROGRAM)

$(OBJS): $(wildcard *.h)

%.o: %.cpp
@@$(CXX) $(CXXFLAGS) -c $< -o $@

clean:
@@rm -f *.o *~ $(PROGRAM)
EOF
fixtabs "$F"

########## plain C++ tools ##########
simple() { # name  reference-makefile  optflags  program
  local name="$1" ref="$2" flags="$3" prog="$4"
  local F=$P/$name/Makefile.gcc
  cat > "$F" <<EOF
# ---------------------------------------------------------------------------
# $name -- Makefile for GCC (any EasyBuild GCC/GCCcore/foss toolchain)
#
#   module load GCC/12.3.0        (or foss/2023a)
#   cd $name/src
#   make -f Makefile.gcc -j 4
#
# Ported from the upstream Makefile (icpc $flags). Plain, single-threaded
# C++98-compatible code: no MKL, no OpenMP, no MPI, no Intel-only flags.
# Flags are the upstream ones with only the compiler name changed.
# ---------------------------------------------------------------------------

CXX           = g++
CC            = gcc
CXXFLAGS      = $flags
DEST          = ./
LDFLAGS       =
LIBS          =
EOF
  if [ -n "$ref" ]; then objs "$ref" >> "$F"; else printf 'OBJS          = mergeResult.o\n' >> "$F"; fi
  cat >> "$F" <<EOF
PROGRAM       = $prog

.PHONY: all clean

all:            \$(PROGRAM)

\$(PROGRAM):     \$(OBJS)
@@\$(CXX) \$(CXXFLAGS) \$(OBJS) \$(LDFLAGS) \$(LIBS) -o \$(PROGRAM)

\$(OBJS): \$(wildcard *.h)

%.o: %.cpp
@@\$(CXX) \$(CXXFLAGS) -c \$< -o \$@

clean:
@@rm -f *.o *~ \$(PROGRAM)
EOF
  fixtabs "$F"
}
simple makeMtr        $S/makeMtr/src/Makefile        "-O2 -DNDEBUG" makeMtr
simple TetGen2Femtic  $S/TetGen2Femtic/src/Makefile  "-O2 -DNDEBUG" TetGen2Femtic
simple makeDHexaMesh  $S/makeDHexaMesh/src/Makefile  "-O3 -DNDEBUG" makeDHexaMesh
simple mergeResultOfFEMTIC ""                        "-O2 -DNDEBUG" mergeResultOfFEMTIC

########## tetgen ##########
cat > $P/tetgen/BUILD.txt <<'EOF'
cd tetgen && sed -i 's/\r$//' makefile && make tetgen CXX=g++ CXXFLAGS=-O3 PREDCXXFLAGS=-O0
# (upstream makefile defaults; keep PREDCXXFLAGS=-O0 for predicates.cxx -- Shewchuk's exact-arithmetic predicates break under optimisation/fast-math. The sed strips the CRLF that the Windows clone added (git autocrlf=true); harmless if already LF. CMake alternative "cmake -S . -B build -DBUILD_EXECUTABLE=ON -DBUILD_LIBRARY=OFF -DCMAKE_BUILD_TYPE=Release && cmake --build build" compiles predicates.cxx with the same -O flags as tetgen.cxx, so prefer make. For icpx: make tetgen CXX=icpx CXXFLAGS="-O3 -fp-model=precise" PREDCXXFLAGS="-O0 -fp-model=precise", because icpx defaults to fast-math.)
EOF
echo "generated:"; find $P -type f | sort
