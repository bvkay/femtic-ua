#!/usr/bin/env bash
# acc_copyback.sh -- copy the small evidence files of the half-space runs acc_vN_RHO (every batch dir and any
# earlier run dir under it) from ext4 to /mnt/d/BEN/FEMTIC_2026/mesh/vulcan_vN/halfspace/acc_RHO/, then
# check that no CR crept in. mesh.dat and the 36+ MB resistivity blocks are NOT copied (reproducible:
# make_acc_inputs.py). result_*_iter0.csv and femtic_*.log are copied but git-ignored by the project rules;
# acc_eval_vN_RHO.{json,txt} are the committed record.
#
#   acc_copyback.sh N RHO
set -uo pipefail
N=$1; RHO=$2
SRC=/home/tara/femtic_wsl/mesh_runs/acc_v${N}_${RHO}
DST=/mnt/d/BEN/FEMTIC_2026/mesh/vulcan_v$N/halfspace/acc_$RHO
mkdir -p "$DST"
cp -f "$SRC"/*.json "$SRC"/*.txt "$SRC"/*.out "$SRC"/*.DONE "$DST"/ 2>/dev/null
for d in "$SRC"/*/; do
  b=$(basename "$d")
  mkdir -p "$DST/$b"
  for f in control.dat observe.dat femtic.cnv run.log run_env.txt time_v.log rss_samples.log FEMTIC.DONE \
           make_inputs.log free_at_launch.txt watchdog.log extra_procs.log femtic_*.log result_*_iter0.csv; do
    for g in "$d"$f; do [ -e "$g" ] && cp -f "$g" "$DST/$b/"; done
  done
done
if grep -rlI $'\r' "$DST"; then echo "CR FOUND in the files above"; else echo "no CR in $DST"; fi
du -sh "$DST"; ls "$DST"
