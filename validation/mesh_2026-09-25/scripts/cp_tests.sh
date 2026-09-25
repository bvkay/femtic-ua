#!/bin/bash
# Negative controls and script tests. Each test states the expected outcome; OVERALL FAIL if any differs.
set -u
export PATH=/home/tara/femtic_wsl/bin:$PATH
S=/home/tara/femtic_wsl/mesh_runs/chain_tests; rm -rf $S; mkdir -p $S
SP=/mnt/c/Users/joint/AppData/Local/Temp/claude/D--BEN-FEMTIC-2026/4e858f54-ea4e-47a8-9815-7766aca9830d/scratchpad
SRC=$SP/femticPy/projects/synthetic
CHAIN=/mnt/d/BEN/FEMTIC_2026/scripts/run_mesh_chain.sh
CHECK=/mnt/d/BEN/FEMTIC_2026/validation/mesh_2026-09-25/check_mesh.py
REF=/home/tara/femtic_wsl/mesh_runs/chain_proof
CR=$(printf '\r')
source /home/tara/miniforge3/etc/profile.d/conda.sh; conda activate femticpy
fail=0
chk(){ if [ "$2" = "$3" ]; then echo "  PASS $1 (got '$2')"; else echo "  FAIL $1: got '$2' want '$3'"; fail=1; fi; }
newcase(){ # newcase <name> [raw] : upstream synthetic inputs (LF unless raw)
  local d=$S/$1; mkdir -p $d
  cp $SRC/meshGen/files/{analysis_domain.dat,control.dat,makeMtr.param,observing_site.dat,obs_site.dat,resistivity_attr.dat} $d/
  cp $SRC/input_data/{topography.dat,bathymetry.dat,coast_line.dat} $d/
  [ "${2:-}" = raw ] || sed -i 's/\r$//' $d/*
  echo $d
}
manual(){ # manual <dir> <rounds> <seed lines...> : bare meshGen.sh sequence, no checks; prints rc of each tool
  local d=$1 n=$2; shift 2; cd $d
  for s in 1 2 3 4; do makeTetraMesh -stp $s > /dev/null 2>&1; echo "rc makeTetraMesh-$s=$?"; done
  sed -i "$(( $(wc -l < output.poly) ))s/.*/$#/" output.poly
  local k=0; for l in "$@"; do k=$((k+1)); echo "$k $l" >> output.poly; done
  tetgen -nVpYAakq3.0/0 output.poly > tetgen_1.log 2>&1; echo "rc tetgen=$?"
  python $SP/femticPy/scripts/fix_output1.py > fix.log 2>&1; echo "rc fix_output1=$?"
  for i in $(seq 1 $n); do
    makeMtr output.$i > mtr_$i.log 2>&1; echo "rc makeMtr-$i=$?"
    tetgen -nmpYVrAakq3.0/0 output.$i > tg_$i.log 2>&1; echo "rc tetgen_r-$i=$?"
  done
  TetGen2Femtic output.$((n+1)) > t2f.log 2>&1; echo "rc TetGen2Femtic=$?"
  cd - > /dev/null
}
attrs(){ awk 'NR==1{next} /^#/{next} NF>0{print $NF+0}' $1 | sort -n | uniq | tr '\n' ' ' | sed 's/ $//'; }

echo "T0 usage: no arguments -> exit 2 and help text"
out=$(bash $CHAIN 2>&1); rc=$?; chk rc $rc 2; chk help "$(echo "$out" | grep -c 'Usage (inside WSL)')" 1

echo "T1 positive: raw CRLF upstream inputs + meshGen.sh synthetic seeds via script -> CHAIN OK, mesh.dat/resistivity_block identical to manual Run A"
d=$(newcase t1 raw); printf '0.0 0.0 -40.0 10 1e9\n0.0 0.0 10.0 20 1e9\n' > $d/region_seeds.dat
bash $CHAIN $d 5 > $d.out 2>&1; chk rc $? 0; chk ok "$(tail -1 $d.out)" "CHAIN OK"
chk crlf_notes "$(grep -c 'converted CRLF' $d.out)" 9
for f in mesh.dat resistivity_block_iter0.dat; do chk "md5 $f" "$(md5sum < $d/$f)" "$(md5sum < $REF/$f)"; done
grep "touch the top" $d.out | sed 's/^/     /'
echo "T1b rerun in the same dir (stale products must be wiped first) -> CHAIN OK, identical again"
bash $CHAIN $d 5 > $d.out2 2>&1; chk rc $? 0; chk md5 "$(md5sum < $d/mesh.dat)" "$(md5sum < $REF/mesh.dat)"

echo "T2 swapped seeds (air attr 10 seeded BELOW the surface, earth 20 ABOVE)"
echo "   T2a bare tool chain -> every tool exits 0 (the tools cannot see the error)"
d=$(newcase t2a); manual $d 5 "0.0 0.0 -40.0 20 1e9" "0.0 0.0 10.0 10 1e9" > $d.out
chk nonzero_tool_rcs "$(grep -vc '=0$' $d.out)" 0; chk products "$(ls $d/mesh.dat $d/resistivity_block_iter0.dat 2>/dev/null | wc -l)" 2
echo "   T2b check_mesh.py on that product -> exit 1 (air cell below the surface)"
python $CHECK $d --flat-surface-z 0 > $d.check 2>&1; chk check_rc $? 1
grep FAIL $d.check | sed 's/^/     /'
echo "   T2c run_mesh_chain.sh -> CHAIN FAILED at the air-on-top check, no mesh.dat"
d=$(newcase t2c); printf '0.0 0.0 -40.0 20 1e9\n0.0 0.0 10.0 10 1e9\n' > $d/region_seeds.dat
bash $CHAIN $d 5 > $d.out 2>&1; chk rc $? 1; chk msg "$(grep -c 'CHAIN FAILED: air attribute' $d.out)" 1
chk no_mesh "$(ls $d/mesh.dat 2>/dev/null | wc -l)" 0
grep -E "touch the top|CHAIN FAILED" $d.out | sed 's/^/     /'

echo "T3 both seeds in the air region -> earth unseeded -> tetgen gives it 21 -> CHAIN FAILED on attribute set"
# First run predicted {10 20 21} and got {10 21}: tetgen does report 'Found 3 subdomains' (the 2nd seed re-labels
# only its own seed tet as 20), but that single tet is replaced during quality optimisation, so 20 never reaches
# output.1.ele. The script's verdict (FAIL, rc 1) is unchanged; expectation corrected after reading tetgen.cxx.
d=$(newcase t3); printf '0.0 0.0 -40.0 10 1e9\n0.0 0.0 -50.0 20 1e9\n' > $d/region_seeds.dat
bash $CHAIN $d 5 > $d.out 2>&1; chk rc $? 1; chk attrs "$(attrs $d/output.1.ele)" "10 21"
chk tetgen_subdomains "$(grep -c 'Found 3 subdomains' $d/logs/tetgen_1.log)" 1
grep -E "attr |CHAIN FAILED" $d.out | sed 's/^/     /'

echo "T4 earth seed missing, bare tool chain incl. fix_output1 (the 31/32 fix) -> attrs {10 11}; fix_output1 leaves 11 (<=30);"
echo "   TetGen2Femtic exits 1 'Region attribute 11 cannot be found' but mesh.dat is already written"
d=$(newcase t4); manual $d 0 "0.0 0.0 -40.0 10 1e9" > $d.out
chk attrs_after_fix "$(attrs $d/output.1.ele)" "10 11"; chk fix_rc "$(grep 'rc fix_output1' $d.out)" "rc fix_output1=0"
chk t2f_rc "$(grep 'rc TetGen2Femtic' $d.out)" "rc TetGen2Femtic=1"
chk t2f_msg "$(grep -c 'Region attiribute << 11' $d/t2f.log)" 1
chk mesh_dat_exists "$(ls $d/mesh.dat 2>/dev/null | wc -l)" 1; chk block_exists "$(ls $d/resistivity_block_iter0.dat 2>/dev/null | wc -l)" 0
grep -i "error" $d/t2f.log | sed 's/^/     /'
echo "   T4b same via script -> refused in preflight (seeded {10} != resistivity_attr {10 20})"
d=$(newcase t4b); printf '0.0 0.0 -40.0 10 1e9\n' > $d/region_seeds.dat
bash $CHAIN $d 5 > $d.out 2>&1; chk rc $? 1; grep "CHAIN FAILED" $d.out | sed 's/^/     /'

echo "T5 raw CRLF inputs through the bare tools (no conversion) -> same mesh.dat as LF run?"
d=$(newcase t5 raw); chk crlf_files "$(grep -l "$CR" $d/* | wc -l)" 9
manual $d 5 "0.0 0.0 -40.0 10 1e9" "0.0 0.0 10.0 20 1e9" > $d.out
chk nonzero_tool_rcs "$(grep -vc '=0$' $d.out)" 0
chk md5_mesh "$(md5sum < $d/mesh.dat)" "$(md5sum < $REF/mesh.dat)"
chk md5_block "$(md5sum < $d/resistivity_block_iter0.dat)" "$(md5sum < $REF/resistivity_block_iter0.dat)"
echo "T5b meshGen.sh itself is CRLF: its first lines (cd into the project) fail under bash"
mkdir -p $S/t5b/sub; head -4 $SP/femticPy/scripts/meshGen.sh | sed 's#\.\./projects/\$project#sub#' > $S/t5b/x.sh
( cd $S/t5b && bash x.sh synthetic > out.txt 2>&1; echo "rc=$?" >> out.txt ); sed 's/^/     /' $S/t5b/out.txt
chk crlf_script_breaks "$(grep -c 'No such file or directory' $S/t5b/out.txt)" 1

echo "T6 missing input -> preflight refuses and names the file"
d=$(newcase t6); rm $d/obs_site.dat
bash $CHAIN $d 5 > $d.out 2>&1; chk rc $? 1; chk msg "$(grep -c 'missing input file(s): obs_site.dat' $d.out)" 1

echo "T7 seed outside the analysis domain -> refused"
d=$(newcase t7); printf '0.0 0.0 -400.0 10 1e9\n0.0 0.0 10.0 20 1e9\n' > $d/region_seeds.dat
bash $CHAIN $d 5 > $d.out 2>&1; chk rc $? 1; chk msg "$(grep -c 'outside the analysis domain' $d.out)" 1

echo "T8 FIX_OUTPUT1=1 path (pandas 2.3.3) -> CHAIN OK and identical mesh (fix is a no-op for 10/20)"
d=$(newcase t8); printf '0.0 0.0 -40.0 10 1e9\n0.0 0.0 10.0 20 1e9\n' > $d/region_seeds.dat
FIX_OUTPUT1=1 FIX_OUTPUT1_PY=$SP/femticPy/scripts/fix_output1.py bash $CHAIN $d 5 > $d.out 2>&1; chk rc $? 0
chk fix_ran "$(grep -c 'fix_output1 rc=0' $d.out)" 1; chk md5 "$(md5sum < $d/mesh.dat)" "$(md5sum < $REF/mesh.dat)"

echo "T9 N_ROUNDS=0 with default land-only seeds -> TetGen2Femtic on output.1, CHAIN OK"
d=$(newcase t9); bash $CHAIN $d 0 > $d.out 2>&1; chk rc $? 0; chk vtk "$(ls $d/output.1.femtic.vtk 2>/dev/null | wc -l)" 1
grep -E "region seeds  |nodes / elements|parameter cells" $d.out | sed 's/^/     /'

echo; echo "OVERALL: $([ $fail = 0 ] && echo PASS || echo FAIL)"
