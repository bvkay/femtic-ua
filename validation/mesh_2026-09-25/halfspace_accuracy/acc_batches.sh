#!/usr/bin/env bash
# acc_batches.sh -- run several batches of acc_batch.sh one after another (one heavy job at a time) and stop at
# the first batch that fails or is stopped by the watchdog. Writes BATCHES.DONE with the outcome.
#
#   acc_batches.sh N RHO NP NT "K1 K2 ..."      e.g.  acc_batches.sh 1 100 2 4 "1 2 3 4"
set -uo pipefail
N=$1; RHO=$2; NP=$3; NT=$4; KS=$5
HERE=/mnt/d/BEN/FEMTIC_2026/validation/mesh_2026-09-25/halfspace_accuracy
ROOT=/home/tara/femtic_wsl/mesh_runs/acc_v${N}_${RHO}
mkdir -p "$ROOT"
TAG=$(echo "$KS" | tr ' ' '_')
MARK=$ROOT/BATCHES_${TAG}.DONE
rm -f "$MARK"
sed 's/\r$//' "$HERE/acc_batch.sh" > /tmp/acc_batch_$$.sh
for K in $KS; do
  bash /tmp/acc_batch_$$.sh "$N" "$RHO" "$K" "$NP" "$NT" > "$ROOT/batch_$K.out" 2>&1
  rc=$?
  cat "$ROOT/batch_$K.out"
  if [ $rc -ne 0 ]; then echo "stopped at batch $K rc=$rc $(date -Is)" > "$MARK"; exit $rc; fi
done
echo "ok batches $KS $(date -Is)" > "$MARK"
