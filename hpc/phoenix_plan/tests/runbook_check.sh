#!/bin/bash
# =============================================================================
# runbook_check.sh -- checks RUNBOOK_first_inversion.md and UPLOAD_LIST_2026-09-28.txt against the kit, the kit's
# own functions, outputs of the kit's scripts (tests/c1c2_test.sh fake-femtic runs), the WSL run logs and the local
# input files. The runbook's own command blocks run in a sandbox that mirrors the Phoenix folders: vulcan_femtic/
# inputs/vulcan_v{2,3}, filled the way the upload list and step B3 say, and vulcan_femtic/work/<mesh>/<dir>. Fake
# sacct, sbatch and rcstat give synthetic outputs; each command gets a passing and a failing case.
#   bash runbook_check.sh [RUNBOOK] [UPLOAD_LIST]
#   env: MESH  (default /d/BEN/FEMTIC_2026/mesh: the gated v2/v3 inputs and the 2026-09-25 WSL gate logs)
#        WT    (default: the checkout this script is in; the rotated v2 data is $WT/mesh/vulcan_v2_rot/inversion)
#        C1C2  (a directory to keep, or reuse, the tests/c1c2_test.sh run; default: a fresh run in a temp directory)
#        CHECK_GROUPS  (e.g. "K3 K7": run only these groups; default all)
# PC only (Git Bash): it reads the local mesh files and WSL logs. Light: c1c2_test.sh and portability_test.sh with
# fakes (~2 min), md5 of the 704 MB of inputs, awk over mesh.dat headers. No femtic, mpirun or Slurm runs.
# Groups: K1 the runbook's commands on real/fake outputs; K2 quoted strings vs the scripts, the kit's gates and
# self-test counts; K3 numbers recomputed with the kit's functions; K4 files, sizes, md5, the list vs its generator;
# K5 bash syntax and hygiene; K6 cited evidence; K7 command rules and Phoenix folders.
# Every check prints "fails if ..." first. Exit 0 only if every check passes. tests/runbook_mutate.py makes mutants.
# =============================================================================
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WT=${WT:-}; [ -n "$WT" ] || WT=$(cd "$KIT/../.." && pwd)
RB=${1:-$KIT/RUNBOOK_first_inversion.md}; UL=${2:-$KIT/UPLOAD_LIST_2026-09-28.txt}
MESH=${MESH:-/d/BEN/FEMTIC_2026/mesh}
ROT=$WT/mesh/vulcan_v2_rot/inversion
T=$(mktemp -d)
np=0; nf=0; FAILED_GROUPS=""
crit() { echo; echo "CHECK $1: fails if $2"; CUR=${1%%.*}; }
ok()   { echo "  PASS $*"; np=$((np + 1)); }
bad()  { echo "  FAIL $*"; nf=$((nf + 1)); case " $FAILED_GROUPS " in *" $CUR "*) ;; *) FAILED_GROUPS="$FAILED_GROUPS $CUR" ;; esac; }
has()  { if grep -qF -- "$2" "$1"; then ok "'$2'"; else bad "'$2' not found in $(basename "$1")"; fi; }
hasnt(){ if grep -qF -- "$2" "$1"; then bad "'$2' found in $(basename "$1")"; else ok "no '$2'"; fi; }
cnt()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got '$2', want '$3'"; fi; }
# the first grep -E / grep -cE pattern of the runbook that contains $1
rbpat() { grep -oE "grep -c?E '[^']*'" "$RB" | grep -F -- "$1" | head -1 | sed -E "s/^grep -c?E '//; s/'\$//"; }
# the first ```bash block of the runbook that contains $1
blk()  { awk -v want="$1" '/^```bash$/ {on = 1; b = ""; next} /^```$/ && on {on = 0; if (index(b, want)) {printf "%s", b; exit}} on {b = b $0 "\n"}' "$RB"; }
want() { case " ${CHECK_GROUPS:-K1 K2 K3 K4 K5 K6 K7} " in *" $1 "*) return 0 ;; esac; return 1; }   # CHECK_GROUPS="K3 K7" runs only those
[ -f "$RB" ] && [ -f "$UL" ] || { echo "runbook_check: $RB or $UL missing"; exit 2; }
[ -d "$MESH/vulcan_v2/inversion" ] || { echo "runbook_check: no $MESH/vulcan_v2/inversion (set MESH)"; exit 2; }
[ -f "$ROT/observe.dat" ] || { echo "runbook_check: no $ROT/observe.dat (set WT)"; exit 2; }
echo "runbook_check: RB=$RB  UL=$UL  KIT=$KIT  WT=$WT  MESH=$MESH  bash $BASH_VERSION"
# shellcheck disable=SC1090,SC1091
source "$KIT/femtic_lib.sh"

# ---------------- tests/c1c2_test.sh as it runs on Phoenix: no WSL log (f1 real-log case skipped), no ACC_ROOT,
# STALE_LIB = the 55bbf44 femtic_lib.sh (version 2, the copy installed on Phoenix since 2026-09-28), as B1.4 prescribes
if ! want K1 && ! want K2; then CD=$T/none; mkdir -p "$CD/work/inv_e/logs"; : > "$CD/run.txt"
elif [ -n "${C1C2:-}" ] && [ -f "$C1C2/run.txt" ]; then CD=$C1C2; echo "reusing $CD/run.txt"
else
  CD=${C1C2:-$T/c1c2}; mkdir -p "$CD"; STALE=""
  git -C "$WT" --no-optional-locks show 55bbf44:hpc/phoenix_plan/femtic_lib.sh > "$CD/lib_55bbf44.sh" 2>/dev/null && STALE=$CD/lib_55bbf44.sh
  echo "running tests/c1c2_test.sh as on Phoenix (STALE_LIB=${STALE:-none}) ..."
  WORK=$CD/work STALE_LIB=$STALE REAL_INV_LOG=/nonexistent ACC_ROOT=/nonexistent bash "$KIT/tests/c1c2_test.sh" "$KIT" > "$CD/run.txt" 2>&1
fi
CW=$CD/work
REP_OK=$(grep -lF 'GATE (half-space, START_RHO=100): PASS' "$CW"/inv_e/logs/fwd0_report_*.txt | head -1)
REP_BAD=$(grep -lF 'GATE (half-space, START_RHO=100): FAIL' "$CW"/inv_e/logs/fwd0_report_*.txt | head -1)
J06=$(basename "$REP_OK" .txt); J06=${J06#fwd0_report_}
OUT04=$(grep -l -- '--- sizing report ---' "$CW"/inv_*/slurm-04-*.out | head -1)
echo "c1c2 run: $(tail -1 "$CD/run.txt")"; echo "06 gate PASS report: $REP_OK; FAIL report: $REP_BAD; 04 output: $OUT04"

# ---------------- sandbox: fake sacct, sbatch and rcstat, synthetic OpenMPI --report-bindings output
FB=$T/fakebin; mkdir -p "$FB"
cat > "$FB/sacct" <<'EOF'
#!/bin/bash
a="$*"; j=""; while [ $# -gt 0 ]; do [ "$1" = -j ] && j=$2; shift; done
case "$a" in
  *"--format=JobID,MaxRSS"*) printf '%s|\n%s.batch|%s\n%s.extern|0M\n' "$j" "$j" "$FAKE_RSS" "$j" ;;
  *"--format=JobID,Elapsed,TotalCPU,AllocCPUS"*) printf '%s|%s|%s|72\n%s.batch|%s|%s|72\n%s.extern|%s|00:00.002|72\n' "$j" "$FAKE_EL" "$FAKE_CPU" "$j" "$FAKE_EL" "$FAKE_CPU" "$j" "$FAKE_EL" ;;
  *) echo "fake sacct $a" ;;
esac
EOF
cat > "$FB/sbatch" <<'EOF'
#!/bin/bash
echo "cwd=$PWD args=$*" >> "${FAKE_SBATCH_LOG:-/dev/null}"
[ -n "${FAKE_JOBID:-}" ] || { echo "sbatch: error: fake submission failure" >&2; exit 1; }
case " $* " in *" --parsable "*) echo "$FAKE_JOBID" ;; *) echo "Submitted batch job $FAKE_JOBID" ;; esac
EOF
printf '#!/bin/bash\necho "fake rcstat $*"\n' > "$FB/rcstat"; chmod +x "$FB"/*
# genbind "rank:first_core:ncores ..." -> one OpenMPI 4.1 --report-bindings line per rank, 2 sockets x 36 cores
genbind() { awk -v spec="$1" 'BEGIN { n = split(spec, S, " ")
  for (i = 1; i <= n; i++) { split(S[i], a, ":"); r = a[1]; f = a[2]; c = a[3]; txt = ""; map = "["
    for (k = f; k < f + c; k++) txt = txt (txt == "" ? "" : ", ") sprintf("socket %d[core %d[hwt 0]]", (k < 36 ? 0 : 1), k)
    for (k = 0; k < 72; k++) { if (k == 36) map = map "]["; else if (k > 0) map = map "/"; map = map ((k >= f && k < f + c) ? "B" : ".") }
    printf "[p2-cpu-17:04711] MCW rank %d bound to %s: %s]\n", r, txt, map } }'; }

# ---------------- K1: the runbook's own commands, run on real or fake outputs (sandbox $SB, fakes first on PATH)
if want K1; then
export MSYS=winsymlinks:sys    # Git Bash: real symlinks for the sandbox (ignored elsewhere)
SB=$T/sb; mkdir -p "$SB/P"
runblk() {  # runblk MARKER DIR OUT [VAR=VALUE ...]: run the runbook block holding MARKER in DIR (env RB_APPEND: one more line)
  local m=$1 d=$2 o=$3; shift 3; blk "$m" > "$T/blk.sh"
  [ -s "$T/blk.sh" ] || { echo "(no bash block with '$m')" > "$o"; return 1; }
  [ -n "${RB_APPEND:-}" ] && echo "$RB_APPEND" >> "$T/blk.sh"
  ( cd "$d" && env PATH="$FB:$PATH" P="$SB/P" VF="$SB/vf" IN="$SB/vf/inputs" WK="$SB/vf/work" LEDGER="$SB/ledger" PLAN="$KIT" BIN="$KIT" "$@" bash "$T/blk.sh" ) > "$o" 2>&1; }
# upload STEP ROOT: do what WinSCP does for every row of the list with this step: the local file lands at its Phoenix
# path, /hpcfs/users/a1690074/vulcan_femtic/... -> ROOT/... (a copy below 10 MB, else a link, so no block can write
# through to a real input)
upload() { local st=$1 root=$2 id s lp ar dp rest pp q
  while read -r id s lp ar dp rest; do
    case "$id" in [BCD][0-9][0-9]) ;; *) continue ;; esac; [ "$s" = "$st" ] || continue
    pp=/d/$(echo "${lp#D:?}" | tr '\134' /); q=${dp#/hpcfs/users/a1690074/vulcan_femtic/}
    [ "$q" != "$dp" ] || { echo "upload: $id goes to $dp, outside vulcan_femtic"; continue; }
    mkdir -p "$root/$(dirname "$q")"; rm -f "$root/$q"
    if [ "$(wc -c < "$pp")" -lt 10000000 ]; then cp "$pp" "$root/$q"; else ln -s "$pp" "$root/$q"; fi
  done < "$UL"; }

crit K1.1 "the B3 steps, run as written on a sandbox filled from the upload list (B3.1 rows, the B3.2 block, B3.3 rows, B3.2 again), do not give 7 + 5 ': OK' lines, the rotated observe.dat's sha256 prefix and the header lines the runbook quotes; or a wrong order (B3.2 skipped or late, B3.3 skipped) gives 12 ': OK' lines or files a rotated observe.dat as observe_unrotated.dat"
b3() {  # b3 ROOT OUT STEP...: a fresh vulcan_femtic tree ROOT/vf through the steps, then the B3.4 block
  local r=$1 o=$2 s; shift 2; rm -rf "$r/vf"; mkdir -p "$r/vf/inputs"
  for s in "$@"; do case $s in B3.2) runblk 'mv observe.dat observe_unrotated.dat' "$r" "$o.b32" VF="$r/vf" IN="$r/vf/inputs" ;; *) upload "$s" "$r/vf" ;; esac; done
  runblk '== vulcan_v2' "$r" "$o" VF="$r/vf" IN="$r/vf/inputs"; }
b3 "$SB" "$T/k11" B3.1 B3.2 B3.3 B3.2
awk '/^== vulcan_v2/ {s = 2} /^== vulcan_v3/ {s = 3} /: OK$/ {n[s]++} END {print n[2] + 0, n[3] + 0}' "$T/k11" > "$T/k11n"
cnt "': OK' lines for v2 and v3" "$(cat "$T/k11n")" "7 5"
cnt "lines with FAILED or 'No such file'" "$(grep -cE 'FAILED|No such file' "$T/k11")" 0
grep -qF '12 lines ending in `: OK` (7 for v2, 5 for v3)' "$RB" && ok "runbook quotes 12 = 7 + 5 OK lines" || bad "runbook lacks '12 lines ending in \`: OK\` (7 for v2, 5 for v3)'"
grep -qx 'd501abcf5a7dde5f' "$T/k11" && grep -qF '`d501abcf5a7dde5f`, the rotated observe.dat' "$RB" && ok "sha256 prefix d501abcf5a7dde5f printed and quoted" || bad "sha256 prefix line missing or not quoted"
for v in 2 3; do q=$(grep -oE "^\* \`TETRA [0-9]+ / [0-9]+ [0-9]+\` for v$v" "$RB" | sed -E 's/^\* `//; s/` for.*//')
  [ -n "$q" ] && grep -qxF -- "$q" "$T/k11" && ok "v$v header '$q' printed" || bad "v$v: runbook PASS text '$q' is not a line of the block's output"; done
I2=$SB/vf/inputs/vulcan_v2
cmp -s "$I2/observe.dat" "$ROT/observe.dat" && cmp -s "$I2/station_map.csv" "$ROT/station_map.csv" && cmp -s "$I2/observe_unrotated.dat" "$MESH/vulcan_v2/inversion/observe.dat" \
  && cmp -s "$I2/station_map_unrotated.csv" "$MESH/vulcan_v2/inversion/station_map.csv" && ok "inputs/vulcan_v2: rotated pair as observe.dat/station_map.csv, unrotated pair kept" || bad "inputs/vulcan_v2 files are not where B3 says"
has "$T/k11.b32" "observe_unrotated.dat"
for c in "skip32|B3.1 B3.3" "late32|B3.1 B3.3 B3.2" "skip33|B3.1 B3.2"; do IFS='|' read -r n st <<< "$c"
  b3 "$SB/b3_$n" "$T/k11_$n" $st; k=$(grep -c ': OK$' "$T/k11_$n")
  [ "$k" -lt 12 ] && ok "order $n ($st): $k ': OK' lines, not 12" || bad "order $n ($st) still gives $k ': OK' lines"
  u=$SB/b3_$n/vf/inputs/vulcan_v2/observe_unrotated.dat
  [ -e "$u" ] && cmp -s "$u" "$ROT/observe.dat" && bad "order $n: the rotated observe.dat was filed as observe_unrotated.dat" || ok "order $n: no rotated file under the unrotated name"; done

crit K1.2 "the B4a gate-directory block (M=v2, M=v3) or the B5 t4 block does not give each directory a regular control.dat and links '../../../inputs/vulcan_<mesh>/<file>' that resolve to the input folder's files (v2: the rotated observe.dat); or 06's own link and input lines, and 04's input check and memory model, run in them, do not reach the same files; or t4 changes an input"
mkdir -p "$SB/vf/work/v2/gate100/logs"; echo "28629 job777 3x24 peak_rss_kb=na pardiso_kb=na" > "$SB/vf/work/v2/gate100/logs/fwd_rank_mb"
L06=$(grep -E 'ln -sf "\$INV_DIR/(\$f|resistivity_block_iter0\.dat)"' "$KIT/06_forward_only.slurm" | sed 's/^ *//'); I06=$(grep -E '^for f in control.dat mesh.dat observe.dat resistivity_block_iter0.dat; do \[ -f' "$KIT/06_forward_only.slurm")
I04=$(grep -E '^for f in control.dat mesh.dat observe.dat; do \[ -f' "$KIT/04_inversion.slurm")
cnt "06 link lines and input checks found (06:115,138,156; 04:122)" "$(echo "$L06" | grep -c .) $(echo "$I06" | grep -c .) $(echo "$I04" | grep -c .)" "2 1 1"
links() {  # links DIR MESH FILES...: every file a link '../../../inputs/vulcan_MESH/f' resolving to the input folder's file
  local d=$1 m=$2 f n=0 b=""; shift 2
  for f in "$@"; do if [ "$(readlink "$d/$f")" = "../../../inputs/vulcan_$m/$f" ] && [ "$(readlink -f "$d/$f")" = "$(readlink -f "$SB/vf/inputs/vulcan_$m/$f")" ] && cmp -s "$d/$f" "$SB/vf/inputs/vulcan_$m/$f"; then n=$((n + 1)); else b="$b $f"; fi; done
  [ -z "$b" ] && ok "${d#$SB/vf/}: $n links resolve into inputs/vulcan_$m" || bad "${d#$SB/vf/}: wrong or dangling:$b"; }
for M in v2 v3; do runblk 'for G in gate100 gate3' "$SB" "$T/k12_$M" M=$M
  for G in gate100 gate3; do d=$SB/vf/work/$M/$G
    grep -qE "^$M $G ready: .*/vf/inputs/vulcan_$M/observe.dat\$" "$T/k12_$M" && ok "$M $G ready (observe.dat -> inputs/vulcan_$M)" || bad "$M $G: no 'ready' line naming inputs/vulcan_$M/observe.dat"
    [ -f "$d/control.dat" ] && [ ! -L "$d/control.dat" ] && cmp -s "$d/control.dat" "$MESH/vulcan_$M/inversion/control.dat" && ok "$M $G: control.dat is a copy" || bad "$M $G: control.dat not a regular copy"
    links "$d" "$M" mesh.dat observe.dat resistivity_block_iter0.dat station_map.csv
    ( cd "$d" && INV_DIR=$PWD && W=$PWD/fwd0_777 && mkdir -p "$W" && eval "$I06" && eval "$L06" && echo "06 inputs ok" ) > "$T/k12_06" 2>&1
    s=0; for f in mesh.dat observe.dat resistivity_block_iter0.dat; do cmp -s "$d/fwd0_777/$f" "$SB/vf/inputs/vulcan_$M/$f" && s=$((s + 1)); done
    grep -q '06 inputs ok' "$T/k12_06" && [ $s = 3 ] && ok "$M $G: 06's input check passes and its fwd0 links reach the 3 input files" || bad "$M $G: 06 input/link lines: $(tr '\n' ' ' < "$T/k12_06") ($s of 3 reached)"
  done; done
cmp -s "$SB/vf/work/v2/gate100/observe.dat" "$ROT/observe.dat" && cmp -s "$SB/vf/work/v3/gate100/observe.dat" "$MESH/vulcan_v3/inversion/observe.dat" && ok "v2 gates read the rotated observe.dat, v3 gates the unrotated one" || bad "gate observe.dat is not the file B3 names"
runblk "femtic_ctl_set control.dat ITERATION '0 1'" "$SB" "$T/k12_t4" M=v2 N=3
d4=$SB/vf/work/v2/t4
cnt "t4 block: ': OK' lines, then ITERATION" "$(grep -c ': OK$' "$T/k12_t4") $(tail -1 "$T/k12_t4")" "2 0 1"
links "$d4" v2 mesh.dat observe.dat resistivity_block_iter0.dat station_map.csv products.md5
[ -f "$d4/control.dat" ] && [ ! -L "$d4/control.dat" ] && cmp -s "$d4/logs/fwd_rank_mb" "$SB/vf/work/v2/gate100/logs/fwd_rank_mb" && ok "t4: control.dat a copy, fwd_rank_mb from gate100" || bad "t4: control.dat or logs/fwd_rank_mb wrong"
( cd "$d4" && INV_DIR=$PWD && eval "$I04" && femtic_iter_ok . 0 && FWD_MB=auto femtic_mem_model . > /dev/null && echo "04 inputs ok; N_eq $FM_NEQ from $FM_NEQ_SRC; FWD_MB $FM_FWD_MB" ) > "$T/k12_04" 2>&1
grep -qE '^04 inputs ok; N_eq 2847429 from mesh.dat nodes \+ elements.*; FWD_MB 28629$' "$T/k12_04" && ok "04's input check, femtic_iter_ok and femtic_mem_model in t4: $(cat "$T/k12_04")" || bad "04 in t4: $(tr '\n' ' ' < "$T/k12_04")"
cnt "ITERATION of inputs/vulcan_v2/control.dat after the t4 block (untouched)" "$(femtic_ctl_get "$SB/vf/inputs/vulcan_v2/control.dat" ITERATION)" "$(femtic_ctl_get "$MESH/vulcan_v2/inversion/control.dat" ITERATION)"

crit K1.3 "the B4a per-job block misses a report line on a passing 06 report, or passes a failing one; or its binding check or CPU-efficiency check gives the wrong verdict on synthetic OpenMPI binding reports and sacct rows"
job() {  # job NAME REPORT BINDSPEC R T EL CPU -> runs the per-job block in a copy of the c1c2 gate directory, job id 777
  local d=$SB/job_$1; rm -rf "$d"; mkdir -p "$d/logs" "$d/fwd0_777"
  cp "$2" "$d/logs/fwd0_report_777.txt"; cp "$CW/inv_e/logs/halfspace_eval_$J06.txt" "$d/logs/halfspace_eval_777.txt"
  genbind "$3" > "$d/fwd0_777/stdout.txt"
  runblk 'MCW rank' "$d" "$T/k13_$1" J=777 R="$4" T="$5" FAKE_EL="$6" FAKE_CPU="$7"; }
job ok "$REP_OK" "0:0:24 1:24:24 2:48:24" 3 24 00:40:00 1-10:00:00
for s in 'T6 (forward-only): PASS' 'LIMIT rho_a       5 %  : PASS' 'LIMIT phase     1.5 deg: PASS' 'LIMIT diagonal    2 %  : PASS' 'COMPLETENESS: 2520 expected (site, band) pairs, 0 missing' 'RESULT: PASS' 'GATE (half-space, START_RHO=100): PASS' \
         'bindings: 3 lines for 3 ranks; cores per rank: 24 24 24 (want 24); cores bound to two ranks: 0: PASS' 'CPU efficiency 70.8 % = TotalCPU(.batch) 122400 s / (Elapsed 2400 s x 72 cpus): PASS'; do has "$T/k13_ok" "$s"; done
job v3 "$REP_OK" "0:0:36 1:36:36" 2 36 02:10:00 5-04:48:00; has "$T/k13_v3" "cores per rank: 36 36 (want 36); cores bound to two ranks: 0: PASS"; has "$T/k13_v3" "CPU efficiency 80.0 % = TotalCPU(.batch) 449280 s / (Elapsed 7800 s x 72 cpus): PASS"
job gfail "$REP_BAD" "0:0:24 1:24:24 2:48:24" 3 24 00:40:00 1-10:00:00; has "$T/k13_gfail" 'GATE (half-space, START_RHO=100): FAIL'; has "$T/k13_gfail" 'RESULT: FAIL'
for c in "overlap|0:0:24 1:0:24 2:48:24|cores bound to two ranks: 24: FAIL" "onecore|0:0:1 1:1:1 2:2:1|cores per rank: 1 1 1 (want 24)" "missing|0:0:24 2:48:24|bindings: 2 lines for 3 ranks" "wrongT|0:0:36 1:36:36|bindings: 2 lines for 3 ranks" "none||bindings: 0 lines for 3 ranks"; do
  IFS='|' read -r n s w <<< "$c"; job "$n" "$REP_OK" "$s" 3 24 00:40:00 1-10:00:00
  grep -F -- "$w" "$T/k13_$n" | grep -q ': FAIL$' && ok "binding case $n: FAIL ($w)" || bad "binding case $n not failed: $(grep '^bindings' "$T/k13_$n")"; done
for c in "eff33|00:40:00|15:50:00|CPU efficiency 33.0 %|FAIL" "eff4|00:40:00|01:50:00|CPU efficiency 3.8 %|FAIL" "eff50|00:40:00|1-00:00:00|CPU efficiency 50.0 %|PASS" "effdays|1-02:00:00|65-00:00:00|CPU efficiency 83.3 %|PASS"; do
  IFS='|' read -r n el cp w v <<< "$c"; job "$n" "$REP_OK" "0:0:24 1:24:24 2:48:24" 3 24 "$el" "$cp"
  grep -F -- "$w" "$T/k13_$n" | grep -q ": $v\$" && ok "efficiency case $n: $w ... $v" || bad "efficiency case $n: $(grep '^CPU efficiency' "$T/k13_$n"), want '$w ... $v'"; done

crit K1.4 "the band-row pattern does not match exactly the 0.0019947 and 0.0012553 Hz rows of the real evaluator on the WSL v3 bs_lowf run plus an evaluator-formatted 0.0031521 row"
PB=$(rbpat 0031521); echo "  pattern: $PB"
python "$KIT/tools/halfspace_eval.py" 100 "$MESH/vulcan_v3/halfspace/acc_100/bs_lowf" > "$T/lowf.txt" 2>&1
python -c 'f = float("%.6e" % 3.152100e-03); print("%10g %8.3f %9.2f %+6.2f %5.2f %7.2f %+6.2f %5.2f %6.2f %10s %6d  %s" % (f, 1.0, 0, 0, 0, 0, 0, 0, 0, "0/0/0", 120, "PASS"))' >> "$T/lowf.txt"
M=$(grep -E "$PB" "$T/lowf.txt" | awk '{print $1}' | sort | tr '\n' ' '); cnt "rows matched" "$M" "0.0012553 0.0019947 0.0031521 "

crit K1.5 "the first-minutes pattern, run on a 06 job output, misses the half-space gate, memory model, layout rule or launch lines"
P=$(rbpat 'half-space gate'); grep -E "$P" "$CW/inv_e/slurm-06-$J06.out" > "$T/k15"; echo "  pattern: $P"
for s in 'half-space gate: START_RHO=100 ohm-m on ' 'memory model: N_eq' 'memory model: per rank' 'layout rule: ' 'launch: '; do has "$T/k15" "$s"; done

crit K1.6 "the B4b block does not reject a fwd_rank_mb from another job, or its B5 preview (run in inputs/vulcan_<mesh>) does not print 04's rule for the real v2/v3 inputs (N_eq from mesh.dat) with the numbers the runbook's table quotes"
b4b() {  # b4b NAME MESHV GATEJOB WANTJOB FWD R SF
  local g=$SB/vf/work/$2/gate100; mkdir -p "$g/logs"
  echo "$5 job$3 ${6}x$((72 / $6)) peak_rss_kb=na pardiso_kb=na" > "$g/logs/fwd_rank_mb"; cp "$REP_OK" "$g/logs/fwd0_report_$4.txt"
  echo "sbatch=-p icelake -N 1 --ntasks-per-node=$6 --cpus-per-task=$((72 / $6)) --mem=254952M" > "$g/LAYOUT"
  runblk 'femtic_layout_check "$R"' "$SB" "$T/k16_$1" G="$g" J="$4" M="$2" R="$6" SF="$7"; }
b4b v2 v2 777 777 28629 3 20101
for s in 'fwd_rank_mb: 28629 MiB from job777: PASS' 'frequency rows over all ranks: ' 'largest PARDISO in-core need per rank: ' 'forward memory per rank (FWD_MB for 04): ' 'sbatch=-p icelake -N 1 --ntasks-per-node=3 --cpus-per-task=24 --mem=254952M' 'memory model: N_eq 2847429 (mesh.dat nodes + elements'; do has "$T/k16_v2" "$s"; done
b4b v3 v3 778 778 33552 2 21120
for c in "v2 3 28629 43147 0" "v2 3 28629 43147 20101" "v3 2 33552 53820 0" "v3 2 33552 53820 21120"; do
  set -- $c; L=$(femtic_layout_check "$2" "$3" "$4" 254952 95 "$5"); need=$(echo "$L" | sed -E 's/.* = ([0-9]+) MiB <= .*/\1/')
  has "$T/k16_$1" "$L"
  case "$L" in *": OK (up to "*) q="+ $5 extra = $need MiB ...: OK"; grep -qF -- "$q" "$RB" && ok "runbook quotes '$q' ($1)" || bad "runbook lacks '$q' ($1)" ;;
    *) bad "$1 preview is not OK: $L" ;; esac; done
grep -qF '`3 ranks/node x (28629 forward + 43147 sensitivity-step MiB) + 0 extra' "$RB" && grep -qF '`2 ranks/node x (33552 forward + 53820 ...) + 0 extra' "$RB" && ok "table rows name the preview terms" || bad "table rows lack the preview terms"
b4b wrong v2 777 779 28629 3 20101; has "$T/k16_wrong" 'fwd_rank_mb: 28629 MiB from job777: FAIL (want job779)'

crit K1.7 "the B5 after-job block does not judge 04's ps peak / N against 0.8 Z - 1 .. 1.2 Z + 1 MiB (Z read from 04's output), passes an empty Z or ps reading, takes sacct as the primary, lets the sacct cross-check pass outside 10 % of the ps reading, or judges J4 when J4b is set"
Z0=$(awk '/^predicted per rank \(layout rule\): / {for (i = 1; i <= NF; i++) if ($i == "=") print $(i + 1)}' "$OUT04"); echo "  Z in the fake 04 output (read independently): $Z0"
kb() { awk -v z="$1" -v f="$2" -v o="$3" 'BEGIN {printf "%.0f", 3 * (f * z + o) * 1024}'; }   # node-sum KiB for f x Z + o MiB per rank
mb() { awk -v z="$1" -v f="$2" 'BEGIN {printf "%.2fM", 3 * f * z}'; }                          # sacct .batch MaxRSS for f x Z per rank
b5() {  # b5 NAME PS_KB SACCT OUT04 [J4B]: the after-job block in its own work tree; J4=888, J4b=$5 if given
  local w=$SB/b5_$1/work; local d=$w/v2/t4 j=${5:-888}; rm -rf "$SB/b5_$1"; mkdir -p "$d/logs"
  cp "$4" "$d/slurm-t4_v2-$j.out"; [ -n "$2" ] && echo "$2" > "$d/logs/peak_rss_kb_$j"
  if [ -n "$5" ]; then cp "$OUT04" "$d/slurm-t4_v2-888.out"; echo 1 > "$d/logs/peak_rss_kb_888"; fi
  runblk 'judging job $JT' "$SB" "$T/k17_$1" WK="$w" M=v2 N=3 J4=888 ${5:+J4b=$5} FAKE_RSS="$3" FAKE_EL=03:00:00 FAKE_CPU=6-00:00:00; }
pl() { grep -E "^per rank, 04 ps peak / N: .* x Z $2 MiB .*: $3\$" "$T/k17_$1" > /dev/null; }
xl() { grep -E "^cross-check, sacct MaxRSS\(\.batch\) / N: .*: $2\$" "$T/k17_$1" > /dev/null; }
for c in "mid|1 0|PASS" "lo_in|0.8 -0.5|PASS" "lo_out|0.8 -1.5|FAIL" "hi_in|1.2 0.5|PASS" "hi_out|1.2 1.5|FAIL"; do
  IFS='|' read -r n fo v <<< "$c"; set -- $fo; b5 "$n" "$(kb "$Z0" $1 $2)" "$(mb "$Z0" $1)" "$OUT04"
  pl "$n" "$Z0" "$v" && ok "ps case $n ($1 x Z $2 MiB): $v" || bad "ps case $n: $(grep '^per rank' "$T/k17_$n"), want $v"; done
b5 nops "" "$(mb "$Z0" 1)" "$OUT04"; pl nops "$Z0" FAIL && ok "no ps reading: FAIL" || bad "no ps reading: $(grep '^per rank' "$T/k17_nops")"
grep -v '^predicted per rank' "$OUT04" > "$T/out04_noZ"; b5 noz "$(kb "$Z0" 1 0)" "$(mb "$Z0" 1)" "$T/out04_noZ"
grep -q '^per rank, 04 ps peak.*: FAIL$' "$T/k17_noz" && ok "no Z line: FAIL" || bad "no Z line: $(grep '^per rank' "$T/k17_noz")"
b5 none "" "" "$T/out04_noZ"; grep -q '^per rank, 04 ps peak.*: FAIL$' "$T/k17_none" && ok "no Z line and no ps reading: FAIL" || bad "no Z and no ps: $(grep '^per rank' "$T/k17_none")"
b5 prim "$(kb "$Z0" 1 0)" "$(mb "$Z0" 0.75)" "$OUT04"; pl prim "$Z0" PASS && xl prim FAIL && ok "ps 1.0 Z, sacct 0.75 Z: primary PASS, cross-check FAIL" || bad "primary/cross-check: $(grep -E '^(per rank|cross)' "$T/k17_prim" | tr '\n' ' ')"
for c in "x_in|1.09|PASS" "x_hi|1.15|FAIL" "x_lo|0.85|FAIL"; do IFS='|' read -r n f v <<< "$c"; b5 "$n" "$(kb "$Z0" 1 0)" "$(mb "$Z0" $f)" "$OUT04"
  xl "$n" "$v" && ok "cross-check sacct $f x ps: $v" || bad "cross-check $n: $(grep '^cross' "$T/k17_$n"), want $v"; done
b5 x_none "$(kb "$Z0" 1 0)" "" "$OUT04"; xl x_none FAIL && ok "no sacct MaxRSS: cross-check FAIL" || bad "no sacct: $(grep '^cross' "$T/k17_x_none")"
for s in 'judging job 888 with N=3 ranks per node' 'OUTCOME: ' '--- sizing report ---' 'N_iv (right-hand sides per interpolator solve): measured' 'sensitivity scratch used' 'CPU efficiency 66.7 % = TotalCPU(.batch) 518400 s / (Elapsed 10800 s x 72 cpus): PASS' 'fake rcstat 888'; do has "$T/k17_mid" "$s"; done
Z2=$((Z0 + 1000)); sed "s/^\(predicted per rank (layout rule): .* = \)$Z0 MiB;/\1$Z2 MiB;/" "$OUT04" > "$T/out04_z2"
b5 jt "$(kb "$Z2" 1 0)" "$(mb "$Z2" 1)" "$T/out04_z2" 999; pl jt "$Z2" PASS && has "$T/k17_jt" 'judging job 999 with N=3' || bad "J4b=999 set: the block did not judge job 999 against its Z $Z2: $(grep -E '^(judging|per rank)' "$T/k17_jt" | tr '\n' ' ')"
P=$(rbpat tmpfs); grep -E "$P" "$OUT04" > "$T/k17c"; for s in 'memory model: N_eq' 'layout rule: ' 'launch: '; do has "$T/k17c" "$s"; done
A=$(grep -o "grep -A1 'df -hT[^']*'" "$RB" | head -1 | sed "s/^grep -A1 '//; s/'\$//"); cnt "df line + its data line" "$(grep -A1 -F "$A" "$OUT04" | grep -c .)" 2

crit K1.8 "the B1 and B2 DONE-line commands, run as written, miss 01's DONE line when 'next:' lines follow it, or accept a failed test (T1=FAIL, T5=FAIL); or B1.5's required block (the one printing 'installed lib identical') lacks the install before its cmp or runs 01_build_femtic.sh; or the optional rebuild block does not take md5sum \$BIN/femtic \$BIN/femtic_env.sh before and after 01_build_femtic.sh"
C1=$(blk 'BUILD DONE  T1=PASS' | grep -F 'BUILD DONE  T1=PASS' | head -1); C2=$(blk 'SMOKE_ONLY DONE  T1=PASS  T2=PASS' | grep -F 'SMOKE_ONLY DONE' | grep -F 'grep -cE' | head -1)
echo "  B1: $C1"; echo "  B2: $C2"
b1() { ( BL=$1; eval "$C1" ) 2>&1 | tail -1; }
b2() { local d=$T/b2run; rm -rf "$d"; mkdir -p "$d"; cp "$1" "$d/slurm-femtic_smoke-555.out"; ( cd "$d" && JS=555 && eval "$C2" ) 2>&1 | tail -1; }
BL=$KIT/build_foss_20260925_181212.log
cnt "B1 command on the real 09-25 build log (DONE line followed by a next: line)" "$(b1 "$BL")" 1
cnt "  its last line holds T1=PASS (the old 'last line' criterion)" "$(tail -1 "$BL" | grep -c 'T1=PASS')" 0
sed 's/BUILD DONE  T1=PASS/BUILD DONE  T1=FAIL/' "$BL" > "$T/bl_t1fail"; cnt "B1 command on the same log with T1=FAIL" "$(b1 "$T/bl_t1fail")" 0
sed -n '/ DONE  T1=\$T1  T2=\$T2  T5=\$T5/,/^\[ "\$T1" = PASS \]/p' "$KIT/01_build_femtic.sh" | sed '$d' > "$T/done01.sh"
cnt "01's DONE echo plus its next: lines extracted" "$(grep -c 'next:' "$T/done01.sh")" 1
for c in "PASS|1" "INCONCLUSIVE|1" "FAIL|0"; do v=${c%|*}
  ( SMOKE_ONLY=1 T1=PASS T2=PASS T5=$v LOG=/x/smoke_foss_1.log; . "$T/done01.sh" ) > "$T/smoke_$v"
  cnt "B2 command on 01's own SMOKE_ONLY output with T5=$v ($(wc -l < "$T/smoke_$v" | tr -d ' ') lines)" "$(b2 "$T/smoke_$v")" "${c#*|}"; done
( SMOKE_ONLY=1 T1=FAIL T2=PASS T5=PASS LOG=/x/l; . "$T/done01.sh" ) > "$T/smoke_t1"; cnt "B2 command with T1=FAIL" "$(b2 "$T/smoke_t1")" 0
hasnt "$RB" 'last line'
BI=$(blk 'installed lib identical')   # B1.5's required block; the rebuild block above it is optional
grep -qF 'install -m 644 $PLAN/femtic_lib.sh $BIN/' <<< "$BI" && ok "B1.5 install block installs femtic_lib.sh" || bad "B1.5 install block has no 'install -m 644 \$PLAN/femtic_lib.sh \$BIN/'"
awk '/^install -m 644 \$PLAN\/femtic_lib.sh/ {i = NR} /^cmp \$PLAN\/femtic_lib.sh \$BIN\/femtic_lib.sh/ {c = NR} END {exit !(i && c && i < c)}' <<< "$BI" && ok "the install comes before the cmp" || bad "install/cmp order"
grep -q '01_build_femtic.sh' <<< "$BI" && bad "B1.5 install block runs 01_build_femtic.sh (the rebuild is optional)" || ok "B1.5 install block does not rebuild"
blk 'BUILD DONE  T1=PASS' | awk '/^md5sum \$BIN\/femtic \$BIN\/femtic_env.sh/ {if (!b) m1 = NR; else m2 = NR} /01_build_femtic\.sh/ {b = NR} END {exit !(m1 && b && m2)}' && ok "rebuild block: md5sum of femtic and femtic_env.sh before and after 01_build_femtic.sh" || bad "rebuild block lacks md5sum \$BIN/femtic \$BIN/femtic_env.sh before or after the build"

crit K1.9 "the B1.3 CR count does not cover exactly the files of the B1.1 manifest: it counts a file outside the upload, or misses a CR in one inside it"
C=$(grep -F "grep -c \$'" "$RB" | head -1 | sed 's/ | tee .*//'); echo "  command: $C"
# Git Bash grep strips CR from text lines unless -U (so grep -c $'\r' is always 0 there); Phoenix's Linux grep does not.
GB=$T/lingrep; mkdir -p "$GB"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) { echo '#!/bin/bash'; echo 'exec /usr/bin/grep -U "$@"'; } > "$GB/grep"; chmod +x "$GB/grep" ;; esac
R=$SB/crP; mkdir -p "$R/hpc/phoenix_plan"; printf 'a\n' > "$R/hpc/phoenix_plan/f1.sh"; printf 'b\n' > "$R/hpc/phoenix_plan/f2.slurm"
printf 'old\r\n' > "$R/hpc/phoenix_plan/00_discover.sh"
( cd "$R" && md5sum hpc/phoenix_plan/f1.sh hpc/phoenix_plan/f2.slurm > hpc/phoenix_plan/UPLOAD_2026-09-28.md5 )
( cd "$R" && PATH="$GB:$PATH" && eval "$C" ) > "$T/k19a" 2>&1
cnt "clean upload, CR only in the unlisted 00_discover.sh: lines ':0'" "$(grep -c ':0$' "$T/k19a")" 2
hasnt "$T/k19a" '00_discover'
printf 'a\r\n' > "$R/hpc/phoenix_plan/f1.sh"; ( cd "$R" && PATH="$GB:$PATH" && eval "$C" ) > "$T/k19b" 2>&1
has "$T/k19b" 'hpc/phoenix_plan/f1.sh:1'

crit K1.10 "the N_iv 840 rerun block, run as written with a fake sbatch, does not submit 04 from t4 with NIV=840 at 2 x 36, set J4b and append it to the ledger; or it writes a ledger line when sbatch fails; or the copy-back block does not take J4b when it is set and J4 when it is not"
w=$SB/k110/work; d=$w/v2/t4; mkdir -p "$d/logs"
RB_APPEND='echo "J4b=[$J4b]"' runblk 'NIV=840 $PLAN/04_inversion.slurm' "$SB" "$T/k110a" WK="$w" M=v2 LEDGER="$SB/k110/ledger" FAKE_JOBID=999 FAKE_SBATCH_LOG="$SB/k110/sbatch.log"
has "$T/k110a" 'J4b=[999]'
cnt "ledger lines '999 B5 t4_v2 NIV=840 2x36 <date>'" "$(grep -cE '^999 B5 t4_v2 NIV=840 2x36 [0-9-]+_[0-9:]+$' "$SB/k110/ledger" 2>/dev/null)" 1
grep -qE "^cwd=.*/k110/work/v2/t4 args=.*--ntasks-per-node=2 --cpus-per-task=36 .*--export=ALL,WATCH_S=10,NIV=840 .*/04_inversion.slurm\$" "$SB/k110/sbatch.log" && ok "sbatch: 04 from t4, 2 x 36, NIV=840" || bad "sbatch call: $(cat "$SB/k110/sbatch.log")"
RB_APPEND='echo "J4b=[$J4b]"' runblk 'NIV=840 $PLAN/04_inversion.slurm' "$SB" "$T/k110b" WK="$w" M=v2 LEDGER="$SB/k110/ledger" FAKE_JOBID= FAKE_SBATCH_LOG=/dev/null
cnt "failed sbatch: ledger lines, J4b, message" "$(wc -l < "$SB/k110/ledger" | tr -d ' ') $(grep -c 'J4b=\[\]' "$T/k110b") $(grep -c 'no job id: sbatch failed' "$T/k110b")" "1 1 1"
for j in 888 999; do for f in slurm-t4_v2-$j.out logs/sacct_$j.txt logs/rcstat_$j.txt logs/peak_rss_kb_$j logs/control.dat.before_$j logs/control.dat.used_$j logs/COMPLETED_$j; do echo "$j" > "$d/$f"; done; done
echo x > "$d/job_outcomes.tsv"; echo x > "$d/femtic_0.log"; echo x > "$d/femtic.cnv"
runblk 'mkdir -p $P/export/B5_$JT' "$SB" "$T/k110c" WK="$w" M=v2 J4=888 J4b=999
[ -f "$SB/P/export/B5_999/slurm-t4_v2-999.out" ] && [ ! -e "$SB/P/export/B5_888" ] && [ "$(ls "$SB/P/export/B5_999" | wc -l)" -ge 10 ] && ok "copy-back with J4b=999: export/B5_999 ($(ls "$SB/P/export/B5_999" | wc -l) files)" || bad "copy-back with J4b set: $(ls "$SB/P/export" | tr '\n' ' ')"
runblk 'mkdir -p $P/export/B5_$JT' "$SB" "$T/k110d" WK="$w" M=v2 J4=888
[ -f "$SB/P/export/B5_888/slurm-t4_v2-888.out" ] && ok "copy-back without J4b: export/B5_888" || bad "copy-back without J4b: $(ls "$SB/P/export" | tr '\n' ' ')"

fi   # K1

# ---------------- K2: every output string the runbook quotes is printed by the script it names (static text in the source)
if want K2; then
crit K2.1 "a string quoted in the runbook is absent from the runbook (list drift) or its static source text is absent from the script"
S01=$KIT/01_build_femtic.sh; S03=$KIT/03_mesh.slurm; S04=$KIT/04_inversion.slurm; S05=$KIT/05_chain.sh; S06=$KIT/06_forward_only.slurm
SLIB=$KIT/femtic_lib.sh; SEV=$KIT/tools/halfspace_eval.py; SC12=$KIT/tests/c1c2_test.sh; SPT=$KIT/tests/portability_test.sh
while IFS='|' read -r rbtext src srctext; do
  [ -z "$rbtext" ] && continue
  src=$(eval echo "$src")
  if ! grep -qF -- "$rbtext" "$RB"; then bad "runbook lacks '$rbtext'"; continue; fi
  if grep -qF -- "$srctext" "$src"; then ok "'$rbtext' <- $(basename "$src")"; else bad "'$srctext' not in $(basename "$src") (runbook quotes '$rbtext')"; fi
done <<'LIST'
T1 (linkage): PASS|$S01|echo "T1 (linkage): $T1"
SMOKE_ONLY DONE  T1=PASS  T2=PASS  T5=PASS   log:|$S01| DONE  T1=$T1  T2=$T2  T5=$T5   log: $LOG
BUILD DONE  T1=PASS  T2=SKIPPED  T5=SKIPPED   log:|$S01|T2=SKIPPED; T5=SKIPPED
T2 (smoke run): PASS    T5 (restart equivalence): PASS    work dir:|$S01|T2 (smoke run): $T2    T5 (restart equivalence): $T5    work dir:
relative misfit difference|$S01|relative misfit difference %.3e (tolerance %s)
-- iteration-0 row (compare with the WSL build of the same example; expect >= 6 equal significant digits):|$S01|-- iteration-0 row (compare with the WSL build of the same example; expect >= 6 equal significant digits):
femtic.cnv.leg2|$S01|cp "$1/femtic.cnv" "$1/femtic.cnv.$2"
femtic_0.log.straight|$S01|cp "$1/femtic_0.log" "$1/femtic_0.log.$2"
sbatch --parsable -p icelake -N 1 -n 4 --mem=8G --time=00:30:00 -J femtic_smoke -o slurm-%x-%j.out|$S01|sbatch -p icelake -N 1 -n 4 --mem=8G --time=00:30:00 -J femtic_smoke -o slurm-%x-%j.out
half-space gate: START_RHO=100 ohm-m on 65341 blocks, 1 block(s) of >= 1e6 ohm-m (air) kept; blocks off START_RHO after re-reading: 0|$S06|half-space gate: START_RHO=$START_RHO ohm-m on $NSET blocks, $NKEEP block(s) of >= 1e6 ohm-m (air) kept; blocks off START_RHO after re-reading: $NBAD
launch: mpirun -np 3 --map-by ppr:3:node:PE=24 --bind-to core --report-bindings|$SLIB|FEMTIC_LAUNCH=(mpirun -np "$n" --map-by "ppr:${rpn}:node:PE=${t}" --bind-to core --report-bindings "$exe")
fwd0_<jobid>/stdout.txt|$S06|"${FEMTIC_LAUNCH[@]}" > "$W/stdout.txt" 2>&1 &
T6 (forward-only): PASS|$S06|T6 (forward-only): $T6
GATE (half-space, START_RHO=100): PASS|$S06|GATE (half-space, START_RHO=$START_RHO): $GATE
COMPLETENESS: 2520 expected (site, band) pairs, 0 missing|$SEV|COMPLETENESS: %d expected (site, band) pairs, %d missing
frequency rows over all ranks: N (must equal F = 21)|$S06|frequency rows over all ranks: $NROWS (must equal F = 
forward phase wall time for this layout (slowest rank): T s|$S06|forward phase wall time for this layout (slowest rank): ${TFWD:-?} s
largest PARDISO in-core need per rank: X GiB (Y KB)|$S06|largest PARDISO in-core need per rank: ${PGB:-?} GiB (${PKB:-?} KB)
peak summed RSS of femtic processes on the node|$S06|peak summed RSS of femtic processes on the node
forward memory per rank (FWD_MB for 04): W MiB|$S06|forward memory per rank (FWD_MB for 04): $FWD_MEAS MiB
node, sensitivity step with this layout|$S06|node, sensitivity step with this layout and the forward memory measured here
pessimistic N_iv = |$S06|pessimistic N_iv = 4 x
logs/fwd0_report_$J.txt|$S06|logs/fwd0_report_$SLURM_JOB_ID.txt
logs/halfspace_eval_$J|$S06|logs/halfspace_eval_$SLURM_JOB_ID.txt
second field is not `job<id of the 100 ohm-m job>`|$S06|echo "$FWD_MEAS job$SLURM_JOB_ID ${RPN}x$NTHR
sbatch=-p icelake -N 1 --ntasks-per-node=3 --cpus-per-task=24|$S06|LSB="${SLURM_JOB_PARTITION:+-p $SLURM_JOB_PARTITION }-N $NNODES --ntasks-per-node=$(( NTASKS / NNODES )) --cpus-per-task=$CPT --mem=${NODE_MEM}M"
fwd0_$J/result_*_iter0.csv|$SEV|result_*_iter0.csv
--- sizing report ---|$S04|--- sizing report ---
predicted per rank (layout rule): <FWD_MB> forward + <NONPARDISO_MB> sensitivity-step = Z MiB|$S04|predicted per rank (layout rule): $FM_FWD_MB forward + $FM_NONP_MB sensitivity-step = $(( FM_FWD_MB + FM_NONP_MB )) MiB;
peak summed RSS of the node's femtic processes (sampled every 10 s): X GB|$S04|peak summed RSS of the node's femtic processes (sampled every $WATCH_S s): 
WARNING: measured N_iv 840 differs from the 480|$S04|WARNING: measured N_iv $NIV_MEAS differs from the $FM_NIV
df -hT sense dir|$S04|--- df -hT sense dir
WARNING: ... tmpfs|$S04|WARNING: $SENSE_DIR is tmpfs (RAM-backed): its sensitivity files, $SF MiB per iteration
OUT-OF-CORE|$S04|PARDISO ran OUT-OF-CORE
oversubscribed|$S04|(oversubscribed)
ranks > ... frequencies|$S04|ranks > $NF frequencies
logs/run_<stamp>/|$S04|PREV="logs/run_$(date -r femtic_0.log
now takes N_eq from them|$SLIB|FM_NEQ=$(femtic_log_neq "$d"/femtic_*.log "$d"/fwd0_*/femtic_*.log "$d"/logs/run_*/femtic_*.log)
N_eq = mesh.dat nodes + elements|$SLIB|FM_NEQ_SRC="mesh.dat nodes + elements (
logs/peak_rss_kb_$JT|$S04|FEMTIC_RSS_FILE="logs/peak_rss_kb_$SLURM_JOB_ID"
logs/control.dat.before_$JT|$S04|logs/control.dat.before_$SLURM_JOB_ID
logs/control.dat.used_$JT|$S04|logs/control.dat.used_$SLURM_JOB_ID
logs/COMPLETED_$JT|$S04|logs/COMPLETED_$SLURM_JOB_ID
WATCH_S=10|$S04|WATCH_S=${WATCH_S:-60}
NIV=840|$S04|NIV=${NIV:-auto}
--time=12:00:00|$KIT/README_phoenix.md|sbatch --time=12:00:00 $PLAN/04_inversion.slurm
--gres=tmpfs:200G|$S04|#SBATCH --gres=tmpfs:200G
`--time=04:00:00` is also the 06 header's value|$S06|#SBATCH --time=04:00:00
the 06 header's 4 h is sized for v3 at|$S06|#SBATCH --ntasks-per-node=2
--signal=B:USR1@600|$S06|#SBATCH --signal=B:USR1@600
hard stop 5 min before the|$S06|WALL_MARGIN_MIN=${WALL_MARGIN_MIN:-5}
Solve phase is performed simultaneously|$SLIB|# Solve phase is performed simultaneously for [0-9]+ right-hand sides
needs FEMTIC_LIB_VERSION >= 4` (01 SMOKE_ONLY, 03, 04, 05, 06)|$S06|[ "${FEMTIC_LIB_VERSION:-0}" -ge 4 ] || { echo "ERROR: $BIN/femtic_lib.sh is version ${FEMTIC_LIB_VERSION:-unset}; this script needs FEMTIC_LIB_VERSION >= 4
needs FEMTIC_LIB_VERSION >= 4` (01 SMOKE_ONLY, 03, 04, 05, 06)|$S04|[ "${FEMTIC_LIB_VERSION:-0}" -ge 4 ] || { echo "ERROR: $BIN/femtic_lib.sh is version ${FEMTIC_LIB_VERSION:-unset}; this script needs FEMTIC_LIB_VERSION >= 4
needs FEMTIC_LIB_VERSION >= 4` (01 SMOKE_ONLY, 03, 04, 05, 06)|$S05|[ "${FEMTIC_LIB_VERSION:-0}" -ge 4 ] || { echo "ERROR: $BIN/femtic_lib.sh is version ${FEMTIC_LIB_VERSION:-unset}; this script needs FEMTIC_LIB_VERSION >= 4
needs FEMTIC_LIB_VERSION >= 4` (01 SMOKE_ONLY, 03, 04, 05, 06)|$S01|[ "${FEMTIC_LIB_VERSION:-0}" -ge 4 ] || die "SMOKE_ONLY: $BIN/femtic_lib.sh is version ${FEMTIC_LIB_VERSION:-unset}; this script needs FEMTIC_LIB_VERSION >= 4
needs FEMTIC_LIB_VERSION >= 4` (01 SMOKE_ONLY, 03, 04, 05, 06)|$S03|[ "${FEMTIC_LIB_VERSION:-0}" -ge 4 ] || { echo "ERROR: $BIN/femtic_lib.sh is version ${FEMTIC_LIB_VERSION:-unset}; this script needs FEMTIC_LIB_VERSION >= 4
layout REFUSED|$S06|ERROR: layout REFUSED
layout REFUSED|$S04|ERROR: layout REFUSED
FEMTIC_LIB_VERSION=4|$SLIB|FEMTIC_LIB_VERSION=4
(f1 real-log case skipped: ...)|$SC12|(f1 real-log case skipped: $REAL not readable here)
PASS R1 python 3.6.8 RESULT (PASS)|$SPT|eq "R1 python $v RESULT"
`command -v python3.6` printed a path|$SPT|for p in python3.6 ${PYTHON_OLD:-}; do command -v "$p" > /dev/null 2>&1 && PYS+=("$p"); done
module load Python/3.13.5-GCCcore-14.3.0|$KIT/discovery/phoenix_discovery_p2-log-2_2026-09-25.txt|Python/3.13.5-GCCcore-14.3.0
femtic_ctl_set control.dat ITERATION '0 1'|$SLIB|femtic_ctl_set() {
(`femtic_ctl_set`, `sed -i`)|$SLIB|    sed -i -E "/^${k}([[:space:]]|\$)/{n;s|.*|${v}|}" "$f"
It installs `femtic_lib.sh` (01:414)|$S01|install -m 644 "$PLAN_DIR/femtic_lib.sh" "$BIN/femtic_lib.sh"
ps -C femtic -o rss=|$SLIB|rss=$(ps -C femtic -o rss= 2>/dev/null | awk '{s += $1} END {print s + 0}')
WATCH_S` = 10 s|$S04|FEMTIC_WATCH_S="$WATCH_S"
PLAN=$P/hpc/phoenix_plan|$S06|PLAN=${PLAN:-/hpcfs/users/$USER/FEMTIC_2026/hpc/phoenix_plan}
BIN=/hpcfs/users/a1690074/femtic/bin|$S06|BIN=${BIN:-/hpcfs/users/$USER/femtic/bin}
PORTED=$P/hpc/ported|$S01|pass PORTED=/hpcfs/users/$USER/FEMTIC_2026/hpc/ported
refused before any `sbatch`: no `LAYOUT` and no explicit layout|$S05|copy the LAYOUT file of the directory where 06 passed
LIST
crit K2.2 "the c1c2 counts in the runbook (128 on Phoenix, 129 on the PC) differ from the checks tests/c1c2_test.sh runs without the WSL log, plus its one skipped real-log case"
N=$(awk '/^SUMMARY:/ {print $2 + $4}' "$CD/run.txt"); F=$(awk '/^SUMMARY:/ {print $4}' "$CD/run.txt"); S=$(grep -c '(f1 real-log case skipped' "$CD/run.txt")
cnt "c1c2 failures as run on Phoenix" "$F" 0; cnt "skipped real-log cases" "$S" 1
grep -qF "SUMMARY: $N passed, 0 failed" "$RB" && ok "runbook quotes SUMMARY: $N passed" || bad "runbook does not quote 'SUMMARY: $N passed, 0 failed'"
grep -qF "runs $((N + S)) checks" "$RB" && ok "runbook gives the PC count $((N + S))" || bad "runbook lacks 'runs $((N + S)) checks'"
crit K2.3 "the generated femtic_env.sh would not hold exactly one femtic_apps_remap line (runbook B1.5 expects grep -c = 1)"
N=$(sed -n '/^  echo "# generated by 01_build_femtic.sh/,/^} > "\$BIN\/femtic_env.sh"/p' "$S01" | grep -c 'femtic_apps_remap'); cnt "femtic_env.sh lines with femtic_apps_remap" "$N" 1
crit K2.4 "tests/portability_test.sh, run here with two interpreters (PYTHON and PYTHON_OLD, as B1.4 on Phoenix without python3.6), does not print 'SUMMARY: 10 passed, 0 failed', or the runbook's 10 and 14 (python3.6 on PATH too) are not 2 + 4 x the interpreters"
command -v python3.6 > /dev/null 2>&1 && echo "  note: python3.6 is on PATH here, so the run below has 3 interpreters"
PY=""; for p in python python3; do "$p" -c 'import sys; sys.exit(sys.version_info < (3, 8))' 2>/dev/null && { PY=$p; break; }; done
( WORK=$T/port PYTHON=$PY PYTHON_OLD=$PY bash "$KIT/tests/portability_test.sh" "$KIT" ) > "$T/port.txt" 2>&1; echo "  exit=$? $(grep '^SUMMARY' "$T/port.txt")"
NR1=$(grep -c '^  eq "R1 python \$v ' "$SPT"); NB=$(grep -cE '^eq "B1 |^  eq "P1 ' "$SPT")
cnt "R1 checks per interpreter, B1 + P1 checks" "$NR1 $NB" "4 2"
N2=$((NB + 2 * NR1)); N3=$((NB + 3 * NR1)); I=$(command -v python3.6 > /dev/null 2>&1 && echo 3 || echo 2)
grep -q "^SUMMARY: $((NB + I * NR1)) passed, 0 failed" "$T/port.txt" && ok "portability_test here: $(grep '^SUMMARY' "$T/port.txt" | cut -c1-40)" || bad "portability_test here: $(grep -E '^SUMMARY|  FAIL' "$T/port.txt" | head -3 | tr '\n' ' ')"
grep -qF "\`SUMMARY: $N2 passed, 0 failed\`" "$RB" && grep -qF "\`SUMMARY: $N3 passed, 0 failed\`" "$RB" && ok "runbook quotes $N2 and $N3" || bad "runbook lacks 'SUMMARY: $N2 passed, 0 failed' / '... $N3 ...'"
crit K2.5 "01 SMOKE_ONLY or 03 accepts a version-3 femtic_lib.sh: each must exit 1 with 'needs FEMTIC_LIB_VERSION >= 4' before anything runs (the fake femtic and mpirun record any call)"
B3L=$T/bin_v3; SRC3=$T/src_v3; mkdir -p "$B3L" "$SRC3/femtic/examples/INV_MT_01/Tetra"
for f in control.dat mesh.dat observe.dat resistivity_block_iter0.dat; do : > "$SRC3/femtic/examples/INV_MT_01/Tetra/$f"; done
sed 's/^FEMTIC_LIB_VERSION=.*/FEMTIC_LIB_VERSION=3/' "$SLIB" > "$B3L/femtic_lib.sh"
printf 'export PATH=%s:$PATH FEMTIC_TOOLCHAIN=foss FEMTIC_BIN=%s\n. %s/femtic_lib.sh\n' "$B3L" "$B3L" "$B3L" > "$B3L/femtic_env.sh"
for x in femtic mpirun makeTetraMesh tetgen makeMtr TetGen2Femtic; do printf '#!/bin/bash\necho "%s $PWD" >> %s/calls.txt\nexit 1\n' "$x" "$T" > "$B3L/$x"; done; chmod +x "$B3L"/*
( cd "$T" && env "PATH=$B3L:$PATH" SRC="$SRC3" BIN="$B3L" SMOKE_ONLY=1 TOOLCHAIN=foss timeout 300 bash "$S01" > "$T/k25_01.out" 2>&1 ); r1=$?
( cd "$T" && env "PATH=$B3L:$PATH" BIN="$B3L" SLURM_JOB_ID=902 MESHDIR="$T/mesh03" INVDIR="$T/inv03" timeout 300 bash "$S03" > "$T/k25_03.out" 2>&1 ); r3=$?
sleep 1; cat "$SRC3"/smoke_foss_*.log >> "$T/k25_01.out" 2>/dev/null
cnt "01 SMOKE_ONLY / 03 exit with a version-3 library" "$r1 $r3" "1 1"
for x in 01 03; do grep -q 'needs FEMTIC_LIB_VERSION >= 4' "$T/k25_$x.out" && ok "$x: 'needs FEMTIC_LIB_VERSION >= 4'" || bad "$x: $(grep -m2 -E 'ERROR|needs' "$T/k25_$x.out" | tr '\n' ' ')"; done
cnt "fake femtic/mpirun/mesh-tool calls" "$(cat "$T/calls.txt" 2>/dev/null | wc -l | tr -d ' ')" 0

fi   # K2
# ---------------- K3: numbers in the runbook, recomputed with the kit's own functions and the WSL logs
if want K3; then
grp() { echo "$1" | sed -E ':a; s/([0-9])([0-9]{3})($|,)/\1,\2\3/; ta'; }   # 2847429 -> 2,847,429
crit K3.1 "N_eq, NONPARDISO_MB and the tmpfs term the runbook gives for B5 differ from what 04 computes in a t4 directory (femtic_mem_model on the real inputs, 04's own tmpfs awk formula)"
read -r NMT ND < <(femtic_obs_counts "$MESH/vulcan_v2/inversion/observe.dat" 2>/dev/null)
for v in 2 3; do D=$MESH/vulcan_v$v/inversion
  read -r _ _ _ MM XX < <(femtic_block_stats "$D/resistivity_block_iter0.dat"); read -r VN VE < <(femtic_mesh_counts "$D/mesh.dat")
  ( NIV=auto NEQ=auto NONPARDISO_MB=auto FWD_MB=1; femtic_mem_model "$D" > /dev/null; echo "$FM_NEQ $FM_NONP_MB $FM_M" ) > "$T/fm$v"
  read -r NEQ NONP M < "$T/fm$v"
  NEQL=$(femtic_log_neq "$MESH"/vulcan_v$v/halfspace/acc_*/b*/femtic_0.log); SL=$(femtic_sens_mem_mb "$NEQL" 480 "$M" $((8 * NMT)))
  SF=$(awk -v nd="$ND" -v m="$M" -v meth="$(femtic_ctl_get "$D/control.dat" INV_METHOD | awk '{print $1}')" "$(grep -o "'BEGIN {b = nd \* m[^']*'" "$S04" | tr -d "'")")
  eval "NEQ$v=$NEQ NONP$v=$NONP M$v=$M X$v=$XX SL$v=$SL SF$v=$SF NEQL$v=$NEQL"
  echo "  v$v: mesh $VN + $VE = $NEQ (04), logged $NEQL; NONPARDISO_MB $NONP (04) vs $SL (logged N_eq); M $M + $XX fixed; tmpfs term $SF MiB"
  [ "$NEQ" = $((VN + VE)) ] && grep -qF "$(grp "$NEQ")" "$RB" && ok "v$v N_eq $NEQ in the runbook" || bad "v$v N_eq $NEQ (mesh.dat nodes + elements) not in the runbook"
  for x in "$(echo "$NONP" | sed -E 's/([0-9])([0-9]{3})$/\1,\2/') MiB" "$(echo "$SF" | sed -E 's/([0-9])([0-9]{3})$/\1,\2/') MiB"; do grep -qF -- "$x" "$RB" && ok "v$v '$x' in the runbook" || bad "v$v '$x' missing from the runbook"; done
  [ $((NONP - SL)) = "$(case $v in 2) echo 38 ;; 3) echo 37 ;; esac)" ] && [ $((NEQ - NEQL)) = 2557 ] && ok "v$v mesh vs logged N_eq: +$((NEQ - NEQL)) equations, +$((NONP - SL)) MiB" || bad "v$v differences $((NEQ - NEQL)) / $((NONP - SL))"
done
grep -qF "on $M2 blocks, $X2 block(s)" "$RB" && grep -qF "expect \`$M3 blocks\`" "$RB" && ok "block counts v2 $M2 + $X2, v3 $M3" || bad "block counts $M2/$X2/$M3 not in the runbook"
crit K3.2 "the 06 pre-launch layout lines quoted for the gate jobs are not what femtic_fwd_mb_auto + femtic_layout_check print for the real inputs in a directory without logs"
mkdir -p "$T/empty"
for c in "2 3" "3 2"; do set -- $c; eval "NEQ=\$NEQ$1 NONP=\$NONP$1"
  FW=$(femtic_fwd_mb_auto "$T/empty" "$NEQ" | awk '{print $1}'); L=$(femtic_layout_check "$2" "$FW" "$NONP" 254952); Q=${L%%: OK*}
  case "$L" in *": OK (up to "*) grep -qF -- "\`$Q: OK ...\`" "$RB" && ok "v$1: '$Q: OK'" || bad "v$1: kit prints '$L'; runbook does not quote '$Q: OK ...'" ;; *) bad "v$1 pre-launch not OK: $L" ;; esac; done

crit K3.3 "the B5 Z values, PASS bands (0.8 Z - 1 to 1.2 Z + 1 MiB; integer edges rounded inwards, and unrounded), N_iv 840 figures or forward-memory expectations differ from the WSL PARDISO lines + 04's rule"
for c in "2 3 $MESH/vulcan_v2/halfspace/acc_3" "3 2 $MESH/vulcan_v3/halfspace/acc_100"; do set -- $c; eval "NONP=\$NONP$1 NEQL=\$NEQL$1 M=\$M$1"
  K=$(femtic_pardiso_kb "$3"/b*/femtic_0.log); F=$(awk -v k="$K" 'BEGIN {x = k * 1.25 / 1024; n = int(x); if (n < x) n++; print n}')
  Z=$((F + NONP)); B=$(awk -v z="$Z" 'BEGIN {l = 0.8 * z - 1; h = 1.2 * z + 1; a = int(l); if (a < l) a++; printf "%d-%d", a, int(h)}')
  BI=$(echo "$B" | sed -E 's/([0-9])([0-9]{3})(-|$)/\1,\2\3/g'); BU=$(awk -v z="$Z" 'BEGIN {printf "%.1f-%.1f", 0.8 * z - 1, 1.2 * z + 1}' | sed -E 's/([0-9])([0-9]{3})\./\1,\2./g')
  S840=$(femtic_sens_mem_mb "$NEQL" 840 "$M" $((8 * NMT))); Z840=$((F + S840))
  echo "  v$1: PARDISO $K KB -> FWD_MB $F; Z = $F + $NONP = $Z; band $B ($BU); N_iv 840 rerun: $F + $S840 = $Z840"
  for s in "about $(grp "$F")" "Z = $(grp "$Z") MiB; PASS band $BI MiB" "$(grp "$S840") MiB" "$(grp "$Z840")"; do grep -qF -- "$s" "$RB" && ok "v$1 '$s'" || bad "v$1 runbook lacks '$s'"; done
  [ "$1" = 2 ] && { grep -qF "($BU MiB on v2)" "$RB" && ok "v2 unrounded band $BU" || bad "v2 unrounded band $BU not quoted"; }
  femtic_layout_check "$2" "$F" "$S840" 254952 > /dev/null && bad "v$1 N_iv 840 at $2 ranks is OK (runbook: REFUSED)" || ok "v$1 N_iv 840 at $2 ranks REFUSED"
  femtic_layout_check $(( $2 - 1 )) "$F" "$S840" 254952 > /dev/null && ok "v$1 N_iv 840 at $(( $2 - 1 )) rank(s) OK" || bad "v$1 N_iv 840 at $(( $2 - 1 )) rank(s) REFUSED"
  G=$(awk -v k="$K" 'BEGIN {printf "%.1f", k / 1048576}'); grep -qF -- "\`$G GiB ($K KB)\`" "$RB" && ok "v$1 PARDISO '$G GiB ($K KB)' (06 prints PKB as a whole number)" || bad "v$1 runbook lacks '$G GiB ($K KB)'"
done
pk() { awk -F: '/Maximum resident set size/ {v = $2 + 0; if (v > m) m = v} END {printf "%.1f", m / 1048576}' "$@"; }
grep -qF "(3 x $(pk "$MESH"/vulcan_v2/halfspace/acc_3/b*/time_v.log))" "$RB" && grep -qF "(2 x $(pk "$MESH"/vulcan_v3/halfspace/acc_*/b*/time_v.log))" "$RB" && ok "peak RSS per rank 3 x / 2 x WSL GiB" || bad "WSL peak RSS per rank not as quoted"

crit K3.4 "the per-frequency time ranges, per-rank products or the gate --time values disagree with femtic_fwd_times (the function 06 uses) on the WSL logs, or a --time leaves less than 6 min over the slowest rank at WSL speed"
rng() { for L in "$@"; do femtic_fwd_times "$L"; done | awk 'NR == 1 || $2 < a {a = $2} $2 > b {b = $2} END {print a, b}'; }
read -r a2 b2 < <(rng "$MESH"/vulcan_v2/halfspace/acc_3/b*/femtic_0.log); read -r a3 b3 < <(rng "$MESH"/vulcan_v3/halfspace/acc_*/b*/femtic_0.log)
F=$(( ND / 8 / NMT )); r2=$(( (F + 2) / 3 )); r3=$(( (F + 1) / 2 ))
for s in "$a2-$b2 s per frequency on v2 and $a3-$b3 s on v3" "$(grp $((r2 * a2)))-$(grp $((r2 * b2))) s ($r2 x $a2-$b2 s)" "$(grp $((r3 * a3)))-$(grp $((r3 * b3))) s ($r3 x $a3-$b3 s)" \
         "$r2 frequencies per rank x $b2 s = $(grp $((r2 * b2))) s" "$r3 x $b3 s = $(grp $((r3 * b3))) s"; do grep -qF -- "$s" "$RB" && ok "$s" || bad "runbook lacks '$s' (F = $F)"; done
tsec() { echo "$1" | awk -F: '{print $1 * 3600 + $2 * 60 + $3}'; }
for c in "J100=|$r2|$b2" "J3=|$r2|$b2" "K100=|$r3|$b3" "K3=|$r3|$b3"; do IFS='|' read -r v r b <<< "$c"
  tm=$(grep -E "^$v\\$\(sbatch " "$RB" | grep -oE -- '--time=[0-9:]+' | head -1 | cut -d= -f2)
  [ -n "$tm" ] && [ "$(tsec "$tm")" -ge $(( r * b + 360 )) ] && ok "$v --time=$tm = $(tsec "$tm") s >= $r x $b + 360 s" || bad "$v --time '$tm' < $(( r * b + 360 )) s"; done

crit K3.5 "an SU or hour figure is not 72 cpus x hours x 1.2, the wall ranges disagree with the seconds above, or the WSL CPU figures or the count of time_v.log files that hold them (and the empty one) differ from the files"
su() { awk -v h="$1" 'BEGIN {printf "%.0f", 72 * h * 1.2}'; }
for c in "0.3 1 26-86" "0.5 2.3 43-199" "1.5 5 130-432"; do set -- $c; [ "$(su $1)-$(su $2)" = "$3" ] && grep -qF "$3 SU" "$RB" && ok "$1-$2 h -> $3 SU" || bad "$1-$2 h -> $(su $1)-$(su $2), runbook $3"; done
for c in "2 172.8" "4 345.6" "12 1,036.8"; do set -- $c; v=$(awk -v h=$1 'BEGIN {printf "%.1f", 72 * h * 1.2}'); [ "$v" = "$(echo $2 | tr -d ,)" ] && grep -qF "$2" "$RB" && ok "$1 h = $2 SU" || bad "$1 h = $v"; done
[ "$(awk 'BEGIN {printf "%.1f", 4 * 0.5 * 1.2}')" = 2.4 ] && ok "smoke 2.4 SU" || bad "smoke SU"
awk -v a=$((r2 * a2)) -v b=$((r2 * b2)) -v c=$((r3 * a3)) -v d=$((r3 * b3)) 'BEGIN {exit !(a/3600 >= 0.25 && a/3600 < 0.35 && b/3600 <= 1 && c/3600 >= 0.45 && c/3600 < 0.55 && d/3600 > 2.25 && d/3600 < 2.35)}' && ok "0.3-1 h and 0.5-2.3 h cover $((r2 * a2))-$((r2 * b2)) s and $((r3 * a3))-$((r3 * b3)) s" || bad "wall ranges vs seconds"
L=$(awk 'BEGIN {printf "%.1f", 1036.8 + 3 * 72 * 72 * 1.2}'); grep -qF 'fewer than 19,700 SU' "$RB" && awk -v l=$L 'BEGIN {exit !(19700 >= l && 19700 - l < 1)}' && ok "19,700 >= $L" || bad "B6 threshold vs $L"
set -- "$MESH"/vulcan_v*/halfspace/*/*/time_v.log; NTV=$#
read -r lo hi < <(awk -F: '/Percent of CPU/ {v = $2 + 0; if (!n++ || v < a) a = v; if (v > b) b = v} END {print a, b}' "$@")
NTD=$(grep -l 'Percent of CPU' "$@" | wc -l | tr -d ' '); s="$NTD of the $NTV"; grep -qF -- "$s" "$RB" && grep -qF "\"Percent of CPU\" $lo-$hi %" "$RB" && grep -qF "$(awk -v a="$lo" -v b="$hi" 'BEGIN {printf "%g-%g %%", a / 8, b / 8}') of its 8 threads" "$RB" \
  && ok "$NTD of $NTV time_v.log files, $lo-$hi % of 8 threads" || bad "WSL CPU: $NTD of $NTV files, $lo-$hi %; runbook differs"
E=$(for f in "$@"; do grep -q 'Percent of CPU' "$f" || echo "$(wc -c < "$f" | tr -d ' ') ${f#$MESH/}"; done)
cnt "time_v.log files without the line (bytes, path)" "$E" "0 vulcan_v1/halfspace/acc_100/killed_np4_omp4/time_v.log"
grep -qF 'killed run `vulcan_v1/halfspace/acc_100/killed_np4_omp4`, is empty' "$RB" && ok "runbook names the empty one" || bad "runbook does not name the empty time_v.log"

crit K3.6 "the rotated v2 observe.dat differs from the unrotated one in anything but data values (line count, fields per line, station lines, frequencies), in femtic_obs_counts or 04's memory model, or in the evaluator's (site, band) list; or its sha256 does not start with d501abcf5a7dde5f; or the rotated station_map.csv names other sites"
U=$MESH/vulcan_v2/inversion/observe.dat
# cmpobs A B -> "lines structural_differences changed_data_lines" (data = the 17-field frequency lines minus the frequency)
cmpobs() { paste -d'\n' "$1" "$2" | awk 'NR % 2 == 1 {u = $0; nu = NF; f = $1; next} {n++; if (NF != nu) d++; else if (nu == 17) {if ($1 != f) d++; else if ($0 != u) v++} else if ($0 != u) d++} END {printf "%d %d %d\n", n, d + 0, v + 0}'; }
read -r n d v < <(cmpobs "$U" "$ROT/observe.dat"); echo "  unrotated vs rotated: $n lines, $d structural differences, $v data lines changed"
[ "$d" = 0 ] && [ "$v" -gt 0 ] && ok "only data values differ ($v of $n lines)" || bad "rotated observe.dat: $d structural differences, $v data lines changed"
awk '!done && NF == 17 {$1 = $1 * 1.01; done = 1} {print}' "$ROT/observe.dat" > "$T/obs_badfreq"
read -r n d v < <(cmpobs "$U" "$T/obs_badfreq"); [ "$d" = 1 ] && ok "negative control: one frequency changed by 1 % is found ($d)" || bad "negative control not found: $d"
cnt "femtic_obs_counts unrotated / rotated" "$(femtic_obs_counts "$U" | tr '\n' ' ')/ $(femtic_obs_counts "$ROT/observe.dat" | tr '\n' ' ')" "$(femtic_obs_counts "$U" | tr '\n' ' ')/ $(femtic_obs_counts "$U" | tr '\n' ' ')"
RD=$T/rotdir; mkdir -p "$RD"; cp "$ROT/observe.dat" "$RD/"; for f in mesh.dat resistivity_block_iter0.dat control.dat; do MSYS=winsymlinks:sys ln -s "$MESH/vulcan_v2/inversion/$f" "$RD/$f"; done
( NIV=auto NEQ=auto NONPARDISO_MB=auto FWD_MB=1; femtic_mem_model "$RD" > /dev/null; echo "$FM_NEQ $FM_NONP_MB $FM_M $FM_NIV $FM_ND $FM_NMT" ) > "$T/fmrot"
( NIV=auto NEQ=auto NONPARDISO_MB=auto FWD_MB=1; femtic_mem_model "$MESH/vulcan_v2/inversion" > /dev/null; echo "$FM_NEQ $FM_NONP_MB $FM_M $FM_NIV $FM_ND $FM_NMT" ) > "$T/fmunrot"
cnt "04's memory model (N_eq NONPARDISO_MB M N_iv Nd N_MT), rotated vs unrotated data" "$(cat "$T/fmrot")" "$(cat "$T/fmunrot")"
PYB=""; for p in python python3; do "$p" -c 'import sys; sys.exit(sys.version_info < (3, 6))' 2>/dev/null && { PYB=$p; break; }; done
R=$("$PYB" -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import halfspace_eval as h; a = h.read_observe_mt(sys.argv[2]); b = h.read_observe_mt(sys.argv[3]); print(len(a), len(b), a == b)' "$KIT/tools" "$U" "$ROT/observe.dat" 2>&1)
cnt "evaluator (site, band) pairs, unrotated / rotated / equal" "$R" "2520 2520 True"
cnt "sha256 prefix of the rotated observe.dat" "$(sha256sum < "$ROT/observe.dat" | cut -c1-16)" d501abcf5a7dde5f
cnt "station_map.csv: rotated first 10 columns vs unrotated; rot_deg values" "$(cut -d, -f1-10 "$ROT/station_map.csv" | cmp -s - "$MESH/vulcan_v2/inversion/station_map.csv" && echo same) $(tail -n +2 "$ROT/station_map.csv" | cut -d, -f11 | sort -u | tr '\n' ' ')" "same 7.42 "

fi   # K3
# ---------------- K4: files, sizes and md5
if want K4; then
crit K4.1 "a row of the upload list names a missing local file, or its bytes (wc -c) or md5 differ from the file"
while read -r id st lp arrow dp by md; do
  case "$id" in [ABCD][0-9][0-9]) ;; *) continue ;; esac
  pp=/d/$(echo "${lp#D:?}" | tr '\134' /)
  if [ "$by" = - ]; then ok "$id written later/self: $(basename "$pp")"; continue; fi
  [ -f "$pp" ] || { bad "$id $pp missing"; continue; }
  b=$(wc -c < "$pp" | tr -d ' '); m=$(md5sum < "$pp" | cut -c1-32)
  [ "$b" = "$by" ] && [ "$m" = "$md" ] && ok "$id $(basename "$pp") $b $m" || bad "$id $(basename "$pp"): list $by $md, file $b $m"
done < "$UL"
crit K4.2 "an md5 line of the B3.4 block does not match the file B3 puts under that name (v2: the rotated pair, the renamed unrotated pair, control.dat; v3: the unrotated files), products.md5 does not verify, or a part total differs from the runbook"
blk '== vulcan_v2' | awk '/^cd \$IN\/vulcan_v[23]/ {m = substr($2, length($2) - 1)} /^[0-9a-f]{32}  [^ ]+$/ {print m, $1, $2}' > "$T/b34md5"
src34() { case "$1 $2" in "v2 observe.dat") echo "$ROT/observe.dat" ;; "v2 station_map.csv") echo "$ROT/station_map.csv" ;;
  "v2 observe_unrotated.dat") echo "$MESH/vulcan_v2/inversion/observe.dat" ;; "v2 station_map_unrotated.csv") echo "$MESH/vulcan_v2/inversion/station_map.csv" ;;
  "v3 observe.dat"|"v3 station_map.csv"|"v2 control.dat"|"v3 control.dat") echo "$MESH/vulcan_$1/inversion/$2" ;; *) echo /nonexistent ;; esac; }
while read -r m h f; do s=$(src34 "$m" "$f"); x=$(md5sum < "$s" 2>/dev/null | cut -c1-32); [ "$h" = "$x" ] && ok "$m $f $h" || bad "$m $f: runbook $h, $s ${x:-missing}"; done < "$T/b34md5"
cnt "md5 lines in the B3.4 block, v2 and v3" "$(grep -c '^v2 ' "$T/b34md5") $(grep -c '^v3 ' "$T/b34md5")" "5 3"
for v in 2 3; do ( cd "$MESH/vulcan_v$v/inversion" && md5sum -c "../mesh_logs/products.md5" >/dev/null 2>&1 ) && ok "v$v products.md5 verifies" || bad "v$v products.md5 fails"; done
for p in B:312,893,416 C:390,887,243 D:505,628; do k=${p%%:*}; t=$(awk -v k=$k 'substr($1, 1, 1) == k && $1 ~ /^[BCD][0-9][0-9]$/ {s += $6} END {print s}' "$UL")
  [ "$(echo ${p#*:} | tr -d ,)" = "$t" ] && grep -qF "${p#*:} B" "$RB" && ok "part $k total $t" || bad "part $k total $t vs runbook ${p#*:}"; done
crit K4.3 "part A of the list is not exactly the files of the B1.1 md5 command plus the manifest, a kit test or tool is missing from it, a __pycache__ path is listed, or the B1.2/B1.3 counts differ"
blk 'UPLOAD_2026-09-28.md5' | grep '^md5sum ' | sed 's/ > .*//' | tr ' ' '\n' | grep '^hpc/' | sed 's#^hpc/phoenix_plan/##' | sort > "$T/b11"
awk '$1 ~ /^A[0-9][0-9]$/ {n = split($5, a, "/hpc/phoenix_plan/"); print a[2]}' "$UL" | sort > "$T/partA"
{ cat "$T/b11"; echo UPLOAD_2026-09-28.md5; } | sort > "$T/b11m"
NB=$(wc -l < "$T/b11" | tr -d ' ')
cmp -s "$T/b11m" "$T/partA" && ok "part A = the $NB B1.1 files + the manifest" || bad "part A differs from B1.1: $(diff "$T/b11m" "$T/partA" | grep '^[<>]' | tr '\n' ' ')"
cnt "md5 lines B1.3 expects" "$NB" "$(grep -oE 'PASS: [0-9]+ lines ending in `: OK`' "$RB" | head -1 | grep -oE '[0-9]+')"
grep -qF "part A of \`UPLOAD_LIST_2026-09-28.txt\` ($((NB + 1)) files: the $NB above and the md5 list)" "$RB" && ok "B1.2 counts $((NB + 1)) = $NB + 1" || bad "B1.2 does not say '($((NB + 1)) files: the $NB above and the md5 list)'"
for f in $(cd "$KIT" && ls tests/*.sh tests/*.py tools/*.py); do grep -qx "$f" "$T/b11" && ok "$f uploaded" || bad "$f not in B1.1 / part A"; done
grep -q '__pycache__' "$T/partA" && bad "__pycache__ in part A" || ok "no __pycache__ in part A"
crit K4.4 "the list's 'Not uploaded' claims disagree with git diff against fa58604 (what Phoenix has), or that block names a file that part A uploads"
if git -C "$WT" --no-optional-locks rev-parse -q --verify fa58604 > /dev/null 2>&1; then
  g() { git -C "$WT" --no-optional-locks diff --name-only fa58604 -- "$@"; }
  cnt "00_discover.sh and 02_env_femticpy.sh changed since fa58604" "$(g hpc/phoenix_plan/00_discover.sh hpc/phoenix_plan/02_env_femticpy.sh | wc -l | tr -d ' ')" 0
  cnt "hpc/ported files changed since fa58604" "$(g hpc/ported | tr '\n' ' ')" "hpc/ported/README.md "
  cnt "discovery/ files changed since fa58604" "$(g hpc/phoenix_plan/discovery | tr '\n' ' ')" "hpc/phoenix_plan/discovery/phoenix_build_foss_2026-09-25.log "
  for s in '00_discover.sh and 02_env_femticpy.sh (unchanged' 'README.md changed' 'phoenix_build_foss_2026-09-25.log' '__pycache__'; do has "$UL" "$s"; done
else bad "fa58604 not in this repository: cannot check the 'Not uploaded' line"; fi
awk '/^Not uploaded/ {on = 1; next} /^Columns:/ {on = 0} on' "$UL" > "$T/notup"
n=0; for f in $(cat "$T/partA"); do grep -qF -- "$f" "$T/notup" && { bad "'Not uploaded' names $f, which part A uploads"; n=1; }; done; [ $n = 0 ] && ok "'Not uploaded' names no part-A file"
crit K4.5 "the upload list differs from what tests/gen_upload_list.sh writes now (every line but line 2, the time), or the generator fails"
WT=$WT MESH=$MESH bash "$KIT/tests/gen_upload_list.sh" "$T/ul_gen.txt" > "$T/gen.out" 2>&1; cnt "generator exit" "$?" 0
diff <(sed 2d "$UL") <(sed 2d "$T/ul_gen.txt") > "$T/uldiff"; cnt "list lines that differ from the generator's output" "$(grep -c '^[<>]' "$T/uldiff")" 0
grep '^[<>]' "$T/uldiff" | head -4 | cut -c1-150 | sed 's/^/    /'

fi   # K4
# ---------------- K5: every bash block of the runbook parses; hygiene of both files
if want K5; then
crit K5.1 "any \`\`\`bash block of the runbook has a bash syntax error (bash -n)"
awk -v d="$T/blk" '/^```bash$/ {n++; f = sprintf("%s_%02d.sh", d, n); on = 1; next} /^```$/ {on = 0; next} on {print > f}' "$RB"
nb=0; for f in "$T"/blk_*.sh; do nb=$((nb + 1)); if e=$(bash -n "$f" 2>&1); then :; else bad "$(basename "$f"): $e"; fi; done
[ "$nb" -gt 0 ] && ok "$nb bash blocks parsed" || bad "no bash blocks found"
crit K5.2 "the runbook or the list has CR bytes or non-ASCII bytes, a fenced block is left open, or a line has a doubled backslash"
for f in "$RB" "$UL"; do
  [ "$(tr -cd '\r' < "$f" | wc -c | tr -d ' ')" = 0 ] && ok "$(basename "$f"): 0 CR" || bad "$(basename "$f"): CR bytes"
  [ "$(LC_ALL=C tr -d '\000-\177' < "$f" | wc -c | tr -d ' ')" = 0 ] && ok "$(basename "$f"): ASCII only" || bad "$(basename "$f"): non-ASCII bytes"
  B2="$(printf '\134\134')" awk 'index($0, ENVIRON["B2"]) {n++} END {exit n > 0}' "$f" && ok "$(basename "$f"): no doubled backslash" || bad "$(basename "$f"): doubled backslash"; done
[ $(( $(grep -c '^```' "$RB") % 2 )) = 0 ] && ok "$(grep -c '^```' "$RB") fence lines (even)" || bad "odd number of fence lines"

fi   # K5
# ---------------- K6: evidence the runbook cites
if want K6; then
crit K6.1 "a cited file or line does not hold what the runbook says"
L34=$(sed -n "$(grep -oE 's6_foss2023a.log:[0-9]+' "$RB" | head -1 | cut -d: -f2)p" "$WT/validation/wsl_2026-09-25/build_logs/s6_foss2023a.log")
case "$L34" in *"5.752642e+03   2.234639e+00"*) ok "s6_foss2023a.log line has Misfit 5.752642e+03 RMS 2.234639e+00" ;; *) bad "cited line is '$L34'" ;; esac
for v in 2.331502e+03 1.309987e+03; do grep -qF "$v" "$WT/validation/wsl_2026-09-25/build_logs/s6_foss2023a.log" && ok "WSL row value $v" || bad "$v not in s6 log"; done
DL=$(grep -oE 'phoenix_discovery_p2-log-2_2026-09-25.txt:[0-9]+-[0-9]+' "$RB" | head -1 | cut -d: -f2)
DX=$(sed -n "${DL%-*},${DL#*-}p" "$KIT/discovery/phoenix_discovery_p2-log-2_2026-09-25.txt")
echo "$DX" | grep -q 'to start at .*partition icelake' && echo "$DX" | grep -q 'to start at .*partition highmem' && ok "discovery lines $DL: icelake and highmem start estimates" || bad "discovery lines $DL lack the start estimates"
for s in '## 6. MPI ranks' '## 10. Validation tests' '1. **`$TMPDIR` type**' '2. **Elapsed or requested time charged**' 'in 74 s' 'rcstat CPU efficiency under about 50%' 'copy its `LAYOUT` into the production directory'; do grep -qF -- "$s" "$KIT/README_phoenix.md" && ok "README: $s" || bad "README lacks $s"; done
for f in "$MESH/vulcan_v2/halfspace/acc_3/b1/femtic_0.log" "$MESH/vulcan_v3/halfspace/acc_100/b1/time_v.log" "$KIT/build_foss_20260925_181212.log"; do [ -f "$f" ] && ok "exists: ${f##*/FEMTIC_2026/}" || bad "missing $f"; done

L=$(grep -oE 'femtic_lib\.sh:[0-9]+' "$RB" | head -1 | cut -d: -f2); sed -n "${L:-0}p" "$KIT/femtic_lib.sh" | grep -qF 'ps -C femtic -o rss=' && ok "femtic_lib.sh:$L sums ps -C femtic -o rss=" || bad "femtic_lib.sh:${L:-?} is not the ps sampler line"
read -r a b < <(grep -oE '\(06:[0-9]+, 06:[0-9]+\)' "$RB" | head -1 | grep -oE '[0-9]+' | sed -n '2p;4p' | tr '\n' ' ')
[ -n "$b" ] && sed -n "${a}p;${b}p" "$KIT/06_forward_only.slurm" | grep -c 'ln -sf "\$INV_DIR/' | grep -qx 2 && ok "06:$a and 06:$b link fwd0_<jobid>/ to \$INV_DIR by absolute path" || bad "06:${a:-?},${b:-?} are not 06's link lines"
L=$(grep -oE '`femtic_lib.sh` \(01:[0-9]+\)' "$RB" | head -1 | grep -oE '[0-9]+\)' | tr -d ')'); sed -n "${L:-0}p" "$KIT/01_build_femtic.sh" | grep -qF 'install -m 644 "$PLAN_DIR/femtic_lib.sh"' && ok "01:$L installs femtic_lib.sh" || bad "01:${L:-?} is not the install line"

fi   # K6
# ---------------- K7: rules for the commands (directories, walltimes, dependencies, script paths, Phoenix folders)
if want K7; then
crit K7.1 "an 06 sbatch line does not use \$PLAN/06_forward_only.slurm, a v2 gate line lacks 3 x 24 and --time=02:00:00, a v3 gate line lacks --time=04:00:00; or an sbatch line carries --dependency, the runbook does not say to submit B4a after reading B2's output, or 01 compares the WSL misfit (then a dependency could enforce B2 after all)"
grep -E 'sbatch .*06_forward_only' "$RB" > "$T/s06"; cnt "06 sbatch lines" "$(wc -l < "$T/s06" | tr -d ' ')" 4
cnt "06 sbatch lines not using \$PLAN/06_forward_only.slurm" "$(grep -vc '\$PLAN/06_forward_only.slurm' "$T/s06")" 0
for v in J100 J3; do grep -E "^$v=" "$T/s06" | grep -q -- '--ntasks-per-node=3 --cpus-per-task=24 --time=02:00:00' && ok "$v: 3 x 24, --time=02:00:00" || bad "$v line lacks 3 x 24 / --time=02:00:00"; done
for v in K100 K3; do grep -E "^$v=" "$T/s06" | grep -q -- '--time=04:00:00' && ok "$v: --time=04:00:00" || bad "$v line lacks --time=04:00:00"; done
cnt "sbatch lines with --dependency" "$(grep -E 'sbatch ' "$RB" | grep -c -- '--dependency')" 0
has "$RB" "**Submit B4a after reading B2's output.**"
cnt "01 lines holding the WSL misfit 5.752642 (B2's Misfit/RMS criterion is not in 01's exit code)" "$(grep -c '5\.752642' "$KIT/01_build_femtic.sh")" 0
crit K7.2 "two gate jobs are submitted from the same directory, or B5 does not take fwd_rank_mb from the 100 ohm-m job's directory"
awk '/^cd \$WK\// {d = $2} /^(J100|J3|K100|K3)=\$\(sbatch / {split($1, a, "="); print a[1], d}' "$RB" > "$T/gdirs"; sed 's/^/  /' "$T/gdirs"
cnt "gate jobs with a cd \$WK/... line before them" "$(wc -l < "$T/gdirs" | tr -d ' ')" 4
cnt "distinct gate directories" "$(awk '{print $2}' "$T/gdirs" | sort -u | wc -l | tr -d ' ')" 4
awk '($1 ~ /100$/ && $2 !~ /gate100$/) || ($1 ~ /3$/ && $2 !~ /gate3$/) {n++} END {exit n > 0}' "$T/gdirs" && ok "each 100/3 ohm-m job runs in gate100/gate3" || bad "a gate job runs in the wrong directory"
grep -qF 'cp $WK/$M/gate100/logs/fwd_rank_mb logs/' "$RB" && ok "B5 copies \$WK/\$M/gate100/logs/fwd_rank_mb" || bad "B5 does not copy \$WK/\$M/gate100/logs/fwd_rank_mb"
grep -qF 'stops femtic about 10 min before the limit' "$RB" && hasnt "$RB" 'stops femtic 5 min before' || bad "the USR1 stop is not described as about 10 min before the limit"
crit K7.3 "a Never rule forbids the directory from which B5 submits 04, no Never rule forbids 04 and 05_chain.sh in gate* directories or jobs in the input folders, or a 04/06 job is submitted from outside \$WK"
awk '/^\*\*Never:\*\*/ {on = 1; next} on && /^\* / {print; next} on && NF {exit}' "$RB" > "$T/never"; sed 's/^/  /' "$T/never"
awk '/^cd / {d = $2} /^[A-Za-z0-9_]+=\$\(sbatch .*(04_inversion|06_forward_only)\.slurm/ {split($1, a, "="); print a[1], d}' "$RB" > "$T/jobdirs"; sed 's/^/  job dir: /' "$T/jobdirs"
cnt "04/06 submissions, and those from outside \$WK/" "$(wc -l < "$T/jobdirs" | tr -d ' ') $(awk '$2 !~ /^\$WK\//' "$T/jobdirs" | wc -l | tr -d ' ')" "6 0"
B5D=$(awk '$1 == "J4" {print $2; exit}' "$T/jobdirs"); echo "  B5 submits 04 from: $B5D"
R=$( set -f; hit=""; gate=0
  while IFS= read -r line; do case "$line" in *" 04 "*|*"05_chain.sh"*) ;; *) continue ;; esac
    g1=0; g2=0; for tk in $(echo "${line%%(*}" | grep -oE '`[^`]+`' | tr -d '`'); do case "$tk" in *.sh|*.slurm) continue ;; esac
      case "${B5D##*/}" in $tk) hit="$hit $tk" ;; esac; case "$B5D" in $tk) hit="$hit $tk" ;; esac
      case gate100 in $tk) g1=1 ;; esac; case gate3 in $tk) g2=1 ;; esac; done
    case "$line" in *" 04 "*"05_chain.sh"*) [ $g1$g2 = 11 ] && gate=1 ;; esac
  done < "$T/never"; echo "${hit:-none} $gate" )
cnt "Never tokens matching B5's directory; a rule forbidding 04 and 05 in gate100/gate3" "$R" "none 1"
grep -qF '* run a job in `$IN/vulcan_v2` or `$IN/vulcan_v3`' "$T/never" && ok "Never: no job in the input folders" || bad "no Never rule for the input folders"
crit K7.4 "the runbook, the upload list, README section 3 step 7 (and its gate paragraph) and the 06 header disagree on the Phoenix folders: inputs in vulcan_femtic/inputs/vulcan_v{2,3}, jobs in vulcan_femtic/work/<mesh>/<dir>, linked with ../../../inputs/vulcan_<mesh>"
C0=$(blk 'LEDGER=')
for s in 'VF=/hpcfs/users/a1690074/vulcan_femtic' 'IN=$VF/inputs' 'WK=$VF/work' 'LEDGER=$VF/jobs_ledger.txt'; do echo "$C0" | grep -qxF -- "$s" && ok "conventions: $s" || bad "conventions block lacks '$s'"; done
hasnt "$RB" '$INV'
cnt "list rows of parts B-D, and those not in vulcan_femtic/inputs/vulcan_v{2,3}/" "$(awk '$1 ~ /^[BCD][0-9][0-9]$/' "$UL" | wc -l | tr -d ' ') $(awk '$1 ~ /^[BCD][0-9][0-9]$/ && $5 !~ /^\/hpcfs\/users\/a1690074\/vulcan_femtic\/inputs\/vulcan_v[23]\/[^\/]+$/' "$UL" | wc -l | tr -d ' ')" "14 0"
cnt "runbook link lines ln -sfn ../../../inputs/vulcan_\$M/\$f (gate, t4)" "$(grep -cE '^for f in mesh.dat observe.dat resistivity_block_iter0.dat station_map.csv( products.md5)?; do ln -sfn \.\./\.\./\.\./inputs/vulcan_\$M/\$f \$f; done$' "$RB")" 2
R7=$(awk '/^7\. \*\*Mesh: copy the gated mesh/ {on = 1} /^8\. \*\*Forward-only job/ {on = 0} on' "$KIT/README_phoenix.md")
for s in 'vulcan_femtic/inputs/vulcan_v2' '.../inputs/vulcan_v3' 'vulcan_femtic/work/v{2,3}/<gate100|gate3|t4|inv01>' 'cp ../../../inputs/vulcan_v2/control.dat .' 'ln -sfn ../../../inputs/vulcan_v2/$f $f' 'observe_unrotated.dat' 'mesh/vulcan_v2_rot/inversion/'; do
  echo "$R7" | grep -qF -- "$s" && ok "README step 7: $s" || bad "README step 7 lacks '$s'"; done
echo "$R7" | grep -qF 'inversion/inv01' && bad "README step 7 still names inversion/inv01" || ok "README step 7: no inversion/inv01"
RG=$(awk '/The same job is the half-space accuracy gate/ {on = 1} on {print} on && /at all 21 observe.dat bands/ {exit}' "$KIT/README_phoenix.md")
echo "$RG" | grep -qF 'in `work/v2/gate100`' && echo "$RG" | grep -qF 'in `work/v2/gate3` the same with `START_RHO=3`' && ok "README gate paragraph: one directory per job" || bad "README gate paragraph: $(echo "$RG" | head -2 | tr '\n' ' ')"
cnt "06 header: START_RHO example in work/v2/gate100; START_RHO lines naming inversion/inv01" "$(grep -c '^#  *cd /hpcfs/users/\$USER/vulcan_femtic/work/v2/gate100 && sbatch --export=ALL,START_RHO=100 ' "$KIT/06_forward_only.slurm") $(grep -E '^#.*START_RHO=' "$KIT/06_forward_only.slurm" | grep -c 'inversion/inv01')" "1 0"

fi   # K7
[ $((np + nf)) -gt 0 ] || { CUR=K0; bad "no check ran (CHECK_GROUPS='${CHECK_GROUPS:-}')"; }
echo; echo "SUMMARY: $np passed, $nf failed${FAILED_GROUPS:+   failed groups:$FAILED_GROUPS}"
rm -rf "$T"
[ "$nf" = 0 ]
