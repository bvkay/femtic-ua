#!/bin/bash
set -u
S=/home/tara/femtic_wsl/mesh_runs; R=$S/chain_proof_meshgen
V=/mnt/d/BEN/FEMTIC_2026/validation/mesh_2026-09-25
source /home/tara/miniforge3/etc/profile.d/conda.sh; conda activate femticpy
export PYTHONPATH=/mnt/c/Users/joint/AppData/Local/Temp/claude/D--BEN-FEMTIC-2026/4e858f54-ea4e-47a8-9815-7766aca9830d/scratchpad/femticPy/src
rm -rf $R
python $V/make_meshgen_case.py $R || { echo "input generation FAILED"; exit 1; }
cd $R
for f in *; do printf '%-22s %6d lines  %s\n' "$f" "$(wc -l < $f)" "$(file -b $f)"; done
echo "--- control.dat"; cat control.dat; echo; echo "--- makeMtr.param"; cat makeMtr.param; echo
echo "--- resistivity_attr.dat (head)"; head -16 resistivity_attr.dat
echo "--- obs_site.dat (head)"; head -9 obs_site.dat
echo "--- observing_site.dat (head)"; head -3 observing_site.dat
echo "--- coast_line.dat"; cat coast_line.dat
echo "--- analysis_domain.dat"; cat analysis_domain.dat
bash /mnt/d/BEN/FEMTIC_2026/scripts/run_mesh_chain.sh $R 5; echo "script exit=$?"
cat logs/refinement.tsv
python $V/check_mesh.py $R --flat-surface-z 0; echo "check_mesh exit=$?"
