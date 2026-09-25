#!/bin/bash
cd /mnt/c/Users/joint/AppData/Local/Temp/claude/D--BEN-FEMTIC-2026/4e858f54-ea4e-47a8-9815-7766aca9830d/scratchpad/phoenix_plan
/tmp/scenv/bin/shellcheck -S warning -s bash -e SC1090,SC1091 *.sh *.slurm; echo "warning-level exit: $?"
/tmp/scenv/bin/shellcheck -S info -s bash -e SC1090,SC1091 -f gcc *.sh *.slurm | sed -E 's/^([^:]+):([0-9]+):[0-9]+: /\1:\2 /' | awk '{c[$0]++} END{for(k in c) print k}' | sort | head -60
