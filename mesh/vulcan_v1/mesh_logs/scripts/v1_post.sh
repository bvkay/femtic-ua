#!/usr/bin/env bash
# v1_post.sh -- after the chain: independent checks, mesh statistics, per-tool /usr/bin/time -v table,
# then copy products back to /mnt/d/BEN/FEMTIC_2026/mesh/vulcan_v1/.
set -uo pipefail
RUN=/home/tara/femtic_wsl/mesh_runs/vulcan_v1
DST=/mnt/d/BEN/FEMTIC_2026/mesh/vulcan_v1
cd "$RUN" || exit 1
source /home/tara/miniforge3/etc/profile.d/conda.sh
conda activate femticpy

echo "== check_mesh.py"
/usr/bin/time -v -o logs/check_mesh.timev python /mnt/d/BEN/FEMTIC_2026/validation/mesh_2026-09-25/check_mesh.py "$RUN" --flat-surface-z 0 > logs/check_mesh.txt 2>&1
echo "check_mesh rc=$?"; cat logs/check_mesh.txt

echo "== mesh_stats.py"
/usr/bin/time -v -o logs/mesh_stats.timev python /mnt/d/BEN/FEMTIC_2026/scripts/mesh_stats.py "$RUN" \
  --observe "$DST/inversion/observe.dat" --station-map "$DST/inversion/station_map.csv" \
  --surface-z 0 --json "$RUN/logs/mesh_stats.json" > logs/mesh_stats.txt 2>&1
echo "mesh_stats rc=$?"

echo "== per-tool /usr/bin/time -v"
{
  printf 'invocation\texit\twall_s\tuser_s\tsys_s\tcpu_pct\tmaxrss_MB\n'
  for f in logs/timev/*.txt; do
    awk -v n="$(basename "$f" .txt)" -F': ' '
      /Elapsed \(wall clock\)/ {w=$2; k=split(w,t,":"); s=0; for(i=1;i<=k;i++) s=s*60+t[i]}
      /User time/ {u=$2} /System time/ {y=$2} /Percent of CPU/ {c=$2} /Maximum resident/ {m=$2/1024} /Exit status/ {x=$2}
      END{printf "%s\t%s\t%.2f\t%.2f\t%.2f\t%s\t%.1f\n", n, x, s, u, y, c, m}' "$f"
  done
  for f in chain_total.timev logs/check_mesh.timev logs/mesh_stats.timev; do
    awk -v n="$f" -F': ' '
      /Elapsed \(wall clock\)/ {w=$2; k=split(w,t,":"); s=0; for(i=1;i<=k;i++) s=s*60+t[i]}
      /User time/ {u=$2} /System time/ {y=$2} /Percent of CPU/ {c=$2} /Maximum resident/ {m=$2/1024} /Exit status/ {x=$2}
      END{printf "%s\t%s\t%.2f\t%.2f\t%.2f\t%s\t%.1f\n", n, x, s, u, y, c, m}' "$f"
  done
} > logs/timev_table.tsv
column -t -s$'\t' logs/timev_table.tsv

md5sum mesh.dat resistivity_block_iter0.dat output.6.femtic.vtk > logs/products.md5
ls -la mesh.dat resistivity_block_iter0.dat output.*.vtk output.*.femtic.vtk 2>/dev/null
