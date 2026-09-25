#!/usr/bin/env bash
# acc_batch.sh -- one frequency batch (2 of the 8 test bands) of the half-space forward test, run under the
# PC resource policy of halfspace_accuracy.md. Run inside WSL.
#
#   acc_batch.sh N RHO K NP NT        e.g.  acc_batch.sh 1 3 1 2 4    (mesh v1, 3 ohm-m, batch 1, 2 ranks x 4 threads)
#   FREQS=100 acc_batch.sh 2 3 s100 1 8   supplementary band(s) outside the 8-band criterion runs, in run dir bs100
#
# Policy enforced here (the run is refused or stopped otherwise):
#   - NP x NT <= 8 threads in total; NUM_THREADS in control.dat = OMP_NUM_THREADS = MKL_NUM_THREADS = NT
#   - no other heavy job (femtic, tetgen, makeTetraMesh, makeMtr, TetGen2Femtic) may be running
#   - "free -g" must show >= 50 GB available at launch
#   - started with "nice -n 10" (inherited by mpirun, prterun and every femtic rank; the sampler records NI)
#   - a ps sampler writes every 5 s (policy: at least every 10 s) to rss_samples.log and KILLS the job if the
#     summed RSS of femtic + prterun + mpirun exceeds LIMIT_KB (default 40 000 000 kB = 40 GB), or if
#     MemAvailable falls below 10 GB
# Inputs: mesh /home/tara/femtic_wsl/mesh_runs/vulcan_vN/{mesh.dat,resistivity_block_iter0.dat};
#         prep  /mnt/d/BEN/FEMTIC_2026/mesh/vulcan_vN/inversion/{observe.dat,control.dat}
# Output: /home/tara/femtic_wsl/mesh_runs/acc_vN_RHO/bK/  (wiped first) with FEMTIC.DONE "rc=<exit status>"
#         (rc=137/143 if killed), watchdog.log if the watchdog fired.
set -uo pipefail
N=$1; RHO=$2; K=$3; NP=$4; NT=$5
LIMIT_KB=${LIMIT_KB:-40000000}
MIN_AVAIL_GB=50
MIN_MEMAVAIL_KB=10000000
HERE=/mnt/d/BEN/FEMTIC_2026/validation/mesh_2026-09-25/halfspace_accuracy
PREP=/mnt/d/BEN/FEMTIC_2026/mesh/vulcan_v$N
MESH=/home/tara/femtic_wsl/mesh_runs/vulcan_v$N
RUN=/home/tara/femtic_wsl/mesh_runs/acc_v${N}_${RHO}/b$K

# a marker file SKIP_acc_vN_RHO in mesh_runs/ cancels every batch of that run (used to drop a queued run)
if [ -e "/home/tara/femtic_wsl/mesh_runs/SKIP_acc_v${N}_${RHO}" ]; then echo "SKIPPED: marker SKIP_acc_v${N}_${RHO} present"; exit 5; fi
if [ $((NP * NT)) -gt 8 ]; then echo "ABORT: $NP ranks x $NT threads > 8"; exit 2; fi
# heavy = the real femtic binary, or a solver/mesh tool name holding > 100 MB (another agent's test scripts
# named "femtic" are ~3 MB bash wrappers and must not block, nor be counted as ranks; see halfspace_accuracy.md)
HEAVY=$(ps -eo rss=,comm=,args= | awk '($2 ~ /^(femtic|tetgen|makeTetraMesh|makeMtr|TetGen2Femtic)$/ && $1 > 100000) || $3 ~ /^\/home\/tara\/femtic_wsl\/bin\/femtic/' | wc -l)
if [ "$HEAVY" -gt 0 ]; then
  echo "ABORT: another heavy job is running:"; ps -eo pid,ni,rss,etime,args | grep -E 'femtic|tetgen|makeTetraMesh|makeMtr|TetGen2Femtic' | grep -v grep
  exit 3
fi
echo "== free -g before launch ($(date -Is))"; free -g
avail=$(free -g | awk '/^Mem:/{print $7}')
if [ "$avail" -lt "$MIN_AVAIL_GB" ]; then echo "ABORT: only $avail GB available (< $MIN_AVAIL_GB GB)"; exit 4; fi

rm -rf "$RUN"; mkdir -p "$RUN"
free -g > "$RUN/free_at_launch.txt"
source /home/tara/miniforge3/etc/profile.d/conda.sh
conda activate femticpy
SEL="--batch $K"; [ -n "${FREQS:-}" ] && SEL="--freqs $FREQS"   # FREQS=100,31.514: supplementary bands, run dir bK
if ! nice -n 10 python "$HERE/make_acc_inputs.py" "$PREP" "$MESH" "$RUN" "$RHO" $SEL --threads "$NT" > "$RUN/make_inputs.log" 2>&1; then
  cat "$RUN/make_inputs.log"; echo "rc=90" > "$RUN/FEMTIC.DONE"; exit 1
fi
cat "$RUN/make_inputs.log"
conda deactivate
conda activate femtic-build
export OMP_NUM_THREADS=$NT MKL_NUM_THREADS=$NT
cd "$RUN" || exit 1
echo "np=$NP omp=$NT limit_kB=$LIMIT_KB host=$(hostname) start=$(date -Is)" > run_env.txt

# sampler + watchdog. Columns: epoch n_femtic rss_femtic_kB rss_job_kB MemAvailable_kB swap_used_kB ni_min ni_max nlwp_femtic
(
  while [ ! -e FEMTIC.DONE ]; do
    now=$(date +%s)
    # n, NI and threads over the real femtic ranks only; RSS over every process named femtic (conservative)
    read -r n rf nimin nimax nl < <(ps -C femtic -o rss=,ni=,nlwp=,args= | awk '{s+=$1} $4 ~ /^\/home\/tara\/femtic_wsl\/bin\/femtic/ {n++; if(mn==""||$2<mn)mn=$2; if($2>mx)mx=$2; l+=$3} END{print n+0, s+0, (mn==""?"NA":mn), (mx==""?"NA":mx), l+0}')
    rj=$(ps -C femtic,prterun,mpirun -o rss= | awk '{s+=$1} END{print s+0}')
    av=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    sw=$(awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{print t-f}' /proc/meminfo)
    echo "$now $n $rf $rj $av $sw $nimin $nimax $nl" >> rss_samples.log
    if [ "$n" -gt "$NP" ]; then { echo "== $now: $n processes named femtic (> $NP ranks)"; ps -C femtic -o pid=,ppid=,ni=,rss=,nlwp=,etimes=,stat=,args=; } >> extra_procs.log; fi
    if [ "$rj" -gt "$LIMIT_KB" ] || [ "$av" -lt "$MIN_MEMAVAIL_KB" ]; then
      echo "$(date -Is) WATCHDOG: job RSS $rj kB (limit $LIMIT_KB), MemAvailable $av kB: killing femtic" >> watchdog.log
      pkill -KILL -x femtic; sleep 2; pkill -TERM -x prterun; pkill -TERM -x mpirun
    fi
    sleep 5
  done
) &
SAMP=$!
nice -n 10 /usr/bin/time -v -o time_v.log timeout 10800 \
  mpirun -np "$NP" --oversubscribe --bind-to none /home/tara/femtic_wsl/bin/femtic > run.log 2>&1
rc=$?
echo "end=$(date -Is)" >> run_env.txt
echo "rc=$rc" > FEMTIC.DONE
wait $SAMP
awk '{if($4>m)m=$4; if(a==""||$5<a)a=$5} END{printf "peak job RSS %.2f GB (%d kB), min MemAvailable %.1f GB, samples %d\n", m/1e6, m, a/1e6, NR}' rss_samples.log
[ -e watchdog.log ] && cat watchdog.log
grep -E "Maximum resident|Elapsed|Percent of CPU|Exit status" time_v.log
echo "batch $K rc=$rc"
exit $rc
