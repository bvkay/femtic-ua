#!/bin/bash -l
#SBATCH --job-name=vulcan_fwd0
#SBATCH -p icelake
#SBATCH -N 1
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=9
#SBATCH --mem=254952M
#SBATCH --time=02:00:00
#SBATCH --signal=B:USR1@600
#SBATCH -o slurm-%x-%j.out
#SBATCH --mail-type=END,FAIL
#SBATCH --mail-user=ben.kay@adelaide.edu.au
# =============================================================================
# 06_forward_only.slurm -- TEST T6, the first Phoenix job after the build and the mesh: one forward
# solve of the starting model (ITERATION 0 0) with the production layout of 04 (1 icelake node,
# 8 ranks x 9 threads), 2 h, before any inversion is submitted. It measures:
#   * forward time per frequency and per rank (FEMTIC's "( N sec )" stamps in femtic_<rank>.log)
#   * PARDISO in-core memory per rank ("Total memory consumed by in-core forward solver")
#   * the peak summed RSS of all femtic processes on the node (sampled every WATCH_S s)
#   * F, M, N_eq and the station count, from which the report PREDICTS the per-rank sensitivity-step
#     arrays and the rank-0 dense terms of README section 5.
# NOT measured here: with ITERATION 0 0 FEMTIC skips the sensitivity step (doesCalculateSensitivity
# is "iter < ITERATION end") and the model update, so the interpolator, derivative and sensitivity
# arrays and rank 0's dense matrices only appear in the T4 test inversion (04 with ITERATION 0 1).
#
# Submit from the inversion directory. Its files are NOT modified: the run happens in
# fwd0_<jobid>/ with a copy of control.dat and symlinks to mesh.dat, observe.dat,
# resistivity_block_iter0.dat (and distortion_iter0.dat when DISTORTION != 0):
#     cd /hpcfs/users/$USER/vulcan_femtic/inversion/inv01 && sbatch /path/to/06_forward_only.slurm
# Other layouts: the same options as 04, e.g. sbatch --ntasks-per-node=12 --cpus-per-task=6 06_forward_only.slurm
# Cost at full walltime: 72 cpus x 2 h x 1.2 SU = 172.8 SU (charged on elapsed time if Phoenix bills that way).
#
# TEST T6 (fails if): femtic exits non-zero; femtic_0.log lacks FEMTIC's end line; the number of
# per-frequency times summed over all ranks' logs differs from F (every frequency solved exactly
# once); or the sampled peak RSS exceeds 90 % of the job's memory.
# Report: fwd0_<jobid>/fwd0_report.txt, copied to logs/fwd0_report_<jobid>.txt; COMPLETED marker
# logs/COMPLETED_<jobid> only when T6 passes (which includes exit 0 and FEMTIC's end line).
# =============================================================================
set -o pipefail
JOB_T0=$(date +%s)
echo "== $(date) job $SLURM_JOB_ID (${SLURM_JOB_NAME:-?}) partition=${SLURM_JOB_PARTITION:-?} node=$(hostname -s)  cwd=$PWD"

BIN=${BIN:-/hpcfs/users/$USER/femtic/bin}
INV_DIR=${INV_DIR:-$SLURM_SUBMIT_DIR}
NONPARDISO_MB=${NONPARDISO_MB:-10240}
RANK0_RESERVE_MB=${RANK0_RESERVE_MB:-0}
MEM_LIMIT_MB=${MEM_LIMIT_MB:-auto}
FWD_SOLVER=${FWD_SOLVER:-}
WALL_MARGIN_MIN=${WALL_MARGIN_MIN:-5}   # hard stop this many minutes before the limit (report still written)
GUARD_MIN_S=${GUARD_MIN_S:-300}
WATCH_S=${WATCH_S:-10}                  # RSS sampling interval (s)
USE_SRUN=${USE_SRUN:-0}
SRUN_MPI=${SRUN_MPI:-pmix}              # VERIFY with 'srun --mpi=list'
export USE_SRUN SRUN_MPI

# shellcheck disable=SC1091
source "$BIN/femtic_env.sh" || { echo "ERROR: $BIN/femtic_env.sh missing -- run 01_build_femtic.sh"; exit 1; }
[ "${FEMTIC_LIB_VERSION:-0}" -ge 2 ] || { echo "ERROR: $BIN/femtic_lib.sh predates this script -- install -m 644 <phoenix_plan>/femtic_lib.sh $BIN/"; exit 1; }
cd "$INV_DIR" || exit 1
for f in control.dat mesh.dat observe.dat resistivity_block_iter0.dat; do [ -f "$f" ] || { echo "ERROR: $f missing in $INV_DIR"; exit 1; }; done
mkdir -p logs
OUTCOMES="$INV_DIR/job_outcomes.tsv"
W="$INV_DIR/fwd0_$SLURM_JOB_ID"
mkdir -p "$W" || exit 1
STOPFILE="$W/stop_reason"
FPID=""
row() {   # row OUTCOME EXIT DETAIL
  femtic_outcome_row "$OUTCOMES" "$SLURM_JOB_ID" 06_forward_only "$(hostname -s)" "$(date -d "@$JOB_T0" +%FT%T)" "$(date +%FT%T)" "$1" 0 0 "$2" "$3"
}
on_usr1() {
  echo "[$(date '+%F %T')] SIGUSR1: wall limit in about 600 s -> logs/WALLTIME_$SLURM_JOB_ID; stopping femtic, the report still gets written"
  echo "usr1 $(date +%s)" > "$INV_DIR/logs/WALLTIME_$SLURM_JOB_ID"
  row walltime_usr1 "" "SIGUSR1 received; the final row follows if the script completes"
  if [ -n "$FPID" ] && kill -0 "$FPID" 2>/dev/null; then femtic_stop "$FPID" usr1 "$STOPFILE" &
  elif [ -z "$FPID" ]; then exit 3; fi
}
trap on_usr1 USR1

# ---------------------------------------------------------------- work directory
# The inputs are symlinked, not copied: FEMTIC only reads them, and it writes resistivity_block_iter<n>
# only for n > the ITERATION start (AnalysisControl::run), so with "0 0" nothing is written through a link.
cp control.dat "$W/control.dat" || exit 1
for f in mesh.dat observe.dat resistivity_block_iter0.dat; do ln -sf "$INV_DIR/$f" "$W/$f"; done
DIST=$(femtic_ctl_get control.dat DISTORTION | awk '{print $1}')
if [ "${DIST:-0}" != 0 ]; then
  [ -f distortion_iter0.dat ] || { echo "ERROR: DISTORTION=$DIST but distortion_iter0.dat is missing"; exit 1; }
  ln -sf "$INV_DIR/distortion_iter0.dat" "$W/distortion_iter0.dat"
fi
WHY=$(femtic_iter_ok "$INV_DIR" 0 "${DIST:-0}") || { echo "ERROR: starting model: $WHY"; exit 1; }
cd "$W" || exit 1

# ---------------------------------------------------------------- layout (same knobs as 04)
NNODES=${SLURM_JOB_NUM_NODES:-1}
NTASKS=${SLURM_NTASKS:-$(( NNODES * ${SLURM_NTASKS_PER_NODE:-1} ))}
NRANKS=${RANKS:-$NTASKS}
[ "$NRANKS" -le "$NTASKS" ] && [ $(( NRANKS % NNODES )) -eq 0 ] || { echo "ERROR: RANKS=$NRANKS does not fit $NTASKS tasks on $NNODES node(s)"; exit 1; }
RPN=$(( NRANKS / NNODES ))
NTHR=${THREADS:-${SLURM_CPUS_PER_TASK:-1}}
export OMP_NUM_THREADS=$NTHR MKL_NUM_THREADS=$NTHR MKL_DYNAMIC=FALSE OMP_PLACES=cores OMP_PROC_BIND=close
ulimit -s unlimited 2>/dev/null || true
NODE_MEM=${SLURM_MEM_PER_NODE:-}
if [ -z "$NODE_MEM" ] && [ -n "${SLURM_MEM_PER_CPU:-}" ] && [ -n "${SLURM_CPUS_ON_NODE:-}" ]; then NODE_MEM=$(( SLURM_MEM_PER_CPU * SLURM_CPUS_ON_NODE )); fi

femtic_ctl_set control.dat ITERATION "0 0" || exit 1
femtic_ctl_set control.dat NUM_THREADS "$NTHR" || exit 1
[ -n "$FWD_SOLVER" ] && { femtic_ctl_set control.dat FWD_SOLVER "$FWD_SOLVER" || exit 1; }
HOLD=0; femtic_ctl_has control.dat HOLD_FWD_MEM && HOLD=1
if [ "$MEM_LIMIT_MB" = auto ] && [ -n "$NODE_MEM" ]; then
  MEM_LIMIT_MB=$(femtic_mem_limit_auto "$NODE_MEM" "$RPN" "$HOLD" "$RANK0_RESERVE_MB" "$NONPARDISO_MB")
fi
if [ "$MEM_LIMIT_MB" != keep ] && [ "$MEM_LIMIT_MB" != auto ] && [ "$MEM_LIMIT_MB" -ge 1024 ]; then
  femtic_ctl_set control.dat MEM_LIMIT "$MEM_LIMIT_MB" || exit 1   # same value 04 would use
fi
echo "layout: $NRANKS ranks ($RPN per node) x $NTHR threads; mem/node ${NODE_MEM:-?} MiB; ITERATION '$(femtic_ctl_get control.dat ITERATION)'; FWD_SOLVER '$(femtic_ctl_get control.dat FWD_SOLVER)'; MEM_LIMIT '$(femtic_ctl_get control.dat MEM_LIMIT)'"

# ---------------------------------------------------------------- launch + watcher (deadline + RSS sampling)
femtic_launch_cmd "$NRANKS" "$RPN" "$NTHR" "$BIN/femtic"
export FEMTIC_STOPFILE="$STOPFILE" FEMTIC_WATCH_S="$WATCH_S" FEMTIC_RSS_FILE="$W/peak_rss_kb"
DEADLINE=""
TL=$(femtic_time_left_s)
if [ -n "$TL" ] && [ "$TL" -gt $(( WALL_MARGIN_MIN * 60 + GUARD_MIN_S )) ]; then DEADLINE=$(( $(date +%s) + TL - WALL_MARGIN_MIN * 60 )); fi
echo "launch: ${FEMTIC_LAUNCH[*]}   (hard stop: ${DEADLINE:+$(date -d "@$DEADLINE" '+%F %T')}${DEADLINE:-none})"
START=$(date +%s)
"${FEMTIC_LAUNCH[@]}" > "$W/stdout.txt" 2>&1 &
FPID=$!
femtic_watch "$FPID" "$DEADLINE" femtic_0.log &
WPID=$!
femtic_wait_pid "$FPID"; RC=$?
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
ELAPSED=$(( $(date +%s) - START ))
STOP=$(awk 'NR==1 {print $1}' "$STOPFILE" 2>/dev/null)
END_LINE=$(grep -m1 -E '^# (Converged|Reach maximum iteration number|Reach maximum retrial number)\.' femtic_0.log 2>/dev/null)
echo "== femtic exit $RC after ${ELAPSED} s; stop=${STOP:-none}; end line: ${END_LINE:-<none>}"
tail -3 femtic_0.log 2>/dev/null

# ---------------------------------------------------------------- report
num() { grep -m1 "$1" "$2" 2>/dev/null | grep -oE '[0-9]+' | head -1; }
NF=$(femtic_nfreq femtic_0.log)
M=$(num 'Total number of model parameter' femtic_0.log)
NSTA=$(num 'Total number of stations' femtic_0.log)
NMT=$(num 'Number of impedance tensor stations' femtic_0.log)
NEQ=$(cat femtic_*.log 2>/dev/null | sed -nE 's/.*Number of equation after degeneration = ([0-9]+).*/\1/p' | sort -n | tail -1)
PEAK_KB=$(cat "$W/peak_rss_kb" 2>/dev/null)
REPORT="$W/fwd0_report.txt"
{
  echo "FEMTIC forward-only report (T6)   job $SLURM_JOB_ID   $(date '+%F %T')   node $(hostname -s)   partition ${SLURM_JOB_PARTITION:-?}"
  echo "layout: $NRANKS ranks x $NTHR threads, $NNODES node(s), --mem ${NODE_MEM:-?} MiB, toolchain ${FEMTIC_TOOLCHAIN:-?}, FWD_SOLVER '$(femtic_ctl_get control.dat FWD_SOLVER)'"
  echo "femtic exit $RC, wall ${ELAPSED} s, stop ${STOP:-none}, end line: ${END_LINE:-<none>}"
  echo "F (frequencies) = ${NF:-?}   M (model parameters) = ${M:-?}   N_eq (largest, after degeneration) = ${NEQ:-?}"
  echo "stations: ${NSTA:-?} total, ${NMT:-?} impedance"
  [ -n "$NSTA" ] && [ -n "$NMT" ] && [ "$NSTA" != "$NMT" ] && echo "NOTE: non-impedance stations present: N_iv and Nd below count impedance stations only (add 3 per VTF station to N_iv; README section 5)"
  echo
  echo "--- measured: forward time per frequency (pure forward: ITERATION 0 0 has no sensitivity step) and PARDISO per rank"
  printf '%-6s %6s %10s %10s %12s   %s\n' rank nfreq sum_s max_s pardiso_GB "freq_hz:s ..."
  for L in $(ls femtic_*.log 2>/dev/null | sort -t_ -k2 -n); do
    r=${L#femtic_}; r=${r%.log}
    T=$(femtic_fwd_times "$L")
    PG=$(awk -F: '/Total memory consumed by in-core forward solver/ {gsub(/[^0-9]/,"",$2); if ($2+0>m) m=$2+0} END {printf "%.2f", m/1024/1024}' "$L")
    echo "$T" | awk -v r="$r" -v pg="$PG" 'NF==2 {n++; s+=$2; if ($2>m) m=$2; l=l " " $1 ":" $2}
         END {printf "%-6s %6d %10d %10d %12s  %s\n", r, n, s, m, pg, l}'
  done
  NROWS=$(for L in femtic_*.log; do femtic_fwd_times "$L"; done 2>/dev/null | grep -c .)
  TFWD=$(for L in femtic_*.log; do femtic_fwd_times "$L" | awk '{s+=$2} END {print s+0}'; done 2>/dev/null | sort -n | tail -1)
  PGB=$(femtic_pardiso_max_gb .)
  echo "frequency rows over all ranks: $NROWS (must equal F = ${NF:-?})"
  echo "forward phase wall time for this layout (slowest rank): ${TFWD:-?} s"
  echo "largest PARDISO in-core need per rank: ${PGB:-?} GB   (MEM_LIMIT for 04 with this layout: $(femtic_ctl_get control.dat MEM_LIMIT) MB)"
  if [ -n "$PEAK_KB" ]; then
    echo "peak summed RSS of femtic processes on the node: $(awk -v k="$PEAK_KB" 'BEGIN{printf "%.1f", k/1024/1024}') GB of $(( ${NODE_MEM:-0} / 1024 )) GB requested (sampled every $WATCH_S s)"
  else
    echo "peak RSS: not sampled (ps unavailable?) -- use sacct MaxRSS / rcstat below"
  fi
  echo
  echo "--- predicted (NOT measured) for 04, Z only: N_iv = 4 x ${NMT:-?} impedance stations; Nd_f = 8 x ${NMT:-?}; Nd = Nd_f x F"
  awk -v neq="${NEQ:-0}" -v nmt="${NMT:-0}" -v m="${M:-0}" -v f="${NF:-0}" -v pg="${PGB:-0}" -v rpn="$RPN" -v node="${NODE_MEM:-0}" -v nonp="$NONPARDISO_MB" 'BEGIN {
      niv = 4 * nmt; ndf = 8 * nmt; nd = ndf * f; G = 1e9
      a = neq * niv * 16 / G; b = 2 * niv * m * 16 / G; c = ndf * m * 8 / G
      printf "per rank, sensitivity step: interpolator N_eq x N_iv x 16 B = %.2f GB; derivatives 2 x N_iv x M x 16 B = %.2f GB; sensitivity block Nd_f x M x 8 B = %.2f GB; sum %.2f GB (NONPARDISO_MB allowance %.1f GB)\n", a, b, c, a + b + c, nonp * 1048576 / G
      if (a + b + c > nonp * 1048576 / G) print "WARNING: predicted non-PARDISO arrays exceed NONPARDISO_MB -- raise NONPARDISO_MB for 04"
      fw = rpn * (pg * 1.073741824 + a + b + c)
      printf "node, forward + sensitivity phase: %d ranks x (PARDISO %.1f GB + %.1f GB) = %.1f GB of %.1f GB requested\n", rpn, pg * 1.073741824, a + b + c, fw, node * 1048576 / G
      printf "rank 0, model space (INV_METHOD 0): %.1f GB transient (2 Nd M 8 B), then %.1f GB (Nd M 8 B + M(M+1)/2 8 B); Nd = %d\n", 2 * nd * m * 8 / G, (nd * m * 8 + m * (m + 1) / 2 * 8) / G, nd
      printf "rank 0, data space (INV_METHOD 1): %.1f GB (Nd^2 8 B); sensitivity files per iteration: %.1f GB (model space) / %.1f GB (data space)\n", nd * nd * 8 / G, nd * m * 8 / G, 2 * nd * m * 8 / G
    }'
  echo
  echo "--- iteration-0 misfit (femtic.cnv: Iter# Retrial# Alpha Damp Roughness Misfit RMS ObjFunc)"
  echo "$(femtic_cnv_row 0 femtic.cnv)"
  echo
  echo "--- next: T4 = 04 with ITERATION 0 1 measures the sensitivity step and the rank-0 update; then"
  echo "    ITER_STEP ~ (72 h - 0.5 h - T_forward) / T_iteration   (T_forward here: ${TFWD:-?} s)"
} > "$REPORT" 2>&1

# ---------------------------------------------------------------- T6 verdict, COMPLETED marker
T6=PASS; WHYF=""
[ "$RC" = 0 ] || { T6=FAIL; WHYF="$WHYF femtic_exit=$RC"; }
[ -n "$END_LINE" ] || { T6=FAIL; WHYF="$WHYF no_end_line"; }
[ -n "$NF" ] && [ "$NROWS" = "$NF" ] || { T6=FAIL; WHYF="$WHYF freq_rows=$NROWS/F=${NF:-?}"; }
if [ -n "$PEAK_KB" ] && [ -n "$NODE_MEM" ] && [ $(( PEAK_KB / 1024 )) -gt $(( NODE_MEM * 9 / 10 )) ]; then T6=FAIL; WHYF="$WHYF peak_rss_over_90pct"; fi
echo "T6 (forward-only): $T6${WHYF:+  --$WHYF}" >> "$REPORT"
if [ "$T6" = PASS ]; then   # T6 PASS implies femtic exit 0 and FEMTIC's end line
  printf 'job %s\nfemtic_exit %s\nend_line %s\nT6 %s\nfinished %s\n' "$SLURM_JOB_ID" "$RC" "$END_LINE" "$T6" "$(date +%FT%T)" > "$INV_DIR/logs/COMPLETED_$SLURM_JOB_ID"
fi
cp "$REPORT" "$INV_DIR/logs/fwd0_report_$SLURM_JOB_ID.txt"
echo; cat "$REPORT"
row "t6_$T6" "$([ "$T6" = PASS ] && echo 0 || echo 1)" "femtic_exit=$RC stop=${STOP:-none} wall_s=$ELAPSED${WHYF:+ fail:$WHYF}"
echo; echo "== efficiency report: rcstat $SLURM_JOB_ID"
rcstat "$SLURM_JOB_ID" 2>/dev/null || echo "(rcstat unavailable on this node -- run 'rcstat $SLURM_JOB_ID' on the login node)"
[ "$T6" = PASS ] || exit 1
exit 0
