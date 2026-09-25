#!/bin/bash
source /home/tara/miniforge3/etc/profile.d/conda.sh
LOG=/home/tara/femtic_wsl/mesh_runs/env_pin.log
start=$(date +%s)
{
echo 'CMD: mamba install -y -n femticpy -c conda-forge "pandas>=1.5,<3"'
mamba install -y -n femticpy -c conda-forge "pandas>=1.5,<3"
echo "EXIT=$?"; echo "ELAPSED=$(( $(date +%s) - start ))"
} > $LOG 2>&1
grep -E "^\s+[-+~^v]|EXIT|ELAPSED|CMD" $LOG | head -30
conda activate femticpy
export PYTHONPATH=/mnt/c/Users/joint/AppData/Local/Temp/claude/D--BEN-FEMTIC-2026/4e858f54-ea4e-47a8-9815-7766aca9830d/scratchpad/femticPy/src
python -W ignore -c 'import femticPy, numpy, scipy, pandas, matplotlib, pyproj, shapely, rdp, tabulate, yaml; print("import femticPy OK; numpy",numpy.__version__,"scipy",scipy.__version__,"pandas",pandas.__version__,"matplotlib",matplotlib.__version__,"pyproj",pyproj.__version__,"shapely",shapely.__version__)'
echo "import exit=$?"
