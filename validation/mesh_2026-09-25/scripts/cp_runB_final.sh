#!/bin/bash
# Re-run Run B (MeshGen inputs) with the FINAL scripts/run_mesh_chain.sh, compare with the first run, re-check, copy back
set -u
R=/home/tara/femtic_wsl/mesh_runs/chain_proof_meshgen
D=/mnt/d/BEN/FEMTIC_2026/mesh/chain_proof_meshgen
V=/mnt/d/BEN/FEMTIC_2026/validation/mesh_2026-09-25
old_mesh=$(md5sum < $R/mesh.dat); old_blk=$(md5sum < $R/resistivity_block_iter0.dat)
bash /mnt/d/BEN/FEMTIC_2026/scripts/run_mesh_chain.sh $R 5 > /tmp/runB_stdout.txt 2>&1; echo "script exit=$?"
cp /tmp/runB_stdout.txt $R/logs/run_mesh_chain.stdout
cat /tmp/runB_stdout.txt
[ "$(md5sum < $R/mesh.dat)" = "$old_mesh" ] && echo "mesh.dat IDENTICAL to first run" || echo "mesh.dat DIFFERENT from first run"
[ "$(md5sum < $R/resistivity_block_iter0.dat)" = "$old_blk" ] && echo "resistivity_block IDENTICAL to first run" || echo "resistivity_block DIFFERENT"
source /home/tara/miniforge3/etc/profile.d/conda.sh; conda activate femticpy
python $V/check_mesh.py $R --flat-surface-z 0 > $R/logs/check_mesh.txt 2>&1; echo "check_mesh exit=$?"; tail -1 $R/logs/check_mesh.txt
python $V/check_mesh.py /home/tara/femtic_wsl/mesh_runs/chain_proof --flat-surface-z 0 > /home/tara/femtic_wsl/mesh_runs/chain_proof/logs/check_mesh.txt 2>&1; echo "check_mesh A exit=$?"
rm -rf $D/logs; cp -r $R/logs $D/logs; cp $R/makeTetraMesh.log $D/logs/makeTetraMesh_last.log
cp /home/tara/femtic_wsl/mesh_runs/chain_proof/logs/check_mesh.txt /mnt/d/BEN/FEMTIC_2026/mesh/chain_proof/logs/
cp $R/mesh.dat $R/resistivity_block_iter0.dat $R/output.6.femtic.vtk $R/output.poly $R/region_seeds.used $D/
( cd $D && md5sum mesh.dat resistivity_block_iter0.dat > products.md5 && cat products.md5 )
