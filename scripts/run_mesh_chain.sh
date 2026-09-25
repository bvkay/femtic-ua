#!/usr/bin/env bash
# run_mesh_chain.sh -- FEMTIC tetrahedral mesh chain, as in femticPy scripts/meshGen.sh, with checks.
#
#   makeTetraMesh -stp 1..4  ->  region seeds into output.poly  ->  tetgen -nVpYAakq3.0/0 output.poly
#   -> [optional femticPy fix_output1.py]  ->  N x (makeMtr output.i ; tetgen -nmpYVrAakq3.0/0 output.i)
#   -> TetGen2Femtic output.(N+1)   =>  mesh.dat, resistivity_block_iter0.dat, output.(N+1).femtic.vtk
#
# Usage (inside WSL):  run_mesh_chain.sh RUN_DIR [N_ROUNDS]      (N_ROUNDS default 5, as meshGen.sh)
#
# RUN_DIR must already contain the inputs (km; FEMTIC frame: x = north, y = east, z positive DOWN):
#   control.dat analysis_domain.dat observing_site.dat coast_line.dat   (makeTetraMesh)
#   the ALTITUDE and SEA_DEPTH files named in control.dat               (makeTetraMesh step 3)
#   obs_site.dat makeMtr.param                                           (makeMtr)
#   resistivity_attr.dat                                                 (TetGen2Femtic; 1st attribute = air)
#   lake.dat                                                             (optional)
#   region_seeds.dat  (optional) one seed per line: "x y z attr maxvol" (km, km^3); '#' comments allowed.
#       If absent AND resistivity_attr.dat lists exactly 2 attributes (land-only: air, earth), default seeds
#       are placed at the domain centre, half-way to the top (air) and half-way to the bottom (earth).
#       Models with sea or lakes MUST supply region_seeds.dat (one seed inside every closed region).
#
# Environment overrides:
#   FEMTIC_BIN     directory with makeTetraMesh tetgen makeMtr TetGen2Femtic   (default /home/tara/femtic_wsl/bin)
#   FIX_OUTPUT1=1  also run femticPy fix_output1.py after the first tetgen (caps region attributes > 30 at 30;
#                  only meaningful for air 10 / sea 20 / earth 30 models). Needs FIX_OUTPUT1_PY (path to the
#                  script) and a python with 1.5 <= pandas < 3 (conda env FEMTICPY_ENV, default femticpy).
#   T2F_ARGS       extra TetGen2Femtic arguments (e.g. "-thread 8")
#
# The chain FAILS (non-zero exit, "CHAIN FAILED" on stderr) if any tool exits non-zero, an expected product
# is missing, tetgen's region attributes differ from the seeded set, the air attribute is not the one on the
# top plane of the domain (or appears on the bottom plane), the element counts in output.N.ele,
# mesh.dat and resistivity_block_iter0.dat disagree, or the element volumes do not sum to the analysis box.
# Everything a previous run produced in RUN_DIR (output.*, mesh.dat, ...) is deleted first, so a stale
# product can never satisfy a check. Logs, per-step timings and a summary go to RUN_DIR/logs/.
set -uo pipefail

die() { echo "CHAIN FAILED: $*" >&2; [ -d logs ] && echo "CHAIN FAILED: $*" >> logs/summary.txt; exit 1; }

if [ $# -lt 1 ] || [ $# -gt 2 ]; then awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 2; fi
RUN_DIR=$1
NROUNDS=${2:-5}
[[ "$NROUNDS" =~ ^[0-9]+$ ]] || { echo "N_ROUNDS must be a non-negative integer" >&2; exit 2; }
FEMTIC_BIN=${FEMTIC_BIN:-/home/tara/femtic_wsl/bin}
export PATH="$FEMTIC_BIN:$PATH"
for t in makeTetraMesh tetgen makeMtr TetGen2Femtic bc; do
  command -v "$t" >/dev/null || { echo "CHAIN FAILED: $t not found (FEMTIC_BIN=$FEMTIC_BIN)" >&2; exit 1; }
done
cd "$RUN_DIR" || { echo "CHAIN FAILED: cannot cd to $RUN_DIR" >&2; exit 1; }

# ---------------------------------------------------------------- clean previous products
rm -rf logs
rm -f output.* mesh.dat resistivity_block_iter0.dat makeTetraMesh.log region_seeds.used \
      ./*.stp1 ./*.stp2 ./*.stp3 ./*.vtk
mkdir -p logs
printf 'step\trc\twall_s\ttime_report\n' > logs/timings.tsv
T_START=$(date +%s.%N)

step() { # step <name> <cmd...> : run, log stdout+stderr to logs/<name>.log, append timing row
  local name=$1; shift
  local t0 t1 rc
  t0=$(date +%s.%N)
  if [ -x /usr/bin/time ]; then
    /usr/bin/time -f "%e s wall, %M KB maxrss" -o "logs/$name.time" "$@" > "logs/$name.log" 2>&1; rc=$?
  else
    "$@" > "logs/$name.log" 2>&1; rc=$?; echo "n/a" > "logs/$name.time"
  fi
  t1=$(date +%s.%N)
  printf '%s\t%d\t%.2f\t%s\n' "$name" "$rc" "$(echo "$t1 - $t0" | bc -l)" "$(tail -1 "logs/$name.time")" >> logs/timings.tsv
  echo "[$(date +%T)] $name rc=$rc ($(tail -1 "logs/$name.time"))"
  return $rc
}
ele_attr_set()  { awk 'NR==1{next} /^#/{next} NF>0{print $NF+0}' "$1" | sort -n | uniq | tr '\n' ' ' | sed 's/ $//'; }
# air_on_top <root> : every element touching the top plane (z = zmin) must carry the air attribute and no
# element touching the bottom plane (z = zmax) may carry it. Catches seeds placed in the wrong region
# (e.g. air and earth attributes swapped), which the attribute-set comparison alone cannot see.
air_on_top() {
  local r
  r=$(awk -v zt="$ZMIN" -v zb="$ZMAX" -v air="$AIR_ATTR" '
    FNR==1{next} /^#/{next}
    FILENAME ~ /\.node$/ {z[$1]=$4; next}
    { eps=1e-9*(zb-zt); top=0; bot=0
      for(k=2;k<=5;k++){ if(z[$k]-zt<eps) top=1; if(zb-z[$k]<eps) bot=1 }
      if(top){nt++; if($NF+0!=air) bt++}  if(bot){nb++; if($NF+0==air) bb++} }
    END{printf "%d %d %d %d", nt, bt+0, nb, bb+0}' "$1.node" "$1.ele")
  read -r NT BT NB BB <<< "$r"
  echo "$1: $NT elements touch the top plane ($BT not air), $NB touch the bottom plane ($BB air)"
  [ "$NT" -gt 0 ] && [ "$NB" -gt 0 ] && [ "$BT" -eq 0 ] && [ "$BB" -eq 0 ]
}
ele_attr_hist() { awk 'NR==1{next} /^#/{next} NF>0{c[$NF+0]++} END{for(k in c) printf "  attr %s : %d elements\n", k, c[k]}' "$1" | sort -n -k2; }

# ---------------------------------------------------------------- preflight
kw_file() { awk -v k="$1" '{sub(/\r$/,"")} $1==k{getline; sub(/\r$/,""); print $1; exit}' control.dat; }
[ -f control.dat ] || die "control.dat missing in $RUN_DIR"
ALT_FILE=$(kw_file ALTITUDE); SEA_FILE=$(kw_file SEA_DEPTH)
inputs=(control.dat analysis_domain.dat observing_site.dat coast_line.dat obs_site.dat makeMtr.param resistivity_attr.dat)
[ -n "$ALT_FILE" ] && inputs+=("$ALT_FILE")
[ -n "$SEA_FILE" ] && inputs+=("$SEA_FILE")
[ -f lake.dat ] && inputs+=(lake.dat)
[ -f region_seeds.dat ] && inputs+=(region_seeds.dat)
missing=(); for f in "${inputs[@]}"; do [ -f "$f" ] || missing+=("$f"); done
[ ${#missing[@]} -eq 0 ] || die "missing input file(s): ${missing[*]}"
for f in "${inputs[@]}"; do
  if grep -q $'\r' "$f"; then sed -i 's/\r$//' "$f"; echo "note: converted CRLF -> LF in $f" | tee -a logs/preflight.txt; fi
done
( for f in "${inputs[@]}"; do md5sum "$f"; done ) > logs/input_md5.txt

read -r XMIN XMAX < <(sed -n 1p analysis_domain.dat)
read -r YMIN YMAX < <(sed -n 2p analysis_domain.dat)
read -r ZMIN ZMAX < <(sed -n 3p analysis_domain.dat)
awk -v a="$ZMIN" -v b="$ZMAX" 'BEGIN{exit !(a<0 && b>0)}' || die "analysis_domain z range ($ZMIN, $ZMAX) must straddle 0"

# attributes declared in resistivity_attr.dat (the N lines after the count; the first one is the air)
NRES=$(awk 'NR==1{print $1; exit}' resistivity_attr.dat)
RES_ATTRS=$(awk -v n="$NRES" 'NR>1 && NR<=n+1 {print $1+0}' resistivity_attr.dat | sort -n | tr '\n' ' ' | sed 's/ $//')
AIR_ATTR=$(awk 'NR==2{print $1+0; exit}' resistivity_attr.dat)

# region seeds
if [ -f region_seeds.dat ]; then
  awk '/^[[:space:]]*#/ || NF==0 {next} {print $1, $2, $3, $4+0, $5}' region_seeds.dat > region_seeds.used
else
  [ "$NRES" = 2 ] || die "resistivity_attr.dat has $NRES region attributes; provide region_seeds.dat (sea/lake models need explicit seeds)"
  EARTH_ATTR=$(awk 'NR==3{print $1+0; exit}' resistivity_attr.dat)
  awk -v x0="$XMIN" -v x1="$XMAX" -v y0="$YMIN" -v y1="$YMAX" -v z0="$ZMIN" -v z1="$ZMAX" -v aa="$AIR_ATTR" -v ea="$EARTH_ATTR" \
      'BEGIN{xc=(x0+x1)/2; yc=(y0+y1)/2; printf "%g %g %g %d 1e9\n%g %g %g %d 1e9\n", xc, yc, z0/2, aa, xc, yc, z1/2, ea}' > region_seeds.used
  echo "note: no region_seeds.dat; land-only default seeds (air $AIR_ATTR above, earth $EARTH_ATTR below)" | tee -a logs/preflight.txt
fi
NSEEDS=$(wc -l < region_seeds.used)
[ "$NSEEDS" -ge 2 ] || die "need at least 2 region seeds (air + earth), got $NSEEDS"
awk 'NF!=5{bad=1} END{exit bad}' region_seeds.used || die "region_seeds: every line needs 5 fields: x y z attr maxvol"
awk -v x0="$XMIN" -v x1="$XMAX" -v y0="$YMIN" -v y1="$YMAX" -v z0="$ZMIN" -v z1="$ZMAX" \
    '!($1>x0 && $1<x1 && $2>y0 && $2<y1 && $3>z0 && $3<z1){print "seed outside analysis domain: " $0; bad=1} END{exit bad}' region_seeds.used \
    || die "region seed(s) outside the analysis domain"
SEED_ATTRS=$(awk '{print $4+0}' region_seeds.used | sort -n | uniq | tr '\n' ' ' | sed 's/ $//')
[ "$SEED_ATTRS" = "$RES_ATTRS" ] || die "seeded attributes {$SEED_ATTRS} != resistivity_attr.dat attributes {$RES_ATTRS}"
echo "region seeds (x y z attr maxvol):"; sed 's/^/  /' region_seeds.used

# ---------------------------------------------------------------- STEP 1-4 makeTetraMesh
for s in 1 2 3 4; do
  if ! step "stp$s" makeTetraMesh -stp $s; then
    cp -f makeTetraMesh.log "logs/makeTetraMesh_stp$s.log" 2>/dev/null
    die "makeTetraMesh -stp $s (see logs/makeTetraMesh_stp$s.log)"
  fi
  cp -f makeTetraMesh.log "logs/makeTetraMesh_stp$s.log"      # the tool overwrites its log every step
  if grep -qi "error" makeTetraMesh.log; then die "makeTetraMesh -stp $s logged an error"; fi
done
[ -f output.poly ] || die "makeTetraMesh -stp 4 produced no output.poly"

# ---------------------------------------------------------------- region seeds into output.poly
# makeTetraMesh ends output.poly with "# Part 4" / "0" (zero regions). Replace that 0 with the seed count and
# append one "index x y z attribute maxvolume" line per closed region: tetgen -A gives the attribute to every
# tetrahedron reachable from the seed point without crossing a facet; -a applies maxvolume (1e9 = no limit).
[ "$(tail -n 2 output.poly | head -n 1)" = "# Part 4" ] && [ "$(tail -n 1 output.poly | tr -d ' ')" = "0" ] \
  || die "unexpected output.poly tail (expected '# Part 4' then '0')"
cp output.poly logs/output.poly.unseeded
sed -i "$(wc -l < output.poly)s/.*/$NSEEDS/" output.poly
awk '{printf "%d %s %s %s %s %s\n", NR, $1, $2, $3, $4, $5}' region_seeds.used >> output.poly

# ---------------------------------------------------------------- STEP 5 tetgen
step tetgen_1 tetgen -nVpYAakq3.0/0 output.poly || die "tetgen -nVpYAakq3.0/0 output.poly"
[ -f output.1.ele ] || die "tetgen produced no output.1.ele"
grep -E "Found [0-9]+ (subdomains|domain)" logs/tetgen_1.log | sed 's/^ */tetgen: /'

if [ "${FIX_OUTPUT1:-0}" = 1 ]; then
  [ -f "${FIX_OUTPUT1_PY:-}" ] || die "FIX_OUTPUT1=1 but FIX_OUTPUT1_PY is not the path of femticPy scripts/fix_output1.py"
  CONDA_SH=${CONDA_SH:-$HOME/miniforge3/etc/profile.d/conda.sh}
  if [ -f "$CONDA_SH" ]; then
    # shellcheck disable=SC1090
    source "$CONDA_SH"; conda activate "${FEMTICPY_ENV:-femticpy}" || die "conda activate ${FEMTICPY_ENV:-femticpy}"
  fi
  cp output.1.ele logs/output.1.ele.before_fix
  step fix_output1 python "$FIX_OUTPUT1_PY" || die "fix_output1.py (it needs 1.5 <= pandas < 3)"
fi
GOT=$(ele_attr_set output.1.ele)
echo "output.1.ele region attributes:"; ele_attr_hist output.1.ele
[ "$GOT" = "$SEED_ATTRS" ] || die "tetgen region attributes {$GOT} != seeded {$SEED_ATTRS}: an unseeded closed region got max+1.. (add a seed for it)"
air_on_top output.1 || die "air attribute $AIR_ATTR is not the region at the top of the domain (or is at the bottom): check the region seeds"

# ---------------------------------------------------------------- STEP 6 makeMtr + tetgen refinement
printf 'mesh\tnodes\telements\n' > logs/refinement.tsv
printf 'output.1\t%s\t%s\n' "$(head -1 output.1.node | awk '{print $1}')" "$(head -1 output.1.ele | awk '{print $1}')" >> logs/refinement.tsv
for i in $(seq 1 "$NROUNDS"); do
  step "makeMtr_$i" makeMtr "output.$i" || die "makeMtr output.$i"
  [ -f "output.$i.mtr" ] || die "makeMtr produced no output.$i.mtr"
  step "tetgen_r$i" tetgen -nmpYVrAakq3.0/0 "output.$i" || die "tetgen -nmpYVrAakq3.0/0 output.$i"
  j=$((i + 1))
  [ -f "output.$j.ele" ] || die "tetgen refinement $i produced no output.$j.ele"
  printf 'output.%d\t%s\t%s\n' "$j" "$(head -1 "output.$j.node" | awk '{print $1}')" "$(head -1 "output.$j.ele" | awk '{print $1}')" >> logs/refinement.tsv
done
N=$((NROUNDS + 1))
GOT=$(ele_attr_set "output.$N.ele")
[ "$GOT" = "$SEED_ATTRS" ] || die "output.$N.ele region attributes {$GOT} != seeded {$SEED_ATTRS}"
air_on_top "output.$N" || die "air attribute $AIR_ATTR is not the region at the top of the domain in output.$N"

# ---------------------------------------------------------------- STEP 7 TetGen2Femtic
# shellcheck disable=SC2086
step t2f TetGen2Femtic "output.$N" ${T2F_ARGS:-} || die "TetGen2Femtic output.$N (see logs/t2f.log)"
if grep -qiE "error|cannot" logs/t2f.log; then die "TetGen2Femtic logged an error (see logs/t2f.log)"; fi
for f in mesh.dat resistivity_block_iter0.dat "output.$N.femtic.vtk"; do [ -s "$f" ] || die "missing product $f"; done

# ---------------------------------------------------------------- product checks
NE_ELE=$(head -1 "output.$N.ele" | awk '{print $1}')
NN_ELE=$(head -1 "output.$N.node" | awk '{print $1}')
NN_MESH=$(sed -n 2p mesh.dat | awk '{print $1}')
NE_MESH=$(awk -v nn="$NN_MESH" 'NR==nn+3{print $1; exit}' mesh.dat)
read -r NE_BLK NCELL < <(head -1 resistivity_block_iter0.dat)
{ [ "$NE_ELE" = "$NE_MESH" ] && [ "$NE_MESH" = "$NE_BLK" ]; } || die "element counts disagree: ele $NE_ELE, mesh.dat $NE_MESH, block $NE_BLK"
[ "$NN_ELE" = "$NN_MESH" ] || die "node counts disagree: node $NN_ELE, mesh.dat $NN_MESH"
VOLCHK=$(awk -v x0="$XMIN" -v x1="$XMAX" -v y0="$YMIN" -v y1="$YMAX" -v z0="$ZMIN" -v z1="$ZMAX" '
  FNR==1{next} /^#/{next}
  FILENAME ~ /\.node$/ {x[$1]=$2; y[$1]=$3; z[$1]=$4; next}
  { a=$2; b=$3; c=$4; d=$5
    ux=x[b]-x[a]; uy=y[b]-y[a]; uz=z[b]-z[a]; vx=x[c]-x[a]; vy=y[c]-y[a]; vz=z[c]-z[a]; wx=x[d]-x[a]; wy=y[d]-y[a]; wz=z[d]-z[a]
    v=(ux*(vy*wz-vz*wy) - uy*(vx*wz-vz*wx) + uz*(vx*wy-vy*wx))/6; if(v<0)v=-v; tot+=v; if(v==0) zero++ }
  END{ box=(x1-x0)*(y1-y0)*(z1-z0); rel=(tot-box)/box; if(rel<0)rel=-rel
       printf "%.9e %.9e %.2e %d\n", tot, box, rel, zero+0 }' "output.$N.node" "output.$N.ele")
read -r VTOT VBOX VREL VZERO <<< "$VOLCHK"
awk -v r="$VREL" -v z="$VZERO" 'BEGIN{exit !(r<1e-6 && z==0)}' \
  || die "element volumes sum to $VTOT km^3 vs analysis box $VBOX km^3 (rel $VREL, $VZERO zero-volume elements)"

T_END=$(date +%s.%N)
{
  echo "run_dir            : $(pwd)"
  echo "refinement rounds  : $NROUNDS  (final mesh output.$N)"
  echo "region seeds       : $(tr '\n' ';' < region_seeds.used)"
  echo "region attributes  : {$SEED_ATTRS} in output.1.ele and output.$N.ele (resistivity_attr.dat: {$RES_ATTRS}, air $AIR_ATTR)"
  echo "nodes / elements   : $NN_MESH / $NE_MESH"
  echo "parameter cells    : $NCELL (cell 0 = air)"
  echo "volume check       : sum |V| = $VTOT km^3, box = $VBOX km^3, rel err $VREL"
  printf 'total wall time    : %.1f s\n' "$(echo "$T_END - $T_START" | bc -l)"
  echo "CHAIN OK"
} | tee logs/summary.txt
