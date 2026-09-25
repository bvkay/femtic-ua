#!/usr/bin/env bash
# acc_run.sh -- one FEMTIC half-space forward run for halfspace_accuracy.md (run inside WSL).
#
#   acc_run.sh N RHO [NP] [NT]
#
# Mesh:   /home/tara/femtic_wsl/mesh_runs/vulcan_vN/{mesh.dat,resistivity_block_iter0.dat}  (ext4 chain run)
# Prep:   /mnt/d/BEN/FEMTIC_2026/mesh/vulcan_vN/inversion/{observe.dat,control.dat}      (prep_vulcan.py)
# Run in: /home/tara/femtic_wsl/mesh_runs/acc_vN_RHO/   (wiped first)
# femtic: conda env femtic-build, OMP_NUM_THREADS=NT (default 2), mpirun -np NP (default 8), ITERATION 0 0.
# Records time_v.log (/usr/bin/time -v of mpirun), rss_samples.log (1 s: epoch, n_femtic, sum RSS kB,
# MemAvailable kB, swap used kB), watchdog.log (kills femtic if MemAvailable < 6 GB), FEMTIC.DONE (rc=...).
set -uo pipefail
N=$1; RHO=$2; NP=${3:-8}; NT=${4:-2}
HERE=/mnt/d/BEN/FEMTIC_2026/validation/mesh_2026-09-25/halfspace_accuracy
PREP=/mnt/d/BEN/FEMTIC_2026/mesh/vulcan_v$N
MESH=/home/tara/femtic_wsl/mesh_runs/vulcan_v$N
RUN=/home/tara/femtic_wsl/mesh_runs/acc_v${N}_${RHO}
source /home/tara/miniforge3/etc/profile.d/conda.sh
rm -rf "$RUN"; mkdir -p "$RUN"
conda activate femticpy
if ! python "$HERE/make_acc_inputs.py" "$PREP" "$MESH" "$RUN" "$RHO" > "$RUN/make_inputs.log" 2>&1; then
  cat "$RUN/make_inputs.log"; echo "rc=90" > "$RUN/FEMTIC.DONE"; exit 1
fi
cat "$RUN/make_inputs.log"
conda deactivate
conda activate femtic-build
export OMP_NUM_THREADS=$NT
cd "$RUN" || exit 1
echo "np=$NP omp=$NT host=$(hostname) start=$(date -Is)" > run_env.txt
(
  while [ ! -e FEMTIC.DONE ]; do
    now=$(date +%s.%N)
    read -r n rss < <(ps -C femtic -o rss= | awk '{s+=$1; n++} END{print n+0, s+0}')
    avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    swap=$(awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{print t-f}' /proc/meminfo)
    echo "$now $n $rss $avail $swap" >> rss_samples.log
    if [ "$avail" -lt 6000000 ]; then
      echo "$(date +%T) MemAvailable $avail kB < 6 GB: killing femtic" >> watchdog.log
      pkill -KILL -x femtic
    fi
    sleep 1
  done
) &
SAMP=$!
/usr/bin/time -v -o time_v.log timeout 14400 mpirun -np "$NP" --oversubscribe --bind-to none /home/tara/femtic_wsl/bin/femtic > run.log 2>&1
rc=$?
echo "end=$(date -Is)" >> run_env.txt
echo "rc=$rc" > FEMTIC.DONE
wait $SAMP
echo "femtic rc=$rc"
