#!/bin/bash -l
#SBATCH --job-name=mesh_chain
#SBATCH -p icelake
#SBATCH -N 1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=27G
#SBATCH --time=04:00:00
#SBATCH -o slurm-%x-%j.out
# Mail: none unless asked (no #SBATCH mail lines). run.sh passes --mail-type=NONE, or MAIL=<address> from run.env.
# =============================================================================
# mesh_chain.sh -- the FEMTIC tetrahedral mesh chain as a Phoenix job (P0 of docs/dev/mesh_port_feasibility_2026-10-06.md):
# a port of scripts/run_mesh_chain.sh (the WSL chain that built chain_proof and vulcan_v1-v3), same tools, order, switches:
#   makeTetraMesh -stp 1..4 -> region seeds into output.poly -> tetgen -nVpYAakq3.0/0 output.poly
#   -> [FIX_OUTPUT1=1: femticPy fix_output1.py] -> NROUNDS x (makeMtr output.i ; tetgen -nmpYVrAakq3.0/0 output.i)
#   -> TetGen2Femtic output.(NROUNDS+1)  =>  mesh.dat, resistivity_block_iter0.dat, output.(NROUNDS+1).femtic.vtk
# Normally submitted by the kit's run.sh for a run folder whose run.env says JOB=mesh:  bash $VF/kit/run.sh RunNN
# (1 node, 8 cpus, --mem=27G, --time=04:00:00 by default; the chain is serial except makeTetraMesh's one OpenMP loop,
# whose thread count is NUM_THREADS in control.dat; tetgen alone took 319 s of v2's 360 s in WSL).
# The small case (chain_proof) may also run on the login node, under nice and a LOGIN_MAX_S cap (default 300 s):
#     LOGIN=1 bash $VF/kit/mesh_chain.sh $VF/runs/Run04
# Counts of any built mesh (reads DIR/mesh.dat and DIR/resistivity_block_iter0.dat, changes nothing):
#     bash $VF/kit/mesh_chain.sh --counts DIR    ->  nodes N  tets N  cells N  surface_faces N  outer_faces N
#
# RUN_DIR (argument; default the submit folder) holds FILES/ (default files/, made by scripts/make_run.sh --job mesh)
# with the 10 inputs of mesh/vulcan_v2/files (km; FEMTIC frame: x north, y east, z positive DOWN):
#   control.dat analysis_domain.dat observing_site.dat coast_line.dat topography.dat bathymetry.dat (makeTetraMesh;
#   step 3 reads the ALTITUDE and SEA_DEPTH files control.dat names), obs_site.dat makeMtr.param (makeMtr),
#   resistivity_attr.dat (TetGen2Femtic; its first attribute is the air), region_seeds.dat ("x y z attr maxvol" per
#   closed region, km and km^3, '#' comments allowed), and lake.dat if the model has lakes.
# Two deliberate differences from run_mesh_chain.sh:
#   * region_seeds.dat is required: no default seeds are guessed on Phoenix.
#   * before makeMtr output.i, the output.i.mtr that tetgen round i-1 wrote is kept as output.i.tetgen.mtr, and
#     makeMtr's own output.i.mtr must list one value per node of output.i.node. (The WSL check '[ -f output.i.mtr ]'
#     could not fail for i >= 2, and tetgen ignores a .mtr with the wrong count and refines without sizing.)
# Writes, all inside RUN_DIR (FILES/ is only read):
#   mesh.dat, resistivity_block_iter0.dat, output.6.femtic.vtk     the products (moved up once every check passed)
#   intermediates/   the working folder, kept whole: the inputs as used (LF), region_seeds.used, makeTetraMesh's
#                    *.stp1-3 and output.poly (seeded; logs/output.poly.unseeded), output.1-6.{node,ele,face,neigh},
#                    every .mtr, logs/<step>.log and logs/<step>.timev (/usr/bin/time -v), logs/tools.txt (the
#                    binaries' md5, glibc, OS), timings.tsv, refinement.tsv, input_md5.txt, summary.txt
#   mesh_summary.txt the line 'MESH COUNTS: nodes N  tets N  cells N  surface_faces N  outer_faces N' and the line
#                    'MESH CHAIN DONE: OK, exit 0 (<step> <rc>, ...)' or 'MESH CHAIN DONE: FAILED, exit N at <step>: ...'
#   job_outcomes.tsv one row per job (status.sh shows it)
# REFUSES (exit 1, nothing written) outside Slurm without LOGIN=1, if RUN_DIR already holds mesh.dat,
# resistivity_block_iter0.dat, intermediates/ or mesh_summary.txt (an earlier build: move it away first), if an input
# or a tool is missing. FAILS (exit 1, 'MESH CHAIN DONE: FAILED') if a tool exits non-zero, makeTetraMesh logs an
# error, an expected product is missing, a .mtr has the wrong count, tetgen's region attributes differ from the seeded
# set, the air attribute is not the region on the top plane of the domain (or appears on the bottom plane), the element
# counts of output.N.ele, mesh.dat and resistivity_block_iter0.dat disagree, the element volumes do not sum to the
# analysis box, or the products cannot be counted. SIGTERM (the --time limit, scancel): exit 143, also with a DONE line.
# Environment (defaults): VF, BIN ($VF/bin: makeTetraMesh tetgen makeMtr TetGen2Femtic and femtic_env.sh), KIT
# ($VF/kit: femtic_lib.sh, VERSION), FILES (files), NROUNDS (5), T2F_ARGS (none), FIX_OUTPUT1=1 with FIX_OUTPUT1_PY
# and PYTHON (python3, with 1.5 <= pandas < 3), LOGIN, LOGIN_MAX_S (300), TIME_BIN (/usr/bin/time).
# GNU bash 4.4 and gawk 4.2 (Phoenix); no python unless FIX_OUTPUT1=1.
# =============================================================================
set -o pipefail
VF=${VF:-/hpcfs/users/$USER/vulcan_femtic}
BIN=${BIN:-$VF/bin}                     # the build: $VF/bin is a link to it (RUNBOOK S1); BIN=<folder> overrides
KIT=${KIT:-$VF/kit}                     # the uploaded kit: femtic_lib.sh and VERSION are read from here
FILES=${FILES:-files}
NROUNDS=${NROUNDS:-5}                   # run_mesh_chain.sh and meshGen.sh: 5 rounds, output.1 .. output.5 -> output.6
LOGIN_MAX_S=${LOGIN_MAX_S:-300}
TIME_BIN=${TIME_BIN:-/usr/bin/time}
MESH_INPUTS="analysis_domain.dat bathymetry.dat coast_line.dat control.dat makeMtr.param obs_site.dat observing_site.dat region_seeds.dat resistivity_attr.dat topography.dat"
BIN=${BIN%/}

# mesh_counts DIR: one line "nodes N  tets N  cells N  surface_faces N  outer_faces N" from DIR/mesh.dat (TETRA, the
# node count and nodes, the element count and elements, then 7 face lists, each a count and that many lines; the 7th
# is the Earth surface) and line 1 of DIR/resistivity_block_iter0.dat ("elements cells", cells counting air cell 0).
# Exit 1, no line, if mesh.dat does not end exactly after its 7th list or the two files disagree on the elements.
mesh_counts() {
  local d=${1%/}
  [ -s "$d/mesh.dat" ] && [ -s "$d/resistivity_block_iter0.dat" ] \
    || { echo "mesh_counts: no mesh.dat or resistivity_block_iter0.dat in $d" >&2; return 1; }
  awk 'FNR == 1 { f++ }
    f == 1 {
      if (NF) last = FNR
      if (FNR == 1) { if ($1 != "TETRA") err = "mesh.dat line 1 is not TETRA"; next }
      if (FNR == 2) { nn = $1 + 0; at = nn + 3; next }
      if (FNR == at) {
        if (NF != 1 || $1 !~ /^[0-9]+$/) { if (err == "") err = "mesh.dat line " FNR " is not a count"; next }
        if (!hasne) { ne = $1 + 0; hasne = 1; at = FNR + ne + 1; next }
        k++; c[k] = $1 + 0; at = FNR + c[k] + 1
      }
      next
    }
    f == 2 { bne = $1 + 0; ncell = $2 + 0; nextfile }
    END {
      if (err == "" && (nn < 1 || ne < 1)) err = "mesh.dat has no node or element count"
      if (err == "" && k != 7) err = "mesh.dat has " k + 0 " face lists, not 7"
      if (err == "" && last != at - 1) err = "mesh.dat ends at line " last ", its 7th face list at line " at - 1
      if (err == "" && bne != ne) err = "resistivity_block_iter0.dat lists " bne " elements, mesh.dat " ne
      if (err != "") { print "mesh_counts: " err > "/dev/stderr"; exit 1 }
      printf "nodes %d  tets %d  cells %d  surface_faces %d  outer_faces %d\n", nn, ne, ncell, c[7], c[1] + c[2] + c[3] + c[4] + c[5] + c[6]
    }' "$d/mesh.dat" "$d/resistivity_block_iter0.dat"
}
if [ "${1:-}" = --counts ]; then
  [ $# -eq 2 ] || { echo "usage: bash mesh_chain.sh --counts DIR" >&2; exit 2; }
  mesh_counts "$2"; exit
fi

# ---------------------------------------------------------------- outside Slurm: only LOGIN=1, capped
if [ -z "${SLURM_JOB_ID:-}" ] && [ "${MESH_CHAIN_CAPPED:-0}" != 1 ]; then
  if [ "${LOGIN:-0}" != 1 ]; then
    echo "mesh_chain.sh: REFUSED: not inside a Slurm job. Submit it: bash \$VF/kit/run.sh RunNN (or, for the small case only: LOGIN=1 bash $0 RUN_DIR)" >&2
    exit 1
  fi
  [[ "$LOGIN_MAX_S" =~ ^[1-9][0-9]*$ ]] || { echo "mesh_chain.sh: REFUSED: LOGIN_MAX_S=$LOGIN_MAX_S (seconds, a whole number)" >&2; exit 1; }
  MESH_CHAIN_CAPPED=1 timeout "$LOGIN_MAX_S" nice -n 10 bash "$0" "$@"; rc=$?
  [ "$rc" -ne 124 ] || echo "MESH CHAIN DONE: FAILED, exit 124 at the login-node cap: LOGIN_MAX_S=$LOGIN_MAX_S s reached; submit it with run.sh"
  exit "$rc"
fi

# ---------------------------------------------------------------- the DONE line, on every exit
JOB_T0=$(date +%s); JOB_ID=${SLURM_JOB_ID:-login}
STARTED=0; STEPNAME=setup; FAILMSG=""; STEPS=""; SUMMARY=""
on_exit() {
  local rc=$? line
  if [ "$rc" -eq 0 ]; then line="MESH CHAIN DONE: OK, exit 0 (${STEPS# })"
  else line="MESH CHAIN DONE: FAILED, exit $rc at $STEPNAME: ${FAILMSG:-see the log above} (${STEPS# })"; fi
  echo "$line"
  if [ "$STARTED" = 1 ]; then
    echo "$line" >> "$SUMMARY"
    if declare -F femtic_outcome_row > /dev/null; then
      femtic_outcome_row "$RD/job_outcomes.tsv" "$JOB_ID" mesh_chain "$(hostname -s)" "$(date -d "@$JOB_T0" +%FT%T)" "$(date +%FT%T)" \
        "$([ "$rc" -eq 0 ] && echo mesh_ok || echo mesh_failed)" "" "" "$rc" "$STEPNAME${FAILMSG:+: $FAILMSG}"
    fi
  fi
}
trap on_exit EXIT
trap 'FAILMSG="stopped by SIGTERM (the --time limit, or scancel)"; exit 143' TERM
trap 'FAILMSG="stopped by SIGINT"; exit 130' INT
die() { FAILMSG=$*; echo "MESH CHAIN FAILED: $*" >&2; [ "$STARTED" = 1 ] && echo "MESH CHAIN FAILED: $*" >> "$WD/summary.txt"; exit 1; }

# ---------------------------------------------------------------- before any write: environment, tools, inputs
RD=${1:-${SLURM_SUBMIT_DIR:-$PWD}}
RD=$(cd "$RD" 2>/dev/null && pwd) || die "cannot cd to the run folder ${1:-${SLURM_SUBMIT_DIR:-$PWD}}"
echo "== $(date) job $JOB_ID (${SLURM_JOB_NAME:-login}) partition=${SLURM_JOB_PARTITION:-none} node=$(hostname -s)  run folder $RD"
# shellcheck disable=SC1091
source "$BIN/femtic_env.sh" || die "$BIN/femtic_env.sh missing: RUNBOOK S1 links \$VF/bin to a build (01_build_femtic.sh), or set BIN=<its bin folder>"
# shellcheck disable=SC1091
source "$KIT/femtic_lib.sh" 2>/dev/null || die "no kit at $KIT (femtic_lib.sh missing): upload export/kit there, or pass KIT=<kit folder>"
[ "${FEMTIC_LIB_VERSION:-0}" -ge 5 ] || die "$KIT/femtic_lib.sh is version ${FEMTIC_LIB_VERSION:-unset}; mesh_chain.sh needs FEMTIC_LIB_VERSION >= 5 (upload the current kit)"
femtic_kit_banner
export PATH="$BIN:$PATH"
for t in makeTetraMesh tetgen makeMtr TetGen2Femtic; do
  [ -x "$BIN/$t" ] && [ "$(command -v "$t")" = "$BIN/$t" ] || die "$t is not the one in $BIN (command -v: '$(command -v "$t")')"
done
[[ "$NROUNDS" =~ ^[0-9]+$ ]] || die "NROUNDS=$NROUNDS (a whole number; 5 as in run_mesh_chain.sh)"
[[ "$FILES" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || die "FILES=$FILES (a folder name inside the run folder, e.g. files)"
FD=$RD/$FILES
[ -d "$FD" ] || die "no inputs folder $FD (scripts/make_run.sh --job mesh --files <dir> makes it)"
miss=(); for f in $MESH_INPUTS; do [ -s "$FD/$f" ] || miss+=("$f"); done
[ ${#miss[@]} -eq 0 ] || die "$FD lacks ${miss[*]} (a mesh run needs all 10: $MESH_INPUTS)"
for f in mesh.dat resistivity_block_iter0.dat intermediates mesh_summary.txt; do
  { [ ! -e "$RD/$f" ] && [ ! -L "$RD/$f" ]; } || die "$RD/$f exists: an earlier mesh build is in this run folder (move it away first; mesh_chain.sh never overwrites one)"
done
WD=$RD/intermediates
mkdir "$WD" "$WD/logs" || die "cannot make $WD"
STARTED=1; SUMMARY=$RD/mesh_summary.txt; : > "$SUMMARY"
cd "$WD" || die "cannot cd to $WD"
{ echo "BIN $BIN -> $(cd "$BIN" && pwd -P)   FEMTIC_TOOLCHAIN=${FEMTIC_TOOLCHAIN:-unset}"
  ( cd "$BIN" && md5sum makeTetraMesh tetgen makeMtr TetGen2Femtic )
  echo "glibc: $(ldd --version 2>/dev/null | head -1)"
  echo "os: $(cat /etc/redhat-release 2>/dev/null || uname -sr)   host: $(hostname -s)   cpus: ${SLURM_CPUS_PER_TASK:-$(nproc 2>/dev/null)}"
  echo "settings: FILES=$FILES NROUNDS=$NROUNDS T2F_ARGS='${T2F_ARGS:-}' FIX_OUTPUT1=${FIX_OUTPUT1:-0}"; } > logs/tools.txt
sed 's/^/tools: /' logs/tools.txt

printf 'step\trc\twall_s\tmaxrss_kb\tcommand\n' > timings.tsv
# step NAME CMD...: run CMD in intermediates/, its stdout+stderr to logs/NAME.log, GNU time -v to logs/NAME.timev, one
# row in timings.tsv, "NAME RC" in the DONE line
step() {
  local name=$1 t0 t1 rc rss wall; shift
  STEPNAME=$name; t0=$(date +%s.%N)
  if [ -x "$TIME_BIN" ]; then
    "$TIME_BIN" -v -o "logs/$name.timev" "$@" > "logs/$name.log" 2>&1; rc=$?
  else
    "$@" > "logs/$name.log" 2>&1; rc=$?; echo "no $TIME_BIN on $(hostname -s)" > "logs/$name.timev"
  fi
  t1=$(date +%s.%N)
  rss=$(sed -n 's/^[[:space:]]*Maximum resident set size (kbytes): *//p' "logs/$name.timev" | head -1)
  wall=$(awk -v a="$t0" -v b="$t1" 'BEGIN {printf "%.2f", b - a}')
  printf '%s\t%d\t%s\t%s\t%s\n' "$name" "$rc" "$wall" "${rss:-n/a}" "$*" >> timings.tsv
  STEPS="$STEPS, $name $rc"; STEPS=${STEPS#, }
  echo "[$(date +%T)] $name rc=$rc  ${wall} s  maxrss ${rss:-n/a} KB"
  return "$rc"
}
ele_attr_set()  { awk 'NR==1{next} /^#/{next} NF>0{print $NF+0}' "$1" | sort -n | uniq | tr '\n' ' ' | sed 's/ $//'; }
ele_attr_hist() { awk 'NR==1{next} /^#/{next} NF>0{c[$NF+0]++} END{for(k in c) printf "  attr %s : %d elements\n", k, c[k]}' "$1" | sort -n -k2; }
# air_on_top ROOT: every element touching the top plane (z = zmin) carries the air attribute, none touching the bottom
# plane (z = zmax) does (catches swapped seeds, which every tool accepts with exit 0)
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

# ---------------------------------------------------------------- preflight (run_mesh_chain.sh's, on a copy of FILES/)
for f in "$FD"/*; do [ -f "$f" ] && { cp -p "$f" . || die "cannot copy $f"; }; done
kw_file() { awk -v k="$1" '{sub(/\r$/,"")} $1==k{getline; sub(/\r$/,""); print $1; exit}' control.dat; }
ALT_FILE=$(kw_file ALTITUDE); SEA_FILE=$(kw_file SEA_DEPTH)
inputs=(control.dat analysis_domain.dat observing_site.dat coast_line.dat obs_site.dat makeMtr.param resistivity_attr.dat)
[ -n "$ALT_FILE" ] && inputs+=("$ALT_FILE")
[ -n "$SEA_FILE" ] && inputs+=("$SEA_FILE")
[ -f lake.dat ] && inputs+=(lake.dat)
inputs+=(region_seeds.dat)
miss=(); for f in "${inputs[@]}"; do [ -f "$f" ] || miss+=("$f"); done
[ ${#miss[@]} -eq 0 ] || die "missing input file(s) named by control.dat: ${miss[*]}"
for f in "${inputs[@]}"; do   # CR bytes counted with tr (a grep for CR is unreliable in Git Bash, where the tests run)
  if [ "$(tr -cd '\r' < "$f" | wc -c)" -gt 0 ]; then sed -i 's/\r$//' "$f"; echo "note: converted CRLF -> LF in $f" | tee -a logs/preflight.txt; fi
done
( for f in "${inputs[@]}"; do md5sum "$f"; done ) > input_md5.txt
read -r XMIN XMAX < <(sed -n 1p analysis_domain.dat)
read -r YMIN YMAX < <(sed -n 2p analysis_domain.dat)
read -r ZMIN ZMAX < <(sed -n 3p analysis_domain.dat)
awk -v a="$ZMIN" -v b="$ZMAX" 'BEGIN{exit !(a<0 && b>0)}' || die "analysis_domain z range ($ZMIN, $ZMAX) must straddle 0"
# attributes declared in resistivity_attr.dat (the N lines after the count; the first one is the air)
NRES=$(awk 'NR==1{print $1; exit}' resistivity_attr.dat)
RES_ATTRS=$(awk -v n="$NRES" 'NR>1 && NR<=n+1 {print $1+0}' resistivity_attr.dat | sort -n | tr '\n' ' ' | sed 's/ $//')
AIR_ATTR=$(awk 'NR==2{print $1+0; exit}' resistivity_attr.dat)
# region seeds (required here; run_mesh_chain.sh guessed two for a land-only model without them)
awk '/^[[:space:]]*#/ || NF==0 {next} {print $1, $2, $3, $4+0, $5}' region_seeds.dat > region_seeds.used
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
    die "makeTetraMesh -stp $s (see intermediates/logs/makeTetraMesh_stp$s.log)"
  fi
  cp -f makeTetraMesh.log "logs/makeTetraMesh_stp$s.log"      # the tool overwrites its log every step
  if grep -qi "error" makeTetraMesh.log; then die "makeTetraMesh -stp $s logged an error"; fi
done
[ -f output.poly ] || die "makeTetraMesh -stp 4 produced no output.poly"

# ---------------------------------------------------------------- region seeds into output.poly
# makeTetraMesh ends output.poly with "# Part 4" / "0" (zero regions): that 0 becomes the seed count, then one
# "index x y z attribute maxvolume" line per closed region (tetgen -A: the attribute of every tet reachable from the
# seed without crossing a facet; -a: maxvolume, 1e9 = no limit).
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
  cp output.1.ele logs/output.1.ele.before_fix
  step fix_output1 "${PYTHON:-python3}" "$FIX_OUTPUT1_PY" || die "fix_output1.py (it needs 1.5 <= pandas < 3)"
fi
GOT=$(ele_attr_set output.1.ele)
echo "output.1.ele region attributes:"; ele_attr_hist output.1.ele
[ "$GOT" = "$SEED_ATTRS" ] || die "tetgen region attributes {$GOT} != seeded {$SEED_ATTRS}: an unseeded closed region got max+1.. (add a seed for it)"
air_on_top output.1 || die "air attribute $AIR_ATTR is not the region at the top of the domain (or is at the bottom): check the region seeds"

# ---------------------------------------------------------------- STEP 6 makeMtr + tetgen refinement
printf 'mesh\tnodes\telements\n' > refinement.tsv
printf 'output.1\t%s\t%s\n' "$(head -1 output.1.node | awk '{print $1}')" "$(head -1 output.1.ele | awk '{print $1}')" >> refinement.tsv
for i in $(seq 1 "$NROUNDS"); do
  # tetgen -m of round i-1 wrote an interpolated output.i.mtr: keep it apart, so that makeMtr must write its own
  if [ -e "output.$i.mtr" ]; then mv -f "output.$i.mtr" "output.$i.tetgen.mtr" || die "cannot keep output.$i.mtr apart"; fi
  step "makeMtr_$i" makeMtr "output.$i" || die "makeMtr output.$i"
  [ -s "output.$i.mtr" ] || die "makeMtr produced no output.$i.mtr"
  MN=$(awk 'NR==1{print $1; exit}' "output.$i.mtr"); NN=$(awk 'NR==1{print $1; exit}' "output.$i.node")
  [ "$MN" = "$NN" ] || die "output.$i.mtr lists $MN values, output.$i.node has $NN nodes (tetgen would refine without sizing)"
  step "tetgen_r$i" tetgen -nmpYVrAakq3.0/0 "output.$i" || die "tetgen -nmpYVrAakq3.0/0 output.$i"
  j=$((i + 1))
  [ -f "output.$j.ele" ] || die "tetgen refinement $i produced no output.$j.ele"
  printf 'output.%d\t%s\t%s\n' "$j" "$(head -1 "output.$j.node" | awk '{print $1}')" "$(head -1 "output.$j.ele" | awk '{print $1}')" >> refinement.tsv
done
N=$((NROUNDS + 1))
GOT=$(ele_attr_set "output.$N.ele")
[ "$GOT" = "$SEED_ATTRS" ] || die "output.$N.ele region attributes {$GOT} != seeded {$SEED_ATTRS}"
air_on_top "output.$N" || die "air attribute $AIR_ATTR is not the region at the top of the domain in output.$N"

# ---------------------------------------------------------------- STEP 7 TetGen2Femtic
# shellcheck disable=SC2086
step t2f TetGen2Femtic "output.$N" ${T2F_ARGS:-} || die "TetGen2Femtic output.$N (see intermediates/logs/t2f.log)"
if grep -qiE "error|cannot" logs/t2f.log; then die "TetGen2Femtic logged an error (see intermediates/logs/t2f.log)"; fi
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

# ---------------------------------------------------------------- products up, counts, summary
STEPNAME=products
for f in mesh.dat resistivity_block_iter0.dat "output.$N.femtic.vtk"; do mv "$f" "$RD/" || die "cannot move $f to $RD"; done
COUNTS=$(mesh_counts "$RD") || die "cannot count the products in $RD (mesh_counts above)"
echo "MESH COUNTS: $COUNTS" | tee -a "$SUMMARY"
{
  echo "run_dir            : $RD (inputs $FILES/, work intermediates/)"
  echo "refinement rounds  : $NROUNDS  (final mesh output.$N)"
  echo "region seeds       : $(tr '\n' ';' < region_seeds.used)"
  echo "region attributes  : {$SEED_ATTRS} in output.1.ele and output.$N.ele (resistivity_attr.dat: {$RES_ATTRS}, air $AIR_ATTR)"
  echo "nodes / elements   : $NN_MESH / $NE_MESH"
  echo "parameter cells    : $NCELL (cell 0 = air)"
  echo "volume check       : sum |V| = $VTOT km^3, box = $VBOX km^3, rel err $VREL"
  echo "total wall time    : $(( $(date +%s) - JOB_T0 )) s"
  echo "counts             : $COUNTS"
} | tee summary.txt
echo "refinement:"; sed 's/^/  /' refinement.tsv
echo "timings:"; sed 's/^/  /' timings.tsv
exit 0
