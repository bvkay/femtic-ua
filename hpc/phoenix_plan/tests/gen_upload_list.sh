#!/bin/bash
# =============================================================================
# gen_upload_list.sh -- writes UPLOAD_LIST_2026-09-28.txt from the files as they are now: sizes by stat -c %s and
# md5 by md5sum, measured, never typed. PC only (Git Bash): it reads the worktree and D:/BEN/FEMTIC_2026/mesh.
#   bash gen_upload_list.sh [OUT]            (default: UPLOAD_LIST_2026-09-28.txt next to the runbook)
#   env: MESH (default /d/BEN/FEMTIC_2026/mesh), WT (default: the checkout this script is in)
# Parts in upload order: A kit (runbook B1), B v2 inputs and C v3 inputs (B3.1), D the rotated v2 data (B3.3).
# tests/runbook_check.sh K4.5 runs it into a temp file and compares it with the list (all but the time line).
# =============================================================================
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WT=${WT:-}; [ -n "$WT" ] || WT=$(cd "$KIT/../.." && pwd)
MESH=${MESH:-/d/BEN/FEMTIC_2026/mesh}
OUT=${1:-$KIT/UPLOAD_LIST_2026-09-28.txt}
KDEST=/hpcfs/users/a1690074/FEMTIC_2026/hpc/phoenix_plan
IDEST=/hpcfs/users/a1690074/vulcan_femtic/inputs
ROT=$WT/mesh/vulcan_v2_rot/inversion
# part A: exactly the files of the runbook's B1.1 md5sum line (runbook_check.sh K4.3 compares the two)
KITFILES="femtic_lib.sh 01_build_femtic.sh 06_forward_only.slurm 04_inversion.slurm 05_chain.sh 03_mesh.slurm
  tools/halfspace_eval.py tests/c1c2_test.sh tests/portability_test.sh tests/halfspace_eval_test.sh
  tests/runbook_check.sh tests/runbook_mutate.py tests/gen_upload_list.sh README_phoenix.md RUNBOOK_first_inversion.md"
BS=$(printf '\134')
winp() { case "$1" in /d/*) ;; *) echo "gen_upload_list: $1 is not under /d/" >&2; exit 2 ;; esac
         local p=${1#/d/}; echo "D:$BS$(echo "$p" | tr / '\134')"; }
row() {  # row ID STEP LOCAL_POSIX_PATH PHOENIX_PATH  (a missing local file gives '-' '-')
  local b=- m=-
  if [ -f "$3" ]; then b=$(stat -c %s "$3"); m=$(md5sum < "$3" | cut -c1-32); fi
  printf '%-4s %-5s %s -> %s %s %s\n' "$1" "$2" "$(winp "$3")" "$4" "$b" "$m"
}
[ -d "$MESH/vulcan_v2/inversion" ] && [ -f "$ROT/observe.dat" ] || { echo "gen_upload_list: no $MESH/vulcan_v2/inversion or $ROT/observe.dat" >&2; exit 2; }
body() {
  local i=0 f v P
  echo "# Part A: kit (step B1) -> $KDEST/"
  for f in $KITFILES; do i=$((i + 1)); row "$(printf 'A%02d' $i)" B1 "$KIT/$f" "$KDEST/$f"; done
  i=$((i + 1)); printf '%-4s %-5s %s -> %s %s %s\n' "$(printf 'A%02d' $i)" B1 "$(winp "$KIT/UPLOAD_LIST_2026-09-28.txt")" "$KDEST/UPLOAD_LIST_2026-09-28.txt" - -
  i=$((i + 1)); printf '%-4s %-5s %s -> %s %s %s\n' "$(printf 'A%02d' $i)" B1 "$(winp "$KIT/UPLOAD_2026-09-28.md5")" "$KDEST/UPLOAD_2026-09-28.md5" - -
  for v in 2 3; do
    if [ $v = 2 ]; then P=B; else P=C; fi
    echo; echo "# Part $P: vulcan_v$v inversion inputs as gated on 2026-09-25 (step B3.1) -> $IDEST/vulcan_v$v/"
    row ${P}01 B3.1 "$MESH/vulcan_v$v/mesh_logs/products.md5" "$IDEST/vulcan_v$v/products.md5"
    i=1
    for f in control.dat observe.dat station_map.csv resistivity_block_iter0.dat mesh.dat; do
      i=$((i + 1)); row "$(printf '%s%02d' $P $i)" B3.1 "$MESH/vulcan_v$v/inversion/$f" "$IDEST/vulcan_v$v/$f"
    done
  done
  echo; echo "# Part D: the rotated v2 data (step B3.3, after the B3.2 rename on Phoenix) -> $IDEST/vulcan_v2/"
  row D01 B3.3 "$ROT/observe.dat" "$IDEST/vulcan_v2/observe.dat"
  row D02 B3.3 "$ROT/station_map.csv" "$IDEST/vulcan_v2/station_map.csv"
}
B=$(body) || exit 2
{
  echo "UPLOAD_LIST_2026-09-28.txt -- every file to upload to Phoenix for RUNBOOK_first_inversion.md (STATUS B1-B6), in upload order."
  echo "Written by tests/gen_upload_list.sh at $(date '+%F %T'): sizes (bytes, stat -c %s) and md5 measured on the PC, not typed."
  echo "WinSCP transfer mode: Binary."
  echo "Part A (kit, step B1): other sessions may still edit these files before you upload. The md5 manifest UPLOAD_2026-09-28.md5"
  echo "  is therefore built at upload time, in runbook step B1.1, from the files as they are then, and B1.3 checks it on Phoenix."
  echo "  A size or md5 here that differs from your local file only means the file changed after this list was written;"
  echo "  the B1.1 manifest is the one that counts. The last two rows are this list and the manifest ('-': not measurable here)."
  echo "  tests/runbook_check.sh, runbook_mutate.py and gen_upload_list.sh go up so that the Phoenix copy of the kit is complete;"
  echo "  they are PC-only (they read the local inputs and WSL logs): do not run them on Phoenix."
  echo "Parts B and C (step B3.1): the inputs gated on 2026-09-25 (mesh.dat and the model are gitignored, only under"
  echo "  D:${BS}BEN${BS}FEMTIC_2026${BS}mesh), into the immutable input folders; no job ever runs there (runbook section 0)."
  echo "Part D (step B3.3): the rotated v2 data (STATUS D2; observe.dat sha256 $(sha256sum < "$ROT/observe.dat" | cut -c1-16)). It replaces B03 and B04 under"
  echo "  the same names; step B3.2 first keeps those two as observe_unrotated.dat and station_map_unrotated.csv."
  echo "  v3 takes the same pair (its unrotated files are byte-identical to v2's): if D1 picks v3, runbook B3.2 and B3.3 run again with vulcan_v3."
  echo "Local root of parts A and D: the worktree named in the rows (the changes are uncommitted there); after a merge, the"
  echo "  same relative paths under D:${BS}BEN${BS}FEMTIC_2026."
  echo "Not uploaded (compared with fa58604, the kit on Phoenix, by git diff on 2026-09-28; tests/runbook_check.sh checks it):"
  echo "  * 00_discover.sh and 02_env_femticpy.sh (unchanged since fa58604);"
  echo "  * hpc/ported/: the makefiles and patches are unchanged; only README.md changed (documentation, read by no script);"
  echo "  * discovery/ gained phoenix_build_foss_2026-09-25.log, and hpc/phoenix_plan/ has build_foss_20260925_181212.log: both are"
  echo "    copies of the build log that Phoenix already holds in /hpcfs/users/a1690074/femtic_src/;"
  echo "  * tools/__pycache__/ (Python's byte-code cache)."
  echo "Columns: id  step  local path  ->  Phoenix path  bytes  md5"
  echo
  echo "$B"
  echo
  echo "$B" | awk '$1 ~ /^[ABCD][0-9][0-9]$/ && $6 ~ /^[0-9]+$/ {k = substr($1, 1, 1); t[k] += $6; n[k]++}
       END {printf "Totals: part A %d files measured, %d bytes; part B (v2) %d files, %d bytes; part C (v3) %d files, %d bytes; part D (v2 rotated) %d files, %d bytes\n", n["A"], t["A"], n["B"], t["B"], n["C"], t["C"], n["D"], t["D"]}'
} > "$OUT"
