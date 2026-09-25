#!/bin/bash
source /home/tara/miniforge3/etc/profile.d/conda.sh
[ -x /tmp/scenv/bin/shellcheck ] || mamba create -y -q -p /tmp/scenv -c conda-forge shellcheck >/tmp/sc_install.log 2>&1
P=/mnt/c/Users/joint/AppData/Local/Temp/claude/D--BEN-FEMTIC-2026/4e858f54-ea4e-47a8-9815-7766aca9830d/scratchpad/phoenix_plan
/tmp/scenv/bin/shellcheck --version | head -2
cd $P && /tmp/scenv/bin/shellcheck -S warning -s bash -e SC1090,SC1091 00_discover.sh 01_build_femtic.sh 02_env_femticpy.sh 03_mesh.slurm 04_inversion.slurm 05_chain.sh femtic_lib.sh
echo "shellcheck exit: $?"
