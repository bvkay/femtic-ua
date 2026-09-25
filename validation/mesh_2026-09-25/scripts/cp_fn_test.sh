#!/bin/bash
# Test the copy-pasteable femtic_mesh_chain function from chain_proof.md
set -u
SP=/mnt/c/Users/joint/AppData/Local/Temp/claude/D--BEN-FEMTIC-2026/4e858f54-ea4e-47a8-9815-7766aca9830d/scratchpad
SRC=$SP/femticPy/projects/synthetic
REF=/home/tara/femtic_wsl/mesh_runs/chain_proof
S=/home/tara/femtic_wsl/mesh_runs/chain_fn_test; rm -rf $S; mkdir -p $S/ok $S/swapless
sed 's/\r$//' $SP/chain_proof_work/femtic_mesh_chain.fn.sh > /tmp/fn.sh; source /tmp/fn.sh
for d in ok swapless; do
  cp $SRC/meshGen/files/{analysis_domain.dat,control.dat,makeMtr.param,observing_site.dat,obs_site.dat,resistivity_attr.dat} $S/$d/
  cp $SRC/input_data/{topography.dat,bathymetry.dat,coast_line.dat} $S/$d/
done
printf '# air above, earth below\n0.0 0.0 -40.0 10 1e9\n0.0 0.0 10.0 20 1e9\n' > $S/ok/region_seeds.dat
printf '0.0 0.0 -40.0 10 1e9\n' > $S/swapless/region_seeds.dat
echo "F1 expect OK and md5 identical to manual Run A"
femtic_mesh_chain $S/ok 5; echo "rc=$?"
for f in mesh.dat resistivity_block_iter0.dat; do [ "$(md5sum < $S/ok/$f)" = "$(md5sum < $REF/$f)" ] && echo "IDENTICAL $f" || echo "DIFFERENT $f"; done
echo "F1b rerun same dir, expect OK and identical"
femtic_mesh_chain $S/ok 5; echo "rc=$?"; [ "$(md5sum < $S/ok/mesh.dat)" = "$(md5sum < $REF/mesh.dat)" ] && echo "IDENTICAL mesh.dat"
echo "F2 only the air seed -> expect FAIL rc=1 and no mesh.dat"
femtic_mesh_chain $S/swapless 5; echo "rc=$?"; ls $S/swapless/mesh.dat 2>&1 | tail -1
