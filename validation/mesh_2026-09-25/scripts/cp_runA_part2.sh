#!/bin/bash
set -u
source /tmp/cp_common.sh
R=/home/tara/femtic_wsl/mesh_runs/chain_proof
cd $R
cp output.poly logs/output.poly.before_seed
# meshGen.sh "example synthetic" seed block (land-only: air 10 above, earth 20 below the flat z=0 surface)
sed -i "$(( $(wc -l < output.poly) ))s/.*/2/" output.poly
echo "1   0.0 0.0 -40.0  10 1e9" >> output.poly
echo "2  0.0 0.0  10.0  20 1e9" >> output.poly
echo "--- diff before/after seed edit"; diff logs/output.poly.before_seed output.poly
step tetgen_stp5 tetgen -nVpYAakq3.0/0 output.poly; echo "tetgen rc=$?"
grep -iE "subdomain|domain\.|warning|error" logs/tetgen_stp5.log
head -1 output.1.node; head -1 output.1.ele; tail -1 output.1.ele
echo "--- output.1.ele region attributes"; ele_attrs output.1.ele
cp output.1.ele logs/output.1.ele.before_fix
source /home/tara/miniforge3/etc/profile.d/conda.sh; conda activate femticpy
python -c 'import pandas; print("pandas", pandas.__version__)'
step fix_output1_pandas3 python $SP/femticPy/scripts/fix_output1.py; echo "fix_output1 rc=$?"
tail -5 logs/fix_output1_pandas3.log
cmp -s output.1.ele logs/output.1.ele.before_fix && echo "output.1.ele unchanged" || echo "output.1.ele CHANGED"
cat logs/timings.tsv
