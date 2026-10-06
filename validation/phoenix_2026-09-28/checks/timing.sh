#!/usr/bin/env bash
# Check d: time, threads and PARDISO memory of the B2 smoke runs on icelake (p2-cpu-14), against WSL.
# Mostly a record. Its one pass/fail criterion is a coarse pathology detector:
#   This test fails if the WSL 2 x 2 run (36.9 s, validation/wsl_2026-09-25/run_logs/time_v.log) and the time
#   predicted for it from the Phoenix per-iteration stamps differ by more than a factor of 2 either way
#   (a rank pinned to one core, oversubscription or a wrong thread count would show up as >= 2x).
# FEMTIC stamps are whole seconds, so every per-iteration time below is +-1 s.
# Run from the repository root:  bash validation/phoenix_2026-09-28/checks/timing.sh
set -u
REPO=$(git rev-parse --show-toplevel) || exit 1
EV=$REPO/validation/phoenix_2026-09-28
WSL=$REPO/validation/wsl_2026-09-25

stamps() {   # per-iteration start stamps and the End stamp of one femtic log
  awk '{ if (match($0, /\( *[0-9]+ sec *\)/)) { s = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); t = s + 0 } }
       /^# Start Forward Computation\./ { printf "iter%s@%ss ", $7 + 0, t }
       /^# End femtic/ { printf "End@%ss", t }' "$1"; echo
}
echo "== per-iteration stamps (rank 0 and rank 1 logs; 'iterK@Ts' = iteration K started at T s)"
for f in straight/femtic_0_straight.log.txt straight/femtic_1_straight.log.txt restart/femtic_0.log.leg1 \
         restart/femtic_0_leg2.log.txt restart/femtic_1_leg2.log.txt; do
  printf '  %-38s %s\n' "$f" "$(stamps "$EV/$f")"
done
echo "  slurm .out 'last log line' per run:"; grep -E 'exit [0-9]+; last log line' "$EV/slurm-femtic_smoke-16153670.out" | sed 's/^/   /'
echo "  whole job (first and last '== ' date lines of the .out):"; grep -E '^== ' "$EV/slurm-femtic_smoke-16153670.out" | cut -c1-40 | sed 's/^/   /'

echo; echo "== threads and ranks"
for f in straight/femtic_0_straight.log.txt straight/femtic_1_straight.log.txt restart/femtic_0.log.leg1 restart/femtic_0_leg2.log.txt restart/femtic_1_leg2.log.txt; do
  printf '  %-38s %s\n' "$f" "$(grep -m1 'Number of threads' "$EV/$f")"
done
echo "  control.dat NUM_THREADS: straight $(awk '$1=="NUM_THREADS"{getline; print; exit}' "$EV/straight/control.dat"), restart $(awk '$1=="NUM_THREADS"{getline; print; exit}' "$EV/restart/control.dat"); WSL 2x2 run $(awk '{sub(/\r$/,"")} $1=="NUM_THREADS"{getline; sub(/\r$/,""); print; exit}' "$WSL/run_logs/control.dat")"
echo "  WSL command: $(grep -o 'mpirun[^"]*' "$WSL/run_logs/time_v.log")"
echo "  Phoenix command (kit 55bbf44, 01_build_femtic.sh:487): $(git -C "$REPO" show 55bbf44:hpc/phoenix_plan/01_build_femtic.sh | sed -n '487p' | sed 's/^ *//' | cut -c1-110)"

echo; echo "== PARDISO lines (KB) per factorisation, all runs"
for f in straight/femtic_0_straight.log.txt straight/femtic_1_straight.log.txt restart/femtic_0.log.leg1 restart/femtic_0_leg2.log.txt restart/femtic_1_leg2.log.txt; do
  printf '  %-38s in-core %s | analysis peak %s | permanent %s\n' "$f" \
    "$(awk -F: '/Total memory consumed by in-core/ {gsub(/[^0-9]/, "", $2); printf "%s ", $2}' "$EV/$f")" \
    "$(awk -F: '/Total peak memory required during the analysis/ {gsub(/[^0-9]/, "", $2); printf "%s ", $2}' "$EV/$f")" \
    "$(awk -F: '/Permanent memory required/ {gsub(/[^0-9]/, "", $2); printf "%s ", $2}' "$EV/$f")"
done
echo "  WSL 2x2 run: max RSS of one process $(awk -F: '/Maximum resident/ {gsub(/ /, "", $2); print $2}' "$WSL/run_logs/time_v.log") KB (time -v), summed peak of both ranks $(tail -1 "$WSL/run_logs/rss_samples.log" | sed 's/.*peak_kib=//') KiB (ps, 2 s); no RSS was sampled on Phoenix"

echo; echo "== d. speed sanity: Phoenix-predicted time of the WSL 2x2 run (ITERATION 0 5 = 5 x (forward + sensitivity) + 1 forward)"
read -r i0 i1 i2 e < <(stamps "$EV/straight/femtic_0_straight.log.txt" | sed -E 's/[a-zA-Z]+[0-9]*@//g; s/s//g')
fs=$(( i1 - i0 )); fo=$(( e - i2 ))
w=$(awk -F': ' '/Elapsed \(wall clock\)/ {split($2, a, ":"); print a[1] * 60 + a[2]}' "$WSL/run_logs/time_v.log")
ratio() { awk -v p="$1" -v w="$2" 'BEGIN {r = p / w; printf "%.2f %s", r, (r <= 2 && r >= 0.5) ? "PASS" : "FAIL"}'; }
echo "  Phoenix straight rank 0: forward+sensitivity $fs s (iteration 0->1 stamps), forward only $fo s (iteration 2 -> End)"
echo "  fail case (synthetic: Phoenix 3x slower, forward+sensitivity $((3 * fs)) s, forward $((3 * fo)) s): ratio $(ratio $(( 5 * 3 * fs + 3 * fo )) "$w")"
echo "  real: predicted $(( 5 * fs + fo )) s vs WSL wall $w s (time -v, includes mpirun start-up): ratio $(ratio $(( 5 * fs + fo )) "$w")"
g=$(grep -o 'End femtic ( [0-9]* sec )' "$WSL/build_logs/smoke_inv3_gnugomp.log" | grep -o '[0-9]*')
echo "  for scale: WSL 2 ranks x 4 threads, ITERATION 0 3 (main build, GNU libgomp): End femtic $g s; at the Phoenix 2x2 rate it would take $(( 3 * fs + fo )) s"
