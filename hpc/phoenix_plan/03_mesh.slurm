#!/bin/bash -l
#SBATCH --job-name=vulcan_mesh
#SBATCH -p icelake
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -c 8
#SBATCH --mem=27G
#SBATCH --time=02:00:00
#SBATCH --signal=B:USR1@600
#SBATCH -o slurm-%x-%j.out
#SBATCH --mail-type=END,FAIL
#SBATCH --mail-user=ben.kay@adelaide.edu.au
# =============================================================================
# 03_mesh.slurm -- tetrahedral mesh generation for FEMTIC (7-step meshGen), serial except for
# makeTetraMesh's one OpenMP loop.
#
# Submit from the meshGen directory on /hpcfs (never from /home):
#     cd /hpcfs/users/$USER/vulcan_femtic/meshGen && sbatch /path/to/03_mesh.slurm
#     ... or free of SU on the interactive partition (max 8 cpus per job, so the same request fits):
#     sbatch -p interactive /path/to/03_mesh.slurm
# Request: RAM is granted per cpu (icelake 3541 MiB/cpu), so 8 cpus buy up to 28,328 MiB; --mem=27G
# (27,648 MiB) fits. Cost on icelake at full walltime: 8 cpus x 2 h x 1.2 SU = 19.2 SU; interactive: nil.
# THREADS=N (--export=ALL,THREADS=N) sets OMP_NUM_THREADS (default: --cpus-per-task).
#
# Inputs (from the femticPy prep notebooks, same layout as femticPy/projects/<name>/):
#   $PROJECT/input_data/{topography.dat,bathymetry.dat,coast_line.dat}   (copied into files/)
#   ./files/{control.dat,analysis_domain.dat,observing_site.dat,obs_site.dat,
#            makeMtr.param,resistivity_attr.dat}
#   Site coordinates in observing_site.dat / obs_site.dat must come from
#   Vulcan/site_coords_femticpy.txt only (README_phoenix.md, "Data provenance").
#   ./files/regions.txt  (optional) -- region seeds appended to output.poly in step 4, one per line:
#            <id> <x> <y> <z> <region attribute> <max volume>
#            z is positive DOWN in the makeTetraMesh frame (air seed at z<0), km units.
#            Default (onshore survey, same as femticPy's "synthetic" example):
#              1  0.0 0.0 -40.0  10 1e9      # air   -> attribute 10
#              2  0.0 0.0  10.0  20 1e9      # earth -> attribute 20
#            Add a sea seed (e.g. attribute 20 sea / 30 earth as in the AusLAMP example) only if
#            the domain has ocean. Every attribute must be listed in files/resistivity_attr.dat.
# Outputs: mesh.dat, resistivity_block_iter0.dat -> copied to $INVDIR
#
# Adapted from femticPy/scripts/meshGen.sh (CSIRO). Steps: makeTetraMesh -stp 1..4 ->
# tetgen -nVpYAakq3.0/0 -> NREFINE x (makeMtr + tetgen -nmpYVrAakq3.0/0) -> TetGen2Femtic.
#
# TEST T3 (fails if): resistivity_block_iter0.dat has a different number of element lines or
# block lines than its header says, or a region-seed attribute is missing from
# resistivity_attr.dat. Prints elements, cells, free/fixed cells; warns above MAX_ELEMENTS.
# logs/COMPLETED_<jobid> is written only when every step exited 0, T3 passed and the copy to
# $INVDIR succeeded. SIGUSR1 (600 s before the limit) writes logs/WALLTIME_<jobid> and exits 3.
# =============================================================================
set -o pipefail
JOB_T0=$(date +%s)
echo "== $(date) job ${SLURM_JOB_ID:-none} (${SLURM_JOB_NAME:-?}) partition=${SLURM_JOB_PARTITION:-?} on $(hostname)  cwd=$PWD"

BIN=${BIN:-/hpcfs/users/$USER/femtic/bin}
PROJECT=${PROJECT:-/hpcfs/users/$USER/vulcan_femtic}
MESHDIR=${MESHDIR:-$PROJECT/meshGen}
INVDIR=${INVDIR:-$PROJECT/work/meshgen/inv01}   # an ungated mesh: its own work/<mesh>, never inputs/ or work/v{2,3}
NREFINE=${NREFINE:-5}                 # meshGen.sh uses 5 passes: output.1 .. output.5 -> output.6
MAX_ELEMENTS=${MAX_ELEMENTS:-500000}  # warning threshold for the Vulcan mesh
FIX_ELE=${FIX_ELE:-0}                 # 1 = CSIRO fix_output1.py: cap region attribute of output.1.ele at FIX_ELE_MAX
FIX_ELE_MAX=${FIX_ELE_MAX:-30}

# shellcheck disable=SC1091
source "$BIN/femtic_env.sh" || { echo "ERROR: $BIN/femtic_env.sh missing -- run 01_build_femtic.sh"; exit 1; }
[ "${FEMTIC_LIB_VERSION:-0}" -ge 4 ] || { echo "ERROR: $BIN/femtic_lib.sh is version ${FEMTIC_LIB_VERSION:-unset}; this script needs FEMTIC_LIB_VERSION >= 4 (version 2, installed 2026-09-25, misreads PARDISO memory and has no layout rule; version 3 loses N_iv when DIV_NUM_RHS_FWD > N_iv) -- install -m 644 <phoenix_plan>/femtic_lib.sh $BIN/"; exit 1; }
export OMP_NUM_THREADS=${THREADS:-${SLURM_CPUS_PER_TASK:-1}}   # makeTetraMesh has one OpenMP loop; tetgen etc. are serial
for exe in makeTetraMesh tetgen makeMtr TetGen2Femtic; do
  command -v "$exe" >/dev/null || { echo "ERROR: $exe not on PATH ($BIN)"; exit 1; }
done

cd "$MESHDIR" || exit 1
mkdir -p logs
OUTCOMES="$MESHDIR/job_outcomes.tsv"
STEPNAME="setup"
CUR=""
row() {   # row OUTCOME EXIT DETAIL
  femtic_outcome_row "$OUTCOMES" "${SLURM_JOB_ID:-0}" 03_mesh "$(hostname -s)" "$(date -d "@$JOB_T0" +%FT%T)" "$(date +%FT%T)" "$1" "" "" "$2" "$3"
}
fail() { echo "$*"; row failed 1 "$STEPNAME: $*"; exit 1; }
on_usr1() {
  echo "[$(date '+%F %T')] SIGUSR1: wall limit in about 600 s during '$STEPNAME' -> logs/WALLTIME_${SLURM_JOB_ID:-0}; stopping (mesh is not resumable)"
  echo "usr1 $(date +%s) step=$STEPNAME" > "logs/WALLTIME_${SLURM_JOB_ID:-0}"
  row walltime_usr1 3 "step $STEPNAME"
  [ -n "$CUR" ] && kill -TERM "$CUR" 2>/dev/null
  exit 3
}
trap on_usr1 USR1
# run CMD... : runs one mesh tool in the background and waits, so the USR1 trap fires at once
run() { "$@" & CUR=$!; femtic_wait_pid "$CUR"; local rc=$?; CUR=""; return "$rc"; }

[ -d files ] || fail "ERROR: $MESHDIR/files missing"
for f in topography.dat bathymetry.dat coast_line.dat; do
  if [ -f "$PROJECT/input_data/$f" ]; then cp "$PROJECT/input_data/$f" files/
  elif [ ! -f "files/$f" ]; then fail "ERROR: $f neither in $PROJECT/input_data nor in files/"; fi
done
for f in control.dat analysis_domain.dat observing_site.dat obs_site.dat makeMtr.param resistivity_attr.dat; do
  [ -f "files/$f" ] || fail "ERROR: files/$f missing"
done
sed -i 's/\r$//' files/*.dat files/*.param files/regions.txt 2>/dev/null   # CRLF from Windows-made inputs

# ---------------------------------------------------------------- region seeds (checked before any work)
if [ -f files/regions.txt ]; then
  REGIONS=$(grep -vE '^[[:space:]]*(#|$)' files/regions.txt)
else
  REGIONS=$'1   0.0 0.0 -40.0   10 1e9\n2   0.0 0.0  10.0   20 1e9'
fi
NREG=$(echo "$REGIONS" | grep -c .)
# resistivity_attr.dat: line 1 = number of region attributes N, then N lines "<attr> <rho> ..." (femticPy examples)
NATTR=$(head -1 files/resistivity_attr.dat | awk '{print $1}')
ATTRS=$(awk -v n="$NATTR" 'NR>1 && NR<=n+1 {print $1}' files/resistivity_attr.dat | sort -u | tr '\n' ' ')
echo "region seeds ($NREG):"; echo "$REGIONS"
echo "attributes in resistivity_attr.dat: $ATTRS"
for a in $(echo "$REGIONS" | awk '{print $5}'); do
  echo " $ATTRS " | grep -q " $a " || fail "T3 FAIL: region attribute $a is not in files/resistivity_attr.dat"
done

step() { STEPNAME="$1 $2"; echo; echo "----------------------- STEP $1 : $2  ($(date +%T)) -----------------------"; }

step 1 "makeTetraMesh -stp 1"
cp files/{control.dat,coast_line.dat,analysis_domain.dat,observing_site.dat} . || fail "copy failed"
run makeTetraMesh -stp 1 || fail "makeTetraMesh -stp 1 failed"

step 2 "makeTetraMesh -stp 2"
run makeTetraMesh -stp 2 || fail "makeTetraMesh -stp 2 failed"

step 3 "makeTetraMesh -stp 3 (topography / bathymetry)"
cp files/{topography.dat,bathymetry.dat} . || fail "copy failed"
run makeTetraMesh -stp 3 || fail "makeTetraMesh -stp 3 failed"

step 4 "makeTetraMesh -stp 4 -> output.poly, then append $NREG region seeds"
run makeTetraMesh -stp 4 || fail "makeTetraMesh -stp 4 failed"
# The last line of output.poly is the region count (0 as written); replace it and append the seeds.
sed -i "$(( $(wc -l < output.poly) ))s/.*/$NREG/" output.poly
echo "$REGIONS" >> output.poly
tail -n $((NREG + 1)) output.poly

step 5 "tetgen -nVpYAakq3.0/0 output.poly"
run tetgen -nVpYAakq3.0/0 output.poly || fail "tetgen failed"
if [ "$FIX_ELE" = 1 ]; then
  # awk equivalent of femticPy/scripts/fix_output1.py: keep the header, drop tetgen's trailing
  # comment line, cap column 6 (region attribute) at FIX_ELE_MAX.
  awk -v m="$FIX_ELE_MAX" 'NR==1 {print; next} /^[[:space:]]*#/ {next} {if ($6 > m) $6 = m; print}' output.1.ele > output.1.ele.fix \
    && mv output.1.ele.fix output.1.ele && echo "fixed output.1.ele (attribute > $FIX_ELE_MAX -> $FIX_ELE_MAX)"
fi

step 6 "makeMtr sizing + tetgen refinement x $NREFINE"
cp files/{obs_site.dat,makeMtr.param} . || fail "copy failed"
for i in $(seq 1 "$NREFINE"); do
  echo "  refine pass $i  ($(date +%T))"
  run makeMtr "output.$i" || fail "makeMtr output.$i failed"
  run tetgen -nmpYVrAakq3.0/0 "output.$i" || fail "tetgen refine output.$i failed"
done
FINAL=output.$((NREFINE + 1))

step 7 "TetGen2Femtic $FINAL"
cp files/resistivity_attr.dat . || fail "copy failed"
run TetGen2Femtic "$FINAL" || fail "TetGen2Femtic failed"

# ---------------------------------------------------------------- TEST T3 + report
STEPNAME="T3"
echo; echo "======================= MESH REPORT ======================="
[ -s resistivity_block_iter0.dat ] && [ -s mesh.dat ] || fail "T3 FAIL: TetGen2Femtic did not write mesh.dat / resistivity_block_iter0.dat"
read -r NELEM NBLK NBLK_COUNTED NFREE NFIXED < <(femtic_block_stats resistivity_block_iter0.dat)
NELEM_LINES=$(awk -v n="$NELEM" 'NR>1 && NR<=n+1' resistivity_block_iter0.dat | wc -l)
NTET=$(head -1 "$FINAL.ele" | awk '{print $1}')
NNODE=$(head -1 "$FINAL.node" | awk '{print $1}')
echo "tetgen $FINAL           : $NTET tetrahedra, $NNODE nodes"
echo "resistivity_block_iter0 : $NELEM elements, $NBLK parameter cells ($NFREE free, $NFIXED fixed)"
echo "mesh.dat first line     : $(head -1 mesh.dat)"
T3=PASS
[ "$NELEM_LINES" = "$NELEM" ]  || { echo "T3 FAIL: $NELEM_LINES element lines, header says $NELEM"; T3=FAIL; }
[ "$NBLK_COUNTED" = "$NBLK" ]  || { echo "T3 FAIL: $NBLK_COUNTED block lines, header says $NBLK"; T3=FAIL; }
echo "restart-check view of the same file: $(femtic_block_check resistivity_block_iter0.dat)"
[ "$NTET" = "$NELEM" ] || echo "note: tetgen element count ($NTET) != FEMTIC element count ($NELEM) -- check TetGen2Femtic log"
[ "${NELEM:-0}" -gt "$MAX_ELEMENTS" ] && echo "WARNING: $NELEM elements > target $MAX_ELEMENTS -- coarsen makeMtr.param / control.dat before inverting"
echo
echo "Sizing inputs for 04_inversion.slurm (see README_phoenix.md 'MPI ranks, threads and memory'):"
echo "  M (free model parameters) = $NFREE   (+ distortion parameters if DISTORTION != 0)"
echo "  Vulcan data are impedance only: Nd = 8 x 120 sites x F = 960 x F (F = number of inversion frequencies)"
echo "  sensitivity files per iteration  ~ Nd x M x 8 B = Nd x $(awk -v m="$NFREE" 'BEGIN{printf "%.3g", m*8/1e9}') GB   (x2 for the data-space method)"
echo "  rank-0 dense, model space (INV_METHOD 0): ~ (2 Nd M + M^2/2) x 8 B = 2 Nd x $(awk -v m="$NFREE" 'BEGIN{printf "%.3g", m*8/1e9}') GB + $(awk -v m="$NFREE" 'BEGIN{printf "%.3g", m*m*4/1e9}') GB"
echo "  rank-0 dense, data space  (INV_METHOD 1): ~ Nd^2 x 8 B"
echo "  next job: 06_forward_only.slurm in $INVDIR (measures forward time and PARDISO memory)"
echo "T3 (mesh consistency): $T3"
[ "$T3" = PASS ] || fail "T3 FAIL"

STEPNAME="copy"
mkdir -p "$INVDIR" && cp resistivity_block_iter0.dat mesh.dat "$INVDIR"/ || fail "copy to $INVDIR failed"
echo "copied mesh.dat + resistivity_block_iter0.dat to $INVDIR"
printf 'job %s\nT3 %s\nelements %s\ncells %s free %s fixed %s\ncopied_to %s\nfinished %s\n' "${SLURM_JOB_ID:-0}" "$T3" "$NELEM" "$NBLK" "$NFREE" "$NFIXED" "$INVDIR" "$(date +%FT%T)" > "logs/COMPLETED_${SLURM_JOB_ID:-0}"
row completed 0 "elements=$NELEM cells=$NBLK free=$NFREE"
echo "== done $(date)   COMPLETED marker: $MESHDIR/logs/COMPLETED_${SLURM_JOB_ID:-0}"
echo; echo "== efficiency report: rcstat ${SLURM_JOB_ID:-?}"
rcstat "${SLURM_JOB_ID:-0}" 2>/dev/null || echo "(rcstat unavailable on this node -- run 'rcstat ${SLURM_JOB_ID:-<jobid>}' on the login node)"
exit 0
