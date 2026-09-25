#!/bin/bash -l
# =============================================================================
# 05_chain.sh -- submit K chained FEMTIC inversion jobs (each <= 3 days, the icelake/a100cpu/highmem limit)
#
#   bash -l 05_chain.sh <inversion_dir> [K=3] [ITER_STEP=5] [ITER_MAX]
#   e.g. bash -l 05_chain.sh /hpcfs/users/$USER/vulcan_femtic/inversion/inv01 3 8 30
#   Options (environment): DEP_TYPE=afterok|afterany, JOB_SCRIPT=/path/04_inversion.slurm,
#                          SBATCH_EXTRA="-p a100cpu --mem=514944M" (overrides the 04 header),
#                          SBATCH_EXPORT_EXTRA="RANKS=4,THREADS=18" (added to --export=ALL,...)
#   Run on the login node, where sbatch is available. Nothing here needs internet or git.
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
[ "${FEMTIC_LIB_VERSION:-0}" -ge 2 ] || { echo "ERROR: $BIN/femtic_lib.sh predates this script -- install -m 644 <phoenix_plan>/femtic_lib.sh $BIN/"; exit 1; }
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
[ -n "$HIGHEST" ] || { echo "ERROR: no resistivity_block_iter<N>.dat in $INV_DIR (run 03_mesh.slurm first)"; exit 1; }
LAST=$(femtic_restart_pick . "${DIST:-0}" 0) || { echo "ERROR: no valid restart model in $INV_DIR (messages above; DISTORTION=${DIST:-0})"; exit 1; }
[ "$LAST" = "$HIGHEST" ] || echo "note: model $HIGHEST fails the integrity check; the first job will rename it and restart from $LAST"
if [ -n "$ITER_MAX" ] && [ "$LAST" -ge "$ITER_MAX" ]; then echo "already at iteration $LAST >= ITER_MAX=$ITER_MAX"; exit 0; fi
NEED=$(( ${ITER_MAX:-$(( LAST + K * ITER_STEP ))} - LAST ))
if [ $(( K * ITER_STEP )) -lt "$NEED" ]; then
  echo "note: $K jobs x $ITER_STEP iterations = $(( K * ITER_STEP )) < $NEED needed to reach ITER_MAX=$ITER_MAX"
fi

# ---------------------------------------------------------------- submit
echo "chain of $K jobs in $INV_DIR: from iteration $LAST, +$ITER_STEP per job, cap ${ITER_MAX:-none}, dependency=$DEP_TYPE"
EXPORTS="ALL,AUTO_RESTART=1,ITER_STEP=$ITER_STEP,ITER_MAX=$ITER_MAX,INV_DIR=$INV_DIR,BIN=$BIN${SBATCH_EXPORT_EXTRA:+,$SBATCH_EXPORT_EXTRA}"
PREV=""
IDS=()
for i in $(seq 1 "$K"); do
  DEP=()
  [ -n "$PREV" ] && DEP=(--dependency="$DEP_TYPE:$PREV" --kill-on-invalid-dep=yes)
  # --parsable prints "jobid" or "jobid;cluster"
  # shellcheck disable=SC2086
  OUT=$(sbatch --parsable "${DEP[@]}" --export="$EXPORTS" -D "$INV_DIR" $SBATCH_EXTRA "$JOB_SCRIPT") \
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
