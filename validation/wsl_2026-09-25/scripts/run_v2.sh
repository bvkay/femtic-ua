#!/bin/bash
# runner: strip CR from the two scripts, run generator then verifier, log to scratchpad
SC=/mnt/c/Users/joint/AppData/Local/Temp/claude/D--BEN-FEMTIC-2026/4e858f54-ea4e-47a8-9815-7766aca9830d/scratchpad
sed 's/\r$//' "$SC/gen_v2.sh"    > /tmp/gen_v2.sh
sed 's/\r$//' "$SC/verify_v2.sh" > /tmp/verify_v2.sh
bash /tmp/gen_v2.sh    > "$SC/gen_v2.log"    2>&1; echo "gen-rc=$?"    | tee -a "$SC/gen_v2.log"
bash /tmp/verify_v2.sh > "$SC/verify_v2.log" 2>&1; echo "verify-rc=$?" | tee -a "$SC/verify_v2.log"
