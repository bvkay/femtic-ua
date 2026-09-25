#!/bin/bash
cd /home/tara/femtic_wsl/mesh_runs/chain_proof_meshgen
awk 'NR==1{next} /^#/{next} NF>0{c[$NF+0]++} END{for(k in c) printf "B output.6 attr %s : %d\n", k, c[k]}' output.6.ele
grep -E "touch the top" logs/*.log 2>/dev/null | head; true
cd /mnt/d/BEN/FEMTIC_2026/mesh
n=0; for f in $(find . -type f -size -3M); do if grep -q "$(printf '\r')" "$f"; then echo "CR in $f"; n=$((n+1)); fi; done; echo "files with CR under mesh/ (<3MB): $n"
for f in chain_proof/mesh.dat chain_proof_meshgen/mesh.dat chain_proof/resistivity_block_iter0.dat chain_proof_meshgen/resistivity_block_iter0.dat; do
  if grep -q "$(printf '\r')" "$f"; then echo "CR in $f"; fi; done
cat chain_proof/products.md5 chain_proof_meshgen/products.md5
