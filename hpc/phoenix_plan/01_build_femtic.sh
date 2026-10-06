#!/bin/bash -l
# =============================================================================
# 01_build_femtic.sh -- build FEMTIC v5.0 + the tetra-mesh tool chain on Phoenix
#
# Step A, sources (LOGIN node: git 2.27 and internet):
#     FETCH_ONLY=1 bash -l 01_build_femtic.sh
#   Compute nodes may have no outbound internet, so this script NEVER clones or downloads inside a
#   Slurm job on any partition other than 'interactive'; it stops and says so instead.
# Step B, build + test T1, on the LOGIN node p2-log-2 ONLY (where it ran on 2026-09-25: 74 s with JOBS=8,
#   T1 PASS). Compute nodes have no make and no git (icelake, verified 2026-09-25: "make: command not found"),
#   and the interactive (data-mover) nodes p2-dmv-* have no /apps; section 2 stops if make is missing.
#     TOOLCHAIN=foss  bash -l 01_build_femtic.sh     # GCC 12.3 + OpenMPI 4.1.5 + Intel MKL 2023.1 (default, primary)
#     TOOLCHAIN=intel bash -l 01_build_femtic.sh     # intel-compilers 2023.1 + Intel MPI 2021.9 + MKL 2023.1 (untested fallback)
#   Outside a Slurm allocation T2/T5 are skipped (SMOKE=auto); run them with step C.
# Step C, smoke tests T1 + T2 + T5 of the INSTALLED build, as a batch job (submit from /hpcfs/users/$USER/FEMTIC_2026):
#     sbatch -p icelake -N 1 -n 4 --mem=8G --time=00:30:00 -J femtic_smoke -o slurm-%x-%j.out \
#            --wrap 'TOOLCHAIN=foss SMOKE_ONLY=1 bash -l hpc/phoenix_plan/01_build_femtic.sh'
#   icelake is where 04/06 run; at most 2.4 SU (4 cpus x 0.5 h x 1.2 SU per cpu-hour). '-p interactive' (free
#   according to the wiki) also works, but only with a femtic_env.sh written by THIS version of the script:
#   its nodes have no /apps, and femtic_env.sh now remaps /apps to /gpfs/apps there (femtic_apps_remap).
#   SMOKE_ONLY=1 skips sections 1-4 (sources, module and compiler checks, build, femtic_env.sh): it sources
#   $BIN/femtic_env.sh, runs T1 (ldd) on $BIN/femtic and T2/T5 as section 6 does, and logs to
#   $SRC/smoke_<toolchain>_<date>.log (work files in $SRC/smoke_<toolchain>_<date>/). It needs no git, no
#   make, no compiler and no MKL headers, only the runtime libraries that ldd resolves.
#   SMOKE=1 (build, then T2/T5 in the same run) still works, but only where make exists: the login node.
# Options (environment): SRC, BIN, PORTED, TARBALLS, JOBS=8, PIN=1, SMOKE=auto|1|0, FETCH_ONLY=0|1,
#                        SMOKE_ONLY=0|1, MODS="<module list>",
#                        INTEL_MPICXX="mpiicpc -cxx=icpx" (default) | "mpiicpc -diag-disable=10441" (classic icpc)
# Exit status: 0 = every test that ran passed (T5 may be INCONCLUSIVE), 1 = stopped with ERROR,
#              3 = T1 failed, or T2 or T5 FAILED.
#
# Before running:
#   1. the ported Makefiles must be in $PORTED (default $SRC/ported/; same tree:
#      ported/femtic/Makefile.gcc_openmpi_mkl, ported/makeTetraMesh/Makefile.gcc_mkl, ...).
#      Ben's WinSCP copy of the project puts them in /hpcfs/users/$USER/FEMTIC_2026/hpc/ported:
#      pass PORTED=/hpcfs/users/$USER/FEMTIC_2026/hpc/ported, or copy that directory to $SRC/ported
#   2. keep femtic_lib.sh next to this script (it is installed to $BIN)
#   3. the module names below were verified by 00_discover.sh on the login node p2-log-2 on
#      2026-09-25 (phoenix_plan/discovery/phoenix_discovery_p2-log-2_2026-09-25.txt); no MODS needed
#   4. if a shebang fails with "bad interpreter ^M", the file has CRLF endings: dos2unix *.sh *.slurm
#
# Sources: the tree does not need git. Per repo, the first of these that applies is used:
#   a) $SRC/<repo>/.git          a git checkout; PIN=1 checks out the pinned commit (below). Wherever git
#                                runs, the checked-out commit is also written to $SRC/<repo>/COMMIT_SHA.txt.
#                                On a node without git the commit is read from .git/HEAD (a SHA, or a branch
#                                resolved through .git/refs/heads/ or .git/packed-refs), else COMMIT_SHA.txt
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
#   4. writes $BIN/femtic_env.sh (module loads + PATH + helpers + femtic_apps_remap) that 03/04/06 source
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
#   SMOKE_ONLY=1 runs only 5 and 6, on the installed build (step C). If ldd reports a library "not found",
#   T1 also prints LD_LIBRARY_PATH and what the node sees of /apps and /gpfs/apps.
#
# Toolchain facts (load-tested by 00_discover.sh on p2-log-2, 2026-09-25; README_phoenix.md section 4):
#   * foss/2023a + imkl/2023.1.0 load together: GCC 12.3.0, OpenMPI/4.1.5-GCC-12.3.0 (configured
#     --with-slurm --with-pmi, PMIx 4.2.4, UCX 1.14.1), OpenBLAS 0.3.23, FlexiBLAS 3.3.1, FFTW 3.3.10,
#     ScaLAPACK 2.2.0, imkl 2023.1.0 with MKLROOT=/apps/icl/software/imkl/2023.1.0/mkl/2023.1.0
#     (lib/ and lib/intel64/ both present; lib/intel64 has libmkl_gnu_thread.so and libmkl_intel_ilp64.so).
#     imkl lives under /apps/icl/software, GCC and OpenMPI under /gpfs/apps/icl/software. The MKL check in
#     step 2 accepts versioned names (libmkl_core.so.2), tries the other of /apps and /gpfs/apps before it
#     stops, and then prints what the node sees of both.
#     mpicxx is the OpenMPI 4.1.5 wrapper around g++ 12.3.0. This is THE primary route.
#   * intel/2023a loads: intel-compilers/2023.1.0 (classic icpc AND icpx), impi/2021.9.0-intel-compilers-2023.1.0,
#     imkl/2023.1.0, imkl-FFTW, GCCcore 12.3.0. mpiicpc exists; mpiicpx and mpiicx do NOT
#     ("mpiicpx  MISSING" in the discovery output). So the intel route uses "mpiicpc -cxx=icpx" (the
#     LLVM icpx through the classic wrapper), passed to make as CXX=... because
#     ported/femtic/Makefile.intel_oneapi says CXX = mpiicpx. Classic icpc is the alternative:
#     INTEL_MPICXX="mpiicpc -diag-disable=10441" (silences the "remark #10441 ... deprecated" line).
#     The intel route has never been compiled: it is the untested fallback.
#   * the login node's system compiler is gcc 8.4.1 (RHEL 8.4): never build with it; step 2 refuses g++ < 9.
# =============================================================================
set -o pipefail            # no 'set -u/-e': Lmod/conda shell functions touch unset variables

TOOLCHAIN="${TOOLCHAIN:-foss}"
SRC="${SRC:-/hpcfs/users/$USER/femtic_src}"
BIN="${BIN:-/hpcfs/users/$USER/femtic/bin}"
# Ported Makefiles: prefer the kit's own sibling directory (hpc/ported in the repo, as copied to
# /hpcfs), then fall back to $SRC/ported; PORTED=... on the command line overrides both.
_KIT_PORTED="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/ported"
if [ -z "${PORTED:-}" ] && [ -d "$_KIT_PORTED" ]; then PORTED="$_KIT_PORTED"; fi
PORTED="${PORTED:-$SRC/ported}"
TARBALLS="${TARBALLS:-$SRC/tarballs}"
PLAN_DIR="${PLAN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
JOBS="${JOBS:-8}"
PIN="${PIN:-1}"
SMOKE="${SMOKE:-auto}"
FETCH_ONLY="${FETCH_ONLY:-0}"
SMOKE_ONLY="${SMOKE_ONLY:-0}"          # 1 = test the installed build only (step C); skips sections 1-4
INTEL_MPICXX="${INTEL_MPICXX:-}"        # TOOLCHAIN=intel only; default "mpiicpc -cxx=icpx" (step 2)
EB_MODULES="/hpcfs/users/$USER/easybuild/modules/all"     # EasyBuild fallback prefix (see bottom)

STAMP=$(date +%Y%m%d_%H%M%S)           # names the log and the smoke-test work directory
if [ "$SMOKE_ONLY" = 1 ]; then
  mkdir -p "$SRC" || { echo "cannot create $SRC"; exit 1; }
else
  mkdir -p "$SRC" "$BIN" || { echo "cannot create $SRC / $BIN"; exit 1; }
fi
# another run started in the same second: never share its log or its smoke work directory
compgen -G "$SRC/*_$STAMP*" >/dev/null && STAMP="${STAMP}_$$"
if [ "$SMOKE_ONLY" = 1 ]; then LOG="$SRC/smoke_${TOOLCHAIN}_$STAMP.log"
elif [ "$FETCH_ONLY" = 1 ]; then LOG="$SRC/fetch_$STAMP.log"
else LOG="$SRC/build_${TOOLCHAIN}_$STAMP.log"
fi
exec > >(tee -a "$LOG") 2>&1
echo "== $(date)  TOOLCHAIN=$TOOLCHAIN  SRC=$SRC  BIN=$BIN  PORTED=$PORTED  host=$(hostname)  job=${SLURM_JOB_ID:-none} partition=${SLURM_JOB_PARTITION:-none}$([ "$SMOKE_ONLY" = 1 ] && echo '  SMOKE_ONLY=1')"
die() { echo "ERROR: $*"; echo "log: $LOG"; exit 1; }
node_diag() {   # node_diag [DIR] -> what this node sees of DIR and of the two software-tree prefixes
  echo "   \$ hostname"; hostname
  if [ -n "${1:-}" ]; then echo "   \$ ls -ld $1 $1/lib $1/lib/intel64"; ls -ld "$1" "$1/lib" "$1/lib/intel64" 2>&1; fi
  echo "   \$ ls -d /apps /gpfs/apps"; ls -d /apps /gpfs/apps 2>&1
  if [ -n "${1:-}" ]; then echo "   \$ df -h $1 | tail -1"; df -h "$1" 2>&1 | tail -1; fi
}

case "$SRC$BIN" in /home/*) echo "WARNING: building under /home (10 GB quota); use /hpcfs." ;; esac
[ "$FETCH_ONLY" = 1 ] && [ "$SMOKE_ONLY" = 1 ] && die "FETCH_ONLY=1 and SMOKE_ONLY=1 exclude each other"
[ "$SMOKE_ONLY" = 1 ] || [ -f "$PLAN_DIR/femtic_lib.sh" ] || die "femtic_lib.sh not found next to this script ($PLAN_DIR)"

if [ "$SMOKE_ONLY" = 1 ]; then
# -----------------------------------------------------------------------------
# 0. SMOKE_ONLY=1 (step C): test the INSTALLED build. Sections 1-4 are skipped, so this node needs no git,
#    no compiler and no MKL headers; femtic_env.sh loads the same modules the job scripts (03/04/06) load.
# -----------------------------------------------------------------------------
  EX="$SRC/femtic/examples/INV_MT_01/Tetra"
  [ -f "$BIN/femtic_env.sh" ] || die "SMOKE_ONLY: $BIN/femtic_env.sh not found -- build first (step B), or pass BIN=<the build's bin directory>"
  [ -x "$BIN/femtic" ] || die "SMOKE_ONLY: $BIN/femtic not found or not executable -- build first (step B), or pass BIN=<the build's bin directory>"
  [ -d "$EX" ] || die "SMOKE_ONLY: FEMTIC example directory $EX not found -- it is part of the femtic source tree (step A); pass SRC=<the build's source directory>"
  for f in control.dat mesh.dat observe.dat resistivity_block_iter0.dat; do
    [ -f "$EX/$f" ] || die "SMOKE_ONLY: $EX/$f not found (incomplete femtic source tree?)"
  done
  # shellcheck disable=SC1091
  source "$BIN/femtic_env.sh" || die "SMOKE_ONLY: sourcing $BIN/femtic_env.sh failed"
  [ "${FEMTIC_LIB_VERSION:-0}" -ge 4 ] || die "SMOKE_ONLY: $BIN/femtic_lib.sh is version ${FEMTIC_LIB_VERSION:-unset}; this script needs FEMTIC_LIB_VERSION >= 4 (version 2, installed 2026-09-25, misreads PARDISO memory and has no layout rule; version 3 loses N_iv when DIV_NUM_RHS_FWD > N_iv) -- rebuild on the login node (step B, installs it), or install -m 644 $PLAN_DIR/femtic_lib.sh $BIN/"
  [ "${FEMTIC_TOOLCHAIN:-$TOOLCHAIN}" = "$TOOLCHAIN" ] \
    || die "SMOKE_ONLY: $BIN/femtic_env.sh belongs to a TOOLCHAIN=$FEMTIC_TOOLCHAIN build; rerun with TOOLCHAIN=$FEMTIC_TOOLCHAIN"
  if [ -f "$PLAN_DIR/femtic_lib.sh" ] && ! cmp -s "$PLAN_DIR/femtic_lib.sh" "$BIN/femtic_lib.sh"; then
    echo "NOTE: $BIN/femtic_lib.sh differs from $PLAN_DIR/femtic_lib.sh; the test uses the installed copy, as 03/04/06 do"
  fi
  if [ ! -d /apps ] && [ -d /gpfs/apps ] && ! grep -q femtic_apps_remap "$BIN/femtic_env.sh"; then
    echo "NOTE: /apps is absent on $(hostname) and $BIN/femtic_env.sh predates the /apps -> /gpfs/apps remap, so T1 will"
    echo "      find the MKL libraries missing. Re-run the build on the login node (step B) to regenerate it, or use -p icelake."
  fi
  module list 2>&1
  echo "MKLROOT=${MKLROOT:-<unset>}  (not checked in SMOKE_ONLY mode: T1 checks what ldd resolves)"
  command -v mpirun >/dev/null || die "SMOKE_ONLY: mpirun not on PATH after sourcing $BIN/femtic_env.sh (did its 'module load' fail? see above)"
  echo "-- SMOKE_ONLY: testing $BIN/femtic (installed $(date -r "$BIN/femtic" '+%F %T' 2>/dev/null)) with $(command -v mpirun)"
else   # ---- sections 1-4, not indented: sources, modules, build, femtic_env.sh (skipped by SMOKE_ONLY=1)

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

# Every file read below is guarded, so a missing file never produces a bash redirection error.
first_line() {   # first_line <file> -> its first line without CR and surrounding blanks; status 1 if unreadable/empty
  local l=""
  [ -f "$1" ] && [ -r "$1" ] || return 1
  { IFS= read -r l || [ -n "$l" ]; } < "$1" || return 1
  l=${l%$'\r'}; l=${l#"${l%%[![:space:]]*}"}; l=${l%"${l##*[![:space:]]}"}
  [ -n "$l" ] || return 1
  printf '%s\n' "$l"
}
sha_file() {     # sha_file <COMMIT_SHA.txt> -> the recorded commit, blanks removed; status 1 if absent or empty
  local s
  s=$(first_line "$1") || return 1
  printf '%s\n' "${s//[[:space:]]/}"
}
git_head_nogit() {   # git_head_nogit <repo dir> -> the checked-out commit, read from .git WITHOUT git
  # .git/HEAD holds the SHA itself (detached HEAD: what the pinned checkout leaves) or "ref: refs/heads/<b>",
  # whose SHA is in .git/refs/heads/<b> or, once packed, on a "<sha> refs/heads/<b>" line of .git/packed-refs
  local g="$1/.git" h ref
  h=$(first_line "$g/HEAD") || return 1
  case "$h" in
    ref:*)
      ref=${h#ref:}; ref=${ref#"${ref%%[![:space:]]*}"}
      if ! h=$(first_line "$g/$ref"); then
        [ -f "$g/packed-refs" ] && [ -r "$g/packed-refs" ] || return 1
        h=$(awk -v r="$ref" '{sub(/\r$/, "")} $2 == r {print $1; exit}' "$g/packed-refs")
      fi ;;
  esac
  [[ "$h" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || return 1
  printf '%s\n' "$h"
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
  # version / pin. Wherever git runs (after a clone, after the pinned checkout, in FETCH_ONLY runs) the
  # checked-out commit is recorded in $d/COMMIT_SHA.txt, so later steps on nodes without git never need it.
  WHY=""
  if [ -d "$d/.git" ] && [ "$HAVE_GIT" = 1 ]; then
    if [ "$PIN" = 1 ]; then
      if ! git -C "$d" cat-file -e "$sha^{commit}" 2>/dev/null; then
        [ "$CAN_FETCH" = 1 ] || die "pinned commit $sha of $r is not in $d and fetching is not allowed in this job -- run FETCH_ONLY=1 on the login node"
        git -C "$d" fetch --quiet --depth 1 origin "$sha" || die "cannot fetch pinned commit $sha of $r"
      fi
      git -C "$d" checkout --quiet "$sha" || die "checkout $sha failed in $d (local edits to tracked files?)"
    fi
    HEAD=$(git -C "$d" rev-parse HEAD); DATE=$(git -C "$d" log -1 --format=%cs)
    if [ -n "$HEAD" ]; then
      { echo "$HEAD" > "$d/COMMIT_SHA.txt"; } 2>/dev/null || echo "   WARNING: cannot write $d/COMMIT_SHA.txt"
    else
      WHY="'git rev-parse HEAD' failed in $d"
    fi
  elif [ -d "$d/.git" ]; then
    # a git checkout on a node without git (p2-dmv-1, 2026-09-25): read .git itself, else COMMIT_SHA.txt
    if HEAD=$(git_head_nogit "$d"); then DATE="read from .git; no git on this node"
    elif HEAD=$(sha_file "$d/COMMIT_SHA.txt"); then DATE="COMMIT_SHA.txt; no git on this node"
    else HEAD=""; WHY="no git on this node, and neither $d/.git/HEAD nor $d/COMMIT_SHA.txt gives a commit"
    fi
  else
    HEAD=$(sha_file "$d/COMMIT_SHA.txt"); DATE="git-free tree"
    [ -n "$HEAD" ] || WHY="git-free tree without COMMIT_SHA.txt"
  fi
  if [ -z "$HEAD" ]; then
    echo "-- $r: version UNKNOWN (informational, not an error): $WHY. The ported Makefiles match $sha only;"
    echo "   if that is what $d holds, record it:  echo $sha > $d/COMMIT_SHA.txt"
    UNKNOWN_VERSION+=("$r")
  elif [[ "$sha" != "$HEAD"* ]] || [ "${#HEAD}" -lt 7 ]; then
    if [ "$PIN" = 1 ]; then
      [ "$HAVE_GIT" = 0 ] && [ -d "$d/.git" ] && echo "   (no git on this node: FETCH_ONLY=1 on the login node checks out the pinned commit)"
      die "$r is at '$HEAD', pinned $sha (PIN=0 to accept, at your own risk: OBJS lists may not match)"
    fi
    echo "-- $r @ $HEAD ($DATE)  [UNPINNED: OBJS lists may not match]"
  else
    echo "-- $r @ ${HEAD:0:7} ($DATE)"
  fi
done
[ ${#UNKNOWN_VERSION[@]} -eq 0 ] || echo "WARNING: unknown source version for: ${UNKNOWN_VERSION[*]} (informational only; the build continues. The ported OBJS lists match the pinned commits, and a different tree usually fails at compile or link time)"
if [ "$FETCH_ONLY" = 1 ]; then echo "== FETCH_ONLY: sources ready in $SRC; now build on the login node (step B)"; exit 0; fi

# -----------------------------------------------------------------------------
# 2. Modules (verified: 00_discover.sh on p2-log-2, 2026-09-25, load tests A and B)
#    Phoenix: Lmod 8.2.10, MODULEPATH includes /gpfs/apps/icl/modules/all (full EasyBuild names with
#    toolchain suffixes). Generations present: 2021b, 2023a, 2025b (foss/2025b = GCC 14.3.0 +
#    OpenMPI 5.0.8); only 2023a has both foss and intel, so the kit uses 2023a.
# -----------------------------------------------------------------------------
module purge >/dev/null 2>&1 || true
[ -d "$EB_MODULES" ] && module use "$EB_MODULES"          # picks up EasyBuild-fallback modules if built
case "$TOOLCHAIN" in
  foss)
    # foss/2023a = GCC 12.3.0 + OpenMPI 4.1.5 + FlexiBLAS 3.3.1 + FFTW 3.3.10 + ScaLAPACK 2.2.0
    # imkl/2023.1.0 = oneMKL 2023.1.0 (SYSTEM toolchain; the only imkl 2023.1.0 module on Phoenix)
    MODS="${MODS:-foss/2023a imkl/2023.1.0}"   # load-tested together on p2-log-2, 2026-09-25
    FEMTIC_MK=Makefile.gcc_openmpi_mkl;  FEMTIC_ARGS=()
    MTM_MK=Makefile.gcc_mkl;             MTM_ARGS=()      # makeTetraMesh makes no MKL call (ported/README.md)
    ;;
  intel)
    # intel/2023a = intel-compilers/2023.1.0 + impi/2021.9.0 + imkl/2023.1.0 (load-tested 2026-09-25)
    MODS="${MODS:-intel/2023a}"
    FEMTIC_MK=Makefile.intel_oneapi
    MTM_MK=Makefile.intel_oneapi;        MTM_ARGS=()
    ;;
  *) die "TOOLCHAIN must be foss or intel" ;;
esac
# shellcheck disable=SC2086
module load $MODS || die "module load $MODS failed -- fix the names (MODS=...) or use the EasyBuild fallback at the bottom"
module list 2>&1
command -v make >/dev/null || die "make not found: build on the login node (compute nodes have no make); for the smoke test use SMOKE_ONLY=1"
echo "MKLROOT=${MKLROOT:-<unset>}"
[ -n "${MKLROOT:-}" ] || die "MKLROOT is not set after 'module load $MODS' -- no MKL module loaded"
# libmkl_core may exist only under its versioned name (libmkl_core.so.2), so match by glob. The modules set
# MKLROOT=/apps/icl/... (GCC and OpenMPI come from /gpfs/apps/icl/...), and the interactive (data-mover)
# nodes p2-dmv-* have no /apps at all (2026-09-25), so try the other prefix before stopping.
has_mkl_core() { local f; for f in "$1"/lib/intel64/libmkl_core.so* "$1"/lib/libmkl_core.so*; do [ -e "$f" ] && return 0; done; return 1; }
if ! has_mkl_core "$MKLROOT"; then
  case "$MKLROOT" in
    /apps/*)      ALT_MKLROOT="/gpfs$MKLROOT" ;;
    /gpfs/apps/*) ALT_MKLROOT="${MKLROOT#/gpfs}" ;;
    *)            ALT_MKLROOT="" ;;
  esac
  if [ -n "$ALT_MKLROOT" ] && has_mkl_core "$ALT_MKLROOT"; then
    echo "WARNING: no libmkl_core.so* under MKLROOT=$MKLROOT on $(hostname), but under $ALT_MKLROOT: using MKLROOT=$ALT_MKLROOT."
    echo "         The imkl module's library path still names the first tree, so femtic may not start on this node (T1 will say)."
    export MKLROOT="$ALT_MKLROOT"
  else
    echo "-- MKL diagnostics: no libmkl_core.so* in lib/intel64/ or lib/ of MKLROOT${ALT_MKLROOT:+ or of $ALT_MKLROOT}"
    node_diag "$MKLROOT"
    die "no libmkl_core.so* under MKLROOT=$MKLROOT${ALT_MKLROOT:+ (nor under $ALT_MKLROOT)} on $(hostname) -- see the diagnostics above; build on the login node, where it was found on 2026-09-25"
  fi
fi
command -v g++ >/dev/null || die "g++ not on PATH (GCC/GCCcore module missing?)"
# The RHEL 8.4 system compiler (gcc 8.4.1 on p2-log-2) must never build this: GCCcore 12.3.0 from the modules must win.
[ "$(g++ -dumpversion 2>/dev/null | cut -d. -f1)" -ge 9 ] 2>/dev/null \
  || die "g++ on PATH is $(command -v g++) $(g++ -dumpfullversion 2>/dev/null) (the system compiler?) -- 'module load $MODS' did not put GCC 12.3.0 first"

if [ "$TOOLCHAIN" = intel ]; then
  # Phoenix's intel/2023a (impi 2021.9.0) has mpiicpc but no mpiicpx / mpiicx (00_discover.sh, 2026-09-25),
  # so icpx is driven through the classic wrapper. "mpiicpc -diag-disable=10441" = classic icpc instead
  # (flags identical to upstream Makefile_IntelMPI; the option silences the deprecation remark).
  INTEL_MPICXX="${INTEL_MPICXX:-mpiicpc -cxx=icpx}"
  command -v "${INTEL_MPICXX%% *}" >/dev/null || die "${INTEL_MPICXX%% *} not on PATH after 'module load $MODS'"
  FEMTIC_ARGS=("CXX=$INTEL_MPICXX")
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
  echo "module load $MODS || echo \"femtic_env.sh: module load $MODS FAILED\" >&2"
  echo "export PATH=\"$BIN:\$PATH\""
  echo "export FEMTIC_TOOLCHAIN=$TOOLCHAIN FEMTIC_BIN=\"$BIN\""
  echo ". \"$BIN/femtic_lib.sh\""
  echo "femtic_apps_remap   # nodes without /apps (interactive/data-mover p2-dmv-*): /apps/ -> /gpfs/apps/ in the module paths"
} > "$BIN/femtic_env.sh"
echo "-- wrote $BIN/femtic_env.sh"
fi   # ---- end of sections 1-4 (skipped by SMOKE_ONLY=1)

# -----------------------------------------------------------------------------
# 5. TEST T1 -- linkage
#    Fails if: libmkl_core or libmkl_intel_ilp64 missing from 'ldd femtic', any "not found" (in every mode,
#    SMOKE_ONLY included: there T1 is the only check of the runtime libraries),
#    or the OpenMP runtime does not match the toolchain (foss: libgomp + mkl_gnu_thread, no libiomp5;
#    intel: libiomp5 + mkl_intel_thread, no libgomp).
# -----------------------------------------------------------------------------
echo; echo "=============== T1: ldd $BIN/femtic | grep -i mkl ==============="
LDD=$(ldd "$BIN/femtic" 2>&1)
echo "$LDD" | grep -i mkl
echo "$LDD" | grep -iE 'libmpi|omp'
T1=PASS
t1fail() { echo "T1 FAIL: $*"; T1=FAIL; }
if echo "$LDD" | grep -q 'not found'; then
  t1fail "unresolved libraries: $(echo "$LDD" | grep 'not found' | tr '\n' ' ')"
  echo "   LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-<unset>}"
  node_diag "${MKLROOT:-}"
fi
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
[ "$SMOKE_ONLY" = 1 ] && SMOKE=1            # the smoke test is the point of SMOKE_ONLY, in or outside Slurm
if [ "$SMOKE" = auto ]; then
  if [ -n "${SLURM_JOB_ID:-}" ]; then SMOKE=1; else SMOKE=0; fi
fi
T2=SKIPPED; T5=SKIPPED
if [ "$SMOKE" = 1 ]; then
  # shellcheck disable=SC1091
  . "$BIN/femtic_lib.sh"
  EX="$SRC/femtic/examples/INV_MT_01/Tetra"
  W="$SRC/smoke_${TOOLCHAIN}_$STAMP"
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
  echo; echo "T2/T5 skipped (not inside a Slurm allocation). Run them on this build as a batch job (at most 2.4 SU):"
  echo "   sbatch -p icelake -N 1 -n 4 --mem=8G --time=00:30:00 -J femtic_smoke -o slurm-%x-%j.out --wrap 'TOOLCHAIN=$TOOLCHAIN SRC=$SRC BIN=$BIN SMOKE_ONLY=1 bash -l $PLAN_DIR/01_build_femtic.sh'"
fi

echo; echo "== $(date)  $([ "$SMOKE_ONLY" = 1 ] && echo SMOKE_ONLY || echo BUILD) DONE  T1=$T1  T2=$T2  T5=$T5   log: $LOG"
echo "   next: copy the gated WSL mesh (mesh.dat, resistivity_block_iter0.dat, control.dat, observe.dat, station_map.csv)"
echo "         into vulcan_femtic/inputs/vulcan_v2 and vulcan_v3 and check it (RUNBOOK B3; not 03_mesh.slurm: ungated);"
echo "         then 06_forward_only.slurm, one job per work directory vulcan_femtic/work/<mesh>/gate100 and gate3 (RUNBOOK B4a)"
[ "$T1" = PASS ] && [ "$T2" != FAIL ] && [ "$T5" != FAIL ] || exit 3
exit 0

# =============================================================================
# EasyBuild FALLBACK -- NOT NEEDED as of 2026-09-25: the central foss/2023a, imkl/2023.1.0 and
# intel/2023a modules exist and load (00_discover.sh on p2-log-2). Kept only in case they are retired.
# Phoenix has EasyBuild/4.5.5 ... 4.9.4, 5.0.0, 5.1.0, 5.3.0; 00_discover.sh loaded 5.3.0 (the newest),
# whose robot path /apps/icl/software/EasyBuild/5.3.0/easybuild/easyconfigs contains imkl-2023.1.0.eb
# (SYSTEM toolchain; binary installer, no compilation), intel-2023a.eb and
# impi-2021.9.0-intel-compilers-2023.1.0.eb ('eb -S', 2026-09-25). EasyBuild 5.3.0 runs on the
# system Python 3.6.8 with a deprecation warning, and its default installpath/buildpath/sourcepath are
# under /home/$USER/.local/easybuild (10 GB cap), so EASYBUILD_PREFIX below is essential.
#
#   module load EasyBuild/5.3.0
#   export EASYBUILD_PREFIX=/hpcfs/users/$USER/easybuild          # software/, modules/, sources/
#   export MODULEPATH=$EASYBUILD_PREFIX/modules/all:$MODULEPATH
#   mkdir -p $EASYBUILD_PREFIX
#
#   # (a) MKL only (~2-3 GB download, no compile)
#   eb imkl-2023.1.0.eb --robot -Dx                # dry run: shows what would be built
#   eb imkl-2023.1.0.eb --robot                    # downloads l_onemkl_p_2023.1.0.46342_offline.sh from Intel
#   module load foss/2023a imkl/2023.1.0           # then re-run:  TOOLCHAIN=foss bash -l 01_build_femtic.sh
#       # No internet on the build node? download the installer elsewhere and place it at
#       #   $EASYBUILD_PREFIX/sources/i/imkl/l_onemkl_p_2023.1.0.46342_offline.sh
#
#   # (b) whole Intel toolchain (hours if GCCcore 12.3.0 must be compiled too)
#   eb intel-2023a.eb --robot -Dx
#   eb intel-2023a.eb --robot
#
#   This script and femtic_env.sh already 'module use' $EASYBUILD_PREFIX/modules/all when it exists,
#   so batch jobs see the user-built modules without editing ~/.bashrc. Check the module name the
#   build prints ('eb --show-config | grep module_naming') and pass MODS="..." if it differs.
# =============================================================================
