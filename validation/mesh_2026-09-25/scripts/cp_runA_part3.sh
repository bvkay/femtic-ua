#!/bin/bash
set -u
source /tmp/cp_common.sh
R=/home/tara/femtic_wsl/mesh_runs/chain_proof
NROUNDS=${1:-5}
cd $R
source /home/tara/miniforge3/etc/profile.d/conda.sh; conda activate femticpy
python -c 'import pandas; print("pandas", pandas.__version__)'
cp logs/output.1.ele.before_fix output.1.ele
step fix_output1 python $SP/femticPy/scripts/fix_output1.py || { echo "fix_output1 FAILED"; exit 1; }
head -3 logs/output.1.ele.before_fix; echo; head -3 output.1.ele; tail -2 output.1.ele
# numeric comparison ignoring whitespace and the tetgen comment footer
if diff -q <(awk '!/^#/{$1=$1; print}' logs/output.1.ele.before_fix) <(awk '!/^#/{$1=$1; print}' output.1.ele) >/dev/null; then echo "fix_output1: numeric content identical (no attribute > 30 to cap)"; else echo "fix_output1: numeric content CHANGED"; fi
echo "--- output.1.ele region attributes after fix"; ele_attrs output.1.ele
# STEP 6
cp files/{obs_site.dat,makeMtr.param} .
for i in $(seq 1 $NROUNDS); do
  step makeMtr_$i makeMtr output.$i || { echo "makeMtr $i FAILED"; exit 1; }
  step tetgen_r$i tetgen -nmpYVrAakq3.0/0 output.$i || { echo "tetgen refine $i FAILED"; exit 1; }
  j=$((i+1)); printf 'output.%d: nodes %s elements %s\n' $j "$(head -1 output.$j.node | awk '{print $1}')" "$(head -1 output.$j.ele | awk '{print $1}')"
done
N=$((NROUNDS+1))
echo "--- output.$N.ele region attributes"; ele_attrs output.$N.ele
# STEP 7
cp files/resistivity_attr.dat .
step t2f TetGen2Femtic output.$N; echo "TetGen2Femtic rc=$?"
grep -iE "error|cannot|resistivity data|number of" logs/t2f.log | head -20
ls -la mesh.dat resistivity_block_iter0.dat output.$N.femtic.vtk
echo "--- mesh.dat header"; head -2 mesh.dat
echo "--- resistivity_block_iter0.dat header"; head -1 resistivity_block_iter0.dat
cat logs/timings.tsv
