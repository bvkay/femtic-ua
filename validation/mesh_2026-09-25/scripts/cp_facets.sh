#!/bin/bash
# -Y evidence: number of PLC facets in output.poly vs boundary faces in the final mesh.dat
for r in chain_proof chain_proof_meshgen; do
  cd /home/tara/femtic_wsl/mesh_runs/$r
  nf=$(awk '/^# Part 2/{getline; print $1; exit}' output.poly)
  nn=$(sed -n 2p mesh.dat | awk '{print $1}')
  # after the node and element blocks, 7 lists: 6 outer planes + earth surface
  read -r outer surf < <(awk -v nn="$nn" '
    NR==nn+3 {ne=$1; start=nn+3+ne+1}
    start && NR>=start {
      if (need==0) { k++; cnt[k]=$1; need=$1; if (k==7 && need==0) exit; next }
      need--; if (k==7 && need==0) exit }
    END{ o=0; for(i=1;i<=6;i++) o+=cnt[i]; print o, cnt[7] }' mesh.dat)
  echo "$r: output.poly facets=$nf ; final mesh.dat outer-plane faces=$outer earth-surface faces=$surf sum=$((outer+surf))"
  # surface triangles in output.1 and output.6 boundary .face files (tetgen boundary faces incl. internal facets)
  echo "   output.1.face=$(head -1 output.1.face | awk '{print $1}') output.6.face=$(head -1 output.6.face | awk '{print $1}')"
done
