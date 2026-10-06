#!/usr/bin/env bash
# Runs checks a-e on the B2 smoke evidence and writes checks_output.txt next to this script.
# Light work only (python, awk, md5sum); reads Ben's D:/BEN/FEMTIC_2026/hpc/smoke_foss_20260928_211308 read-only.
# Run from anywhere inside the repository:  bash validation/phoenix_2026-09-28/checks/run_all.sh
cd "$(git rev-parse --show-toplevel)" || exit 1
H=validation/phoenix_2026-09-28/checks
PY=${PYTHON:-python}
{
  echo "# checks run $(date '+%F %T %z') in $(pwd) at commit $(git rev-parse --short HEAD) plus the uncommitted worktree"
  echo "# femtic_lib.sh (worktree) md5 $(md5sum < hpc/phoenix_plan/femtic_lib.sh | cut -c1-32); python $($PY --version 2>&1); $(bash --version | head -1)"
  for s in cnv_compare.py model_diff.py; do
    echo; echo "######## $s  (check $([ $s = cnv_compare.py ] && echo 'a + T5 rows' || echo 'b'))"; $PY "$H/$s"; echo "exit=$?"
  done
  for s in lib_parsers.sh timing.sh build_logs.sh; do echo; echo "######## $s"; bash "$H/$s"; echo "exit=$?"; done
} 2>&1 | tr -d '\r' > "$H/checks_output.txt"    # Windows python writes CRLF into a pipe
grep -E '^SUMMARY|^exit=|ratio .* (PASS|FAIL)' "$H/checks_output.txt"
