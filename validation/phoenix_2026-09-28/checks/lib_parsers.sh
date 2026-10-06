#!/usr/bin/env bash
# Check c: the kit's log parsers (femtic_lib.sh, version 4, worktree copy) on the REAL Phoenix logs of the
# B2 smoke job 16153670 - their first genuine Phoenix input. Read-only on Ben's disk.
#
# This test fails if a parser prints nothing, or prints a value other than the one read by hand from the log
# lines quoted below (grep -n output, printed by this script so the record shows them).
# Fail cases run first: the same comparator must say FAIL for (1) the version-2 PARDISO parser on a %g line
# ("2.5e+07" KB), and (2) femtic_niv_measured on the real log cut before its first sensitivity step.
#
# Run from the repository root:  bash validation/phoenix_2026-09-28/checks/lib_parsers.sh
set -u
REPO=$(git rev-parse --show-toplevel) || exit 1
LIB=$REPO/hpc/phoenix_plan/femtic_lib.sh
SM=${SMOKE_DIR:-/d/BEN/FEMTIC_2026/hpc/smoke_foss_20260928_211308}
MAN=$REPO/validation/phoenix_2026-09-28/MANIFEST.md5
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git -C "$REPO" show 55bbf44:hpc/phoenix_plan/femtic_lib.sh > "$T/lib_v2.sh"

# the logs used, tied to the manifest
for f in straight/femtic_0.log straight/femtic_1.log restart/femtic_0.log restart/femtic_1.log; do
  want=$(awk -v p="smoke_foss_20260928_211308/$f" '$3 == p {print $1}' "$MAN")
  have=$(md5sum < "$SM/$f" | cut -c1-32)
  [ "$want" = "$have" ] || { echo "STOP: $SM/$f md5 $have is not the manifest's $want"; exit 1; }
done
echo "4 logs match MANIFEST.md5"
printf 'lib: %s  FEMTIC_LIB_VERSION=%s  md5 %s  (%s B)\n' "$LIB" "$(sed -n 's/^FEMTIC_LIB_VERSION=//p' "$LIB")" \
  "$(md5sum < "$LIB" | cut -c1-32)" "$(wc -c < "$LIB")"

PASS=0; FAIL=0
chk() {   # chk <label> <got> <expected>
  if [ -n "$2" ] && [ "$2" = "$3" ]; then printf '  PASS %-58s got [%s]\n' "$1" "$2"; PASS=$((PASS + 1))
  else printf '  FAIL %-58s got [%s] expected [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi
}

echo; echo "== hand-read lines (the expected values come from these)"
for f in straight/femtic_0.log straight/femtic_1.log; do
  echo "-- $f"
  grep -n 'Total memory consumed by in-core forward solver' "$SM/$f"
  grep -n 'Number of equation after degeneration' "$SM/$f" | sort -t= -k3 -n | tail -1
  grep -n -A2 '^# Solve phase of matrix solver for right-hand sides consisting of interpolator vectors' "$SM/$f" | head -3
  grep -n -m1 '^# Start Forward Computation' "$SM/$f"
  sed -n '98p' "$SM/$f" | sed 's/^/98:/'
  grep -n -m3 -E '^# Calculate response functions|^# Release memory of coefficient matrix and sparse solver\.' "$SM/$f"
done

echo; echo "== fail cases (comparator must print FAIL)"
F0=$FAIL
printf '# Total memory consumed by in-core forward solver for internal float point arrays    : 2.5e+07 [KByte]\n' > "$T/femtic_0.log"
chk "F1 v2 femtic_pardiso_max_gb on a '2.5e+07 KB' line" "$(bash -c ". '$T/lib_v2.sh'; femtic_pardiso_max_gb '$T'")" "23.8"
awk '/^# Solve phase of matrix solver for right-hand sides consisting of interpolator vectors/ {exit} {print}' \
  "$SM/straight/femtic_0.log" > "$T/cut.log"
chk "F2 femtic_niv_measured, real log cut before 1st sensitivity" "$(bash -c ". '$LIB'; femtic_niv_measured '$T/cut.log'")" "144"
echo "  -> fail cases printed FAIL: $((FAIL - F0)) of 2"
FC=$((FAIL - F0)); FAIL=$F0
echo "  (control: v4 on the same '2.5e+07' line gives [$(bash -c ". '$LIB'; femtic_pardiso_max_gb '$T'")], expected 23.8)"

echo; echo "== version-4 parsers on the real Phoenix logs"
r() { bash -c ". '$LIB'; $*"; }
chk "femtic_pardiso_kb straight/femtic_0.log"            "$(r femtic_pardiso_kb "$SM/straight/femtic_0.log")" 206687
chk "femtic_pardiso_kb straight/femtic_1.log"            "$(r femtic_pardiso_kb "$SM/straight/femtic_1.log")" 206994
chk "femtic_pardiso_kb both straight logs"               "$(r femtic_pardiso_kb "$SM/straight/femtic_0.log" "$SM/straight/femtic_1.log")" 206994
chk "femtic_pardiso_max_gb straight/ (206994/1048576)"    "$(r femtic_pardiso_max_gb "$SM/straight")" 0.2
chk "femtic_pardiso_log_gb straight/femtic_0.log"        "$(r femtic_pardiso_log_gb "$SM/straight/femtic_0.log")" 0.20
chk "femtic_pardiso_log_gb restart/femtic_1.log (206674)" "$(r femtic_pardiso_log_gb "$SM/restart/femtic_1.log")" 0.20
chk "femtic_log_neq straight/femtic_0.log"               "$(r femtic_log_neq "$SM/straight/femtic_0.log")" 39254
chk "femtic_log_neq all four logs"                       "$(r femtic_log_neq "$SM"/straight/femtic_[01].log "$SM"/restart/femtic_[01].log)" 39254
chk "femtic_niv_measured straight/femtic_0.log"          "$(r femtic_niv_measured "$SM/straight/femtic_0.log")" 144
chk "femtic_niv_measured straight/femtic_1.log"          "$(r femtic_niv_measured "$SM/straight/femtic_1.log")" 144
chk "femtic_niv_measured restart/femtic_[01].log (leg 2)" "$(r femtic_niv_measured "$SM"/restart/femtic_[01].log)" 144
chk "femtic_fwd_times straight/femtic_0.log"             "$(r femtic_fwd_times "$SM/straight/femtic_0.log" | tr '\n' ';')" "0.001 4;0.01 3;"
chk "femtic_fwd_times straight/femtic_1.log"             "$(r femtic_fwd_times "$SM/straight/femtic_1.log" | tr '\n' ';')" "0.1 4;1 3;"
chk "femtic_fwd_times restart/femtic_0.log (leg 2, iter 1)" "$(r femtic_fwd_times "$SM/restart/femtic_0.log" | tr '\n' ';')" "0.001 3;0.01 3;"
chk "femtic_nfreq straight/femtic_0.log"                 "$(r femtic_nfreq "$SM/straight/femtic_0.log")" 4
chk "femtic_last_iter straight/ and restart/"            "$(r femtic_last_iter "$SM/straight") $(r femtic_last_iter "$SM/restart")" "2 2"
chk "femtic_cnv_row 0 straight/femtic.cnv (Misfit, RMS)"  "$(r femtic_cnv_row 0 "$SM/straight/femtic.cnv" | awk '{print $6, $7}')" "5.752642e+03 2.234639e+00"
chk "femtic_block_check restart iter2 vs iter0"          "$(r femtic_block_check "$SM/restart/resistivity_block_iter2.dat" "$SM/restart/resistivity_block_iter0.dat")" "OK 34559 289"
chk "femtic_obs_counts observe.dat (36 sta, 36x4x8 data)" "$(r femtic_obs_counts "$SM/straight/observe.dat" 2>/dev/null)" "36 1152"

echo; echo "== version-2 (HEAD, installed on Phoenix during B2) on the same real logs, for comparison"
chk "v2 femtic_pardiso_max_gb straight/"                  "$(bash -c ". '$T/lib_v2.sh'; femtic_pardiso_max_gb '$SM/straight'")" 0.2
chk "v2 femtic_fwd_times straight/femtic_0.log"          "$(bash -c ". '$T/lib_v2.sh'; femtic_fwd_times '$SM/straight/femtic_0.log'" | tr '\n' ';')" "0.001 4;0.01 3;"
echo; echo "SUMMARY lib_parsers: fail cases $FC/2 FAIL as designed; real-log checks $PASS passed, $FAIL failed"
[ "$FC" = 2 ] && [ "$FAIL" = 0 ]
