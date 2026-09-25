#!/usr/bin/env bash
# mesh_build.sh -- build Vulcan mesh vN from the prep_vulcan.py output with the unmodified
# scripts/run_mesh_chain.sh (as for v1), then run the independent checks and statistics and copy the
# products back to the project. Run inside WSL. One heavy job at a time: refuses to start if femtic,
# tetgen or another mesh tool is running. Everything runs under "nice -n 10"; makeTetraMesh step 3 uses
# the config's num_threads (8), every other tool is single-threaded.
#
#   mesh_build.sh N [N_ROUNDS]        (N_ROUNDS default 5, as v1)
#
# In : /mnt/d/BEN/FEMTIC_2026/mesh/vulcan_vN/files/  (prep_vulcan.py output)
# Run: /home/tara/femtic_wsl/mesh_runs/vulcan_vN/    (ext4; tool wrappers record /usr/bin/time -v per call)
# Out: /mnt/d/BEN/FEMTIC_2026/mesh/vulcan_vN/{inversion/mesh.dat, inversion/resistivity_block_iter0.dat,
#      vtk/, mesh_logs/}; BUILD.DONE in the run dir with "rc=<chain rc> post=<post rc>"
set -uo pipefail
N=$1
NR=${2:-5}
SRC=/mnt/d/BEN/FEMTIC_2026/mesh/vulcan_v$N
RUN=/home/tara/femtic_wsl/mesh_runs/vulcan_v$N
REAL_BIN=/home/tara/femtic_wsl/bin
WRAP=$RUN/timewrap_bin

if pgrep -x femtic >/dev/null || pgrep -x tetgen >/dev/null || pgrep -f 'makeTetraMesh|makeMtr|TetGen2Femtic' >/dev/null; then
  echo "ABORT: another heavy job is running"; exit 3
fi
[ -d "$SRC/files" ] || { echo "ABORT: $SRC/files missing (run prep_vulcan.py first)"; exit 1; }
mkdir -p "$RUN"
rm -f "$RUN"/*.dat "$RUN"/*.param "$RUN/BUILD.DONE"
cp -v "$SRC"/files/* "$RUN"/ > "$RUN/copy_inputs.log"
( cd "$SRC/files" && md5sum * ) > "$RUN/source_md5.txt"

mkdir -p "$WRAP"
for t in makeTetraMesh tetgen makeMtr TetGen2Femtic; do
  cat > "$WRAP/$t" <<EOF
#!/usr/bin/env bash
d="\$PWD/logs/timev"; mkdir -p "\$d"
n=\$(ls "\$d" | wc -l)
tag=\$(printf '%02d_%s_%s' "\$n" "$t" "\$(echo "\$*" | tr ' /.' '___')")
exec /usr/bin/time -v -o "\$d/\$tag.txt" $REAL_BIN/$t "\$@"
EOF
  chmod +x "$WRAP/$t"
done

cd "$RUN" || exit 1
echo "chain start $(date -Is)"
FEMTIC_BIN=$WRAP nice -n 10 /usr/bin/time -v -o "$RUN/chain_total.timev" \
  bash /mnt/d/BEN/FEMTIC_2026/scripts/run_mesh_chain.sh "$RUN" "$NR" > "$RUN/chain_stdout.log" 2> "$RUN/chain_stderr.log"
crc=$?
echo "chain rc=$crc $(date -Is)"
tail -5 "$RUN/chain_stdout.log"; tail -5 "$RUN/chain_stderr.log"
if [ $crc -ne 0 ]; then echo "rc=$crc post=NA" > "$RUN/BUILD.DONE"; exit $crc; fi

source /home/tara/miniforge3/etc/profile.d/conda.sh
conda activate femticpy
prc=0
nice -n 10 /usr/bin/time -v -o logs/check_mesh.timev python /mnt/d/BEN/FEMTIC_2026/validation/mesh_2026-09-25/check_mesh.py "$RUN" --flat-surface-z 0 > logs/check_mesh.txt 2>&1 || prc=1
echo "check_mesh rc=$prc"; tail -4 logs/check_mesh.txt
nice -n 10 /usr/bin/time -v -o logs/mesh_stats.timev python /mnt/d/BEN/FEMTIC_2026/scripts/mesh_stats.py "$RUN" \
  --observe "$SRC/inversion/observe.dat" --station-map "$SRC/inversion/station_map.csv" \
  --surface-z 0 --json "$RUN/logs/mesh_stats.json" > logs/mesh_stats.txt 2>&1 || prc=$((prc + 2))
echo "mesh_stats rc=$prc"
{
  printf 'invocation\texit\twall_s\tuser_s\tsys_s\tcpu_pct\tmaxrss_MB\n'
  for f in logs/timev/*.txt chain_total.timev logs/check_mesh.timev logs/mesh_stats.timev; do
    awk -v n="$(basename "$f" .txt)" -F': ' '
      /Elapsed \(wall clock\)/ {w=$2; k=split(w,t,":"); s=0; for(i=1;i<=k;i++) s=s*60+t[i]}
      /User time/ {u=$2} /System time/ {y=$2} /Percent of CPU/ {c=$2} /Maximum resident/ {m=$2/1024} /Exit status/ {x=$2}
      END{printf "%s\t%s\t%.2f\t%.2f\t%.2f\t%s\t%.1f\n", n, x, s, u, y, c, m}' "$f"
  done
} > logs/timev_table.tsv
column -t -s$'\t' logs/timev_table.tsv
md5sum mesh.dat resistivity_block_iter0.dat > logs/products.md5
grep -l -i -E "Reach maximum|Error|Warning" logs/*.log 2>/dev/null | sed 's/^/log with Error|Warning|Reach maximum: /'

mkdir -p "$SRC/inversion" "$SRC/vtk" "$SRC/mesh_logs"
cp -f mesh.dat resistivity_block_iter0.dat "$SRC/inversion/"
cp -f output.*.femtic.vtk "$SRC/vtk/" 2>/dev/null
rsync -a --exclude 'output.poly.unseeded' logs/ "$SRC/mesh_logs/"
cp -f chain_stdout.log chain_stderr.log chain_total.timev region_seeds.used "$SRC/mesh_logs/" 2>/dev/null
( cd "$SRC" && md5sum inversion/mesh.dat inversion/resistivity_block_iter0.dat ) > "$RUN/copy_md5.txt"
cat "$RUN/copy_md5.txt" logs/products.md5
echo "rc=$crc post=$prc" > "$RUN/BUILD.DONE"
echo "build done $(date -Is)"
