#!/usr/bin/env bash
# v1_run.sh -- first Vulcan tetra mesh: copy files/ to ext4, run scripts/run_mesh_chain.sh unmodified,
# with every tool invocation wrapped in /usr/bin/time -v (via FEMTIC_BIN pointing at wrapper scripts).
# Usage: v1_run.sh [RUN_NAME] [N_ROUNDS]
set -uo pipefail
NAME=${1:-vulcan_v1}
NR=${2:-5}
SRC=/mnt/d/BEN/FEMTIC_2026/mesh/vulcan_v1/files
RUN=/home/tara/femtic_wsl/mesh_runs/$NAME
REAL_BIN=/home/tara/femtic_wsl/bin
WRAP=$RUN/timewrap_bin

mkdir -p "$RUN"
# fresh copy of the inputs (inputs only; the chain wipes its own products)
rm -f "$RUN"/*.dat "$RUN"/*.param
cp -v "$SRC"/* "$RUN"/ > "$RUN/copy_inputs.log"
( cd "$RUN" && md5sum "$SRC"/* ) > "$RUN/source_md5.txt"

# /usr/bin/time -v wrappers: one file per tool invocation in RUN/logs/timev/NN_tool_args.txt
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

rm -f "$RUN/CHAIN.DONE"
cd "$RUN" || exit 1
FEMTIC_BIN=$WRAP /usr/bin/time -v -o "$RUN/chain_total.timev" \
  bash /mnt/d/BEN/FEMTIC_2026/scripts/run_mesh_chain.sh "$RUN" "$NR" > "$RUN/chain_stdout.log" 2> "$RUN/chain_stderr.log"
echo "rc=$?" > "$RUN/CHAIN.DONE"
