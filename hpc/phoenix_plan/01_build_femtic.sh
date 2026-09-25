#!/bin/bash -l
# =============================================================================
# 01_build_femtic.sh -- build FEMTIC v5.0 + the tetra-mesh tool chain on Phoenix
#
# Step A, sources (LOGIN node, or an interactive-partition job; both have internet):
#     FETCH_ONLY=1 bash -l 01_build_femtic.sh
#   Compute nodes may have no outbound internet, so this script NEVER clones or downloads inside a
#   Slurm job on any partition other than 'interactive'; it stops and says so instead.
# Step B, build + tests (interactive session: needed for the smoke test T2/T5; max 8 cpus per job):
#     srun -p interactive -N 1 -n 8 --mem=16GB --time=04:00:00 --pty bash
#     TOOLCHAIN=foss  bash -l 01_build_femtic.sh     # GCC 12.3 + OpenMPI 4.1.5 + Intel MKL 2023.1 (default)
#     TOOLCHAIN=intel bash -l 01_build_femtic.sh     # intel-compilers 2023.1 + Intel MPI 2021.9 + MKL 2023.1
#   Options (environment): SRC, BIN, PORTED, TARBALLS, JOBS=8, PIN=1, SMOKE=auto|1|0, FETCH_ONLY=0|1,
#                          MODS="<module list>", INTEL_MPICXX=auto|mpiicpx|"mpiicpc -cxx=icpx"|mpiicpc
#
# Before running:
#   1. copy (WinSCP) the ported Makefiles to $SRC/ported/ (same tree:
#      ported/femtic/Makefile.gcc_openmpi_mkl, ported/makeTetraMesh/Makefile.gcc_mkl, ...)
#   2. keep femtic_lib.sh next to this script (it is installed to $BIN)
#   3. run 00_discover.sh and fix the module names below if they differ (all "VERIFY on Phoenix")
#   4. if a shebang fails with "bad interpreter ^M", the file has CRLF endings: dos2unix *.sh *.slurm
#
# Sources: the tree does not need git. Per repo, the first of these that applies is used:
#   a) $SRC/<repo>/.git          a git checkout; PIN=1 checks out the pinned commit (below)
#   b) $SRC/<repo>/ without .git a pre-copied tree (WinSCP, unpacked GitHub zip). Its version is read
#                                from $SRC/<repo>/COMMIT_SHA.txt; without that file it is reported
#                                as UNKNOWN (the ported OBJS lists match the pinned commit only)
#   c) $TARBALLS/<repo>-<sha>.tar.gz | .tgz | .zip  the GitHub archive of the pinned commit
#                                (https://github.com/<owner>/<repo>/archive/<sha>.tar.gz), unpacked to (b)
#                                with COMMIT_SHA.txt written; download it on Windows and WinSCP it over
#   d) fetch (login node / interactive job only): git clone + checkout if git exists, else curl the
#                                GitHub archive of the pinned commit, as in (c)
#
# What it does
#   1. gets the 7 upstream sources as above, pinned to the commits the ported Makefiles were audited
#      against -- their OBJS lists were copied from these commits, so a newer upstream commit that
#      adds a .cpp would otherwise fail at link time
#   2. loads the toolchain modules
#   3. builds each tool with its ported Makefile, installs binaries to $BIN
#   4. writes $BIN/femtic_env.sh (module loads + PATH + helpers) that 03/04/05/06 source
#   5. TEST T1 (linkage) -- fails if femtic is not dynamically linked to libmkl_core and
#      libmkl_intel_ilp64, if any library is "not found", or if the OpenMP runtimes are mixed
#   6. TEST T2/T5 (smoke + restart equivalence, only inside a Slurm allocation unless SMOKE=1):
#      runs FEMTIC's own example INV_MT_01/Tetra with 2 ranks x 2 threads, once straight
#      (ITERATION 0 2) and once as 0->1 then restart 1->2 through the same femtic_ctl_set /
#      femtic_last_iter code the 3-day chain uses. Fails if either run errors, if the restart
#      leg does not start at iteration 1, or if the restart misfit differs from the straight run
#      by more than 1e-4 (iteration 1) / 1e-3 (iteration 2) relative. Tolerances allow for the
#      7-significant-digit model file (%15e) the restart re-reads; a broken restart
#      (wrong start model or iteration) changes the misfit by tens of percent.
#
# Toolchain facts (see README_phoenix.md):
#   * intel/2023a = intel-compilers 2023.1.0 + impi 2021.9.0 + imkl 2023.1.0 (+ GCCcore 12.3.0)  (VERIFY on Phoenix)
#     per the EasyBuild v4.9.4 easyconfigs; whether Phoenix has it is VERIFY on Phoenix.
#   * intel-compilers 2023.1.0 still ships classic icpc (removed in oneAPI 2024.0).
#   * mpiicpx may or may not exist in impi 2021.9; this script auto-detects it and falls back to
#     "mpiicpc -cxx=icpx" (the same LLVM icpx through the classic wrapper). 00_discover.sh reports
#     which wrappers exist. ported/femtic/Makefile.intel_oneapi says CXX = mpiicpx; the make call
#     below always passes CXX=<detected wrapper>.
#   * the EasyBuild imkl module sets MKLROOT (<prefix>/mkl/2023.1.0) and LD_LIBRARY_PATH.
# =============================================================================
set -o pipefail            # no 'set -u/-e': Lmod/conda shell functions touch unset variables

TOOLCHAIN="${TOOLCHAIN:-foss}"
SRC="${SRC:-/hpcfs/users/$USER/femtic_src}"
BIN="${BIN:-/hpcfs/users/$USER/femtic/bin}"
PORTED="${PORTED:-$SRC/ported}"
TARBALLS="${TARBALLS:-$SRC/tarballs}"
PLAN_DIR="${PLAN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
JOBS="${JOBS:-8}"
PIN="${PIN:-1}"
SMOKE="${SMOKE:-auto}"
FETCH_ONLY="${FETCH_ONLY:-0}"
INTEL_MPICXX="${INTEL_MPICXX:-auto}"
EB_MODULES="/hpcfs/users/$USER/easybuild/modules/all"     # EasyBuild fallback prefix (see bottom)

mkdir -p "$SRC" "$BIN" || { echo "cannot create $SRC / $BIN"; exit 1; }
LOG="$SRC/build_${TOOLCHAIN}_$(date +%Y%m%d_%H%M%S).log"
[ "$FETCH_ONLY" = 1 ] && LOG="$SRC/fetch_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
echo "== $(date)  TOOLCHAIN=$TOOLCHAIN  SRC=$SRC  BIN=$BIN  PORTED=$PORTED  host=$(hostname)  job=${SLURM_JOB_ID:-none} partition=${SLURM_JOB_PARTITION:-none}"
die() { echo "ERROR: $*"; echo "log: $LOG"; exit 1; }

case "$SRC$BIN" in /home/*) echo "WARNING: building under /home (10 GB quota); use /hpcfs." ;; esac
[ -f "$PLAN_DIR/femtic_lib.sh" ] || die "femtic_lib.sh not found next to this script ($PLAN_DIR)"

# -----------------------------------------------------------------------------
# 1. Sources, pinned to the commits the ported Makefiles were written against (2026-09-25)
# -----------------------------------------------------------------------------
declare -A URL=(
  [femtic]=https://github.com/yoshiya-usui/femtic.git
  [makeTetraMesh]=https://github.com/yoshiya-usui/makeTetraMesh.git
  [makeMtr]=https://github.com/yoshiya-usui/makeMtr.git
  [TetGen2Femtic]=https://github.com/yoshiya-usui/TetGen2Femtic.git
  [makeDHexaMesh]=https://github.com/yoshiya-usui/makeDHexaMesh.git
  [mergeResultOfFEMTIC]=https://github.com/yoshiya-usui/mergeResultOfFEMTIC.git
  [tetgen]=https://github.com/libigl/tetgen.git
)
declare -A REF=(
  [femtic]=26c8606ea61717a9386f93fff47203391836829c                 # 2026-08-31 (v5.0)
  [makeTetraMesh]=92a9a32e0683458f7908f75743a8e3777753d0a1          # 2026-06-19
  [makeMtr]=df8e2071f908dfd9dc30333ec548a42dc2e5a5c1                # 2021-11-17
  [TetGen2Femtic]=ceb8bfb1493092ed7c6a1a52352307be356d31e3          # 2026-08-26
  [makeDHexaMesh]=66afbfcaf8fea8c64ddcf686e52e553895559238          # 2026-06-19
  [mergeResultOfFEMTIC]=4fe54e1e6c0a55f636fc15a6b1d5bd646d739487    # 2022-05-31
  [tetgen]=e05aca7df74e3f531bc35733ed87d36d437266c5                 # 2025-04-15
)
ORDER=(femtic makeTetraMesh makeMtr TetGen2Femtic makeDHexaMesh mergeResultOfFEMTIC tetgen)

# Fetching is allowed on the login node and in interactive-partition jobs only.
CAN_FETCH=1
if [ -n "${SLURM_JOB_ID:-}" ] && [ "${SLURM_JOB_PARTITION:-}" != interactive ]; then CAN_FETCH=0; fi
HAVE_GIT=0; command -v git >/dev/null 2>&1 && HAVE_GIT=1
echo "-- source policy: fetch allowed=$CAN_FETCH  git=$([ "$HAVE_GIT" = 1 ] && git --version 2>/dev/null || echo absent)  tarballs=$TARBALLS"

unpack() {   # unpack <repo> <archive> -> $SRC/<repo>
  local r=$1 a=$2 tmp="$SRC/.unpack_$1" top
  rm -rf "$tmp"; mkdir -p "$tmp" || die "cannot create $tmp"
  case "$a" in
    *.tar.gz|*.tgz) tar -xzf "$a" -C "$tmp" ;;
    *.zip)          unzip -q "$a" -d "$tmp" ;;
    *)              false ;;
  esac || die "cannot unpack $a"
  top=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)
  [ -n "$top" ] || die "$a contains no top-level directory"
  mv "$top" "$SRC/$r" || die "cannot move $top to $SRC/$r"
  rm -rf "$tmp"
}

UNKNOWN_VERSION=()
for r in "${ORDER[@]}"; do
  d="$SRC/$r"; sha=${REF[$r]}
  if [ ! -d "$d" ]; then
    arc=$(ls "$TARBALLS/$r-$sha".tar.gz "$TARBALLS/$r-$sha".tgz "$TARBALLS/$r-$sha".zip \
             "$TARBALLS/$r-${sha:0:7}".tar.gz "$TARBALLS/$r-${sha:0:7}".zip 2>/dev/null | head -1)
    if [ -n "$arc" ]; then
      echo "-- $r: unpacking $arc"
      unpack "$r" "$arc"; echo "$sha" > "$d/COMMIT_SHA.txt"
    elif [ "$CAN_FETCH" = 0 ]; then
      die "$r is not in $SRC and this is a job on partition '${SLURM_JOB_PARTITION:-?}' (compute nodes may have no internet). Fetch first on the login node: FETCH_ONLY=1 bash -l $0  (or put $r-$sha.tar.gz in $TARBALLS)"
    elif [ "$HAVE_GIT" = 1 ]; then
      echo "-- cloning $r"
      git clone --quiet --depth 1 "${URL[$r]}" "$d" || die "git clone ${URL[$r]} failed (internet on this node?)"
    else
      echo "-- $r: no git; downloading the archive of commit $sha"
      mkdir -p "$TARBALLS" || die "cannot create $TARBALLS"
      curl -fsSL -o "$TARBALLS/$r-$sha.tar.gz" "${URL[$r]%.git}/archive/$sha.tar.gz" \
        || die "download of ${URL[$r]%.git}/archive/$sha.tar.gz failed (internet on this node?)"
      unpack "$r" "$TARBALLS/$r-$sha.tar.gz"; echo "$sha" > "$d/COMMIT_SHA.txt"
    fi
  fi
  # version / pin
  if [ -d "$d/.git" ] && [ "$HAVE_GIT" = 1 ]; then
    if [ "$PIN" = 1 ]; then
      if ! git -C "$d" cat-file -e "$sha^{commit}" 2>/dev/null; then
        [ "$CAN_FETCH" = 1 ] || die "pinned commit $sha of $r is not in $d and fetching is not allowed in this job -- run FETCH_ONLY=1 on the login node"
        git -C "$d" fetch --quiet --depth 1 origin "$sha" || die "cannot fetch pinned commit $sha of $r"
      fi
      git -C "$d" checkout --quiet "$sha" || die "checkout $sha failed in $d (local edits to tracked files?)"
    fi
    HEAD=$(git -C "$d" rev-parse HEAD); DATE=$(git -C "$d" log -1 --format=%cs)
  else
    HEAD=$(tr -d ' \r\n' < "$d/COMMIT_SHA.txt" 2>/dev/null); DATE="git-free tree"
  fi
  if [ -z "$HEAD" ]; then
    echo "-- $r: git-free tree WITHOUT COMMIT_SHA.txt -> version UNKNOWN. The ported Makefiles match $sha only;"
    echo "   if that is what you copied, record it:  echo $sha > $d/COMMIT_SHA.txt"
    UNKNOWN_VERSION+=("$r")
  elif [[ "$sha" != "$HEAD"* ]] || [ "${#HEAD}" -lt 7 ]; then
    if [ "$PIN" = 1 ]; then die "$r is at '$HEAD', pinned $sha (PIN=0 to accept, at your own risk: OBJS lists may not match)"; fi
    echo "-- $r @ $HEAD ($DATE)  [UNPINNED: OBJS lists may not match]"
  else
    echo "-- $r @ ${HEAD:0:7} ($DATE)"
  fi
done
[ ${#UNKNOWN_VERSION[@]} -eq 0 ] || echo "WARNING: unknown source version for: ${UNKNOWN_VERSION[*]} (build continues; T1/T2 will show a mismatch that breaks the build)"
if [ "$FETCH_ONLY" = 1 ]; then echo "== FETCH_ONLY: sources ready in $SRC; now build in an interactive job (step B)"; exit 0; fi

# -----------------------------------------------------------------------------
# 2. Modules (VERIFY on Phoenix -- confirm with phoenix_discovery_*.txt)
#    Phoenix (Lmod, /gpfs/apps/icl/modules/all) uses full EasyBuild names with toolchain suffixes,
#    e.g. CMake/3.26.3-GCCcore-12.3.0, and has the 2021b, 2023a and 2025a generations (census
#    2026-09-25). Whether foss/2023a, imkl/2023.1.0 and intel/2023a exist was NOT in that census:  (VERIFY on Phoenix)
#    00_discover.sh runs 'module avail foss imkl intel GCC OpenMPI impi' and 'module spider imkl'.
# -----------------------------------------------------------------------------
module purge >/dev/null 2>&1 || true
[ -d "$EB_MODULES" ] && module use "$EB_MODULES"          # picks up EasyBuild-fallback modules if built
case "$TOOLCHAIN" in
  foss)
    # foss/2023a = GCC 12.3.0 + OpenMPI 4.1.5 + FlexiBLAS 3.3.1 + FFTW 3.3.10 + ScaLAPACK 2.2.0  (VERIFY on Phoenix)
    # imkl/2023.1.0 = oneMKL 2023.1.0, SYSTEM toolchain                                        (VERIFY on Phoenix)
    #   if only the gompi build exists: MODS="foss/2023a imkl/2023.1.0-gompi-2023a"            (VERIFY on Phoenix)
    MODS="${MODS:-foss/2023a imkl/2023.1.0}"   # VERIFY on Phoenix
    FEMTIC_MK=Makefile.gcc_openmpi_mkl;  FEMTIC_ARGS=()
    MTM_MK=Makefile.gcc_mkl;             MTM_ARGS=()      # makeTetraMesh makes no MKL call (ported/README.md)
    ;;
  intel)
    # intel/2023a = intel-compilers/2023.1.0 + impi/2021.9.0 + imkl/2023.1.0                   (VERIFY on Phoenix)
    MODS="${MODS:-intel/2023a}"
    FEMTIC_MK=Makefile.intel_oneapi
    MTM_MK=Makefile.intel_oneapi;        MTM_ARGS=()
    ;;
  *) die "TOOLCHAIN must be foss or intel" ;;
esac
# shellcheck disable=SC2086
module load $MODS || die "module load $MODS failed -- fix the names (MODS=...) or use the EasyBuild fallback at the bottom"
module list 2>&1
echo "MKLROOT=${MKLROOT:-<unset>}"
[ -n "${MKLROOT:-}" ] || die "MKLROOT is not set after 'module load $MODS' -- no MKL module loaded"
[ -e "$MKLROOT/lib/intel64/libmkl_core.so" ] || [ -e "$MKLROOT/lib/libmkl_core.so" ] || die "no libmkl_core.so under MKLROOT=$MKLROOT"
command -v g++ >/dev/null || die "g++ not on PATH (GCC/GCCcore module missing?)"

if [ "$TOOLCHAIN" = intel ]; then
  if [ "$INTEL_MPICXX" = auto ]; then
    if command -v mpiicpx >/dev/null; then INTEL_MPICXX=mpiicpx; else INTEL_MPICXX="mpiicpc -cxx=icpx"; fi
  fi
  FEMTIC_ARGS=("CXX=$INTEL_MPICXX")
  # INTEL_MPICXX=mpiicpc gives the classic icpc build (flags identical to upstream Makefile_IntelMPI);
  # it prints "remark #10441 ... deprecated" -- harmless.
  echo "-- FEMTIC MPI C++ compiler: $INTEL_MPICXX  ->  $($INTEL_MPICXX -show 2>&1 | head -1)"
else
  echo "-- FEMTIC MPI C++ compiler: mpicxx  ->  $(mpicxx -showme 2>&1 | head -1)"
fi
echo "-- plain C++ tools use g++ $(g++ -dumpfullversion) in both toolchains (no MPI/MKL/OpenMP in them;"
echo "   avoids icpx's default fast floating-point model in the mesh tools)"

# -----------------------------------------------------------------------------
# 3. Build
# -----------------------------------------------------------------------------
build() {   # build <repo> <ported makefile> <exe> [make VAR=value ...]
  local repo=$1 mk=$2 exe=$3; shift 3
  local d="$SRC/$repo/src"
  echo; echo "=============== $repo  ($mk $*) ==============="
  [ -f "$PORTED/$repo/$mk" ] || die "missing $PORTED/$repo/$mk -- copy the scratchpad 'ported' tree to $PORTED"
  cp -f "$PORTED/$repo/$mk" "$d/$mk" || die "cannot copy $mk into $d"
  ( cd "$d" && { make -f "$mk" clean >/dev/null 2>&1 || true; } && make -f "$mk" -j"$JOBS" "$@" ) || die "make failed for $repo"
  [ -x "$d/$exe" ] || die "$d/$exe was not produced"
  install -m 755 "$d/$exe" "$BIN/$exe" && echo "-- installed $BIN/$exe"
}
build femtic              "$FEMTIC_MK" femtic "${FEMTIC_ARGS[@]}"
build makeTetraMesh       "$MTM_MK"    makeTetraMesh "${MTM_ARGS[@]}"
build makeMtr             Makefile.gcc makeMtr        CXX=g++
build TetGen2Femtic       Makefile.gcc TetGen2Femtic  CXX=g++
build makeDHexaMesh       Makefile.gcc makeDHexaMesh  CXX=g++
build mergeResultOfFEMTIC Makefile.gcc mergeResultOfFEMTIC CXX=g++

# TetGen 1.6 (libigl fork): upstream makefile, as in ported/tetgen/BUILD.txt.
# predicates.cxx MUST stay at -O0 (Shewchuk's exact-arithmetic predicates break under optimisation).
echo; echo "=============== tetgen (upstream makefile, PREDCXXFLAGS=-O0) ==============="
(
  cd "$SRC/tetgen" || exit 1
  if grep -q $'\r' makefile; then sed -i 's/\r$//' makefile; fi
  make clean >/dev/null 2>&1 || true
  make tetgen CXX=g++ CXXFLAGS=-O3 PREDCXXFLAGS=-O0
) || die "tetgen build failed"
install -m 755 "$SRC/tetgen/tetgen" "$BIN/tetgen" && echo "-- installed $BIN/tetgen"

# -----------------------------------------------------------------------------
# 4. Environment file sourced by 03_mesh.slurm / 04_inversion.slurm / 06_forward_only.slurm
#    (05_chain.sh sources femtic_lib.sh directly)
# -----------------------------------------------------------------------------
install -m 644 "$PLAN_DIR/femtic_lib.sh" "$BIN/femtic_lib.sh"
{
  echo "# generated by 01_build_femtic.sh on $(date) -- TOOLCHAIN=$TOOLCHAIN"
  echo "# usage in job scripts (#!/bin/bash -l):   source $BIN/femtic_env.sh"
  echo "module purge >/dev/null 2>&1"
  echo "[ -d \"$EB_MODULES\" ] && module use \"$EB_MODULES\""
  echo "module load $MODS || echo \"femtic_env.sh: module load $MODS FAILED\" >&2   # VERIFY on Phoenix"
  echo "export PATH=\"$BIN:\$PATH\""
  echo "export FEMTIC_TOOLCHAIN=$TOOLCHAIN FEMTIC_BIN=\"$BIN\""
  echo ". \"$BIN/femtic_lib.sh\""
} > "$BIN/femtic_env.sh"
echo "-- wrote $BIN/femtic_env.sh"

# -----------------------------------------------------------------------------
# 5. TEST T1 -- linkage
#    Fails if: libmkl_core or libmkl_intel_ilp64 missing from 'ldd femtic', any "not found",
#    or the OpenMP runtime does not match the toolchain (foss: libgomp + mkl_gnu_thread, no libiomp5;
#    intel: libiomp5 + mkl_intel_thread, no libgomp).
# -----------------------------------------------------------------------------
echo; echo "=============== T1: ldd $BIN/femtic | grep -i mkl ==============="
LDD=$(ldd "$BIN/femtic" 2>&1)
echo "$LDD" | grep -i mkl
echo "$LDD" | grep -iE 'libmpi|omp'
T1=PASS
t1fail() { echo "T1 FAIL: $*"; T1=FAIL; }
echo "$LDD" | grep -q 'not found'           && t1fail "unresolved libraries: $(echo "$LDD" | grep 'not found' | tr '\n' ' ')"
echo "$LDD" | grep -q 'libmkl_core'         || t1fail "libmkl_core not linked"
echo "$LDD" | grep -q 'libmkl_intel_ilp64'  || t1fail "libmkl_intel_ilp64 not linked (ILP64 interface is mandatory)"
if [ "$TOOLCHAIN" = foss ]; then
  echo "$LDD" | grep -q 'libmkl_gnu_thread' || t1fail "libmkl_gnu_thread not linked"
  echo "$LDD" | grep -q 'libgomp'           || t1fail "libgomp not linked"
  echo "$LDD" | grep -q 'libiomp5'          && t1fail "libiomp5 linked into a GNU-OpenMP build (two OpenMP runtimes)"
else
  echo "$LDD" | grep -q 'libmkl_intel_thread' || t1fail "libmkl_intel_thread not linked"
  echo "$LDD" | grep -q 'libiomp5'            || t1fail "libiomp5 not linked"
  echo "$LDD" | grep -q 'libgomp'             && t1fail "libgomp linked into an Intel-OpenMP build (two OpenMP runtimes)"
fi
echo "T1 (linkage): $T1"
ls -l "$BIN"

# -----------------------------------------------------------------------------
# 6. TESTS T2 + T5 -- smoke run and restart equivalence on FEMTIC's example INV_MT_01/Tetra
# -----------------------------------------------------------------------------
if [ "$SMOKE" = auto ]; then
  if [ -n "${SLURM_JOB_ID:-}" ]; then SMOKE=1; else SMOKE=0; fi
fi
T2=SKIPPED; T5=SKIPPED
if [ "$SMOKE" = 1 ]; then
  # shellcheck disable=SC1091
  . "$BIN/femtic_lib.sh"
  EX="$SRC/femtic/examples/INV_MT_01/Tetra"
  W="$SRC/smoke_${TOOLCHAIN}_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$W/straight" "$W/restart" || die "cannot create $W"
  for d in straight restart; do
    cp "$EX"/{control.dat,mesh.dat,observe.dat,resistivity_block_iter0.dat} "$W/$d/" || die "example files missing in $EX"
    femtic_ctl_set "$W/$d/control.dat" NUM_THREADS 2 || die "femtic_ctl_set failed"
  done
  femtic_ctl_set "$W/straight/control.dat" ITERATION "0 2"
  femtic_ctl_set "$W/restart/control.dat"  ITERATION "0 1"
  runf() {   # runf <dir> <label>
    local rc
    echo "-- femtic in $1 ($2), ITERATION '$(femtic_ctl_get "$1/control.dat" ITERATION)'"
    if [ "$TOOLCHAIN" = intel ]; then
      ( cd "$1" && OMP_NUM_THREADS=2 I_MPI_HYDRA_BOOTSTRAP=fork I_MPI_FABRICS=shm mpirun -np 2 "$BIN/femtic" > "stdout_$2.txt" 2>&1 ); rc=$?
    else
      ( cd "$1" && OMP_NUM_THREADS=2 mpirun -np 2 --bind-to none "$BIN/femtic" > "stdout_$2.txt" 2>&1 ); rc=$?
    fi
    cp "$1/femtic_0.log" "$1/femtic_0.log.$2" 2>/dev/null; cp "$1/femtic.cnv" "$1/femtic.cnv.$2" 2>/dev/null
    echo "   exit $rc; last log line: $(tail -1 "$1/femtic_0.log" 2>/dev/null)"
    return $rc
  }
  T2=PASS; T5=PASS
  runf "$W/straight" straight || T2=FAIL
  [ -f "$W/straight/resistivity_block_iter2.dat" ] || { echo "T2: resistivity_block_iter2.dat missing"; T2=FAIL; }
  echo "-- frequencies in example: $(femtic_nfreq "$W/straight/femtic_0.log")"
  runf "$W/restart" leg1 || T5=FAIL
  LAST=$(femtic_last_iter "$W/restart")
  [ "$LAST" = 1 ] || { echo "T5: after leg 1 femtic_last_iter=$LAST (want 1)"; T5=FAIL; }
  femtic_ctl_set "$W/restart/control.dat" ITERATION "$LAST 2"
  runf "$W/restart" leg2 || T5=FAIL
  grep -m1 'Start Forward Computation' "$W/restart/femtic_0.log.leg2" | grep -q 'Iteration : 1,' \
    || { echo "T5: restart leg did not start at iteration 1"; T5=FAIL; }
  cmp_misfit() {   # cmp_misfit <iter> <tol>  -> compares column 6 (Misfit) straight vs restart leg 2
    local a b
    a=$(femtic_cnv_row "$1" "$W/straight/femtic.cnv.straight"); b=$(femtic_cnv_row "$1" "$W/restart/femtic.cnv.leg2")
    echo "   iter $1  straight: $a"
    echo "   iter $1  restart : $b"
    [ -n "$a" ] && [ -n "$b" ] || { echo "T5: missing cnv row for iteration $1"; T5=FAIL; return; }
    awk -v a="$a" -v b="$b" -v t="$2" 'BEGIN{split(a,x); split(b,y);
         m=(x[6]<0?-x[6]:x[6]); n=(y[6]<0?-y[6]:y[6]); d=x[6]-y[6]; if(d<0)d=-d; s=(m>n?m:n); if(s==0)s=1e-300;
         r=d/s; printf "   relative misfit difference %.3e (tolerance %s)\n", r, t;
         if (x[2]!=0 || y[2]!=0 || x[4]!=y[4]) {print "   INCONCLUSIVE: retrial or damping differs (restart resets STEP_LENGTH)"; exit 2}
         exit (r<=t)?0:1}'
    case $? in 0) ;; 2) [ "$T5" = PASS ] && T5=INCONCLUSIVE ;; *) T5=FAIL ;; esac
  }
  echo "-- T5 comparison (femtic.cnv columns: Iter# Retrial# Alpha Damp Roughness Misfit RMS ObjFunc)"
  cmp_misfit 1 1e-4
  cmp_misfit 2 1e-3
  echo "-- iteration-0 row (compare with the WSL build of the same example; expect >= 6 equal significant digits):"
  echo "   $(femtic_cnv_row 0 "$W/straight/femtic.cnv.straight")"
  echo "T2 (smoke run): $T2    T5 (restart equivalence): $T5    work dir: $W"
else
  echo; echo "T2/T5 skipped (not inside a Slurm allocation). To run them:"
  echo "   srun -p interactive -N 1 -n 4 --mem=8GB --time=01:00:00 --pty bash"
  echo "   TOOLCHAIN=$TOOLCHAIN SMOKE=1 bash -l $0     # rebuild is quick; or SMOKE=1 on this node if policy allows"
fi

echo; echo "== $(date)  BUILD DONE  T1=$T1  T2=$T2  T5=$T5   log: $LOG"
echo "   next: 02_env_femticpy.sh, 03_mesh.slurm, then 06_forward_only.slurm (first Phoenix job on the real mesh)"
[ "$T1" = PASS ] && [ "$T2" != FAIL ] && [ "$T5" != FAIL ] || exit 3
exit 0

# =============================================================================
# EasyBuild FALLBACK -- only if 00_discover.sh shows no usable central imkl / intel / foss module.
# Easyconfig filenames verified in easybuilders/easybuild-easyconfigs at tag
# easybuild-easyconfigs-v4.9.4 (the version Phoenix's EasyBuild/4.9.4 module ships):  (VERIFY on Phoenix)
#   imkl-2023.1.0.eb                              (SYSTEM toolchain; binary installer, no compilation)
#   imkl-2023.1.0-gompi-2023a.eb                  (same MKL, gompi-2023a toolchain)
#   intel-compilers-2023.1.0.eb                   (deps: GCCcore-12.3.0, binutils-2.40)
#   impi-2021.9.0-intel-compilers-2023.1.0.eb     (dep: UCX 1.14.1)
#   intel-2023a.eb                                (= the four above + imkl-FFTW 2023.1.0)
#   foss-2023a.eb                                 (GCC 12.3.0, OpenMPI 4.1.5, FlexiBLAS 3.3.1, FFTW 3.3.10, ScaLAPACK 2.2.0)
#
#   module load EasyBuild/4.9.4  (VERIFY on Phoenix)
#   export EASYBUILD_PREFIX=/hpcfs/users/$USER/easybuild          # software/, modules/, sources/
#   export MODULEPATH=$EASYBUILD_PREFIX/modules/all:$MODULEPATH
#   mkdir -p $EASYBUILD_PREFIX
#
#   # (a) most likely case: foss/2023a exists centrally but no imkl -> MKL only (~2-3 GB download, no compile)  (VERIFY on Phoenix)
#   eb imkl-2023.1.0.eb --robot -Dx                # dry run: shows what would be built
#   eb imkl-2023.1.0.eb --robot                    # downloads l_onemkl_p_2023.1.0.46342_offline.sh from Intel
#   module load foss/2023a imkl/2023.1.0           # VERIFY on Phoenix; then re-run:  TOOLCHAIN=foss bash -l 01_build_femtic.sh
#       # No internet on the build node? download the installer elsewhere and place it at
#       #   $EASYBUILD_PREFIX/sources/i/imkl/l_onemkl_p_2023.1.0.46342_offline.sh
#       # The module sets MKLROOT=<prefix>/software/imkl/2023.1.0/mkl/2023.1.0 plus LD_LIBRARY_PATH,  (VERIFY on Phoenix)
#       # LIBRARY_PATH, CPATH, CMAKE_PREFIX_PATH, PKG_CONFIG_PATH (easyblock imkl.py, v4.9.4).
#
#   # (b) whole Intel toolchain (hours if GCCcore 12.3.0 must be compiled too)
#   eb intel-2023a.eb --robot -Dx
#   eb intel-2023a.eb --robot
#
#   # (c) whole foss toolchain (compiles GCC + OpenMPI from source: many hours; do it in an
#   #     interactive session with EASYBUILD_BUILDPATH=$TMPDIR and --gres=tmpfs:50G)
#   eb foss-2023a.eb --robot -Dx
#   eb foss-2023a.eb --robot
#
#   This script and femtic_env.sh already 'module use' $EASYBUILD_PREFIX/modules/all when it exists,
#   so batch jobs see the user-built modules without editing ~/.bashrc. Note the module NAME may carry
#   a toolchain suffix depending on the module naming scheme EasyBuild/4.9.4 is configured with on  (VERIFY on Phoenix)
#   Phoenix ('eb --show-config | grep module_naming'); pass MODS="..." accordingly.
# =============================================================================
