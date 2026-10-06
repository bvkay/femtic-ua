#!/bin/bash
# =============================================================================
# make_run.sh -- make a run folder on the PC (Git Bash), ready to copy to Phoenix with WinSCP:
#   bash scripts/make_run.sh Run01 --mesh v2 --data mesh/vulcan_v2_rot/inversion --job gate --start-rho 100 \
#        --layout 3x24 --time 02:00:00 --purpose "Half-space gate at 100 ohm-m on v2"
# Options (the first six required; --start-rho and --iter-step/--iter-max when the job needs them; the last three optional):
#   --mesh v2|v3          the shared mesh on Phoenix ($VF/shared/mesh_v2 or mesh_v3; run.sh links it)
#   --data DIR            folder with control.dat, observe.dat, station_map.csv (e.g. mesh/vulcan_v2_rot/inversion)
#   --job gate|forward|t4|inversion
#   --layout RxT          R MPI ranks per node x T threads per rank (v2 3x24, v3 2x36 on icelake)
#   --time HH:MM:SS       wall time per job (D-HH:MM:SS also works)
#   --purpose "TEXT"      why the run exists; goes to RUN.md and runs/INDEX.md
#   --start-rho OHM_M     gate only: the half-space resistivity
#   --iter-step N --iter-max N   inversion only: iterations per chained job, last iteration
#   --partition icelake|highmem  (default icelake)
#   --niv N               N_iv for the layout rule and the job (default none: 4 x MT stations = 480; 840 if Run03
#                         measured it)
#   --mail ADDRESS        email when each job ends or fails (default none: no email)
# Writes runs/RunNN/ (RUNS overrides runs/): control.dat, observe.dat, station_map.csv copied from --data (t4: control.dat
# set to ITERATION 0 1), run.env (read by the kit's run.sh), RUN.md (purpose, date, data source; run.sh adds a line per
# job, and each job's output records the code that ran in its KIT VERSION line), and adds the run's line to
# runs/INDEX.md. Refuses an existing run name, a missing data file or a bad option.
# Next: WinSCP runs/RunNN to /hpcfs/users/<your user>/vulcan_femtic/runs/, then on Phoenix: bash $VF/kit/run.sh RunNN
# =============================================================================
set -o pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
RUNS=${RUNS:-$REPO/runs}
die() { echo "make_run.sh: REFUSED: $*" >&2; exit 1; }
RUN=${1:-}; shift
[[ "$RUN" =~ ^Run[0-9]{2,}$ ]] || die "the first argument is the run name: Run01, Run02, ... (got '$RUN')"
MESH=""; DATA=""; JOB=""; RHO=none; LAYOUT=""; TIME=""; PURPOSE=""; STEP=none; IMAX=none; PART=icelake; NIV=none; MAIL=none
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || die "option $1 needs a value"
  case "$1" in
    --mesh) MESH=$2 ;; --data) DATA=$2 ;; --job) JOB=$2 ;; --start-rho) RHO=$2 ;; --layout) LAYOUT=$2 ;;
    --time) TIME=$2 ;; --purpose) PURPOSE=$2 ;; --iter-step) STEP=$2 ;; --iter-max) IMAX=$2 ;; --partition) PART=$2 ;;
    --niv) NIV=$2 ;; --mail) MAIL=$2 ;;
    *) die "unknown option $1" ;;
  esac
  shift 2
done
case "$MESH" in v2|v3) ;; *) die "--mesh v2 or v3 (got '$MESH')" ;; esac
case "$JOB" in gate|forward|t4|inversion) ;; *) die "--job gate, forward, t4 or inversion (got '$JOB')" ;; esac
[[ "$LAYOUT" =~ ^([1-9][0-9]*)x([1-9][0-9]*)$ ]] || die "--layout RANKSxTHREADS, e.g. 3x24 (got '$LAYOUT')"
RANKS=${BASH_REMATCH[1]}; THREADS=${BASH_REMATCH[2]}
[ $(( RANKS * THREADS )) -le 72 ] || die "--layout $LAYOUT asks for $(( RANKS * THREADS )) cpus; a node has 72"
[[ "$TIME" =~ ^([0-9]+-)?[0-9]{1,2}:[0-9]{2}:[0-9]{2}$ ]] || die "--time HH:MM:SS or D-HH:MM:SS (got '$TIME')"
case "$PART" in icelake|highmem) ;; *) die "--partition icelake or highmem (got '$PART')" ;; esac
[ -n "$PURPOSE" ] || die "--purpose \"...\" is required: say why this run exists"
[ "$NIV" = none ] || [[ "$NIV" =~ ^[1-9][0-9]*$ ]] || die "--niv N, a whole number >= 1 (got '$NIV')"
[ "$MAIL" = none ] || [[ "$MAIL" =~ ^[^@,[:space:]]+@[^@,[:space:]]+$ ]] || die "--mail ADDRESS, an email address (got '$MAIL')"
if [ "$JOB" = gate ]; then
  [[ "$RHO" =~ ^[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$ ]] && awk -v r="$RHO" 'BEGIN {exit !(r + 0 > 0)}' \
    || die "--job gate needs --start-rho <ohm-m> > 0 (got '$RHO')"
else
  [ "$RHO" = none ] || die "--start-rho is for --job gate only"
fi
if [ "$JOB" = inversion ]; then
  [[ "$STEP" =~ ^[1-9][0-9]*$ && "$IMAX" =~ ^[1-9][0-9]*$ ]] || die "--job inversion needs --iter-step N and --iter-max N"
else
  [ "$STEP" = none ] && [ "$IMAX" = none ] || die "--iter-step and --iter-max are for --job inversion only"
fi
RD=$RUNS/$RUN
[ ! -e "$RD" ] || die "$RD exists already: run names are never reused (take the next number)"
grep -q "^| $RUN |" "$RUNS/INDEX.md" 2>/dev/null && die "$RUNS/INDEX.md already has a line for $RUN"
[ -d "$DATA" ] || { [ -d "$REPO/$DATA" ] && DATA=$REPO/$DATA; } || die "--data '$DATA' is not a folder"
DATA=$(cd "$DATA" && pwd)
for f in control.dat observe.dat station_map.csv; do [ -s "$DATA/$f" ] || die "$DATA/$f is missing or empty"; done
DSRC=${DATA#"$REPO"/}

mkdir -p "$RD" || die "cannot create $RD"
cp "$DATA/control.dat" "$DATA/observe.dat" "$DATA/station_map.csv" "$RD/" || die "copy from $DATA failed"
if [ "$JOB" = t4 ]; then
  # shellcheck disable=SC1091
  source "$REPO/hpc/phoenix_plan/femtic_lib.sh" && femtic_ctl_set "$RD/control.dat" ITERATION "0 1" \
    || die "cannot set ITERATION 0 1 in $RD/control.dat"
fi
NOW=$(date '+%Y-%m-%d %H:%M')
cat > "$RD/run.env" <<ENV
# $RUN, written by scripts/make_run.sh on $NOW. Read by the kit's run.sh on Phoenix ("none": does not apply).
MESH=$MESH
JOB=$JOB
START_RHO=$RHO
RANKS=$RANKS
THREADS=$THREADS
TIME=$TIME
PARTITION=$PART
ITER_STEP=$STEP
ITER_MAX=$IMAX
NIV=$NIV
MAIL=$MAIL
ENV
case "$JOB" in
  gate)      WHAT="half-space accuracy gate, START_RHO=$RHO ohm-m (06_forward_only.slurm)"
             NOTE="A half-space gate runs one forward solve of a uniform $RHO ohm-m model and compares it with the analytic
half-space at every site and band. The data values in observe.dat do not matter, only its sites and frequencies." ;;
  forward)   WHAT="one forward solve of resistivity_block_iter0.dat (06_forward_only.slurm, ITERATION 0 0)"
             NOTE="Measures the forward time per frequency and the memory per rank of this layout." ;;
  t4)        WHAT="T4, one inversion iteration (04_inversion.slurm; control.dat ITERATION 0 1)"
             NOTE="Measures the sensitivity step (memory, N_iv) and the time of one iteration. The model is not kept for later runs." ;;
  inversion) WHAT="inversion, $STEP iterations per job up to iteration $IMAX (05_chain.sh -> 04_inversion.slurm)"
             NOTE="05_chain.sh submits chained 3-day jobs; 'run.sh $RUN --again' continues from the last complete model." ;;
esac
cat > "$RD/RUN.md" <<MD
# $RUN

- purpose: $PURPOSE
- made: $NOW by scripts/make_run.sh on the PC
- job: $WHAT
- mesh: $MESH (on Phoenix \$VF/shared/mesh_$MESH/, linked into this folder by run.sh)
- layout: $RANKS ranks x $THREADS threads per node, --time=$TIME, partition $PART$([ "$NIV" = none ] || echo ", NIV=$NIV")
- data: $DSRC (control.dat, observe.dat, station_map.csv copied from there)

$NOTE

On Phoenix (VF=/hpcfs/users/\$USER/vulcan_femtic): bash \$VF/kit/run.sh $RUN   then   bash \$VF/kit/status.sh $RUN

## Jobs
MD
IDX=$RUNS/INDEX.md
[ -s "$IDX" ] || printf '# Runs\n\n| run | mesh | purpose | layout | job id(s) | verdict |\n|---|---|---|---|---|---|\n' > "$IDX"
echo "| $RUN | $MESH | $(printf '%s' "$PURPOSE" | tr '|\n' '/ ') | $LAYOUT | - | - |" >> "$IDX"
echo "made $(cd "$RD" && { pwd -W 2>/dev/null || pwd; }): $(cd "$RD" && ls | tr '\n' ' ')"
echo "next: WinSCP the folder $RUN to /hpcfs/users/<your user>/vulcan_femtic/runs/, then on Phoenix:"
echo "      bash /hpcfs/users/\$USER/vulcan_femtic/kit/run.sh $RUN"
