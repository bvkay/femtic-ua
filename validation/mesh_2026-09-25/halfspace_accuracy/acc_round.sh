#!/usr/bin/env bash
# acc_round.sh -- one round of the half-space accuracy test on mesh vN: 3 and 100 ohm-m, analysis, copy-back.
#
#   acc_round.sh N [NP] [NT]        (inside WSL; NP MPI ranks x NT OpenMP threads, default 4 x 4)
#
# Results: /home/tara/femtic_wsl/mesh_runs/acc_vN_{3,100}/  ->  /mnt/d/BEN/FEMTIC_2026/mesh/vulcan_vN/halfspace/
set -uo pipefail
N=$1; NP=${2:-4}; NT=${3:-4}
HERE=/mnt/d/BEN/FEMTIC_2026/validation/mesh_2026-09-25/halfspace_accuracy
DST=/mnt/d/BEN/FEMTIC_2026/mesh/vulcan_v$N/halfspace
MARK=/home/tara/femtic_wsl/mesh_runs/acc_v${N}_ROUND.DONE
rm -f "$MARK"
sed 's/\r$//' "$HERE/acc_run.sh" > /tmp/acc_run_$N.sh
for RHO in 3 100; do
  bash /tmp/acc_run_$N.sh "$N" "$RHO" "$NP" "$NT"
done
source /home/tara/miniforge3/etc/profile.d/conda.sh
conda activate femticpy
mkdir -p "$DST"
for RHO in 3 100; do
  RUN=/home/tara/femtic_wsl/mesh_runs/acc_v${N}_${RHO}
  python "$HERE/acc_analyse.py" "$RUN" "$RHO" --json "$RUN/acc_analysis.json" > "$RUN/acc_analysis.txt" 2>&1
  cat "$RUN/acc_analysis.txt"
  D=$DST/acc_$RHO
  rm -rf "$D"; mkdir -p "$D"
  cp -f "$RUN"/{control.dat,observe.dat,femtic.cnv,run.log,run_env.txt,time_v.log,rss_samples.log,FEMTIC.DONE,make_inputs.log,acc_analysis.json,acc_analysis.txt} "$D"/ 2>/dev/null
  cp -f "$RUN"/femtic_*.log "$RUN"/result_*_iter0.csv "$D"/ 2>/dev/null
  [ -e "$RUN/watchdog.log" ] && cp -f "$RUN/watchdog.log" "$D"/
  md5sum "$RUN/mesh.dat" > "$D/mesh_md5.txt"
done
echo "done $(date -Is)" > "$MARK"
