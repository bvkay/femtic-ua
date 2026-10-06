#!/bin/bash -l
# =============================================================================
# 05_chain.sh -- submit K chained FEMTIC inversion jobs (each <= 3 days, the icelake/highmem MaxTime)
#
#   bash -l 05_chain.sh <inversion_dir> [K=3] [ITER_STEP=5] [ITER_MAX]
#   e.g. bash -l 05_chain.sh /hpcfs/users/$USER/vulcan_femtic/work/v2/inv01 3 8 30
#   Run on the login node, where sbatch is available. Nothing here needs internet or git.
#
# Layout (ranks x threads, partition, --mem). The chain REFUSES to start without one. The 04 header's 2 x 36 is
# the v3 layout; v2 runs 3 x 24, and a v2 chain on the header would silently get 2 ranks for 21 frequencies
# (10 and 11 per rank instead of 7). The layout comes from, in this order:
#   1. SBATCH_EXTRA with BOTH --ntasks-per-node and --cpus-per-task (or -c), taken as given:
#        SBATCH_EXTRA='--ntasks-per-node=3 --cpus-per-task=24' bash -l 05_chain.sh ...                    (v2)
#        SBATCH_EXTRA='--ntasks-per-node=2 --cpus-per-task=36' bash -l 05_chain.sh ...                    (v3)
#        SBATCH_EXTRA='-p highmem --mem=1900G --ntasks-per-node=7 --cpus-per-task=10' bash -l 05_chain.sh ...
#      (highmem is the only route above ~255 GB per node, 2.5 SU/cpu-h; a100cpu has no advantage). One of the
#      two options alone is refused: it would combine with the header's other value.
#   2. <inversion_dir>/LAYOUT, which 06_forward_only.slurm writes when its T6 passed under 04's full memory rule:
#      its "sbatch=" line (-p, -N, --ntasks-per-node, --cpus-per-task, --mem of that 06 job) and its "export="
#      line (RANKS/THREADS, if 06 ran fewer than it bought). Other SBATCH_EXTRA options (e.g. --time) follow it.
# Every 04 job re-checks the memory rule before femtic starts and refuses a layout that breaks it.
# Other options (environment): DEP_TYPE=afterok|afterany, JOB_SCRIPT=/path/04_inversion.slurm,
#   SBATCH_EXPORT_EXTRA="WATCH_S=30" (added to --export=ALL,...; RANKS=R,THREADS=T run fewer ranks or threads than
#   the layout's tasks and cpus).
#
# Each job is 04_inversion.slurm with AUTO_RESTART=1. On start it picks the restart iteration N
# with femtic_restart_pick: the highest resistivity_block_iter<N>.dat (and distortion_iter<N>.dat
# when DISTORTION != 0) whose line counts match its header and iteration 0's; a truncated N is
# renamed *.corrupt_<jobid> and N-1 is used. It then rewrites ITERATION to "N N+ITER_STEP" (capped
# at ITER_MAX). FEMTIC writes resistivity_block_iter<n>.dat (rank 0) as soon as model n's forward
# response is accepted, so a stopped job loses at most the iteration in progress, plus one repeated
# forward solve for model N at the next start. This script runs the same check (without renaming)
# to decide the start iteration it reports and the ITER_MAX arithmetic.
#
# Dependency semantics:
#   afterok (default) -- job i+1 starts only if job i exited 0. 04_inversion.slurm exits 0 when
#     FEMTIC converged, reached the ITERATION end, or was stopped by the script (safe point,
#     hard stop or SIGUSR1) AFTER writing >= 1 new valid model. So a 3-day job that runs out of time
#     still hands on, while a crash, a silent exit 0 (no COMPLETED marker), a job with no progress,
#     or a STALLED inversion (max retrials) stops the chain. --kill-on-invalid-dep=yes then cancels
#     the remaining jobs rather than leaving them pending with "DependencyNeverSatisfied".
#   afterany -- next job starts whatever happened (not recommended: repeats failures and burns SU).
#   singleton -- alternative: same --job-name for all jobs + --dependency=singleton (one at a time).
#
# Choose ITER_STEP from 06 (forward time) and T4 (time per iteration):
#   ITER_STEP ~ (72 h - 0.5 h margin - T_forward) / T_iteration.
# Too high is safe (the watcher stops the job at a safe point and it hands on); too low wastes queue time.
# =============================================================================
set -o pipefail
INV_DIR=${1:?usage: 05_chain.sh <inversion_dir> [K] [ITER_STEP] [ITER_MAX]}
K=${2:-3}
ITER_STEP=${3:-5}
ITER_MAX=${4:-}
DEP_TYPE=${DEP_TYPE:-afterok}
JOB_SCRIPT=${JOB_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/04_inversion.slurm}
SBATCH_EXTRA=${SBATCH_EXTRA:-}
SBATCH_EXPORT_EXTRA=${SBATCH_EXPORT_EXTRA:-}
BIN=${BIN:-/hpcfs/users/$USER/femtic/bin}

# shellcheck disable=SC1091
source "$BIN/femtic_lib.sh" 2>/dev/null || { echo "ERROR: $BIN/femtic_lib.sh missing -- run 01_build_femtic.sh"; exit 1; }
[ "${FEMTIC_LIB_VERSION:-0}" -ge 4 ] || { echo "ERROR: $BIN/femtic_lib.sh is version ${FEMTIC_LIB_VERSION:-unset}; this script needs FEMTIC_LIB_VERSION >= 4 (version 2, installed 2026-09-25, misreads PARDISO memory and has no layout rule; version 3 loses N_iv when DIV_NUM_RHS_FWD > N_iv) -- install -m 644 <phoenix_plan>/femtic_lib.sh $BIN/"; exit 1; }
INV_DIR=$(cd "$INV_DIR" 2>/dev/null && pwd) || { echo "ERROR: $1 is not a directory"; exit 1; }
case "$INV_DIR" in /home/*) echo "ERROR: jobs must run from /hpcfs, not /home"; exit 1 ;; esac
cd "$INV_DIR" || exit 1

# ---------------------------------------------------------------- pre-submission checks
[ -f "$JOB_SCRIPT" ] || { echo "ERROR: job script $JOB_SCRIPT not found"; exit 1; }
if grep -q $'\r' "$JOB_SCRIPT"; then echo "ERROR: $JOB_SCRIPT has CRLF line endings -- run: dos2unix $JOB_SCRIPT"; exit 1; fi
for f in control.dat mesh.dat observe.dat; do [ -f "$f" ] || { echo "ERROR: $f missing in $INV_DIR"; exit 1; }; done
grep -q 'YOUR_EMAIL@' "$JOB_SCRIPT" && { echo "ERROR: set --mail-user in $JOB_SCRIPT first"; exit 1; }
[[ "$K" =~ ^[0-9]+$ && "$ITER_STEP" =~ ^[0-9]+$ && "$K" -ge 1 && "$ITER_STEP" -ge 1 ]] || { echo "ERROR: K and ITER_STEP must be positive integers"; exit 1; }
[ -z "$ITER_MAX" ] || [[ "$ITER_MAX" =~ ^[0-9]+$ ]] || { echo "ERROR: ITER_MAX must be an integer"; exit 1; }
[ -f CONVERGED ] && { echo "CONVERGED marker exists in $INV_DIR -- remove it to continue"; exit 1; }
[ -f STALLED ]   && { echo "STALLED marker exists in $INV_DIR -- inspect femtic.cnv / logs, then rm STALLED"; exit 1; }
DIST=$(femtic_ctl_get control.dat DISTORTION | awk '{print $1}')
HIGHEST=$(femtic_last_iter .)
[ -n "$HIGHEST" ] || { echo "ERROR: no resistivity_block_iter<N>.dat in $INV_DIR (copy the gated mesh first: README section 3, step 7)"; exit 1; }
LAST=$(femtic_restart_pick . "${DIST:-0}" 0) || { echo "ERROR: no valid restart model in $INV_DIR (messages above; DISTORTION=${DIST:-0})"; exit 1; }
[ "$LAST" = "$HIGHEST" ] || echo "note: model $HIGHEST fails the integrity check; the first job will rename it and restart from $LAST"
if [ -n "$ITER_MAX" ] && [ "$LAST" -ge "$ITER_MAX" ]; then echo "already at iteration $LAST >= ITER_MAX=$ITER_MAX"; exit 0; fi
NEED=$(( ${ITER_MAX:-$(( LAST + K * ITER_STEP ))} - LAST ))
if [ $(( K * ITER_STEP )) -lt "$NEED" ]; then
  echo "note: $K jobs x $ITER_STEP iterations = $(( K * ITER_STEP )) < $NEED needed to reach ITER_MAX=$ITER_MAX"
fi

# ---------------------------------------------------------------- layout (header): explicit, else 06's LAYOUT file
# lay_opt LONG SHORT WORD... -> the value of --LONG=V, --LONG V or SHORT V among the WORDs; status 1 if absent
lay_opt() {
  local long=$1 short=$2 w take=""; shift 2
  for w in "$@"; do
    if [ -n "$take" ]; then echo "$w"; return 0; fi
    case "$w" in
      "--$long="*) echo "${w#*=}"; return 0 ;;
      "--$long") take=1 ;;
      *) [ -n "$short" ] && [ "$w" = "$short" ] && take=1 ;;
    esac
  done
  return 1
}
read -r -a XW <<< "$SBATCH_EXTRA"
NTPN=$(lay_opt ntasks-per-node "" "${XW[@]}"); CPT=$(lay_opt cpus-per-task -c "${XW[@]}")
LAYOUT_SBATCH=""; LAYOUT_EXPORT=""
if [ -n "$NTPN" ] && [ -n "$CPT" ]; then
  LAYOUT_SRC="SBATCH_EXTRA (explicit)"
  [ -f LAYOUT ] && echo "note: $INV_DIR/LAYOUT (from 06) is not used: $(sed -n 's/^sbatch=//p' LAYOUT | head -1)"
elif [ -n "$NTPN$CPT" ]; then
  echo "ERROR: SBATCH_EXTRA='$SBATCH_EXTRA' sets only one of --ntasks-per-node and --cpus-per-task. Give both, e.g."
  echo "       SBATCH_EXTRA='--ntasks-per-node=3 --cpus-per-task=24' (v2) or '--ntasks-per-node=2 --cpus-per-task=36' (v3)"
  exit 1
elif [ -f LAYOUT ]; then
  LAYOUT_SBATCH=$(sed -n 's/^sbatch=//p' LAYOUT | head -1)
  LAYOUT_EXPORT=$(sed -n 's/^export=//p' LAYOUT | head -1)
  re_sb='^[-A-Za-z0-9=_. ]+$'; re_ex='^[A-Z_]+=[0-9]+(,[A-Z_]+=[0-9]+)*$'
  if ! [[ "$LAYOUT_SBATCH" =~ $re_sb && "$LAYOUT_SBATCH" == *--ntasks-per-node=* && "$LAYOUT_SBATCH" == *--cpus-per-task=* ]]; then
    echo "ERROR: $INV_DIR/LAYOUT has no valid 'sbatch=' line with --ntasks-per-node and --cpus-per-task ('$LAYOUT_SBATCH')"; exit 1
  fi
  [ -z "$LAYOUT_EXPORT" ] || [[ "$LAYOUT_EXPORT" =~ $re_ex ]] || { echo "ERROR: $INV_DIR/LAYOUT: bad 'export=' line '$LAYOUT_EXPORT'"; exit 1; }
  LAYOUT_SRC="$INV_DIR/LAYOUT ($(sed -n '1s/^# written by \(.*\): T6 .*/\1/p' LAYOUT))"
else
  echo "ERROR: no layout for the chain. Run 06_forward_only.slurm in $INV_DIR first (it writes LAYOUT when T6 passes),"
  echo "       or copy the LAYOUT file of the directory where 06 passed on the same mesh (e.g. the gate run's),"
  echo "       or give the layout explicitly, both options:"
  echo "         SBATCH_EXTRA='--ntasks-per-node=3 --cpus-per-task=24' bash -l $0 $*    (v2)"
  echo "         SBATCH_EXTRA='--ntasks-per-node=2 --cpus-per-task=36' bash -l $0 $*    (v3)"
  echo "       The 04 header's 2 x 36 is not used silently: on v2 it would run 2 ranks instead of 3."
  exit 1
fi
echo "layout: ${LAYOUT_SBATCH:+$LAYOUT_SBATCH }$SBATCH_EXTRA${LAYOUT_EXPORT:+  --export ...,$LAYOUT_EXPORT}   from $LAYOUT_SRC${LAYOUT_SBATCH:+${SBATCH_EXTRA:+ (SBATCH_EXTRA follows it: a repeated option takes its value)}}"

# ---------------------------------------------------------------- submit
echo "chain of $K jobs in $INV_DIR: from iteration $LAST, +$ITER_STEP per job, cap ${ITER_MAX:-none}, dependency=$DEP_TYPE"
EXPORTS="ALL,AUTO_RESTART=1,ITER_STEP=$ITER_STEP,ITER_MAX=$ITER_MAX,INV_DIR=$INV_DIR,BIN=$BIN${LAYOUT_EXPORT:+,$LAYOUT_EXPORT}${SBATCH_EXPORT_EXTRA:+,$SBATCH_EXPORT_EXTRA}"
PREV=""
IDS=()
for i in $(seq 1 "$K"); do
  DEP=()
  [ -n "$PREV" ] && DEP=(--dependency="$DEP_TYPE:$PREV" --kill-on-invalid-dep=yes)
  # --parsable prints "jobid" or "jobid;cluster"
  # shellcheck disable=SC2086
  OUT=$(sbatch --parsable "${DEP[@]}" --export="$EXPORTS" -D "$INV_DIR" $LAYOUT_SBATCH $SBATCH_EXTRA "$JOB_SCRIPT") \
    || { echo "ERROR: sbatch failed at job $i: $OUT"; [ ${#IDS[@]} -gt 0 ] && echo "already submitted: ${IDS[*]}  (scancel them if needed)"; exit 1; }
  JID=${OUT%%;*}
  [[ "$JID" =~ ^[0-9]+$ ]] || { echo "ERROR: unexpected sbatch output '$OUT'"; exit 1; }
  echo "  job $i/$K -> $JID  ${PREV:+(after $DEP_TYPE:$PREV)}"
  IDS+=("$JID")
  PREV=$JID
done
printf '%s %s\n' "$(date +%F_%T)" "${IDS[*]}" >> "$INV_DIR/chain_jobs.txt"
echo "submitted: ${IDS[*]}   (also appended to $INV_DIR/chain_jobs.txt)"
echo "monitor:   squeue -u $USER -o '%.10i %.14j %.8T %.10M %.6D %R'"
echo "progress:  tail -3 $INV_DIR/femtic.cnv ; column -t -s \$'\\t' $INV_DIR/job_outcomes.tsv"
echo "after each job: rcstat <jobid>   (also printed at the end of slurm-<jobname>-<jobid>.out)"
echo "cancel:    scancel ${IDS[*]}"
