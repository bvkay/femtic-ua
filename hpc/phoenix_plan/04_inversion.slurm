#!/bin/bash -l
#SBATCH --job-name=vulcan_inv01
#SBATCH -p icelake
#SBATCH -N 1
#SBATCH --ntasks-per-node=2
#SBATCH --cpus-per-task=36
#SBATCH --mem=254952M
#SBATCH --time=3-00:00:00
#SBATCH --gres=tmpfs:200G
#SBATCH --signal=B:USR1@600
#SBATCH -o slurm-%x-%j.out
# Mail: none unless asked (no #SBATCH mail lines). run.sh passes --mail-type=NONE, or MAIL=<address> from run.env;
# by hand: sbatch --mail-type=END,FAIL --mail-user=<your address> ... (command-line options override #SBATCH)
# =============================================================================
# 04_inversion.slurm -- FEMTIC hybrid MPI/OpenMP inversion on Phoenix (icelake: 72 cores/node, SMT off)
#
# Normally submitted by the kit's run.sh from a run folder $VF/runs/RunNN (VF=/hpcfs/users/$USER/vulcan_femtic):
#     bash $VF/kit/run.sh Run03        (run.env JOB=t4: this script once; JOB=inversion: 05_chain.sh)
# By hand, from the run folder:  cd $VF/runs/Run03 && sbatch --export=ALL,KIT=$VF/kit $VF/kit/04_inversion.slurm
# 05_chain.sh submits K dependent copies (it sets AUTO_RESTART=1, and takes the layout from an explicit SBATCH_EXTRA,
# as run.sh passes it, or from the LAYOUT file that a passing 06 writes; it refuses to fall back on this header's 2 x 36).
# KIT (default $VF/kit) is where femtic_lib.sh is read from: a batch job runs from a spooled copy of this script and
# cannot find its own directory.
#
# ---- partition and memory: RAM is granted PER CPU (scontrol show partition + sbatch --test-only,
#      00_discover.sh on p2-log-2, 2026-09-25; phoenix_plan/discovery/) ----
#   --mem is capped at cpus x MaxMemPerCPU of the partition, so memory is bought with cpus.
#   The default is one whole icelake node:
#     icelake   72 cpus x  3541 MiB =   254,952 MiB -> --mem=254952M (header, accepted)  1.2 SU/cpu-h
#     highmem   72 cpus x 27126 MiB = 1,953,072 MiB -> --mem=1900G   (accepted)          2.5 SU/cpu-h
#   highmem is the ONLY route above ~255 GB per node (7 nodes; QoS highmem: at most 432 cpus = 6 nodes per job):
#     e.g.  sbatch -p highmem --mem=1900G 04_inversion.slurm
#   a100cpu is NOT a bigger-memory option: MaxCPUsPerNode=36 and MaxMemPerCPU=7152, so a job gets at
#   most 36 cpus and 257,472 MiB per node there, at the same 1.2 SU/cpu-h. That is icelake's RAM with
#   half the cores, so it has no advantage for FEMTIC (a 72-cpu a100cpu request was rejected: QOS policy).
#   --mem=250G means 256,000 MiB (Slurm G = 1024 MiB), which is over 254,952 and is rejected on icelake.
#   Limits: QoS normal / account physci set no MaxTRES; the icelake partition QoS allows 1200 cpus per
#   user (16 whole nodes) and 7416 per job. 2 icelake nodes x 8x9 x --mem=254952M was accepted.
#   The 3-day partition MaxTime, not the SU budget, is the constraint (README_phoenix.md section 1).
#   Billing is CPU-only (TRESBillingWeights=CPU=1.20 on icelake, 2.5 on highmem): memory is not charged.
#   $TMPDIR exists only with --gres=tmpfs:<N>G (header 200G; icelake, a100cpu and highmem nodes offer
#   tmpfs:2400G, TmpDisk=0) and holds the sensitivity files. VERIFY whether it is RAM-backed: the
#   'df -hT' line below prints its type (2,400 GB on a 255 GB node suggests it is disk-backed).
#
# ---- layout knobs (sbatch options or --export=ALL,KNOB=value,...) ----
#   --ntasks-per-node  MPI ranks per node (header 2). FEMTIC gives each rank a contiguous block of
#                      frequencies (ObservedData::calcFrequenciesCalculatedByThisPE; the last F%R
#                      ranks get one extra), so ranks <= F (number of frequencies), ideally a divisor.
#                      Every rank factorises the FULL mesh: node memory grows linearly with ranks.
#   --cpus-per-task    cpus per rank (header 36). Production layouts (README section 6), F = 21:
#                        v2 (2.45 M tets): sbatch --ntasks-per-node=3 --cpus-per-task=24 04_inversion.slurm
#                        v3 (3.07 M tets): the header's 2 x 36 on icelake, or
#                                          sbatch -p highmem --mem=1900G --ntasks-per-node=7 --cpus-per-task=10 ...
#                      The old default 8 x 9 is refused for both meshes (below).
#   RANKS=N            run N ranks although more tasks were allocated (cpus bought for RAM), e.g.
#                      sbatch --export=ALL,RANKS=4,THREADS=18 04_inversion.slurm
#   THREADS=T          OpenMP + MKL threads per rank (default --cpus-per-task). Written to NUM_THREADS in
#                      control.dat, because FEMTIC calls omp_set_num_threads(NUM_THREADS) and
#                      mkl_set_num_threads(NUM_THREADS), overriding OMP_NUM_THREADS.
#   Others (defaults below): AUTO_RESTART ITER_STEP ITER_MAX MEM_LIMIT_MB NONPARDISO_MB FWD_MB NIV NEQ
#                      MEM_SAFETY_PCT RANK0_RESERVE_MB FWD_SOLVER WALL_MARGIN_MIN GUARD_MIN_S WATCH_S USE_SRUN SRUN_MPI
#
# ---- memory: the layout rule (README section 6) ----
#   Before femtic starts, the job is REFUSED (exit 1, nothing launched, a layout_refused row) unless
#       ranks per node x (FWD_MB + NONPARDISO_MB) + EXTRA <= MEM_SAFETY_PCT (95) % of --mem
#   FWD_MB = one rank's forward-phase memory (logs/fwd_rank_mb from 06, else 1.25 x the PARDISO line of earlier
#   logs, else 11,000 MiB per 10^6 equations); NONPARDISO_MB = 2 x N_eq x N_iv x 16 B + 2 x N_iv x M x 16 B + Nd_f x M x 8 B, from
#   the logs, mesh.dat, observe.dat and resistivity_block_iter0.dat (femtic_mem_model); EXTRA = RANK0_RESERVE_MB
#   under HOLD_FWD_MEM, plus the sensitivity files when $TMPDIR turns out to be RAM-backed (tmpfs counts against
#   --mem). NONPARDISO_MB and MEM_LIMIT do NOT prevent an out-of-memory kill: FEMTIC's default solver is in-core
#   and MEM_LIMIT only steers FWD_SOLVER 1/2. The number of ranks per node is the only lever.
#   Vulcan (F = 21, N_iv = 480): v2 about 27,645 + 43,109 MiB per rank -> 3 ranks per icelake node;
#   v3 about 32,869 + 53,783 MiB per rank -> 2 ranks. With N_iv = 840 (unmeasured, see README) v3 fits 1 rank.
#
# ---- what the script does ----
#   * archives the previous femtic.cnv / femtic_<rank>.log (FEMTIC truncates both on every start)
#   * AUTO_RESTART=1: femtic_restart_pick chooses the restart iteration N BEFORE ITERATION is
#     rewritten: the highest resistivity_block_iter<N>.dat (+ distortion_iter<N>.dat when
#     DISTORTION != 0) whose line counts match its header and iteration 0's header. If N fails, its
#     files are renamed *.corrupt_<jobid> and N-1 is used. Then ITERATION "N min(N+ITER_STEP, ITER_MAX)".
#   * rewrites NUM_THREADS, SENSE_MAT_DIRECTORY, MEM_LIMIT (auto), FWD_SOLVER (optional)
#   * stops femtic before the wall limit without cutting a model file where it can (femtic_watch):
#     FEMTIC has no stop file and no signal handler (AnalysisControl.cpp), so the stop comes from
#     outside. (1) safe point: right after FEMTIC logs "# Start Inversion.  Iteration : N" (model N
#     is written and closed), if the next model cannot be written before the hard stop; (2) hard stop
#     WALL_MARGIN_MIN before the limit; (3) SIGUSR1 from Slurm 600 s before the limit, last resort:
#     the trap writes logs/WALLTIME_<jobid> and a job_outcomes.tsv row, then stops femtic.
#   * logs/COMPLETED_<jobid> only when femtic exited 0 AND femtic_0.log has FEMTIC's own end line
#     ("# Converged.", "# Reach maximum iteration number." or "# Reach maximum retrial number.").
#     An exit 0 without an end line is a silent death and counts as FAIL.
#   * exit 0 = converged, reached the ITERATION end, or stopped by this script after >= 1 new VALID
#     model; 2 = STALLED (max retrials); 3 = stopped with no new model; other = failure. With
#     05_chain.sh (--dependency=afterok --kill-on-invalid-dep=yes) non-zero cancels the rest of the chain.
#   * one row per job in job_outcomes.tsv; nothing is copied back from $TMPDIR (scratch).
# =============================================================================
set -o pipefail
JOB_T0=$(date +%s)
echo "== $(date) job $SLURM_JOB_ID (${SLURM_JOB_NAME:-?}) partition=${SLURM_JOB_PARTITION:-?} nodes=$SLURM_JOB_NUM_NODES ($SLURM_JOB_NODELIST)  cwd=$PWD"

VF=${VF:-/hpcfs/users/$USER/vulcan_femtic}
BIN=${BIN:-$VF/bin}                     # FEMTIC: $VF/bin is a link to a build (RUNBOOK S1); BIN=<folder> overrides
KIT=${KIT:-${PLAN:-$VF/kit}}            # the uploaded kit: femtic_lib.sh and VERSION are read from here
PLAN=$KIT
INV_DIR=${INV_DIR:-$SLURM_SUBMIT_DIR}
SCRATCH_SHARED=${SCRATCH_SHARED:-$VF/scratch}
AUTO_RESTART=${AUTO_RESTART:-0}         # 1 = continue from the highest VALID resistivity_block_iter<N>.dat (05_chain.sh)
ITER_STEP=${ITER_STEP:-5}               # iterations per job when AUTO_RESTART=1
ITER_MAX=${ITER_MAX:-}                  # optional absolute cap on the iteration number
MEM_LIMIT_MB=${MEM_LIMIT_MB:-auto}      # auto = femtic_mem_limit_auto (below); "keep" = leave control.dat; or MB per rank
NONPARDISO_MB=${NONPARDISO_MB:-auto}    # per-rank sensitivity-step arrays outside PARDISO, MiB; auto = femtic_mem_model (README section 6)
FWD_MB=${FWD_MB:-auto}                  # per-rank forward-phase memory, MiB; auto = femtic_fwd_mb_auto (06's logs/fwd_rank_mb first)
NIV=${NIV:-auto}                        # interpolator right-hand sides per frequency; auto = 4 x MT stations (840 = pessimistic)
NEQ=${NEQ:-auto}                        # equations after degeneration; auto = femtic logs, else mesh.dat nodes + elements
MEM_SAFETY_PCT=${MEM_SAFETY_PCT:-95}    # the layout rule may fill this % of --mem
RANK0_RESERVE_MB=${RANK0_RESERVE_MB:-0} # rank-0 dense matrices; subtracted ONLY if control.dat has HOLD_FWD_MEM
FWD_SOLVER=${FWD_SOLVER:-}              # empty = keep control.dat (FEMTIC default 0 = in-core); 1 = in/out-of-core by MEM_LIMIT
WALL_MARGIN_MIN=${WALL_MARGIN_MIN:-20}  # hard stop this many minutes before the wall limit
GUARD_MIN_S=${GUARD_MIN_S:-600}         # watcher deadline only if at least this many seconds of run time remain
WATCH_S=${WATCH_S:-60}                  # watcher poll interval (s)
USE_SRUN=${USE_SRUN:-0}                 # 1 = launch with srun instead of mpirun (default mpirun: OpenMPI's ess slurm, nothing to set)
SRUN_MPI=${SRUN_MPI:-pmi2}              # Phoenix 'srun --mpi=list': pmi2, none, cray_shasta (NO pmix); MpiDefault=none
export USE_SRUN SRUN_MPI

# shellcheck disable=SC1091
source "$BIN/femtic_env.sh" || { echo "ERROR: $BIN/femtic_env.sh missing -- run 01_build_femtic.sh"; exit 1; }
# shellcheck disable=SC1091
source "$KIT/femtic_lib.sh" || { echo "ERROR: no kit at $KIT (femtic_lib.sh missing): upload export/kit there, or pass KIT=<kit folder>"; exit 1; }
[ "${FEMTIC_LIB_VERSION:-0}" -ge 5 ] || { echo "ERROR: $KIT/femtic_lib.sh is version ${FEMTIC_LIB_VERSION:-unset}; this script needs FEMTIC_LIB_VERSION >= 5 (an older kit: upload the current one, made by scripts/make_phoenix_kit.sh)"; exit 1; }
femtic_kit_banner
cd "$INV_DIR" || exit 1
for f in control.dat mesh.dat observe.dat; do [ -f "$f" ] || { echo "ERROR: $f missing in $INV_DIR"; exit 1; }; done
mkdir -p logs
OUTCOMES="$INV_DIR/job_outcomes.tsv"
STOPFILE="logs/stop_reason_$SLURM_JOB_ID"
rm -f "$STOPFILE"
START_ITER=""
FPID=""
row() {   # row OUTCOME ITER_END EXIT DETAIL
  femtic_outcome_row "$OUTCOMES" "$SLURM_JOB_ID" 04_inversion "$(hostname -s)" "$(date -d "@$JOB_T0" +%FT%T)" "$(date +%FT%T)" "$1" "${START_ITER:-}" "$2" "$3" "$4"
}

# ---------------------------------------------------------------- SIGUSR1 (--signal=B:USR1@600)
on_usr1() {
  echo "[$(date '+%F %T')] SIGUSR1: wall limit in about 600 s -> logs/WALLTIME_$SLURM_JOB_ID; stopping femtic if it still runs"
  echo "usr1 $(date +%s) highest_model=$(femtic_last_iter .)" > "logs/WALLTIME_$SLURM_JOB_ID"
  row walltime_usr1 "$(femtic_last_iter .)" "" "SIGUSR1 received; the final row follows if the script completes"
  if [ -n "$FPID" ] && kill -0 "$FPID" 2>/dev/null; then
    femtic_stop "$FPID" usr1 "$STOPFILE" &    # background: this shell must go back to 'wait' to reap femtic
  elif [ -z "$FPID" ]; then
    exit 3                                    # femtic never started
  fi
}
trap on_usr1 USR1

# ---------------------------------------------------------------- restart markers
if [ "$AUTO_RESTART" = 1 ]; then
  [ -f CONVERGED ] && { echo "CONVERGED marker present -- nothing to do"; exit 0; }
  [ -f STALLED ]   && { echo "STALLED marker present (FEMTIC hit max retrials) -- inspect, then rm STALLED"; exit 2; }
fi

# ---------------------------------------------------------------- archive the previous run's logs
# femtic.cnv and femtic_<rank>.log are opened with truncation (OutputFiles.cpp), so each restart
# would erase the history. Full history: cat logs/run_*/femtic.cnv femtic.cnv | awk '$1!="Iter#"'
if [ -f femtic_0.log ] || [ -f femtic.cnv ]; then
  PREV="logs/run_$(date -r femtic_0.log +%Y%m%d_%H%M%S 2>/dev/null || date +%Y%m%d_%H%M%S)"
  mkdir -p "$PREV" && mv -f femtic_*.log "$PREV"/ 2>/dev/null; cp -f femtic.cnv "$PREV"/ 2>/dev/null
  echo "archived previous logs to $PREV"
fi
cp control.dat "logs/control.dat.before_$SLURM_JOB_ID"

# ---------------------------------------------------------------- ranks / threads
NNODES=${SLURM_JOB_NUM_NODES:-1}
NTASKS=${SLURM_NTASKS:-$(( NNODES * ${SLURM_NTASKS_PER_NODE:-1} ))}
NRANKS=${RANKS:-$NTASKS}
[ "$NRANKS" -le "$NTASKS" ] || { echo "ERROR: RANKS=$NRANKS > $NTASKS allocated tasks"; exit 1; }
[ $(( NRANKS % NNODES )) -eq 0 ] || { echo "ERROR: RANKS=$NRANKS is not a multiple of $NNODES nodes"; exit 1; }
RPN=$(( NRANKS / NNODES ))
NTHR=${THREADS:-${SLURM_CPUS_PER_TASK:-1}}
if [ -n "${SLURM_CPUS_ON_NODE:-}" ] && [ $(( RPN * NTHR )) -gt "$SLURM_CPUS_ON_NODE" ]; then
  echo "WARNING: $RPN ranks x $NTHR threads = $(( RPN * NTHR )) > $SLURM_CPUS_ON_NODE cpus on the node (oversubscribed)"
fi
export OMP_NUM_THREADS=$NTHR MKL_NUM_THREADS=$NTHR MKL_DYNAMIC=FALSE
export OMP_PLACES=cores OMP_PROC_BIND=close
ulimit -s unlimited 2>/dev/null || true
NODE_MEM=${SLURM_MEM_PER_NODE:-}
if [ -z "$NODE_MEM" ] && [ -n "${SLURM_MEM_PER_CPU:-}" ] && [ -n "${SLURM_CPUS_ON_NODE:-}" ]; then NODE_MEM=$(( SLURM_MEM_PER_CPU * SLURM_CPUS_ON_NODE )); fi
echo "ranks=$NRANKS  ranks/node=$RPN  threads/rank=$NTHR  mem/node=${NODE_MEM:-?} MiB  cpus/node=${SLURM_CPUS_ON_NODE:-?}  toolchain=${FEMTIC_TOOLCHAIN:-?}  stack=$(ulimit -s)"
PREVLOG=$(ls -1t logs/run_*/femtic_0.log 2>/dev/null | head -1)
if [ -n "$PREVLOG" ]; then
  NF=$(femtic_nfreq "$PREVLOG")
  echo "frequencies (from $PREVLOG): ${NF:-?}"
  # calcFrequenciesCalculatedByThisPE: quotient=NF/R, the LAST NF%R ranks get one extra, so with R > NF
  # it is ranks 0..R-NF-1 (including rank 0) that get no frequency and sit idle in the forward phase.
  if [ -n "$NF" ] && [ "$NRANKS" -gt "$NF" ]; then echo "WARNING: $NRANKS ranks > $NF frequencies -- ranks 0..$(( NRANKS - NF - 1 )) get no frequency (idle cores)"; fi
fi

# ---------------------------------------------------------------- SENSE_MAT_DIRECTORY
# FEMTIC writes sensMatFreq<f> (and sensMatFreq<f>Mod in the data-space method) there every
# iteration, ~Nd x M x 8 bytes in total. In BOTH inversion methods rank 0 alone then reads the
# files of ALL frequencies (InversionGaussNewtonModelSpace.cpp and InversionGaussNewtonDataSpace.cpp,
# inside "myProcessID == 0"). Node-local $TMPDIR is therefore only correct for a single-node job;
# with -N > 1 the files must be on a shared filesystem.
if [ "$NNODES" -eq 1 ] && [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ]; then
  SENSE_DIR="$TMPDIR/sense"
else
  SENSE_DIR="$SCRATCH_SHARED/sense_$SLURM_JOB_ID"
  echo "multi-node job (or no \$TMPDIR): sensitivity files go to shared $SENSE_DIR"
fi
mkdir -p "$SENSE_DIR" || exit 1
echo "--- df -hT sense dir (the filesystem type tells whether it is RAM-backed):"
df -hT "$SENSE_DIR" 2>/dev/null | tail -1
SENSE_FSTYPE=$(df -PT "$SENSE_DIR" 2>/dev/null | awk 'NR > 1 {t = $2} END {print t}')
# PARDISO out-of-core files (FWD_SOLVER 1/2) are named ooc_temp_3D_PE<rank>* / ooc_temp_inv_3D_PE<rank>*
# relative to the CURRENT directory (pardiso_setenv in PARDISOSolver.cpp), i.e. here on /hpcfs.
# No keyword moves them, so size the job to stay in-core.

# ---------------------------------------------------------------- memory model and layout rule (README section 6)
# Refused here, before any SU are spent: nothing else can stop an in-core FEMTIC from being killed at --mem.
HOLD=0; femtic_ctl_has control.dat HOLD_FWD_MEM && HOLD=1
femtic_mem_model "$INV_DIR" || { echo "ERROR: memory model incomplete (message above)"; row setup_error "" 1 "memory model incomplete"; exit 1; }
EXTRA_MB=0; [ "$HOLD" = 1 ] && EXTRA_MB=$RANK0_RESERVE_MB
if [ "$SENSE_FSTYPE" = tmpfs ] && [ -n "$FM_ND" ] && [ -n "$FM_M" ]; then
  # sensitivity files on a RAM-backed $TMPDIR count against --mem: Nd x M x 8 B (model space), twice that (data space)
  SF=$(awk -v nd="$FM_ND" -v m="$FM_M" -v meth="$(femtic_ctl_get control.dat INV_METHOD | awk '{print $1}')" 'BEGIN {b = nd * m * 8 * (meth == 1 ? 2 : 1); x = b / 1048576; n = int(x); if (n < x) n++; print n}')
  echo "WARNING: $SENSE_DIR is tmpfs (RAM-backed): its sensitivity files, $SF MiB per iteration, count against --mem and are added to the layout rule"
  EXTRA_MB=$(( EXTRA_MB + SF ))
fi
[ -n "$NODE_MEM" ] || { echo "ERROR: --mem per node unknown (SLURM_MEM_PER_NODE unset), so the layout rule cannot be checked: submit with --mem"; row setup_error "" 1 "no --mem"; exit 1; }
if ! LC=$(femtic_layout_check "$RPN" "$FM_FWD_MB" "$FM_NONP_MB" "$NODE_MEM" "$MEM_SAFETY_PCT" "$EXTRA_MB"); then
  echo "$LC"
  echo "ERROR: layout REFUSED: $RPN ranks per node would not fit in --mem=${NODE_MEM}M. Use fewer ranks per node"
  echo "       (sbatch --ntasks-per-node=R --cpus-per-task=72/R, or --export=ALL,RANKS=R,THREADS=T) or -p highmem --mem=1900G."
  echo "       Production layouts (README section 6): v2 3 x 24, v3 2 x 36 on icelake."
  row layout_refused "" 1 "$LC"
  exit 1
fi
echo "$LC"

# ---------------------------------------------------------------- control.dat rewrite
femtic_ctl_set control.dat NUM_THREADS "$NTHR" || exit 1
femtic_ctl_set control.dat SENSE_MAT_DIRECTORY "$SENSE_DIR" || exit 1
[ -n "$FWD_SOLVER" ] && { femtic_ctl_set control.dat FWD_SOLVER "$FWD_SOLVER" || exit 1; }
if [ "$MEM_LIMIT_MB" = auto ] && [ -n "$NODE_MEM" ]; then
  MEM_LIMIT_MB=$(femtic_mem_limit_auto "$NODE_MEM" "$RPN" "$HOLD" "$RANK0_RESERVE_MB" "$FM_NONP_MB")
  echo "MEM_LIMIT auto = (0.85 x $NODE_MEM MB - $([ "$HOLD" = 1 ] && echo "$RANK0_RESERVE_MB rank-0 reserve [HOLD_FWD_MEM]" || echo "0 [no HOLD_FWD_MEM: forward memory is freed before the rank-0 update]")) / $RPN ranks - $FM_NONP_MB non-PARDISO = $MEM_LIMIT_MB MB per rank"
  [ "$MEM_LIMIT_MB" -ge 1024 ] || { echo "ERROR: MEM_LIMIT auto = $MEM_LIMIT_MB MB per rank is below 1 GB -- fewer ranks per node, or -p highmem --mem=1900G"; exit 1; }
fi
if [ "$MEM_LIMIT_MB" != keep ] && [ "$MEM_LIMIT_MB" != auto ]; then
  femtic_ctl_set control.dat MEM_LIMIT "$MEM_LIMIT_MB" || exit 1   # MB per rank: MKL_PARDISO_OOC_MAX_CORE_SIZE (used by FWD_SOLVER 1/2 only)
fi

# ---------------------------------------------------------------- restart point (validated)
DIST=$(femtic_ctl_get control.dat DISTORTION | awk '{print $1}')
if [ "$AUTO_RESTART" = 1 ]; then
  START_ITER=$(femtic_restart_pick . "${DIST:-0}" 1) \
    || { echo "ERROR: no valid restart model in $INV_DIR (messages above)"; row no_valid_model "" 1 "restart check failed"; exit 1; }
  END=$(( START_ITER + ITER_STEP ))
  if [ -n "$ITER_MAX" ] && [ "$END" -gt "$ITER_MAX" ]; then END=$ITER_MAX; fi
  if [ "$START_ITER" -ge "$END" ]; then echo "iteration $START_ITER already >= ITER_MAX=$ITER_MAX -- nothing to do"; exit 0; fi
  femtic_ctl_set control.dat ITERATION "$START_ITER $END" || exit 1
  echo "AUTO_RESTART: iterations $START_ITER -> $END (the first forward re-evaluates model $START_ITER; STEP_LENGTH damping restarts at its initial value)"
else
  START_ITER=$(femtic_ctl_get control.dat ITERATION | awk '{print $1}')
  START_ITER=${START_ITER:-0}
  WHY=$(femtic_iter_ok . "$START_ITER" "${DIST:-0}") \
    || { echo "ERROR: ITERATION starts at $START_ITER but $WHY"; row no_valid_model "" 1 "$WHY"; exit 1; }
fi
echo "--- effective control.dat keys (absent = FEMTIC default: NUM_THREADS 1, FWD_SOLVER 0, MEM_LIMIT 3000, INV_METHOD 0) ---"
for k in NUM_THREADS FWD_SOLVER MEM_LIMIT ITERATION DISTORTION INV_METHOD SENSE_MAT_DIRECTORY DIV_NUM_RHS_FWD DIV_NUM_RHS_INV; do
  printf '  %-20s %s\n' "$k" "$(femtic_ctl_get control.dat $k)"
done
printf '  %-20s %s\n' HOLD_FWD_MEM "$([ "$HOLD" = 1 ] && echo present || echo absent)"
cp control.dat "logs/control.dat.used_$SLURM_JOB_ID"

# ---------------------------------------------------------------- launch + watcher
femtic_launch_cmd "$NRANKS" "$RPN" "$NTHR" "$BIN/femtic"
export FEMTIC_STOPFILE="$STOPFILE" FEMTIC_WATCH_S="$WATCH_S" FEMTIC_SAFEPOINTS="logs/safe_points.tsv" FEMTIC_RSS_FILE="logs/peak_rss_kb_$SLURM_JOB_ID"
DEADLINE=""
TL=$(femtic_time_left_s)
if [ -n "$TL" ] && [ "$TL" -gt $(( WALL_MARGIN_MIN * 60 + GUARD_MIN_S )) ]; then
  DEADLINE=$(( $(date +%s) + TL - WALL_MARGIN_MIN * 60 ))
  echo "stop plan: safe-point stop if the next model cannot be written in time; hard stop at $(date -d "@$DEADLINE" '+%F %T') (${WALL_MARGIN_MIN} min before the limit); SIGUSR1 600 s before the limit as the last resort"
else
  echo "stop plan: no watcher deadline (time left '${TL:-unknown}'); SIGUSR1 600 s before the limit is the only stop"
fi
echo "launch: ${FEMTIC_LAUNCH[*]}"
START=$(date +%s)
"${FEMTIC_LAUNCH[@]}" &
FPID=$!
femtic_watch "$FPID" "$DEADLINE" femtic_0.log &
WPID=$!
femtic_wait_pid "$FPID"; RC=$?
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
ELAPSED=$(( $(date +%s) - START ))
STOP=$(awk 'NR==1 {print $1}' "$STOPFILE" 2>/dev/null)
LAST_AFTER=$(femtic_restart_pick . "${DIST:-0}" 0 2>/dev/null)
HIGHEST=$(femtic_last_iter .)
echo "== femtic exit code $RC after $(( ELAPSED / 3600 )) h $(( ELAPSED % 3600 / 60 )) min; stop=${STOP:-none}; valid models: $START_ITER -> ${LAST_AFTER:-?}  ($(date))"
if [ -n "$HIGHEST" ] && [ "$HIGHEST" != "$LAST_AFTER" ]; then
  echo "WARNING: model file $HIGHEST fails the integrity check (cut by a stop?); the next job restarts from ${LAST_AFTER:-?} and renames it"
  femtic_iter_ok . "$HIGHEST" "${DIST:-0}"
fi

# ---------------------------------------------------------------- outcome -> COMPLETED marker, exit code
END_LINE=$(grep -m1 -E '^# (Converged|Reach maximum iteration number|Reach maximum retrial number)\.' femtic_0.log 2>/dev/null)
PROGRESS=0
[ -n "$LAST_AFTER" ] && [ -n "$START_ITER" ] && [ "$LAST_AFTER" -gt "$START_ITER" ] && PROGRESS=1
if [ "$RC" = 0 ] && [ -n "$END_LINE" ]; then
  printf 'job %s\nfemtic_exit %s\nend_line %s\nmodels %s -> %s\nfinished %s\n' "$SLURM_JOB_ID" "$RC" "$END_LINE" "$START_ITER" "$LAST_AFTER" "$(date +%FT%T)" > "logs/COMPLETED_$SLURM_JOB_ID"
  echo "COMPLETED marker written: logs/COMPLETED_$SLURM_JOB_ID ($END_LINE)"
  case "$END_LINE" in
    "# Converged.")
      echo "OUTCOME: converged -> touch CONVERGED (later chained jobs exit at once)"; touch CONVERGED; OUTCOME=converged; EXIT=0 ;;
    "# Reach maximum retrial number.")
      echo "OUTCOME: FEMTIC reached the maximum number of retrials (objective not decreasing) -> STALLED"; touch STALLED; OUTCOME=stalled; EXIT=2 ;;
    *)
      echo "OUTCOME: reached the ITERATION end ($LAST_AFTER)"; OUTCOME=iteration_end; EXIT=0 ;;
  esac
elif [ -n "$STOP" ]; then
  [ "$END_LINE" = "# Converged." ] && touch CONVERGED
  if [ "$PROGRESS" = 1 ]; then
    case "$STOP" in
      safe_point*) echo "OUTCOME: stopped at a safe point after progress ($STOP; model file closed) -> chain may continue from $LAST_AFTER" ;;
      *)           echo "OUTCOME: stopped by the wall-clock guard after progress ($STOP) -> chain may continue from $LAST_AFTER" ;;
    esac
    OUTCOME="stopped_$STOP"; EXIT=0
  else
    echo "OUTCOME: stopped by the wall-clock guard ($STOP) with NO new valid model -> one iteration takes longer than this job; resize"
    OUTCOME="stopped_no_progress_$STOP"; EXIT=3
  fi
elif [ -n "$END_LINE" ]; then
  echo "OUTCOME: FEMTIC logged '$END_LINE' but exited $RC -- no COMPLETED marker; FAIL (read the MPI messages in this file)"
  [ "$END_LINE" = "# Converged." ] && touch CONVERGED
  OUTCOME=end_line_but_nonzero_exit; EXIT=$RC
elif [ "$RC" = 0 ]; then
  echo "OUTCOME: femtic exited 0 WITHOUT FEMTIC's end line in femtic_0.log -> silent death, FAIL (no COMPLETED marker)"
  OUTCOME=silent_exit0; EXIT=1
else
  echo "OUTCOME: femtic failed (exit $RC) -- see femtic_0.log tail below"; OUTCOME=failed; EXIT=$RC
fi
tail -5 femtic_0.log 2>/dev/null

# ---------------------------------------------------------------- sizing report for the next job
echo; echo "--- sizing report ---"
NF=$(femtic_nfreq femtic_0.log)
echo "frequencies: ${NF:-?}   ranks: $NRANKS   ($( [ -n "$NF" ] && [ $(( NF % NRANKS )) -ne 0 ] && echo "uneven split: $(( NF / NRANKS ))-$(( NF / NRANKS + 1 )) per rank" || echo "even split" ))"
grep -m1 -E '# Total number of model parameter' femtic_0.log 2>/dev/null
grep -m1 -E '# Number of data' femtic_0.log 2>/dev/null
PGB=$(femtic_pardiso_max_gb .)
echo "largest per-rank in-core PARDISO memory: ${PGB:-?} GB   (MEM_LIMIT $(femtic_ctl_get control.dat MEM_LIMIT) MB; FWD_SOLVER $(femtic_ctl_get control.dat FWD_SOLVER))"
PKB=$(femtic_pardiso_kb femtic_*.log)
if [ -n "$PKB" ] && [ -n "$(femtic_ctl_get control.dat MEM_LIMIT)" ] && [ "$(femtic_ctl_get control.dat FWD_SOLVER)" = 1 ]; then
  awk -v k="$PKB" -v m="$(femtic_ctl_get control.dat MEM_LIMIT)" 'BEGIN{ if (k / 1024 > m) print "WARNING: in-core need exceeds MEM_LIMIT -> PARDISO ran OUT-OF-CORE (ooc_temp_* files on /hpcfs, slow)"}'
fi
NIV_MEAS=$(femtic_niv_measured femtic_*.log)
echo "N_iv (right-hand sides per interpolator solve): measured ${NIV_MEAS:-? (no sensitivity step logged)}; the layout rule used $FM_NIV ($FM_NIV_SRC)"
if [ -n "$NIV_MEAS" ] && [ "$NIV_MEAS" != "$FM_NIV" ]; then
  echo "WARNING: measured N_iv $NIV_MEAS differs from the $FM_NIV the layout rule used: pass NIV=$NIV_MEAS to the next job (README section 6)"
fi
echo "predicted per rank (layout rule): $FM_FWD_MB forward + $FM_NONP_MB sensitivity-step = $(( FM_FWD_MB + FM_NONP_MB )) MiB; compare with sacct MaxRSS below (per task) and rcstat"
[ -s "$FEMTIC_RSS_FILE" ] && echo "peak summed RSS of the node's femtic processes (sampled every $WATCH_S s): $(awk '{printf "%.1f GB", $1/1024/1024}' "$FEMTIC_RSS_FILE")  of $(( ${NODE_MEM:-0} / 1024 )) GB requested"
awk -F'\t' -v j="$SLURM_JOB_ID" '$1==j && $4!="" {n++; s+=$4} END {if (n) printf "safe-point interval (one iteration incl. retrials) this job: %.1f h mean over %d\n", s/n/3600, n}' logs/safe_points.tsv 2>/dev/null
echo "sensitivity scratch used: $(du -sh "$SENSE_DIR" 2>/dev/null | cut -f1)   in $SENSE_DIR"
ls -la resistivity_block_iter*.dat distortion_iter*.dat 2>/dev/null | tail -3
sacct -j "$SLURM_JOB_ID" --format=JobID,Elapsed,TotalCPU,MaxRSS,State -P 2>/dev/null | head -5

# Nothing is copied back from $TMPDIR (Slurm removes it). Shared scratch is removed explicitly.
case "$SENSE_DIR" in "$SCRATCH_SHARED"/*) rm -rf "$SENSE_DIR" ;; esac

row "$OUTCOME" "${LAST_AFTER:-}" "$EXIT" "femtic_exit=$RC stop=${STOP:-none} elapsed_s=$ELAPSED ranks=${NRANKS}x${NTHR}"
echo; echo "== efficiency report: rcstat $SLURM_JOB_ID (target > 80 % CPU, memory and walltime; also in slurm-${SLURM_JOB_NAME:-?}-$SLURM_JOB_ID.out)"
rcstat "$SLURM_JOB_ID" 2>/dev/null || echo "(rcstat unavailable on this node -- run 'rcstat $SLURM_JOB_ID' on the login node)"
exit "$EXIT"
