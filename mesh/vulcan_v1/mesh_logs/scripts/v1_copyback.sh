#!/usr/bin/env bash
# v1_copyback.sh -- copy the Vulcan v1 mesh products and logs from ext4 back to the project on D:.
set -euo pipefail
RUN=/home/tara/femtic_wsl/mesh_runs/vulcan_v1
DST=/mnt/d/BEN/FEMTIC_2026/mesh/vulcan_v1
mkdir -p "$DST/inversion" "$DST/vtk" "$DST/mesh_logs"
cp -f "$RUN/mesh.dat" "$RUN/resistivity_block_iter0.dat" "$DST/inversion/"
cp -f "$RUN"/output.*.femtic.vtk "$DST/vtk/"
# logs: everything except the 16 MB unseeded PLC copy (reproducible, and git-ignored by mesh/**/output.*)
rsync -a --exclude 'output.poly.unseeded' "$RUN/logs/" "$DST/mesh_logs/"
cp -f "$RUN/chain_stdout.log" "$RUN/chain_stderr.log" "$RUN/chain_total.timev" "$RUN/region_seeds.used" "$DST/mesh_logs/"
cd "$DST"
md5sum inversion/mesh.dat inversion/resistivity_block_iter0.dat vtk/output.6.femtic.vtk
cat "$RUN/logs/products.md5"
ls -la inversion vtk mesh_logs | head -60
# CR check on every text file copied
if grep -rlI $'\r' mesh_logs inversion/resistivity_block_iter0.dat; then echo "CR FOUND"; else echo "no CR in copied text files"; fi
