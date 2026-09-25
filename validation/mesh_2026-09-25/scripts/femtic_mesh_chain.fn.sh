femtic_mesh_chain() {  # usage: femtic_mesh_chain RUN_DIR [N_ROUNDS=5]; needs RUN_DIR/region_seeds.dat ("x y z attr maxvol" per region)
  local dir=$1 n=${2:-5}
  ( set -eo pipefail
    export PATH=/home/tara/femtic_wsl/bin:$PATH
    cd "$dir"
    rm -f output.* mesh.dat resistivity_block_iter0.dat           # never let a stale product pass
    sed -i 's/\r$//' ./*.dat ./*.param                            # CRLF -> LF (harmless if already LF)
    for s in 1 2 3 4; do makeTetraMesh -stp "$s"; done            # makeTetraMesh.log is overwritten each step
    awk '!/^[[:space:]]*(#|$)/' region_seeds.dat > seeds.tmp
    sed -i "$(wc -l < output.poly)s/.*/$(wc -l < seeds.tmp)/" output.poly   # last line "0" = region count
    awk '{print NR, $0}' seeds.tmp >> output.poly                          # "i x y z attr maxvol"
    tetgen -nVpYAakq3.0/0 output.poly > tetgen_1.log
    want=$(awk '{print $4+0}' seeds.tmp | sort -nu | xargs)
    got=$(awk 'NR>1 && !/^#/ {print $NF+0}' output.1.ele | sort -nu | xargs)
    [ "$got" = "$want" ] || { echo "FAIL: tetgen region attributes {$got} != seeded {$want}" >&2; exit 1; }
    for i in $(seq 1 "$n"); do
      makeMtr "output.$i" > "makeMtr_$i.log"
      tetgen -nmpYVrAakq3.0/0 "output.$i" > "tetgen_r$i.log"
    done
    TetGen2Femtic "output.$((n + 1))" > t2f.log
    echo "OK: $(sed -n 2p mesh.dat | xargs) nodes; elements/cells: $(head -1 resistivity_block_iter0.dat | xargs)"
  )
}
