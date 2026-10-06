#!/bin/bash -l
#SBATCH --job-name=vulcan_fwd0
#SBATCH -p icelake
#SBATCH -N 1
#SBATCH --ntasks-per-node=2
#SBATCH --cpus-per-task=36
#SBATCH --mem=254952M
#SBATCH --time=04:00:00
#SBATCH --signal=B:USR1@600
#SBATCH -o slurm-%x-%j.out
#SBATCH --mail-type=END,FAIL
#SBATCH --mail-user=ben.kay@adelaide.edu.au
# =============================================================================
# 06_forward_only.slurm -- TEST T6, the first Phoenix job on the real mesh: one forward solve of the starting
# model (ITERATION 0 0) in the production layout of 04, before any inversion is submitted. It measures:
#   * forward time per frequency and per rank (FEMTIC's "( N sec )" stamps in femtic_<rank>.log)
#   * PARDISO in-core memory per rank ("Total memory consumed by in-core forward solver", femtic_pardiso_kb)
#   * the peak summed RSS of all femtic processes on the node (sampled every WATCH_S s). The per-rank forward
#     memory derived from it goes to logs/fwd_rank_mb, where 04 and later 06 runs read it (FWD_MB=auto).
#   * F, M, N_eq and the station count, from which the report PREDICTS the per-rank sensitivity-step
#     arrays and the rank-0 dense terms of README section 6.
# NOT measured here: with ITERATION 0 0 FEMTIC skips the sensitivity step (doesCalculateSensitivity
# is "iter < ITERATION end") and the model update, so the interpolator, derivative and sensitivity
# arrays and rank 0's dense matrices only appear in the T4 test inversion (04 with ITERATION 0 1).
#
# Layout (README section 6). The header asks for 2 ranks x 36 threads, which fits both candidate meshes:
#   v2 (2.45 M tets): sbatch --ntasks-per-node=3 --cpus-per-task=24 06_forward_only.slurm   (3 divides F = 21)
#   v3 (3.07 M tets): the header's 2 x 36, or highmem:
#                     sbatch -p highmem --mem=1900G --ntasks-per-node=7 --cpus-per-task=10 06_forward_only.slurm
# Before launching, the job REFUSES (exit 1, femtic not started) a layout that breaks the rule
#     ranks per node x (FWD_MB + NONPARDISO_MB) [+ rank-0 reserve under HOLD_FWD_MEM] <= MEM_SAFETY_PCT % of --mem
# (femtic_layout_check; FWD_MB and NONPARDISO_MB come from femtic_mem_model unless set). It is 04's rule, because
# the layout 06 approves is the one 04 runs. LAYOUT_CHECK=forward drops the sensitivity term, for a forward-only
# experiment such as the half-space gate at another layout. 8 x 9 on v3 is refused even then: 8 x 32,869 MiB
# of forward memory alone (WSL peak RSS) is more than the 254,952 MiB icelake gives a job.
#
# Half-space accuracy gate, START_RHO=<ohm-m>: the run uses a uniform model instead of the starting model. Every
# block below 1e6 ohm-m is set to START_RHO and the air block is kept (femtic_block_uniform). The model is written
# to fwd0_<jobid>/ and the inversion directory is not touched. Afterwards $PLAN/tools/halfspace_eval.py compares
# result_*_iter0.csv at every site and band of observe.dat with the analytic half-space, and prints PASS/FAIL per
# limit with the worst site and band. The gate FAILS if |rho_a/rho - 1| > 5 %, |phase - 45 deg| > 1.5 deg or
# max(|Zxx|,|Zyy|)/|Zxy| > 2 % anywhere, or if a (site, band) of observe.dat has no row. This is the WSL gate
# (validation/mesh_2026-09-25/halfspace_accuracy.md), at all 21 observe.dat bands. One job per directory (3 ohm-m: gate3):
#     cd /hpcfs/users/$USER/vulcan_femtic/work/v2/gate100 && sbatch --export=ALL,START_RHO=100 $PLAN/06_forward_only.slurm
# PLAN (default /hpcfs/users/$USER/FEMTIC_2026/hpc/phoenix_plan) locates the evaluator: a batch job runs from a
# spooled copy of this script and cannot find its own directory. PYTHON (default python3) runs it (standard
# library only).
#
# Submit from a work directory work/<mesh>/<name>, never from inputs/ (RUNBOOK section 0). Its input files are NOT
# modified: the run happens in fwd0_<jobid>/ with a copy of control.dat and symlinks to mesh.dat, observe.dat,
# resistivity_block_iter0.dat (and distortion_iter0.dat when DISTORTION != 0):
#     cd /hpcfs/users/$USER/vulcan_femtic/work/<mesh>/<name> && sbatch /path/to/06_forward_only.slurm
# Knobs (sbatch --export=ALL,KNOB=value,...): RANKS THREADS FWD_MB NONPARDISO_MB NIV NEQ MEM_SAFETY_PCT
#   LAYOUT_CHECK START_RHO PLAN PYTHON MEM_LIMIT_MB RANK0_RESERVE_MB FWD_SOLVER WALL_MARGIN_MIN GUARD_MIN_S WATCH_S
#   USE_SRUN SRUN_MPI (defaults below).
# Partitions (verified 2026-09-25): icelake gives a job at most 72 cpus and 254,952 MiB per node. Above that the only
# route is highmem (sbatch -p highmem --mem=1900G ..., 2.5 SU/cpu-h). a100cpu gives a job at most 36 cpus and
# 257,472 MiB, so it has no advantage (04's header has the details). sbatch --test-only accepted the 8 x 9 request
# with --mem=254952M on 2026-09-25; 2 x 36 asks for the same 72 cpus and memory.
# Walltime (header 04:00:00, sized for the header's 2 x 36). A rank solves its ceil(F/R) frequencies one after
# another, so --time >= ceil(F/R) x T_f + about 6 min (setup, and the hard stop WALL_MARGIN_MIN before the limit),
# T_f = the slowest single frequency. On WSL (1 rank x 8 threads; femtic_fwd_times on the 2026-09-25 gate logs)
# T_f was 755 s on v3 and 418 s on v2. With F = 21:
#     v3 2 x 36 (header):   11 x 755 s = 8,305 s = 2.3 h  -> 04:00:00 (1.7 x headroom)
#     v2 3 x 24:             7 x 418 s = 2,926 s          -> --time=02:00:00 is enough
#     v3 highmem 7 x 10:     3 x 755 s = 2,265 s          -> --time=01:30:00
#     v3 1 x 72 (N_iv 840): 21 x 755 s = 15,855 s = 4.4 h -> --time=08:00:00
# A run cut by the limit fails T6 (no end line), so size --time for the layout on the sbatch line.
# Cost at full walltime: SU = nodes x 72 cpus x hours x rate (icelake 1.2, highmem 2.5 SU per cpu-hour; billing is
# CPU-only, TRESBillingWeights=CPU=1.20 / 2.5). Header: 1 x 72 x 4 h x 1.2 = 345.6 SU at most; v2 3 x 24 at 2 h:
# 172.8 SU; highmem 7 x 10 at 1.5 h: 270 SU. Less if Phoenix charges elapsed time (README section 10, item 2).
#
# LAYOUT file: when T6 passes under the full rule (LAYOUT_CHECK=full), the job writes $INV_DIR/LAYOUT with its own
# sbatch layout (-p, -N, --ntasks-per-node, --cpus-per-task, --mem; RANKS/THREADS if set). 05_chain.sh submits 04
# with it, and refuses to start without it or an explicit layout. A later passing 06 run overwrites it.
#
# TEST T6 (fails if): femtic exits non-zero; femtic_0.log lacks FEMTIC's end line; the number of
# per-frequency times summed over all ranks' logs differs from F (every frequency solved exactly
# once); or the sampled peak RSS exceeds 90 % of the job's memory.
# Report: fwd0_<jobid>/fwd0_report.txt, copied to logs/fwd0_report_<jobid>.txt; COMPLETED marker
# logs/COMPLETED_<jobid> only when T6 passes (which includes exit 0 and FEMTIC's end line).
# Exit: 0 = T6 PASS (and, with START_RHO, the gate PASS); 1 = T6 FAIL, a refused layout or a setup error;
#       4 = T6 PASS, but the half-space gate FAILED or could not be evaluated.
#       The exit column of the job's job_outcomes.tsv row is this same code.
# =============================================================================
set -o pipefail
JOB_T0=$(date +%s)
echo "== $(date) job $SLURM_JOB_ID (${SLURM_JOB_NAME:-?}) partition=${SLURM_JOB_PARTITION:-?} node=$(hostname -s)  cwd=$PWD"

BIN=${BIN:-/hpcfs/users/$USER/femtic/bin}
PLAN=${PLAN:-/hpcfs/users/$USER/FEMTIC_2026/hpc/phoenix_plan}   # locates tools/halfspace_eval.py
INV_DIR=${INV_DIR:-$SLURM_SUBMIT_DIR}
NONPARDISO_MB=${NONPARDISO_MB:-auto}    # per-rank sensitivity-step arrays, MiB; auto = femtic_mem_model (README section 6)
FWD_MB=${FWD_MB:-auto}                  # per-rank forward-phase memory, MiB; auto = femtic_fwd_mb_auto
NIV=${NIV:-auto}                        # interpolator right-hand sides per frequency; auto = 4 x MT stations (840 = pessimistic)
NEQ=${NEQ:-auto}                        # equations after degeneration; auto = femtic logs, else mesh.dat nodes + elements
MEM_SAFETY_PCT=${MEM_SAFETY_PCT:-95}    # the layout rule may fill this % of --mem
LAYOUT_CHECK=${LAYOUT_CHECK:-full}      # full = 04's rule (forward + sensitivity step); forward = forward phase only
START_RHO=${START_RHO:-}                # ohm-m: half-space accuracy gate on a uniform model (header)
PYTHON=${PYTHON:-python3}
RANK0_RESERVE_MB=${RANK0_RESERVE_MB:-0}
MEM_LIMIT_MB=${MEM_LIMIT_MB:-auto}
FWD_SOLVER=${FWD_SOLVER:-}
WALL_MARGIN_MIN=${WALL_MARGIN_MIN:-5}   # hard stop this many minutes before the limit (report still written)
GUARD_MIN_S=${GUARD_MIN_S:-300}
WATCH_S=${WATCH_S:-10}                  # RSS sampling interval (s)
USE_SRUN=${USE_SRUN:-0}                 # default mpirun (OpenMPI's ess slurm); 1 = srun
SRUN_MPI=${SRUN_MPI:-pmi2}              # Phoenix 'srun --mpi=list': pmi2, none, cray_shasta (NO pmix)
export USE_SRUN SRUN_MPI

# shellcheck disable=SC1091
source "$BIN/femtic_env.sh" || { echo "ERROR: $BIN/femtic_env.sh missing -- run 01_build_femtic.sh"; exit 1; }
[ "${FEMTIC_LIB_VERSION:-0}" -ge 4 ] || { echo "ERROR: $BIN/femtic_lib.sh is version ${FEMTIC_LIB_VERSION:-unset}; this script needs FEMTIC_LIB_VERSION >= 4 (version 2, installed 2026-09-25, misreads PARDISO memory and has no layout rule; version 3 loses N_iv when DIV_NUM_RHS_FWD > N_iv) -- install -m 644 <phoenix_plan>/femtic_lib.sh $BIN/"; exit 1; }
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
for f in mesh.dat observe.dat; do ln -sf "$INV_DIR/$f" "$W/$f"; done
DIST=$(femtic_ctl_get control.dat DISTORTION | awk '{print $1}')
if [ "${DIST:-0}" != 0 ]; then
  [ -f distortion_iter0.dat ] || { echo "ERROR: DISTORTION=$DIST but distortion_iter0.dat is missing"; exit 1; }
  ln -sf "$INV_DIR/distortion_iter0.dat" "$W/distortion_iter0.dat"
fi
WHY=$(femtic_iter_ok "$INV_DIR" 0 "${DIST:-0}") || { echo "ERROR: starting model: $WHY"; exit 1; }
if [ -n "$START_RHO" ]; then
  # half-space gate: a uniform copy of the starting model in the work directory
  U=$(femtic_block_uniform "$INV_DIR/resistivity_block_iter0.dat" "$W/resistivity_block_iter0.dat" "$START_RHO") \
    || { echo "ERROR: START_RHO=$START_RHO: $U"; exit 1; }
  read -r _ NSET NKEEP <<< "$U"
  # independent re-read of the file just written: every block below 1e6 ohm-m must be START_RHO to 1e-6
  NBAD=$(awk -v r="$START_RHO" 'NR == 1 {ne = $1; next} NR > ne + 1 && NF >= 6 && $2 + 0 < 1e6 {d = $2 / r - 1; if (d > 1e-6 || d < -1e-6) n++} END {print n + 0}' "$W/resistivity_block_iter0.dat")
  WHY=$(femtic_block_check "$W/resistivity_block_iter0.dat" "$INV_DIR/resistivity_block_iter0.dat") || { echo "ERROR: uniform model: $WHY"; exit 1; }
  echo "half-space gate: START_RHO=$START_RHO ohm-m on $NSET blocks, $NKEEP block(s) of >= 1e6 ohm-m (air) kept; blocks off START_RHO after re-reading: $NBAD"
  [ "${NSET:-0}" -gt 0 ] && [ "$NBAD" = 0 ] || { echo "ERROR: the uniform model is not as intended"; exit 1; }
else
  ln -sf "$INV_DIR/resistivity_block_iter0.dat" "$W/resistivity_block_iter0.dat"
fi
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

# ---------------------------------------------------------------- memory model and layout rule (README section 6)
# NONPARDISO_MB does not stop an out-of-memory kill: FEMTIC's default solver is in-core, and MEM_LIMIT only
# steers FWD_SOLVER 1/2. The number of ranks per node is the only lever, so a layout that breaks the rule is
# refused here, before any SU are spent.
femtic_mem_model "$INV_DIR" || { echo "ERROR: memory model incomplete (message above)"; row setup_error 1 "memory model incomplete"; exit 1; }
case "$LAYOUT_CHECK" in
  full)    NP_CHECK=$FM_NONP_MB; EXTRA_MB=0; [ "$HOLD" = 1 ] && EXTRA_MB=$RANK0_RESERVE_MB ;;
  forward) NP_CHECK=0; EXTRA_MB=0 ;;
  *) echo "ERROR: LAYOUT_CHECK=$LAYOUT_CHECK (full or forward)"; exit 1 ;;
esac
[ -n "$NODE_MEM" ] || { echo "ERROR: --mem per node unknown (SLURM_MEM_PER_NODE unset), so the layout rule cannot be checked: submit with --mem"; row setup_error 1 "no --mem"; exit 1; }
if ! LC=$(femtic_layout_check "$RPN" "$FM_FWD_MB" "$NP_CHECK" "$NODE_MEM" "$MEM_SAFETY_PCT" "$EXTRA_MB"); then
  echo "$LC   [LAYOUT_CHECK=$LAYOUT_CHECK]"
  echo "ERROR: layout REFUSED: $RPN ranks per node would not fit in --mem=${NODE_MEM}M. Use fewer ranks per node"
  echo "       (sbatch --ntasks-per-node=R --cpus-per-task=72/R, or --export=ALL,RANKS=R,THREADS=T) or -p highmem --mem=1900G."
  echo "       Production layouts (README section 6): v2 3 x 24, v3 2 x 36 on icelake."
  row layout_refused 1 "$LC"
  exit 1
fi
echo "$LC   [LAYOUT_CHECK=$LAYOUT_CHECK]"

if [ "$MEM_LIMIT_MB" = auto ]; then
  MEM_LIMIT_MB=$(femtic_mem_limit_auto "$NODE_MEM" "$RPN" "$HOLD" "$RANK0_RESERVE_MB" "$FM_NONP_MB")
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
echo "launch: ${FEMTIC_LAUNCH[*]}   (hard stop: $([ -n "$DEADLINE" ] && date -d "@$DEADLINE" '+%F %T' || echo none))"
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
NVTF=$(num 'Number of VTF stations' femtic_0.log)
NEQ_LOG=$(femtic_log_neq femtic_*.log)
PEAK_KB=$(cat "$W/peak_rss_kb" 2>/dev/null)
PKB=$(femtic_pardiso_kb femtic_*.log)
# per-rank forward memory measured by this job: max(peak summed RSS / ranks per node, 1.25 x largest PARDISO line)
FWD_MEAS=$(awk -v p="${PEAK_KB:-0}" -v r="$RPN" -v k="${PKB:-0}" 'BEGIN { a = (r > 0 ? p / r / 1024 : 0); b = k * 1.25 / 1024; x = (a > b ? a : b); n = int(x); if (n < x) n++; print n }')
REPORT="$W/fwd0_report.txt"
{
  echo "FEMTIC forward-only report (T6)   job $SLURM_JOB_ID   $(date '+%F %T')   node $(hostname -s)   partition ${SLURM_JOB_PARTITION:-?}"
  echo "layout: $NRANKS ranks x $NTHR threads, $NNODES node(s), --mem ${NODE_MEM:-?} MiB, toolchain ${FEMTIC_TOOLCHAIN:-?}, FWD_SOLVER '$(femtic_ctl_get control.dat FWD_SOLVER)'"
  echo "model: $([ -n "$START_RHO" ] && echo "uniform START_RHO=$START_RHO ohm-m (half-space gate)" || echo "resistivity_block_iter0.dat of $INV_DIR")"
  echo "femtic exit $RC, wall ${ELAPSED} s, stop ${STOP:-none}, end line: ${END_LINE:-<none>}"
  echo "F (frequencies) = ${NF:-?}   M (model parameters) = ${M:-?}   N_eq (largest, after degeneration) = ${NEQ_LOG:-?}"
  echo "stations: ${NSTA:-?} total, ${NMT:-?} impedance, ${NVTF:-0} VTF"
  echo "before launch, $LC   [LAYOUT_CHECK=$LAYOUT_CHECK]"
  echo
  echo "--- measured: forward time per frequency (pure forward: ITERATION 0 0 has no sensitivity step) and PARDISO per rank"
  printf '%-6s %6s %10s %10s %12s   %s\n' rank nfreq sum_s max_s pardiso_GiB "freq_hz:s ..."
  for L in $(ls femtic_*.log 2>/dev/null | sort -t_ -k2 -n); do
    r=${L#femtic_}; r=${r%.log}
    T=$(femtic_fwd_times "$L")
    PG=$(femtic_pardiso_log_gb "$L")
    echo "$T" | awk -v r="$r" -v pg="$PG" 'NF==2 {n++; s+=$2; if ($2>m) m=$2; l=l " " $1 ":" $2}
         END {printf "%-6s %6d %10d %10d %12s  %s\n", r, n, s, m, pg, l}'
  done
  NROWS=$(for L in femtic_*.log; do femtic_fwd_times "$L"; done 2>/dev/null | grep -c .)
  TFWD=$(for L in femtic_*.log; do femtic_fwd_times "$L" | awk '{s+=$2} END {print s+0}'; done 2>/dev/null | sort -n | tail -1)
  PGB=$(femtic_pardiso_max_gb .)
  echo "frequency rows over all ranks: $NROWS (must equal F = ${NF:-?})"
  echo "forward phase wall time for this layout (slowest rank): ${TFWD:-?} s"
  echo "largest PARDISO in-core need per rank: ${PGB:-?} GiB (${PKB:-?} KB)   (MEM_LIMIT for 04 with this layout: $(femtic_ctl_get control.dat MEM_LIMIT) MB)"
  if [ -n "$PEAK_KB" ]; then
    echo "peak summed RSS of femtic processes on the node: $(awk -v k="$PEAK_KB" 'BEGIN{printf "%.1f", k/1024/1024}') GiB of $(( ${NODE_MEM:-0} / 1024 )) GiB requested (sampled every $WATCH_S s)"
  else
    echo "peak RSS: not sampled (ps unavailable?) -- use sacct MaxRSS / rcstat below"
  fi
  echo "forward memory per rank (FWD_MB for 04): $FWD_MEAS MiB = max(peak RSS / $RPN ranks, 1.25 x PARDISO)"
  echo
  echo "--- predicted (NOT measured) for 04, Z only (README section 6): N_iv = ${FM_NIV:-?} (${FM_NIV_SRC:-?}); Nd_f = 8 x ${NMT:-?}; Nd = Nd_f x F"
  NDF=$(( 8 * ${NMT:-0} ))
  SENS_MB=$(femtic_sens_mem_mb "${NEQ_LOG:-0}" "${FM_NIV:-0}" "${M:-0}" "$NDF" 2>/dev/null)
  NIV_PESS=$(( 4 * ${NMT:-0} + 3 * ${NVTF:-0} ))
  awk -v neq="${NEQ_LOG:-0}" -v niv="${FM_NIV:-0}" -v m="${M:-0}" -v ndf="$NDF" -v f="${NF:-0}" -v used="$FM_NONP_MB" -v smb="${SENS_MB:-0}" 'BEGIN {
      nd = ndf * f; G = 1e9
      a = 2 * neq * niv * 16 / G; b = 2 * niv * m * 16 / G; c = ndf * m * 8 / G
      printf "per rank, sensitivity step: RHS matrix + its solution 2 x N_eq x N_iv x 16 B = %.2f GB; derivatives 2 x N_iv x M x 16 B = %.2f GB; sensitivity block Nd_f x M x 8 B = %.2f GB; sum %.2f GB = %d MiB (NONPARDISO_MB used by this job: %d MiB)\n", a, b, c, a + b + c, smb, used
      if (smb > used) print "WARNING: the non-PARDISO arrays predicted from this run exceed the NONPARDISO_MB this job used -- 04 derives its own (NONPARDISO_MB=auto); check the layout rule line below"
      printf "rank 0, model space (INV_METHOD 0): %.1f GB transient (2 Nd M 8 B), then %.1f GB (Nd M 8 B + M(M+1)/2 8 B); Nd = %d\n", 2 * nd * m * 8 / G, (nd * m * 8 + m * (m + 1) / 2 * 8) / G, nd
      printf "rank 0, data space (INV_METHOD 1): %.1f GB (Nd^2 8 B); sensitivity files per iteration: %.1f GB (model space) / %.1f GB (data space)\n", nd * nd * 8 / G, nd * m * 8 / G, 2 * nd * m * 8 / G
    }'
  if [ -n "$SENS_MB" ] && [ -n "$NODE_MEM" ]; then
    echo "node, sensitivity step with this layout and the forward memory measured here:"
    echo "  $(femtic_layout_check "$RPN" "$FWD_MEAS" "$SENS_MB" "$NODE_MEM" "$MEM_SAFETY_PCT")"
    if [ "${NVTF:-0}" -gt 0 ] && [ "$NIV_PESS" != "${FM_NIV:-0}" ]; then
      SENS_P=$(femtic_sens_mem_mb "${NEQ_LOG:-0}" "$NIV_PESS" "${M:-0}" "$NDF" 2>/dev/null)
      echo "  pessimistic N_iv = 4 x ${NMT:-?} + 3 x $NVTF VTF = $NIV_PESS (if the dummy VTF stations added right-hand sides; T4 settles it):"
      echo "  $(femtic_layout_check "$RPN" "$FWD_MEAS" "${SENS_P:-0}" "$NODE_MEM" "$MEM_SAFETY_PCT")"
    fi
  fi
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
  # the forward memory measured here becomes FWD_MB=auto for 04 and later 06 runs (femtic_fwd_mb_auto)
  echo "$FWD_MEAS job$SLURM_JOB_ID ${RPN}x$NTHR peak_rss_kb=${PEAK_KB:-na} pardiso_kb=${PKB:-na}" > "$INV_DIR/logs/fwd_rank_mb"
  # the layout this job ran, checked against 04's full rule, becomes 05_chain.sh's layout ($INV_DIR/LAYOUT)
  if [ "$LAYOUT_CHECK" = full ]; then
    CPT=${SLURM_CPUS_PER_TASK:-1}
    LSB="${SLURM_JOB_PARTITION:+-p $SLURM_JOB_PARTITION }-N $NNODES --ntasks-per-node=$(( NTASKS / NNODES )) --cpus-per-task=$CPT --mem=${NODE_MEM}M"
    LEX=""
    if [ "$NRANKS" != "$NTASKS" ] || [ "$NTHR" != "$CPT" ]; then LEX="RANKS=$NRANKS,THREADS=$NTHR"; fi
    { echo "# written by 06_forward_only.slurm job $SLURM_JOB_ID on $(date '+%F %T'): T6 PASS, LAYOUT_CHECK=full (the 04 memory rule)."
      echo "# 05_chain.sh submits 04 with these sbatch options (and --export additions); remove the file to choose again."
      echo "sbatch=$LSB"
      echo "export=$LEX"
      echo "ranks_x_threads=${NRANKS}x$NTHR"
      echo "rule=$LC"; } > "$INV_DIR/LAYOUT"
    echo "LAYOUT for 05_chain.sh written to $INV_DIR/LAYOUT: $LSB${LEX:+  (--export $LEX)}" >> "$REPORT"
  fi
fi

# ---------------------------------------------------------------- half-space gate (START_RHO)
GATE=""
if [ -n "$START_RHO" ]; then
  EV="$PLAN/tools/halfspace_eval.py"
  # site names (G7, Vul24-19) come from station_map.csv, which is copied with the mesh (README section 3, step 7)
  SMAP=(); SNOTE=""
  if [ -f "$INV_DIR/station_map.csv" ]; then SMAP=(--station-map "$INV_DIR/station_map.csv")
  else SNOTE="NOTE: no station_map.csv in $INV_DIR, so sites are named by FEMTIC station id only; copy mesh/vulcan_v{2,3}/inversion/station_map.csv there"; fi
  if [ ! -f "$EV" ]; then
    GATE=NOT_EVALUATED; echo "$EV not found (set PLAN=<phoenix_plan directory>)" > "$W/halfspace_eval.txt"
  elif ! command -v "$PYTHON" >/dev/null 2>&1; then
    GATE=NOT_EVALUATED; echo "$PYTHON not found (set PYTHON=...)" > "$W/halfspace_eval.txt"
  else
    "$PYTHON" "$EV" "$START_RHO" "$W" "${SMAP[@]}" > "$W/halfspace_eval.txt" 2>&1; ERC=$?
    RES=$(awk '$1 == "RESULT:" {r = $2} END {print r}' "$W/halfspace_eval.txt")
    case "$ERC:$RES" in
      0:PASS) GATE=PASS ;;
      1:FAIL) GATE=FAIL ;;
      *) GATE=NOT_EVALUATED; echo "evaluator exit $ERC, RESULT '${RES}'" >> "$W/halfspace_eval.txt" ;;
    esac
  fi
  { echo; echo "--- half-space accuracy gate: START_RHO=$START_RHO ohm-m ($EV${SMAP[1]:+ --station-map ${SMAP[1]}})"
    [ -n "$SNOTE" ] && echo "$SNOTE"
    cat "$W/halfspace_eval.txt"
    echo "GATE (half-space, START_RHO=$START_RHO): $GATE"; } >> "$REPORT"
  cp "$W/halfspace_eval.txt" "$INV_DIR/logs/halfspace_eval_$SLURM_JOB_ID.txt"
fi
cp "$REPORT" "$INV_DIR/logs/fwd0_report_$SLURM_JOB_ID.txt"
echo; cat "$REPORT"
# exit code (header): 1 = T6 FAIL; 4 = T6 PASS but the gate did not PASS; 0 otherwise. The row gets the same code.
EXIT=0
[ "$T6" = PASS ] || EXIT=1
if [ "$EXIT" = 0 ] && [ -n "$START_RHO" ] && [ "$GATE" != PASS ]; then EXIT=4; fi
row "t6_$T6${GATE:+_gate_$GATE}" "$EXIT" "femtic_exit=$RC stop=${STOP:-none} wall_s=$ELAPSED${WHYF:+ fail:$WHYF}${START_RHO:+ start_rho=$START_RHO gate=$GATE}"
echo; echo "== efficiency report: rcstat $SLURM_JOB_ID"
rcstat "$SLURM_JOB_ID" 2>/dev/null || echo "(rcstat unavailable on this node -- run 'rcstat $SLURM_JOB_ID' on the login node)"
echo "== exit $EXIT"
exit "$EXIT"
