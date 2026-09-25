#!/usr/bin/env bash
# acc_chain_rest.sh -- the remaining half-space batches after each configuration's first batch was measured
# (policy: measure RSS on the first batch before continuing). Strictly sequential; stops at the first batch
# that fails or is stopped by the watchdog. All runs 1 rank x 8 threads, nice 10, 40 GB watchdog (acc_batch.sh).
set -uo pipefail
HERE=/mnt/d/BEN/FEMTIC_2026/validation/mesh_2026-09-25/halfspace_accuracy
sed 's/\r$//' "$HERE/acc_batches.sh" > /tmp/acc_batches_chain.sh
MARK=/home/tara/femtic_wsl/mesh_runs/ACC_CHAIN.DONE
rm -f "$MARK"
run() { bash /tmp/acc_batches_chain.sh "$@" > /dev/null 2>&1; rc=$?; echo "$(date -Is) acc_batches $* rc=$rc"; [ $rc -eq 0 ]; }
run 3 3 1 8 "2 3 4" && run 3 100 1 8 "1 2 3 4" && run 1 100 1 8 "1 2 3 4" && run 2 100 1 8 "1 2 3 4"
echo "chain end rc=$? $(date -Is)" | tee "$MARK"
