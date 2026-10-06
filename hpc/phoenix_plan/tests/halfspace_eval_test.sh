#!/bin/bash
# =============================================================================
# halfspace_eval_test.sh -- tests tools/halfspace_eval.py (the half-space gate that 06 START_RHO runs) on the WSL
# gate runs of 2026-09-25, whose result csv files and acc_eval.py reports are in D:/BEN/FEMTIC_2026/mesh/.
#
#   bash halfspace_eval_test.sh [PLAN_DIR]
#   env: ACC_ROOT=<.../mesh> (default /d/BEN/FEMTIC_2026/mesh), WORK=<dir> (default mktemp -d), PYTHON=<python 3>
# Needs the local run outputs, so it runs on Ben's PC (Git Bash or WSL with ACC_ROOT=/mnt/d/BEN/FEMTIC_2026/mesh),
# not on Phoenix; without them it prints SKIPPED and exits 3 (not a pass). Light: python over 138 KB csv files.
# Every check prints its failure criterion before its result. Exit 0 only if every check passes.
# =============================================================================
PLAN=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
EV=$PLAN/tools/halfspace_eval.py
ACC_ROOT=${ACC_ROOT:-/d/BEN/FEMTIC_2026/mesh}
WORK=${WORK:-$(mktemp -d)}; mkdir -p "$WORK"
if [ -z "${PYTHON:-}" ]; then
  for p in python3 python; do
    if [ "$("$p" -c 'import sys; print(sys.version_info[0])' 2>/dev/null)" = 3 ]; then PYTHON=$p; break; fi
  done
fi
[ -d "$ACC_ROOT/vulcan_v3/halfspace/acc_100/b1" ] || { echo "SKIPPED: no gate runs under ACC_ROOT=$ACC_ROOT"; exit 3; }
[ -f "$EV" ] || { echo "FAIL: $EV missing"; exit 1; }
echo "halfspace_eval_test: EV=$EV  ACC_ROOT=$ACC_ROOT  WORK=$WORK  PYTHON=$PYTHON"
npass=0; nfail=0
crit() { echo; echo "CHECK $1: fails if $2"; }
ok()   { echo "  PASS $*"; npass=$((npass + 1)); }
bad()  { echo "  FAIL $*"; nfail=$((nfail + 1)); }
eq()   { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got '$2', want '$3'"; fi; }
has()  { if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1: '$3' found"; else bad "$1: '$3' not in $2"; fi; }

# table STORED_TXT NEW_OUT -> number of per-band rows whose first 10 columns (f Hz, delta km, max|rho|%, mean%, std%,
#   max|ph|, mean, std, diag%, fail r/p/d) or PASS/FAIL verdict differ between acc_eval.py's stored report and
#   halfspace_eval.py's output, plus a count mismatch; prints the differing rows. 0 = identical.
table() {
  awk 'FNR == 1 {file++}
       $1 ~ /^[0-9.]+(e[-+][0-9]+)?$/ && $2 ~ /^[0-9.]+$/ && NF >= 11 {
         k = ""; for (i = 1; i <= 10; i++) k = k " " $i; k = k " " $NF
         if (file == 1) {a[++na] = k} else {b[++nb] = k} }
       END { d = (na != nb); for (i = 1; i <= na; i++) if (a[i] != b[i]) {d++; print "   stored:" a[i]; print "   new:   " b[i]}
             if (na != nb) print "   rows: stored " na ", new " nb
             print "DIFF " d }' "$1" "$2"
}
# dirs STORED_TXT -> the run directories acc_eval.py used, mapped from WSL to ACC_ROOT
dirs() { sed -nE 's#^run /home/tara/femtic_wsl/mesh_runs/acc_(v[0-9])_([0-9]+)/([^:]+):.*#'"$ACC_ROOT"'/vulcan_\1/halfspace/acc_\2/\3#p' "$1"; }

crit E0 "the table comparison does not notice a one-digit change (2.91 -> 2.92) in a copy of acc_eval_v3_100.txt"
S=$ACC_ROOT/vulcan_v3/halfspace/acc_100/acc_eval_v3_100.txt
sed 's/^\( 0.0063033   63.355 \)     2.91/\1     2.92/' "$S" > "$WORK/tampered.txt"
eq "E0 the copy differs in one line" "$(diff "$S" "$WORK/tampered.txt" | grep -c '^>')" 1
# shellcheck disable=SC2046
"$PYTHON" "$EV" 100 $(dirs "$S") > "$WORK/E0.out" 2>&1
eq "E0 comparator verdict" "$(table "$WORK/tampered.txt" "$WORK/E0.out" | awk '$1 == "DIFF" {print ($2 > 0 ? "differs" : "same")}')" differs

crit E1 "halfspace_eval.py differs from any stored acc_eval.py report (7 of them, 2 FAIL and 5 PASS) in any per-band value, band verdict or RESULT"
for S in "$ACC_ROOT"/vulcan_v*/halfspace/acc_*/acc_eval_*.txt; do
  rho=$(awk 'NR == 1 {print $2; exit}' "$S")
  n=$(basename "$S" .txt)
  # shellcheck disable=SC2046
  "$PYTHON" "$EV" "$rho" $(dirs "$S") > "$WORK/$n.out" 2>&1; rc=$?
  T=$(table "$S" "$WORK/$n.out"); d=$(echo "$T" | awk '$1 == "DIFF" {print $2}')
  want=$(awk '/^RESULT:/ {print $2}' "$S"); got=$(awk '/^RESULT:/ {print $2}' "$WORK/$n.out")
  eq "E1 $n: rows differing from the stored table" "$d" 0
  [ "$d" = 0 ] || echo "$T"
  eq "E1 $n: RESULT (stored $want)" "$got" "$want"
  eq "E1 $n: exit status" "$rc" "$([ "$want" = PASS ] && echo 0 || echo 1)"
done
grep -h "^LIMIT\|^RESULT" "$WORK/acc_eval_v3_100.out" "$WORK/acc_eval_v3_100_bs_lowf.out" "$WORK/acc_eval_v2_3.out" | sed 's/^/    /'

crit E2 "a copy of v3 acc_100/b1 with Re(Zxy)_Cal of site 7 at 200 Hz scaled by 1.10 does not FAIL (exit 1) with the worst rho_a at site 7, 200 Hz; the unmodified copy (control) does not PASS"
B=$WORK/b1_copy; P=$WORK/b1_pert; rm -rf "$B" "$P"; mkdir -p "$B" "$P"
cp "$ACC_ROOT/vulcan_v3/halfspace/acc_100/b1/"{result_0_iter0.csv,observe.dat} "$B/"; cp "$B"/* "$P/"
awk -F, -v OFS=, '$1 + 0 == 7 && $2 + 0 == 200 {$5 = sprintf("%16.6e", $5 * 1.10); n++} {print} END {if (n != 1) print "PERTURB_ROWS " n > "/dev/stderr"}' \
  "$B/result_0_iter0.csv" > "$P/result_0_iter0.csv"
eq "E2 lines changed by the perturbation" "$(diff "$B/result_0_iter0.csv" "$P/result_0_iter0.csv" | grep -c '^>')" 1
"$PYTHON" "$EV" 100 "$B" > "$WORK/E2_control.out" 2>&1; eq "E2 control exit" "$?" 0
"$PYTHON" "$EV" 100 "$P" > "$WORK/E2_pert.out" 2>&1; eq "E2 perturbed exit" "$?" 1
has "E2 RESULT" "$WORK/E2_pert.out" "RESULT: FAIL"
has "E2 worst rho_a at site 7, 200 Hz" "$WORK/E2_pert.out" "at site 7, 200 Hz (Zxy"
grep -h "^LIMIT\|^RESULT" "$WORK/E2_pert.out" | sed 's/^/    /'

crit E3 "a copy of b1 without the row of site 7 at 200 Hz does not FAIL on completeness (1 missing, 7@200)"
M=$WORK/b1_missing; rm -rf "$M"; mkdir -p "$M"; cp "$B/observe.dat" "$M/"
awk -F, '!($1 + 0 == 7 && $2 + 0 == 200)' "$B/result_0_iter0.csv" > "$M/result_0_iter0.csv"
"$PYTHON" "$EV" 100 "$M" > "$WORK/E3.out" 2>&1; eq "E3 exit" "$?" 1
has "E3 completeness" "$WORK/E3.out" "240 expected (site, band) pairs, 1 missing e.g. 7@200"

crit E4 "the unmodified 100 ohm-m run evaluated as a 3 ohm-m half-space does not FAIL (a gate that passes any RHO is vacuous)"
"$PYTHON" "$EV" 3 "$B" > "$WORK/E4.out" 2>&1; eq "E4 exit" "$?" 1

echo; echo "SUMMARY: $npass passed, $nfail failed   (EV=$EV)"
[ "$nfail" = 0 ]
