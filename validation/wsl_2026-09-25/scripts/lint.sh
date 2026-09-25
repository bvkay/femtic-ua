#!/bin/bash
P=/mnt/c/Users/joint/AppData/Local/Temp/claude/D--BEN-FEMTIC-2026/4e858f54-ea4e-47a8-9815-7766aca9830d/scratchpad/phoenix_plan
for f in $P/*.sh $P/*.slurm; do printf '%-22s bash -n: %s  CR=%s  shebang=%s\n' "$(basename $f)" "$(bash -n $f 2>&1 && echo ok)" "$(tr -cd '\r' < $f | wc -c)" "$(head -1 $f)"; done
command -v shellcheck && shellcheck --version | head -2 || echo "shellcheck: not installed"
