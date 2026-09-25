#!/bin/bash
set -u
LOG=/home/tara/femtic_wsl/mesh_runs/env_create.log
mkdir -p /home/tara/femtic_wsl/mesh_runs
source /home/tara/miniforge3/etc/profile.d/conda.sh
start=$(date +%s)
{
echo "CMD: mamba create -y -n femticpy -c conda-forge python=3.12 numpy scipy pandas matplotlib pyproj shapely rdp tabulate pyyaml jupyterlab"
mamba create -y -n femticpy -c conda-forge python=3.12 numpy scipy pandas matplotlib pyproj shapely rdp tabulate pyyaml jupyterlab
echo "EXIT=$?"
echo "ELAPSED=$(( $(date +%s) - start ))"
} > $LOG 2>&1
touch /home/tara/femtic_wsl/mesh_runs/env_create.DONE
