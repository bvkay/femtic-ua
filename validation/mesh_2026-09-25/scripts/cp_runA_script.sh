#!/bin/bash
# Re-run the upstream synthetic case through scripts/run_mesh_chain.sh and compare with the manual run
set -u
S=/home/tara/femtic_wsl/mesh_runs
rm -rf $S/chain_proof_script; mkdir -p $S/chain_proof_script
SP=/mnt/c/Users/joint/AppData/Local/Temp/claude/D--BEN-FEMTIC-2026/4e858f54-ea4e-47a8-9815-7766aca9830d/scratchpad
SRC=$SP/femticPy/projects/synthetic
# raw upstream (CRLF) inputs on purpose: the script must normalise them
cp $SRC/meshGen/files/{analysis_domain.dat,control.dat,makeMtr.param,observing_site.dat,obs_site.dat,resistivity_attr.dat} $S/chain_proof_script/
cp $SRC/input_data/{topography.dat,bathymetry.dat,coast_line.dat} $S/chain_proof_script/
printf '# meshGen.sh "example synthetic" seeds\n0.0 0.0 -40.0 10 1e9\n0.0 0.0 10.0 20 1e9\n' > $S/chain_proof_script/region_seeds.dat
bash /mnt/d/BEN/FEMTIC_2026/scripts/run_mesh_chain.sh $S/chain_proof_script 5; echo "script exit=$?"
echo "--- compare with manual run"
for f in output.poly output.6.node output.6.ele mesh.dat resistivity_block_iter0.dat; do
  a=$(md5sum < $S/chain_proof/$f | cut -c1-32); b=$(md5sum < $S/chain_proof_script/$f | cut -c1-32)
  if [ "$a" = "$b" ]; then echo "IDENTICAL $f $a"; else echo "DIFFERENT $f $a $b"; fi
done
diff <(awk '!/^#/' $S/chain_proof/output.poly) <(awk '!/^#/' $S/chain_proof_script/output.poly) | head
