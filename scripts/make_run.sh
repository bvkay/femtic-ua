#!/bin/bash
# =============================================================================
# make_run.sh -- make a run folder on the PC (Git Bash), ready to copy to Phoenix with WinSCP:
#   bash scripts/make_run.sh Run01 --mesh v2 --data mesh/vulcan_v2_rot/inversion --job gate --start-rho 100 \
#        --layout 3x24 --time 02:00:00 --purpose "Half-space gate at 100 ohm-m on v2"
#   bash scripts/make_run.sh Run05 --job mesh --files mesh/vulcan_v2/files --purpose "Build v2 on Phoenix"
# Options (FEMTIC runs: the first six required; --start-rho and --iter-step/--iter-max when the job needs them; the
# last three optional):
#   --mesh v2|v3          the shared mesh on Phoenix ($VF/shared/mesh_v2 or mesh_v3; run.sh links it)
#   --data DIR            folder with control.dat, observe.dat, station_map.csv (e.g. mesh/vulcan_v2_rot/inversion)
#   --job gate|forward|t4|inversion|mesh
#   --layout RxT          R MPI ranks per node x T threads per rank (v2 3x24, v3 2x36 on icelake; mesh default 1x8)
#   --time HH:MM:SS       wall time per job (D-HH:MM:SS also works; mesh default 04:00:00)
#   --purpose "TEXT"      why the run exists; goes to RUN.md and runs/INDEX.md
#   --start-rho OHM_M     gate only: the half-space resistivity
#   --iter-step N --iter-max N   inversion only: iterations per chained job, last iteration
#   --partition icelake|highmem  (default icelake)
#   --niv N               N_iv for the layout rule and the job (default none: 4 x MT stations = 480; 840 if Run03
#                         measured it)
#   --mail ADDRESS        email when each job ends or fails (default none: no email)
# A mesh build (--job mesh; no --mesh, --data, --start-rho, --iter-*, --niv):
#   --files DIR           folder with the mesh inputs, copied into the run's files/ (e.g. mesh/vulcan_v2/files). It
#                         must hold the 10 inputs of mesh/vulcan_v2/files: analysis_domain.dat bathymetry.dat
#                         coast_line.dat control.dat makeMtr.param obs_site.dat observing_site.dat region_seeds.dat
#                         resistivity_attr.dat topography.dat; region_seeds.dat may instead come from --seeds
#   --seeds "x y z attr maxvol; ..."   only when DIR has no region_seeds.dat: one seed per closed region (km, z
#                         positive down; maxvol km^3, 1e9 = none), written to files/region_seeds.dat
# Writes runs/RunNN/ (RUNS overrides runs/): control.dat, observe.dat, station_map.csv copied from --data (t4: control.dat
# set to ITERATION 0 1), or files/ for a mesh build, run.env (read by the kit's run.sh), RUN.md (purpose, date, data
# source; run.sh adds a line per job, and each job's output records the code that ran in its KIT VERSION line), and
# adds the run's line to runs/INDEX.md. Refuses an existing run name, a missing data or input file or a bad option.
# Next: WinSCP runs/RunNN to /hpcfs/users/<your user>/vulcan_femtic/runs/, then on Phoenix: bash $VF/kit/run.sh RunNN
# =============================================================================
set -o pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
RUNS=${RUNS:-$REPO/runs}
die() { echo "make_run.sh: REFUSED: $*" >&2; exit 1; }
RUN=${1:-}; shift
[[ "$RUN" =~ ^Run[0-9]{2,}$ ]] || die "the first argument is the run name: Run01, Run02, ... (got '$RUN')"
MESH=""; DATA=""; JOB=""; RHO=none; LAYOUT=""; TIME=""; PURPOSE=""; STEP=none; IMAX=none; PART=icelake; NIV=none; MAIL=none
FILES=""; SEEDS=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || die "option $1 needs a value"
  case "$1" in
    --mesh) MESH=$2 ;; --data) DATA=$2 ;; --job) JOB=$2 ;; --start-rho) RHO=$2 ;; --layout) LAYOUT=$2 ;;
    --time) TIME=$2 ;; --purpose) PURPOSE=$2 ;; --iter-step) STEP=$2 ;; --iter-max) IMAX=$2 ;; --partition) PART=$2 ;;
    --niv) NIV=$2 ;; --mail) MAIL=$2 ;; --files) FILES=$2 ;; --seeds) SEEDS=$2 ;;
    *) die "unknown option $1" ;;
  esac
  shift 2
done
case "$JOB" in gate|forward|t4|inversion|mesh) ;; *) die "--job gate, forward, t4, inversion or mesh (got '$JOB')" ;; esac
MESH_INPUTS="analysis_domain.dat bathymetry.dat coast_line.dat control.dat makeMtr.param obs_site.dat observing_site.dat region_seeds.dat resistivity_attr.dat topography.dat"
if [ "$JOB" = mesh ]; then
  [ -z "$MESH" ] || die "--mesh is for FEMTIC runs: a --job mesh run builds its mesh from --files"
  [ -z "$DATA" ] || die "--data is for FEMTIC runs: a --job mesh run takes its inputs from --files"
  [ "$NIV" = none ] || die "--niv is for FEMTIC runs, not --job mesh"
  [ -n "$FILES" ] || die "--job mesh needs --files DIR (the mesh inputs, e.g. mesh/vulcan_v2/files)"
  MESH=none; LAYOUT=${LAYOUT:-1x8}; TIME=${TIME:-04:00:00}
else
  case "$MESH" in v2|v3) ;; *) die "--mesh v2 or v3 (got '$MESH')" ;; esac
  [ -z "$FILES" ] && [ -z "$SEEDS" ] || die "--files and --seeds are for --job mesh only"
fi
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
if [ "$JOB" = mesh ]; then
  [ -d "$FILES" ] || { [ -d "$REPO/$FILES" ] && FILES=$REPO/$FILES; } || die "--files '$FILES' is not a folder"
  FILES=$(cd "$FILES" && pwd)
  for f in $MESH_INPUTS; do
    [ "$f" = region_seeds.dat ] && [ -n "$SEEDS" ] && continue
    [ -s "$FILES/$f" ] || die "$FILES/$f is missing or empty (a mesh run needs: $MESH_INPUTS$([ "$f" = region_seeds.dat ] && echo "; or give the seeds with --seeds \"x y z attr maxvol; ...\""))"
  done
  if [ -n "$SEEDS" ]; then
    [ ! -e "$FILES/region_seeds.dat" ] || die "--seeds, but $FILES has a region_seeds.dat: give the seeds one way only"
    printf '%s\n' "$SEEDS" | tr ';' '\n' | awk 'NF == 0 {next} {n++; if (NF != 5) bad = 1
        for (i = 1; i <= 5; i++) if ($i !~ /^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/) bad = 1} END {exit (bad || n < 2)}' \
      || die "--seeds \"x y z attr maxvol; x y z attr maxvol; ...\": at least 2 seeds (air, earth) of 5 numbers each (got '$SEEDS')"
  fi
  DSRC=${FILES#"$REPO"/}
else
  [ -d "$DATA" ] || { [ -d "$REPO/$DATA" ] && DATA=$REPO/$DATA; } || die "--data '$DATA' is not a folder"
  DATA=$(cd "$DATA" && pwd)
  for f in control.dat observe.dat station_map.csv; do [ -s "$DATA/$f" ] || die "$DATA/$f is missing or empty"; done
  DSRC=${DATA#"$REPO"/}
fi

mkdir -p "$RD" || die "cannot create $RD"
NOW=$(date '+%Y-%m-%d %H:%M')
if [ "$JOB" = mesh ]; then
  mkdir -p "$RD/files" || die "cannot create $RD/files"
  for f in "$FILES"/*; do [ -f "$f" ] && { cp "$f" "$RD/files/" || die "copy of $f failed"; }; done
  if [ -n "$SEEDS" ]; then
    { echo "# x_km y_km z_km(down) attribute max_volume_km3 -- one seed per closed region; from make_run.sh --seeds, $NOW"
      printf '%s\n' "$SEEDS" | tr ';' '\n' | awk 'NF == 5 {print $1, $2, $3, $4, $5}'; } > "$RD/files/region_seeds.dat"
  fi
else
  cp "$DATA/control.dat" "$DATA/observe.dat" "$DATA/station_map.csv" "$RD/" || die "copy from $DATA failed"
  if [ "$JOB" = t4 ]; then
    # shellcheck disable=SC1091
    source "$REPO/hpc/phoenix_plan/femtic_lib.sh" && femtic_ctl_set "$RD/control.dat" ITERATION "0 1" \
      || die "cannot set ITERATION 0 1 in $RD/control.dat"
  fi
fi
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
[ "$JOB" = mesh ] && echo "FILES=files" >> "$RD/run.env"
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
  mesh)      WHAT="mesh build from files/ (mesh_chain.sh: makeTetraMesh -stp 1-4, tetgen, 5 x makeMtr + tetgen -r, TetGen2Femtic; --mem=27G)"
             NOTE="The job builds mesh.dat, resistivity_block_iter0.dat and output.6.femtic.vtk in this folder from files/,
and keeps every intermediate (output.poly, output.1-6.*, each round's .mtr, the logs and timings) in intermediates/.
mesh_summary.txt holds the counts (nodes, tets, cells, surface faces) and the MESH CHAIN DONE line." ;;
esac
if [ "$JOB" = mesh ]; then
  MESHLINE="- mesh: built by this run (mesh_chain.sh), into this folder"
  DATALINE="- files: $DSRC (copied into files/)$([ -z "$SEEDS" ] || echo "; files/region_seeds.dat written from --seeds \"$SEEDS\"")"
else
  MESHLINE="- mesh: $MESH (on Phoenix \$VF/shared/mesh_$MESH/, linked into this folder by run.sh)"
  DATALINE="- data: $DSRC (control.dat, observe.dat, station_map.csv copied from there)"
fi
cat > "$RD/RUN.md" <<MD
# $RUN

- purpose: $PURPOSE
- made: $NOW by scripts/make_run.sh on the PC
- job: $WHAT
$MESHLINE
- layout: $RANKS ranks x $THREADS threads per node, --time=$TIME, partition $PART$([ "$NIV" = none ] || echo ", NIV=$NIV")
$DATALINE

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
