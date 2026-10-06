#!/bin/bash
# =============================================================================
# run_sh_test.sh -- developer test of the kit's run.sh and status.sh, and of the KIT VERSION line that 04, 05 and 06
# print and write to job_outcomes.tsv (femtic_lib.sh version 5). Nothing heavy runs: a fake Phoenix tree
# VF=$WORK/vf (kit/ = this kit plus a VERSION file, shared/mesh_v2/ = a 6,000-equation mesh, runs/), and fake sbatch,
# sacct, squeue, mpirun, femtic, rcstat and hostname. The fake sbatch records its arguments; with MOCK_SBATCH_RUN=1 it
# also runs the job script there and then, with the SLURM_* variables its options imply. The fake BIN holds a
# version-2 femtic_lib.sh (as Phoenix's femtic/bin does), so the end-to-end checks also show that the KIT's copy is
# the one that runs. Since 2026-10-07 it also checks that a refused layout leaves no link in the run folder (R4,
# R8), the optional run.env keys NIV and MAIL (R7, R8, P6, P4b), --mail-type=NONE by default (P1), no fixed
# --mail-user in 03/04/06 (M1), and BIN's default $VF/bin in run.sh and in 03/04/05/06 (B1, B2). JOB=mesh (2026-10-06):
# run.sh's mesh refusals and submission (R9, R10, P7), and mesh_chain.sh run on fake makeTetraMesh, tetgen, makeMtr,
# TetGen2Femtic and GNU time (a 12-tet mesh of the box): its failing chains (X1, X2), a full chain (P8), status.sh
# (S2), the login-node mode (L1) and --counts (C1). The real meshes' counts are checked by runbook_walk_test.sh C16.
#   bash run_sh_test.sh [PLAN_DIR]     PLAN_DIR = the kit to test (default: the directory above this script)
#   env: WORK=<dir> (default mktemp -d), PYTHON=<python 3> (default: the first of python3, python that runs)
# Every check prints its failure criterion ("fails if ...") before its result; refusals come before the passing
# submission. Exit 0 only if every check passes. Git Bash: run.sh is run with MSYS=winsymlinks:native, so that its
# links are links (Git Bash's default ln -s copies the file); Phoenix's ln needs nothing.
# =============================================================================
PLAN=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
PLAN=$(cd "$PLAN" && pwd) || exit 2
WORK=${WORK:-$(mktemp -d)}; mkdir -p "$WORK" || exit 2; WORK=$(cd "$WORK" && pwd)
if [ -z "${PYTHON:-}" ]; then
  for p in python3 python; do
    if [ "$("$p" -c 'import sys; print(sys.version_info[0])' 2>/dev/null)" = 3 ]; then PYTHON=$p; break; fi
  done
fi
echo "run_sh_test: PLAN=$PLAN  WORK=$WORK  PYTHON=${PYTHON:-none}  bash $BASH_VERSION"
npass=0; nfail=0
crit() { echo; echo "CHECK $1: fails if $2"; }
ok()   { echo "  PASS $*"; npass=$((npass + 1)); }
bad()  { echo "  FAIL $*"; nfail=$((nfail + 1)); }
eq()   { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got '$2', want '$3'"; fi; }
has()  { if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1: '$3' found"; else bad "$1: '$3' not in $2"; fi; }
hasnt(){ if grep -qF -- "$3" "$2" 2>/dev/null; then bad "$1: '$3' present in $2"; else ok "$1: no '$3'"; fi; }

# ---------------------------------------------------------------- fake Phoenix tree
VF=$WORK/vf; KIT=$VF/kit; SHARED=$VF/shared; RUNS=$VF/runs
rm -rf "$VF"; mkdir -p "$KIT/tools" "$SHARED/mesh_v2" "$RUNS"
cp "$PLAN"/*.sh "$PLAN"/*.slurm "$KIT/"; cp "$PLAN"/tools/*.py "$KIT/tools/"
printf 'abc1234\n2026-10-06 12:00\ntestbranch\n2026-10-06 12:30\n' > "$KIT/VERSION"
awk 'BEGIN { print "TETRA"; print "      1000"; for (i = 0; i < 1000; i++) printf "%10d 0 0 0\n", i; print "      5000" }' > "$SHARED/mesh_v2/mesh.dat"
awk 'BEGIN { printf "%10d%10d\n", 10, 3; for (i = 0; i < 10; i++) printf "%10d%10d\n", i, 1 + i % 2
             printf "%10d   %.6e   %.6e   %.6e   %.6e%10d\n", 0, 1e9, 1e-20, 1e20, 1, 1
             for (k = 1; k < 3; k++) printf "%10d   %.6e   %.6e   %.6e   %.6e%10d\n", k, 20, 1e-20, 1e20, 1, 0 }' > "$SHARED/mesh_v2/resistivity_block_iter0.dat"
# a run folder as scripts/make_run.sh writes it: 2 MT stations x 2 bands, plus the dummy VTF block that prep writes for
# OWNER_ELEMENT -1 (femtic_obs_counts reports such a block on stderr; run.sh must stay quiet about it)
P=$WORK/proto; rm -rf "$P"; mkdir -p "$P"
printf 'MT 2\n1 1001 0 0.1 -0.1\n2\n10 0 0 1e-2 -1e-2 -1e-2 1e-2 0 0 1e-3 1e-3 1e-3 1e-3 1e-3 1e-3 1e-3 1e-3\n0.1 0 0 1e-2 -1e-2 -1e-2 1e-2 0 0 1e-3 1e-3 1e-3 1e-3 1e-3 1e-3 1e-3 1e-3\n2 1002 0 0.2 -0.2\n2\n10 0 0 1e-2 -1e-2 -1e-2 1e-2 0 0 1e-3 1e-3 1e-3 1e-3 1e-3 1e-3 1e-3 1e-3\n0.1 0 0 1e-2 -1e-2 -1e-2 1e-2 0 0 1e-3 1e-3 1e-3 1e-3 1e-3 1e-3 1e-3 1e-3\nVTF 2\n1001 1001 1 0.1 -0.1\n0\n1002 1002 1 0.2 -0.2\n0\nEND\n' > "$P/observe.dat"
printf 'NUM_THREADS\n8\nMESH_TYPE\n1\nDISTORTION\n0\nINV_METHOD\n1\nITERATION\n0 10\nOWNER_ELEMENT\n-1\nEND\n' > "$P/control.dat"
printf 'femtic_station_id,h_station_id,site_id,edi_file\n1,1001,A1,A1.edi\n2,1002,B2,B2.edi\n' > "$P/station_map.csv"
# mkrun NAME JOB [KEY=VALUE ...] -> runs/NAME with run.env (v2 gate 100 ohm-m 3x24 02:00:00 unless overridden; the
# optional NIV and MAIL lines only when given) + RUN.md
mkrun() {
  local n=$1 job=$2 kv k; shift 2
  rm -rf "${RUNS:?}/$n"; mkdir -p "$RUNS/$n"; cp "$P"/* "$RUNS/$n/"
  declare -A V=([MESH]=v2 [JOB]=$job [START_RHO]=none [RANKS]=3 [THREADS]=24 [TIME]=02:00:00 [PARTITION]=icelake [ITER_STEP]=none [ITER_MAX]=none)
  [ "$job" = gate ] && V[START_RHO]=100
  for kv in "$@"; do V[${kv%%=*}]=${kv#*=}; done
  { echo "# $n (test)"; for k in MESH JOB START_RHO RANKS THREADS TIME PARTITION ITER_STEP ITER_MAX; do [ "${V[$k]}" = DROP ] || echo "$k=${V[$k]}"; done
    for k in NIV MAIL; do [ -z "${V[$k]:-}" ] || echo "$k=${V[$k]}"; done; } > "$RUNS/$n/run.env"
  printf '# %s\n\n- purpose: test %s run\n\n## Jobs\n' "$n" "$job" > "$RUNS/$n/RUN.md"
}
# mkmesh NAME [KEY=VALUE ...] -> runs/NAME as scripts/make_run.sh --job mesh writes it: run.env (MESH=none JOB=mesh 1 x 8
# 04:00:00 FILES=files unless overridden; DROP leaves a key out), RUN.md, and files/ with the 10 inputs of a land-only
# +-300 km box (air 10 above, earth 20 below, seeds at z = -40 and +10 km)
MF=$WORK/meshfiles; rm -rf "$MF"; mkdir -p "$MF"
printf 'ALTITUDE\ntopography.dat\n0\n1e10\nEND\n' > "$MF/control.dat"; printf -- '-300 300\n-300 300\n-300 300\n' > "$MF/analysis_domain.dat"
for f in observing_site.dat coast_line.dat obs_site.dat makeMtr.param topography.dat bathymetry.dat; do echo 0 > "$MF/$f"; done
printf '2\n10 1e9 -1 1\n20 100 9 0\n' > "$MF/resistivity_attr.dat"; printf '# x y z attr maxvol\n0 0 -40 10 1e9\n0 0 10 20 1e9\n' > "$MF/region_seeds.dat"
mkmesh() {
  local n=$1 kv k; shift
  rm -rf "${RUNS:?}/$n"; mkdir -p "$RUNS/$n/files"; cp "$MF"/* "$RUNS/$n/files/"
  declare -A V=([MESH]=none [JOB]=mesh [START_RHO]=none [RANKS]=1 [THREADS]=8 [TIME]=04:00:00 [PARTITION]=icelake [ITER_STEP]=none [ITER_MAX]=none [FILES]=files)
  for kv in "$@"; do V[${kv%%=*}]=${kv#*=}; done
  { echo "# $n (test)"; for k in MESH JOB START_RHO RANKS THREADS TIME PARTITION ITER_STEP ITER_MAX FILES; do [ "${V[$k]}" = DROP ] || echo "$k=${V[$k]}"; done; } > "$RUNS/$n/run.env"
  printf '# %s\n\n- purpose: test mesh run\n\n## Jobs\n' "$n" > "$RUNS/$n/RUN.md"
}

# ---------------------------------------------------------------- fake bin (Phoenix's femtic/bin plus Slurm)
BIN=$WORK/bin; rm -rf "$BIN"; mkdir -p "$BIN"
sed 's/^FEMTIC_LIB_VERSION=.*/FEMTIC_LIB_VERSION=2/' "$PLAN/femtic_lib.sh" > "$BIN/femtic_lib.sh"   # stale, as on Phoenix
printf 'export PATH=%s:$PATH FEMTIC_TOOLCHAIN=foss FEMTIC_BIN=%s\n. %s/femtic_lib.sh\n' "$BIN" "$BIN" "$BIN" > "$BIN/femtic_env.sh"
cat > "$BIN/mpirun" <<'FAKE'
#!/bin/bash
np=1; a=("$@"); for ((i = 0; i < ${#a[@]}; i++)); do [ "${a[i]}" = -np ] && np=${a[i+1]}; done
FAKE_NP=$np exec "${@: -1}"
FAKE
printf '#!/bin/bash\necho 1:00:00\n' > "$BIN/squeue"
printf '#!/bin/bash\nexit 0\n' > "$BIN/rcstat"
printf '#!/bin/bash\necho mocknode\n' > "$BIN/hostname"
# fake sacct: "id|COMPLETED|0:0|00:00:05" for every id of -j a,b,c
cat > "$BIN/sacct" <<'FAKE'
#!/bin/bash
a=("$@"); for ((i = 0; i < ${#a[@]}; i++)); do [ "${a[i]}" = -j ] && ids=${a[i+1]}; done
for id in ${ids//,/ }; do echo "$id|COMPLETED|0:0|00:00:05"; done
FAKE
# fake sbatch: one line per call in $WORK/sbatch_calls.txt; prints the job id (7000 + calls so far). MOCK_SBATCH_RUN=1:
# runs the script now, in -D or the current directory, with --export's variables and the SLURM_* its options imply.
cat > "$BIN/sbatch" <<'FAKE'
#!/bin/bash
echo "$*" >> "$WORK/sbatch_calls.txt"
id=$(( 7000 + $(wc -l < "$WORK/sbatch_calls.txt") ))
if [ "${MOCK_SBATCH_RUN:-0}" = 1 ]; then
  J=job; N=1; C=1; PART=icelake; EXP=""; D=$PWD
  for a in "$@"; do
    case "$prev" in -J) J=$a ;; -p) PART=$a ;; -D) D=$a ;; esac; prev=$a
    case "$a" in --ntasks-per-node=*) N=${a#*=} ;; --cpus-per-task=*) C=${a#*=} ;; --export=*) EXP=${a#*=} ;; esac
  done
  S=${*: -1}; EXP=${EXP#ALL}; EXP=${EXP#,}; VARS=(); IFS=, read -r -a VARS <<< "$EXP"
  ( cd "$D" && unset MSYS && env "${VARS[@]}" SLURM_JOB_ID=$id SLURM_JOB_NAME="$J" SLURM_SUBMIT_DIR="$D" SLURM_JOB_PARTITION="$PART" \
      SLURM_JOB_NUM_NODES=1 SLURM_JOB_NODELIST=n1 SLURM_NTASKS=$N SLURM_NTASKS_PER_NODE=$N SLURM_CPUS_PER_TASK=$C \
      SLURM_MEM_PER_NODE=254952 TMPDIR="$WORK/tmp" timeout 300 bash "$S" > "$D/slurm-$J-$id.out" 2>&1 )
fi
echo "$id"
FAKE
# fake femtic: rank 0 solves every band of observe.dat on a half-space of block 1's resistivity (result_0_iter<A>.csv,
# femtic_0.log with FEMTIC's frequency list, stamps and end line), femtic.cnv, and models A+1..B for ITERATION "A B"
cat > "$BIN/femtic" <<'FAKE'
#!/bin/bash
read -r A B < <(awk '$1=="ITERATION"{getline; print; exit}' control.dat)
NST=$(awk '$1=="MT"{print $2; exit}' observe.dat)
read -r -a FR < <(awk '$1=="MT"{s=1; next} s==1{s=2; next} s==2{n=$1; s=3; next} s==3{printf "%s ", $1; if (++k==n) {print ""; exit}}' observe.dat)
RHO=$(awk 'NR==1{ne=$1; next} NR==ne+3{print $2; exit}' resistivity_block_iter0.dat)
{ echo "#++++++++++"; echo "# Forward calculation is performed for the frequencies/periods below."
  echo "#   Freq#  Frequency[Hz]    Period[sec]"; for f in "${FR[@]}"; do echo "#  0  $f  1.0"; done; echo "#++++++++++"
  echo "# Start Forward Computation.  Iteration : $A,  Retrial : 0"; t=1
  for f in "${FR[@]}"; do
    echo "# Start forward calculation. Frequency : $f [Hz], Polarization : Ex-polarization"
    echo "# Number of equation = 6100, Number of equation after degeneration = 6000"
    t=$((t + 2)); echo "# Calculate response functions. ( $t sec )"
  done
  echo "# Release memory of coefficient matrix and sparse solver. ( $t sec )"; } > femtic_0.log
{ echo "MT,"; echo "     StaID,        Freq[Hz],     Re(Zxx)_Cal,     Im(Zxx)_Cal,     Re(Zxy)_Cal,     Im(Zxy)_Cal,     Re(Zyx)_Cal,     Im(Zyx)_Cal,     Re(Zyy)_Cal,     Im(Zyy)_Cal,"
  for f in "${FR[@]}"; do
    awk -v f="$f" -v rho="$RHO" -v nst="$NST" 'BEGIN { pi = atan2(0, -1); a = sqrt(2 * pi * f * 4e-7 * pi * rho) / sqrt(2)
      for (k = 1; k <= nst; k++) printf "%10d, %15.6e, %15.6e, %15.6e, %15.6e, %15.6e, %15.6e, %15.6e, %15.6e, %15.6e,\n", k, f, 0, 0, a, -a, -a, a, 0, 0 }'
  done; } > "result_0_iter$A.csv"
printf '%10s%10s%15s%15s%15s%15s%15s%15s\n' 'Iter#' 'Retrial#' Alpha Damp Roughness Misfit RMS ObjFunc > femtic.cnv
printf '%10d%10d%15e%15e%15e%15e%15e%15e\n' "$A" 0 3 0.5 1 1000 12.5 1 >> femtic.cnv
for ((it = A + 1; it <= B; it++)); do cat resistivity_block_iter0.dat > "resistivity_block_iter$it.dat"; done
echo "# Reach maximum iteration number." >> femtic_0.log
FAKE
# fake mesh tools (mesh_chain.sh, JOB=mesh). makeTetraMesh -stp N: needs control.dat and analysis_domain.dat, rewrites
# makeTetraMesh.log every step (FAKE_MTM_ERROR=N logs an error line at step N), -stp 1-3 write fake.stpN, -stp 4 writes
# output.poly ending "# Part 4" / "0" as the real one does
cat > "$BIN/makeTetraMesh" <<'FAKE'
#!/bin/bash
[ "$1" = -stp ] || exit 2
[ -s control.dat ] && [ -s analysis_domain.dat ] || { echo "cannot open control.dat" > makeTetraMesh.log; exit 1; }
echo "fake makeTetraMesh -stp $2" > makeTetraMesh.log
[ "${FAKE_MTM_ERROR:-0}" = "$2" ] && echo "Error : fake failure at step $2" >> makeTetraMesh.log
case $2 in
  1|2|3) echo "fake step $2" > "fake.stp$2" ;;
  4) printf '# Part 1 - node list\n0 3 0 0\n# Part 2 - facet list\n0 0\n# Part 3 - hole list\n0\n# Part 4\n0\n' > output.poly ;;
esac
FAKE
# fake tetgen SWITCHES BASE. BASE output.poly: the analysis_domain.dat box cut at z = 0 into two hexahedra of 6 tets each
# (12 nodes, 12 tets): the upper one takes the attribute of the region seed with z < 0, the lower one that of the seed
# with z > 0 (an unseeded one gets max + 1, as tetgen does) -> output.1.{node,ele,face,neigh}. BASE output.i (-r):
# reads output.i.node, .ele (and .mtr with -m), writes output.(i+1).{node,ele,face,neigh,mtr}, the same mesh with the
# sizes interpolated (so output.(i+1).mtr exists before makeMtr runs). FAKE_TETGEN_SLEEP=S sleeps S s first.
cat > "$BIN/tetgen" <<'FAKE'
#!/bin/bash
sleep "${FAKE_TETGEN_SLEEP:-0}"
b=${*: -1}; sw=$1
if [ "$b" = output.poly ]; then
  read -r x0 x1 < <(sed -n 1p analysis_domain.dat); read -r y0 y1 < <(sed -n 2p analysis_domain.dat); read -r z0 z1 < <(sed -n 3p analysis_domain.dat)
  read -r up lo < <(awk '$0 == "# Part 4" {p = 1; getline; next} p && NF >= 5 {if ($4 < 0) u = $5 + 0; else l = $5 + 0}
                         END {m = (u > l ? u : l); if (u == "") u = ++m; if (l == "") l = ++m; print u, l}' output.poly)
  awk -v x0="$x0" -v x1="$x1" -v y0="$y0" -v y1="$y1" -v z0="$z0" -v z1="$z1" 'BEGIN { print "12 3 0 0"
    for (iz = 0; iz < 3; iz++) for (iy = 0; iy < 2; iy++) for (ix = 0; ix < 2; ix++)
      printf "%d %s %s %s\n", ix + 2 * iy + 4 * iz, (ix ? x1 : x0), (iy ? y1 : y0), (iz == 0 ? z0 : (iz == 1 ? 0 : z1))
    print "# Generated by tetgen (fake)" }' > output.1.node
  awk -v up="$up" -v lo="$lo" 'BEGIN { split("012 021 102 120 201 210", P, " "); print "12 4 1"; n = 0
    for (k = 0; k < 2; k++) for (p = 1; p <= 6; p++) { c[0] = 0; c[1] = 0; c[2] = 0; id[0] = 4 * k
      for (s = 1; s <= 3; s++) { a = substr(P[p], s, 1); c[a] = 1; id[s] = c[0] + 2 * c[1] + 4 * (c[2] + k) }
      printf "%d %d %d %d %d %d\n", n++, id[0], id[1], id[2], id[3], (k ? lo : up) }
    print "# Generated by tetgen (fake)" }' > output.1.ele
  printf '0 1\n# Generated by tetgen (fake)\n' > output.1.face; printf '12 4\n# Generated by tetgen (fake)\n' > output.1.neigh
  echo "  Found 2 subdomains."
  exit 0
fi
i=${b#output.}; j=$((i + 1))
[ -s "$b.node" ] && [ -s "$b.ele" ] || { echo "Out of memory."; exit 1; }
case "$sw" in *m*) [ -s "$b.mtr" ] || { echo "no $b.mtr"; exit 1; } ;; esac
for e in node ele face neigh; do cp "$b.$e" "output.$j.$e"; done
awk 'NR == 1 {printf "%10d%10d\n", $1, 1; n = $1; for (k = 0; k < n; k++) printf "%15.6e\n", 1.5; exit}' "$b.node" > "output.$j.mtr"
echo "fake refinement $b -> output.$j"
FAKE
# fake makeMtr output.i: needs obs_site.dat, makeMtr.param, output.i.node and .ele; writes output.i.mtr ("%10d%10d" node
# count and 1, then one size per node). FAKE_MTR_SKIP=i: exits 0 in round i without writing; FAKE_MTR_SHORT=i: one
# value too few in round i
cat > "$BIN/makeMtr" <<'FAKE'
#!/bin/bash
b=$1; i=${b#output.}
for f in obs_site.dat makeMtr.param "$b.node" "$b.ele"; do [ -s "$f" ] || { echo "cannot open $f"; exit 1; }; done
[ "${FAKE_MTR_SKIP:-0}" = "$i" ] && { echo "fake makeMtr: round $i writes nothing"; exit 0; }
awk -v short="$([ "${FAKE_MTR_SHORT:-0}" = "$i" ] && echo 1 || echo 0)" 'NR == 1 {n = $1 - short; printf "%10d%10d\n", n, 1
  for (k = 0; k < n; k++) printf "%15.6e\n", 2.0; exit}' "$b.node" > "$b.mtr"
echo "fake makeMtr: $b.mtr"
FAKE
# fake TetGen2Femtic output.N: reads output.N.node, .ele and resistivity_attr.dat (its first attribute is the air);
# an element attribute missing from resistivity_attr.dat: exit 1, as the real one. Writes mesh.dat (TETRA, nodes,
# elements, then 7 face lists: the planes x0, x1, y0, y1, z0, z1 of the box and the Earth surface z = 0 seen from the
# earth side), resistivity_block_iter0.dat (air elements in cell 0, each earth element a cell) and output.N.femtic.vtk.
cat > "$BIN/TetGen2Femtic" <<'FAKE'
#!/bin/bash
b=$1
for f in "$b.node" "$b.ele" resistivity_attr.dat; do [ -s "$f" ] || { echo "cannot open $f"; exit 1; }; done
awk 'FNR == 1 {f++}
  f == 1 && FNR == 1 {na = $1; next} f == 1 && FNR <= na + 1 {ok[$1 + 0] = 1; if (FNR == 2) air = $1 + 0; next} f == 1 {next}
  f == 2 && FNR > 1 && !/^#/ {x[$1] = $2; y[$1] = $3; z[$1] = $4; nn++; if (nn == 1 || $2 < x0) x0 = $2; if (nn == 1 || $2 > x1) x1 = $2
    if (nn == 1 || $3 < y0) y0 = $3; if (nn == 1 || $3 > y1) y1 = $3; if (nn == 1 || $4 < z0) z0 = $4; if (nn == 1 || $4 > z1) z1 = $4; next}
  f == 3 && FNR > 1 && !/^#/ {e = ne++; for (k = 0; k < 4; k++) v[e, k] = $(k + 2); at[e] = $6 + 0
    if (!(at[e] in ok)) {printf "Region attiribute << %d of element %d cannot be found !!\n", at[e], e; bad = 1}}
  END { if (bad) exit 1
    print "TETRA" > "mesh.dat"; printf "%10d\n", nn > "mesh.dat"
    for (i = 0; i < nn; i++) printf "%10d %20.9e %20.9e %20.9e\n", i, x[i] * 1000, y[i] * 1000, z[i] * 1000 > "mesh.dat"
    printf "%10d\n", ne > "mesh.dat"
    for (e = 0; e < ne; e++) printf "%10d %9d %9d %9d %9d %9d %9d %9d %9d\n", e, -1, -1, -1, -1, v[e, 0], v[e, 1], v[e, 2], v[e, 3] > "mesh.dat"
    for (L = 1; L <= 7; L++) { n = 0
      for (e = 0; e < ne; e++) for (fc = 0; fc < 4; fc++) { m = 0
        for (k = 0; k < 4; k++) if (k != fc) { q = v[e, k]
          if (L == 1 && x[q] == x0 || L == 2 && x[q] == x1 || L == 3 && y[q] == y0 || L == 4 && y[q] == y1 || \
              L == 5 && z[q] == z0 || L == 6 && z[q] == z1 || L == 7 && z[q] == 0 && at[e] != air) m++ }
        if (m == 3) lst[n++] = e " " fc }
      printf "%10d\n", n > "mesh.dat"; for (k = 0; k < n; k++) print lst[k] > "mesh.dat" }
    nc = 1; for (e = 0; e < ne; e++) cell[e] = (at[e] == air ? 0 : nc++)
    printf "%10d%10d\n", ne, nc > "resistivity_block_iter0.dat"
    for (e = 0; e < ne; e++) printf "%10d%10d\n", e, cell[e] > "resistivity_block_iter0.dat"
    for (c = 0; c < nc; c++) printf "%10d   %.6e   %.6e   %.6e   %.6e%10d\n", c, (c ? 100 : 1e9), 1e-20, 1e20, 1, (c ? 0 : 1) > "resistivity_block_iter0.dat"
    print "fake TetGen2Femtic: " nn " nodes, " ne " elements, " nc " cells" }' resistivity_attr.dat "$b.node" "$b.ele" || exit 1
printf '# vtk DataFile Version 3.0\nfake TetGen2Femtic\nASCII\n' > "$b.femtic.vtk"
FAKE
# fake GNU time (mesh_chain.sh's TIME_BIN): gnutime -v -o FILE CMD...: runs CMD, writes FILE with the -v lines the chain
# reads, exits as CMD did
cat > "$BIN/gnutime" <<'FAKE'
#!/bin/bash
[ "$1" = -v ] && [ "$2" = -o ] || exit 2
f=$3; shift 3
"$@"; rc=$?
{ [ "$rc" -eq 0 ] || echo "Command exited with non-zero status $rc"
  printf '\tCommand being timed: "%s"\n\tMaximum resident set size (kbytes): 4242\n\tExit status: %d\n' "$*" "$rc"; } > "$f"
exit "$rc"
FAKE
export TIME_BIN=$BIN/gnutime
chmod +x "$BIN"/*
mkdir -p "$WORK/tmp"
# runsh [VAR=VALUE ...] ARGS... -> RC, OUT (stdout+stderr of run.sh), NSB (sbatch calls made by this call)
NR=0
runsh() {
  local ev=() n0
  while [[ "${1:-}" == *=* ]]; do ev+=("$1"); shift; done
  NR=$((NR + 1)); OUT=$WORK/runsh_$NR.out; n0=$(cat "$WORK/sbatch_calls.txt" 2>/dev/null | wc -l)
  ( env "PATH=$BIN:$PATH" WORK="$WORK" VF="$VF" BIN="$BIN" MSYS=winsymlinks:native WATCH_S=1 PYTHON="${PYTHON:-python3}" "${ev[@]}" \
      timeout 300 bash "$KIT/run.sh" "$@" > "$OUT" 2>&1 ); RC=$?
  NSB=$(( $(cat "$WORK/sbatch_calls.txt" 2>/dev/null | wc -l) - n0 ))
}
lastcall() { tail -1 "$WORK/sbatch_calls.txt"; }
: > "$WORK/sbatch_calls.txt"

# ================================================================ refusals (nothing may reach sbatch)
crit R1 "run.sh accepts a run that has no folder in runs/ (must exit 1 with 'unknown run' and call sbatch 0 times)"
runsh Run99; eq "R1 exit" "$RC" 1; has "R1 message" "$OUT" "unknown run Run99"; eq "R1 sbatch calls" "$NSB" 0
crit R2 "run.sh accepts a run.env without TIME, with an unknown key (RANK=3), a gate without START_RHO, or a START_RHO on a forward run (each: exit 1, sbatch 0 times)"
mkrun Run02 gate TIME=DROP; runsh Run02
eq "R2 no TIME: exit" "$RC" 1; has "R2 no TIME" "$OUT" "run.env has no TIME"; eq "R2 no TIME: sbatch calls" "$NSB" 0
mkrun Run02 gate; echo "RANK=3" >> "$RUNS/Run02/run.env"; runsh Run02
eq "R2 unknown key: exit" "$RC" 1; has "R2 unknown key" "$OUT" "unknown key RANK"; eq "R2 unknown key: sbatch calls" "$NSB" 0
mkrun Run02 gate START_RHO=none; runsh Run02
eq "R2 gate without START_RHO: exit" "$RC" 1; has "R2 gate without START_RHO" "$OUT" "JOB=gate needs START_RHO"; eq "R2 sbatch calls" "$NSB" 0
mkrun Run02 forward START_RHO=100; runsh Run02
eq "R2 forward with START_RHO: exit" "$RC" 1; has "R2 forward with START_RHO" "$OUT" "START_RHO=100 is for JOB=gate only"; eq "R2 sbatch calls" "$NSB" 0
crit R3 "run.sh accepts a run whose shared mesh is missing (MESH=v3, no shared/mesh_v3) or empty (a 0-byte mesh_v3/mesh.dat), or links anything for it"
mkrun Run03 gate MESH=v3; runsh Run03
eq "R3 missing: exit" "$RC" 1; has "R3 missing" "$OUT" "shared mesh file $SHARED/mesh_v3/mesh.dat is missing or empty"; eq "R3 missing: sbatch calls" "$NSB" 0
eq "R3 no link made" "$([ -e "$RUNS/Run03/mesh.dat" ] || [ -L "$RUNS/Run03/mesh.dat" ] && echo made || echo none)" none
mkdir -p "$SHARED/mesh_v3"; : > "$SHARED/mesh_v3/mesh.dat"; cp "$SHARED/mesh_v2/resistivity_block_iter0.dat" "$SHARED/mesh_v3/"; runsh Run03
eq "R3 empty: exit" "$RC" 1; has "R3 empty" "$OUT" "mesh_v3/mesh.dat is missing or empty"; eq "R3 empty: sbatch calls" "$NSB" 0
rm -rf "$SHARED/mesh_v3"
crit R4 "run.sh links the mesh into a run folder whose layout it refuses, or submits 8 x 9 when N_eq = 3,571,112 (v3's size: 8 x (39,283 forward + 872 sensitivity-step MiB) > 95 % of 254,952), or refuses 2 x 36 there (the control)"
mkrun Run04 gate RANKS=8 THREADS=9; runsh NEQ=3571112 Run04
eq "R4 8x9: exit" "$RC" 1; has "R4 8x9 refused" "$OUT" "8 ranks/node x (39283 forward + 872 sensitivity-step MiB)"; has "R4 advice" "$OUT" "Use fewer ranks per node"; eq "R4 8x9: sbatch calls" "$NSB" 0
eq "R4 8x9: the refusal leaves the run folder as it was (no mesh link)" "$(cd "$RUNS/Run04" && ls -A | tr '\n' ' ')" "RUN.md control.dat observe.dat run.env station_map.csv "
mkrun Run04 gate RANKS=2 THREADS=36; runsh NEQ=3571112 Run04
eq "R4 control 2x36: exit" "$RC" 0; eq "R4 control 2x36: sbatch calls" "$NSB" 1
hasnt "R4 control: the rule is silent when it passes" "$OUT" "layout rule"
crit R5 "run.sh submits JOB=t4 while control.dat says ITERATION 0 10 (T4 is one iteration: 0 1)"
mkrun Run05 t4; runsh Run05
eq "R5 exit" "$RC" 1; has "R5 message" "$OUT" "JOB=t4 needs ITERATION 0 1 in control.dat (it says '0 10')"; eq "R5 sbatch calls" "$NSB" 0
crit R6 "run.sh submits JOB=inversion without ITER_STEP and ITER_MAX"
mkrun Run06 inversion; runsh Run06
eq "R6 exit" "$RC" 1; has "R6 message" "$OUT" "JOB=inversion needs ITER_STEP and ITER_MAX"; eq "R6 sbatch calls" "$NSB" 0
crit R7 "run.sh accepts the optional keys with bad values (NIV=abc, NIV=0, MAIL=nobody without @), or does not name the key (each: exit 1, sbatch 0 times)"
mkrun Run07 gate; echo "NIV=abc" >> "$RUNS/Run07/run.env"; runsh Run07
eq "R7 NIV=abc: exit" "$RC" 1; has "R7 NIV=abc" "$OUT" "run.env: NIV=abc (a whole number >= 1, or none)"; eq "R7 NIV=abc: sbatch calls" "$NSB" 0
mkrun Run07 gate; echo "NIV=0" >> "$RUNS/Run07/run.env"; runsh Run07
eq "R7 NIV=0: exit" "$RC" 1; has "R7 NIV=0" "$OUT" "run.env: NIV=0 (a whole number >= 1, or none)"; eq "R7 NIV=0: sbatch calls" "$NSB" 0
mkrun Run07 gate; echo "MAIL=nobody" >> "$RUNS/Run07/run.env"; runsh Run07
eq "R7 MAIL=nobody: exit" "$RC" 1; has "R7 MAIL=nobody" "$OUT" "run.env: MAIL=nobody (an email address, or none)"; eq "R7 MAIL=nobody: sbatch calls" "$NSB" 0
crit R8 "NIV=840 in run.env does not reach the layout rule: a t4 run at v3's N_eq (3,571,112) with 2 x 36 must be refused with N_iv 840 (2 x (39,283 + 91,545) MiB > 95 % of 254,952) and leave no link, while R4 accepted 2 x 36 with N_iv from observe.dat"
. "$KIT/femtic_lib.sh"; mkrun Run08 t4 RANKS=2 THREADS=36 NIV=840; femtic_ctl_set "$RUNS/Run08/control.dat" ITERATION "0 1"
runsh NEQ=3571112 Run08
eq "R8 exit" "$RC" 1; has "R8 refused with N_iv 840" "$OUT" "2 ranks/node x (39283 forward + 91545 sensitivity-step MiB)"; eq "R8 sbatch calls" "$NSB" 0
eq "R8 no mesh link left" "$( { [ -e "$RUNS/Run08/mesh.dat" ] || [ -L "$RUNS/Run08/mesh.dat" ] || [ -L "$RUNS/Run08/resistivity_block_iter0.dat" ]; } && echo made || echo none)" none
crit R9 "run.sh submits a JOB=mesh run whose files/ lacks region_seeds.dat or has an empty topography.dat, whose run.env says MESH=v2 or has no FILES, a gate run with a FILES key, or a mesh run whose folder already holds a build (intermediates/), or links a mesh into such a folder (each: exit 1, sbatch 0 times)"
mkmesh Run12; rm "$RUNS/Run12/files/region_seeds.dat"; runsh Run12
eq "R9 no region_seeds.dat: exit" "$RC" 1; has "R9 no region_seeds.dat" "$OUT" "files lacks region_seeds.dat (missing or empty"; eq "R9 no region_seeds.dat: sbatch calls" "$NSB" 0
mkmesh Run12; : > "$RUNS/Run12/files/topography.dat"; runsh Run12
eq "R9 empty topography.dat: exit" "$RC" 1; has "R9 empty topography.dat" "$OUT" "files lacks topography.dat"; eq "R9 empty topography.dat: sbatch calls" "$NSB" 0
mkmesh Run12 MESH=v2; runsh Run12
eq "R9 MESH=v2: exit" "$RC" 1; has "R9 MESH=v2" "$OUT" "JOB=mesh builds a mesh, so MESH=none (got MESH=v2)"; eq "R9 MESH=v2: sbatch calls" "$NSB" 0
mkmesh Run12 FILES=DROP; runsh Run12
eq "R9 no FILES: exit" "$RC" 1; has "R9 no FILES" "$OUT" "JOB=mesh needs FILES=<the run's folder of mesh inputs>"; eq "R9 no FILES: sbatch calls" "$NSB" 0
mkrun Run12 gate; echo "FILES=files" >> "$RUNS/Run12/run.env"; runsh Run12
eq "R9 gate with FILES: exit" "$RC" 1; has "R9 gate with FILES" "$OUT" "FILES=files is for JOB=mesh only"; eq "R9 gate with FILES: sbatch calls" "$NSB" 0
mkmesh Run12; mkdir "$RUNS/Run12/intermediates"; runsh Run12 --again
eq "R9 earlier build: exit" "$RC" 1; has "R9 earlier build" "$OUT" "intermediates exists: an earlier mesh build is in this run folder"; eq "R9 earlier build: sbatch calls" "$NSB" 0
eq "R9 no mesh link in the mesh run folder" "$( { [ -e "$RUNS/Run12/mesh.dat" ] || [ -L "$RUNS/Run12/mesh.dat" ]; } && echo made || echo none)" none
crit R10 "run.sh submits a JOB=mesh run when BIN holds FEMTIC but no tetgen (it must check the four mesh tools, not femtic: exit 1 naming tetgen, sbatch 0 times)"
NB=$WORK/bin_notetgen; rm -rf "$NB"; cp -r "$BIN" "$NB"; rm -f "$NB/tetgen"
mkmesh Run12; runsh BIN="$NB" Run12
eq "R10 exit" "$RC" 1; has "R10 message" "$OUT" "no mesh tools at $NB (tetgen missing)"; eq "R10 sbatch calls" "$NSB" 0

# ================================================================ submissions
crit P1 "a v2 gate run (100 ohm-m, 3 x 24, 02:00:00, no MAIL in run.env) does not reach sbatch exactly once with -J Run01 -p icelake --ntasks-per-node=3 --cpus-per-task=24 --time=02:00:00 --mail-type=NONE --export=ALL,KIT=<kit>,BIN=<bin>,START_RHO=100 and 06_forward_only.slurm, or the links, RUN.md, INDEX.md or the printed id are wrong"
mkrun Run01 gate; runsh Run01
eq "P1 exit" "$RC" 0; eq "P1 sbatch calls" "$NSB" 1
J1=$(( 7000 + $(wc -l < "$WORK/sbatch_calls.txt") ))
eq "P1 sbatch arguments" "$(lastcall)" "--parsable -J Run01 -p icelake --ntasks-per-node=3 --cpus-per-task=24 --time=02:00:00 --mail-type=NONE --export=ALL,KIT=$KIT,BIN=$BIN,START_RHO=100 $KIT/06_forward_only.slurm"
eq "P1 mesh.dat link" "$(readlink "$RUNS/Run01/mesh.dat")" "../../shared/mesh_v2/mesh.dat"
eq "P1 resistivity_block_iter0.dat link" "$(readlink "$RUNS/Run01/resistivity_block_iter0.dat")" "../../shared/mesh_v2/resistivity_block_iter0.dat"
eq "P1 the link resolves to the shared file" "$(cksum < "$RUNS/Run01/mesh.dat")" "$(cksum < "$SHARED/mesh_v2/mesh.dat")"
has "P1 RUN.md" "$RUNS/Run01/RUN.md" "job $J1 submitted"
has "P1 INDEX.md line" "$RUNS/INDEX.md" "| Run01 | v2 | test gate run | 3x24 | $J1 | - |"
has "P1 printed id" "$OUT" "Run01: submitted job $J1"
eq "P1 run.sh prints two lines (the id and the status command; the memory model and the layout rule stay silent)" "$(wc -l < "$OUT" | tr -d ' ')" 2
crit P2 "a second run.sh Run01 submits again without --again, or --again does not run the job end to end: the job log and job_outcomes.tsv must carry KIT VERSION abc1234 although BIN's femtic_lib.sh is version 2, and the gate must PASS"
eq "P2 precondition: BIN's femtic_lib.sh" "$(sed -n 's/^FEMTIC_LIB_VERSION=//p' "$BIN/femtic_lib.sh")" 2
runsh Run01
eq "P2 repeat: exit" "$RC" 1; has "P2 repeat refused" "$OUT" "Run01 already has job(s) $J1 in RUN.md"; eq "P2 repeat: sbatch calls" "$NSB" 0
runsh MOCK_SBATCH_RUN=1 Run01 --again
J2=$(( J1 + 1 )); SO=$RUNS/Run01/slurm-Run01-$J2.out
eq "P2 --again: exit" "$RC" 0; eq "P2 --again: sbatch calls" "$NSB" 1
eq "P2 job log: kit banner in its first 5 lines" "$(head -5 "$SO" | grep -c 'KIT VERSION: abc1234 (2026-10-06 12:00)')" 1
hasnt "P2 job log: no version-gate error" "$SO" "needs FEMTIC_LIB_VERSION"
eq "P2 job_outcomes.tsv header ends in kit" "$(head -1 "$RUNS/Run01/job_outcomes.tsv" | awk -F'\t' '{print $NF}')" kit
eq "P2 job_outcomes.tsv row: job, outcome, kit" "$(awk -F'\t' -v j="$J2" '$1 == j {print $1, $6, $NF}' "$RUNS/Run01/job_outcomes.tsv")" "$J2 t6_PASS_gate_PASS abc1234"
has "P2 report: gate" "$RUNS/Run01/logs/fwd0_report_$J2.txt" "GATE (half-space, START_RHO=100): PASS"
has "P2 report: kit" "$RUNS/Run01/logs/fwd0_report_$J2.txt" "KIT VERSION: abc1234"
has "P2 INDEX.md has both ids" "$RUNS/INDEX.md" "| Run01 | v2 | test gate run | 3x24 | $J1 $J2 | - |"
eq "P2 RUN.md job lines" "$(grep -c '^job [0-9]* submitted' "$RUNS/Run01/RUN.md")" 2
crit S1 "status.sh accepts an unknown run, or for Run01 does not show both jobs' sacct state, the gate lines of the newest report, the last outcome and the INDEX line"
( env "PATH=$BIN:$PATH" VF="$VF" bash "$KIT/status.sh" Run99 > "$WORK/s1_bad.out" 2>&1 ); rc=$?
eq "S1 unknown run: exit" "$rc" 1; has "S1 unknown run" "$WORK/s1_bad.out" "unknown run 'Run99'"
( env "PATH=$BIN:$PATH" VF="$VF" bash "$KIT/status.sh" Run01 > "$WORK/s1.out" 2>&1 ); rc=$?
eq "S1 exit" "$rc" 0
has "S1 jobs" "$WORK/s1.out" "jobs:    $J1 COMPLETED exit 0:0 elapsed 00:00:05; $J2 COMPLETED exit 0:0 elapsed 00:00:05"
has "S1 report" "$WORK/s1.out" "report:  logs/fwd0_report_$J2.txt"
has "S1 gate line" "$WORK/s1.out" "GATE (half-space, START_RHO=100): PASS"
has "S1 outcome" "$WORK/s1.out" "outcome: job $J2 (06_forward_only): t6_PASS_gate_PASS, exit 0"
has "S1 index" "$WORK/s1.out" "index:   | Run01 | v2 | test gate run | 3x24 | $J1 $J2 | - |"
crit P3 "a t4 run (control.dat ITERATION 0 1) does not submit 04_inversion.slurm with WATCH_S=10, or 04 does not print the kit banner and write it into job_outcomes.tsv"
. "$KIT/femtic_lib.sh"; femtic_ctl_set "$RUNS/Run05/control.dat" ITERATION "0 1"
runsh MOCK_SBATCH_RUN=1 Run05
J5=$(( 7000 + $(wc -l < "$WORK/sbatch_calls.txt") ))
eq "P3 exit" "$RC" 0; eq "P3 sbatch calls" "$NSB" 1
eq "P3 sbatch arguments" "$(lastcall)" "--parsable -J Run05 -p icelake --ntasks-per-node=3 --cpus-per-task=24 --time=02:00:00 --mail-type=NONE --export=ALL,KIT=$KIT,BIN=$BIN,WATCH_S=10 $KIT/04_inversion.slurm"
eq "P3 04 log: kit banner in its first 5 lines" "$(head -5 "$RUNS/Run05/slurm-Run05-$J5.out" | grep -c 'KIT VERSION: abc1234 (2026-10-06 12:00)')" 1
eq "P3 job_outcomes.tsv row" "$(awk -F'\t' -v j="$J5" '$1 == j {print $2, $6, $NF}' "$RUNS/Run05/job_outcomes.tsv")" "04_inversion iteration_end abc1234"
eq "P3 COMPLETED marker" "$([ -s "$RUNS/Run05/logs/COMPLETED_$J5" ] && echo yes || echo no)" yes
crit P4 "an inversion run (ITER_STEP 5, ITER_MAX 12) does not chain ceil(12 / 5) = 3 jobs of 04 through 05_chain.sh with the run's layout, -J Run06 and KIT exported, or RUN.md, INDEX.md and chain_jobs.txt miss the ids or the kit"
mkrun Run06 inversion ITER_STEP=5 ITER_MAX=12 TIME=3-00:00:00; runsh Run06
eq "P4 exit" "$RC" 0; eq "P4 sbatch calls" "$NSB" 3
eq "P4 calls with the layout" "$(tail -3 "$WORK/sbatch_calls.txt" | grep -c -- "-J Run06 -p icelake --ntasks-per-node=3 --cpus-per-task=24 --time=3-00:00:00 --mail-type=NONE $KIT/04_inversion.slurm")" 3
eq "P4 no NIV exported when run.env has none" "$(tail -3 "$WORK/sbatch_calls.txt" | grep -c 'NIV=')" 0
eq "P4 calls exporting KIT and the chain" "$(tail -3 "$WORK/sbatch_calls.txt" | grep -c -- "AUTO_RESTART=1,ITER_STEP=5,ITER_MAX=12,INV_DIR=$RUNS/Run06,BIN=$BIN,KIT=$KIT")" 3
eq "P4 dependent calls" "$(tail -2 "$WORK/sbatch_calls.txt" | grep -c -- '--dependency=afterok:')" 2
eq "P4 05 prints the kit banner first" "$(head -1 "$OUT")" "KIT VERSION: abc1234 (2026-10-06 12:00)"
eq "P4 RUN.md job lines" "$(grep -c '^job [0-9]* submitted' "$RUNS/Run06/RUN.md")" 3
has "P4 chain_jobs.txt kit" "$RUNS/Run06/chain_jobs.txt" "kit=abc1234"
eq "P4 INDEX.md ids" "$(awk -F'|' '$2 == " Run06 " {print $6}' "$RUNS/INDEX.md" | wc -w | tr -d ' ')" 3
crit P5 "a forward run passes a START_RHO, or a highmem run lacks -p highmem --mem=1900G"
mkrun Run07 forward; runsh Run07
eq "P5 forward: exit" "$RC" 0
eq "P5 forward: sbatch arguments" "$(lastcall)" "--parsable -J Run07 -p icelake --ntasks-per-node=3 --cpus-per-task=24 --time=02:00:00 --mail-type=NONE --export=ALL,KIT=$KIT,BIN=$BIN $KIT/06_forward_only.slurm"
mkrun Run08 gate PARTITION=highmem RANKS=7 THREADS=10; runsh Run08
eq "P5 highmem: exit" "$RC" 0
eq "P5 highmem: sbatch arguments" "$(lastcall)" "--parsable -J Run08 -p highmem --ntasks-per-node=7 --cpus-per-task=10 --time=02:00:00 --mem=1900G --mail-type=NONE --export=ALL,KIT=$KIT,BIN=$BIN,START_RHO=100 $KIT/06_forward_only.slurm"
crit P6 "a t4 run with NIV=840 and MAIL=student@example.edu (1 x 72 at v3's N_eq) does not reach sbatch with --mail-type=END,FAIL --mail-user=student@example.edu and NIV=840 in --export, or 04 does not size with the N_iv 840 it was given"
mkrun Run09 t4 RANKS=1 THREADS=72 NIV=840 MAIL=student@example.edu; femtic_ctl_set "$RUNS/Run09/control.dat" ITERATION "0 1"
runsh NEQ=3571112 MOCK_SBATCH_RUN=1 Run09
J9=$(( 7000 + $(wc -l < "$WORK/sbatch_calls.txt") ))
eq "P6 exit" "$RC" 0; eq "P6 sbatch calls" "$NSB" 1
eq "P6 sbatch arguments" "$(lastcall)" "--parsable -J Run09 -p icelake --ntasks-per-node=1 --cpus-per-task=72 --time=02:00:00 --mail-type=END,FAIL --mail-user=student@example.edu --export=ALL,KIT=$KIT,BIN=$BIN,NIV=840,WATCH_S=10 $KIT/04_inversion.slurm"
has "P6 04 sized with N_iv 840" "$RUNS/Run09/slurm-Run09-$J9.out" "the layout rule used 840 (NIV=840 (set))"
has "P6 04 predicted per rank" "$RUNS/Run09/slurm-Run09-$J9.out" "predicted per rank (layout rule): 39283 forward + 91545 sensitivity-step = 130828 MiB"
crit P4b "an inversion run with NIV=840 and MAIL=student@example.edu does not pass both to each of the 3 chained 04 jobs"
mkrun Run11 inversion ITER_STEP=5 ITER_MAX=12 TIME=3-00:00:00 NIV=840 MAIL=student@example.edu; runsh Run11
eq "P4b exit" "$RC" 0; eq "P4b sbatch calls" "$NSB" 3
eq "P4b calls with the mail options" "$(tail -3 "$WORK/sbatch_calls.txt" | grep -c -- "--time=3-00:00:00 --mail-type=END,FAIL --mail-user=student@example.edu $KIT/04_inversion.slurm")" 3
eq "P4b calls exporting NIV=840" "$(tail -3 "$WORK/sbatch_calls.txt" | grep -c -- "INV_DIR=$RUNS/Run11,BIN=$BIN,KIT=$KIT,NIV=840 ")" 3
# chainrun RUN [VAR=VALUE ...]: mesh_chain.sh (MC, default the kit's) run in runs/RUN as a Slurm job would run it, with
# the fake tools and VAR=VALUE in its environment; sets RC and OUT (its output)
NC=0
chainrun() {
  local n=$1; shift; NC=$((NC + 1)); OUT=$WORK/chain_$NC.out
  ( cd "$RUNS/$n" && env "PATH=$BIN:$PATH" VF="$VF" KIT="$KIT" BIN="$BIN" SLURM_JOB_ID=$((9000 + NC)) SLURM_SUBMIT_DIR="$RUNS/$n" "$@" \
      timeout 300 bash "${MC:-$KIT/mesh_chain.sh}" > "$OUT" 2>&1 ); RC=$?
}
nobuild() { { [ -e "$RUNS/$1/mesh.dat" ] || [ -e "$RUNS/$1/resistivity_block_iter0.dat" ]; } && echo "products left" || echo none; }
crit X1 "mesh_chain.sh finishes when makeMtr exits 0 without writing in round 2 (FAKE_MTR_SKIP=2), or writes a round-1 .mtr with one value too few (FAKE_MTR_SHORT=1), or the region seeds are swapped (air attribute 10 below the surface), or makeTetraMesh logs an error at step 3: each must exit 1 with 'MESH CHAIN DONE: FAILED, exit 1 at <step>: <reason>' in the output and mesh_summary.txt, a mesh_failed row, and no product in the run folder"
mkmesh Run13; chainrun Run13 FAKE_MTR_SKIP=2
eq "X1 makeMtr writes nothing in round 2: exit" "$RC" 1; has "X1 round 2" "$OUT" "MESH CHAIN DONE: FAILED, exit 1 at makeMtr_2: makeMtr produced no output.2.mtr"
eq "X1 round 2: no product" "$(nobuild Run13)" none; has "X1 round 2: mesh_summary.txt" "$RUNS/Run13/mesh_summary.txt" "MESH CHAIN DONE: FAILED, exit 1 at makeMtr_2"
eq "X1 round 2: outcome row" "$(awk -F'\t' 'NR > 1 {print $2, $6, $9}' "$RUNS/Run13/job_outcomes.tsv")" "mesh_chain mesh_failed 1"
mkmesh Run13; chainrun Run13 FAKE_MTR_SHORT=1
eq "X1 short .mtr: exit" "$RC" 1; has "X1 short .mtr" "$OUT" "at makeMtr_1: output.1.mtr lists 11 values, output.1.node has 12 nodes"; eq "X1 short .mtr: no product" "$(nobuild Run13)" none
mkmesh Run13; printf '0 0 -40 20 1e9\n0 0 10 10 1e9\n' > "$RUNS/Run13/files/region_seeds.dat"; chainrun Run13
eq "X1 swapped seeds: exit" "$RC" 1; has "X1 swapped seeds" "$OUT" "at tetgen_1: air attribute 10 is not the region at the top of the domain"; eq "X1 swapped seeds: no product" "$(nobuild Run13)" none
mkmesh Run13; chainrun Run13 FAKE_MTM_ERROR=3
eq "X1 makeTetraMesh error: exit" "$RC" 1; has "X1 makeTetraMesh error" "$OUT" "at stp3: makeTetraMesh -stp 3 logged an error"; eq "X1 makeTetraMesh error: no product" "$(nobuild Run13)" none
crit X2 "(control: the WSL check could not fail) a mesh_chain.sh without the line that keeps tetgen's output.i.mtr apart does not finish OK on FAKE_MTR_SKIP=2, i.e. the round-2 refusal of X1 is not owed to that line"
MC=$WORK/mesh_chain_nokeep.sh; grep -v 'output.$i.tetgen.mtr' "$KIT/mesh_chain.sh" > "$MC"
eq "X2 mutant differs by one line" "$(diff "$KIT/mesh_chain.sh" "$MC" | grep -c '^<')" 1
mkmesh Run13; chainrun Run13 FAKE_MTR_SKIP=2; MC=""
eq "X2 mutant exit" "$RC" 0; has "X2 mutant DONE OK" "$OUT" "MESH CHAIN DONE: OK, exit 0"

# ================================================================ JOB=mesh: submission, the chain (fake tools), status
crit P7 "a mesh run (MESH=none, 1 x 8, 04:00:00, FILES=files) does not reach sbatch exactly once with -J Run12 -p icelake --ntasks-per-node=1 --cpus-per-task=8 --time=04:00:00 --mem=27G --mail-type=NONE --export=ALL,KIT=<kit>,BIN=<bin>,FILES=files and mesh_chain.sh, links a mesh.dat, or RUN.md, INDEX.md or run.sh's 2 printed lines miss the job"
mkmesh Run12; runsh Run12
J12=$(( 7000 + $(wc -l < "$WORK/sbatch_calls.txt") ))
eq "P7 exit" "$RC" 0; eq "P7 sbatch calls" "$NSB" 1
eq "P7 sbatch arguments" "$(lastcall)" "--parsable -J Run12 -p icelake --ntasks-per-node=1 --cpus-per-task=8 --time=04:00:00 --mem=27G --mail-type=NONE --export=ALL,KIT=$KIT,BIN=$BIN,FILES=files $KIT/mesh_chain.sh"
eq "P7 no mesh.dat link" "$( { [ -e "$RUNS/Run12/mesh.dat" ] || [ -L "$RUNS/Run12/mesh.dat" ]; } && echo made || echo none)" none
has "P7 RUN.md" "$RUNS/Run12/RUN.md" "job $J12 submitted"
has "P7 INDEX.md line" "$RUNS/INDEX.md" "| Run12 | none | test mesh run | 1x8 | $J12 | - |"
has "P7 printed id" "$OUT" "Run12: submitted job $J12 (JOB=mesh, inputs files/, 1x8, --time=04:00:00)"
eq "P7 run.sh prints 2 lines" "$(wc -l < "$OUT" | tr -d ' ')" 2
crit P8 "the mesh job, run by the fake sbatch with the fake tools (two hexahedra of 6 tets in the +-300 km box: 12 nodes, 12 tets, 1 air + 6 earth cells, 2 Earth-surface and 20 box faces), does not leave mesh.dat, resistivity_block_iter0.dat and output.6.femtic.vtk in the run folder, intermediates/ without output.poly (seeded), output.1-6.{node,ele,face,neigh}, makeMtr's .mtr of rounds 1-5 and tetgen's of rounds 2-5 kept apart, 16 timings rows with rc 0 and a .timev per step, mesh_summary.txt without those counts and 'MESH CHAIN DONE: OK', a job_outcomes.tsv row mesh_ok with the kit, the KIT VERSION banner; or it changes files/"
FS0=$(cat "$RUNS/Run12/files"/* | cksum)
runsh MOCK_SBATCH_RUN=1 Run12 --again
J=$(( 7000 + $(wc -l < "$WORK/sbatch_calls.txt") )); I=$RUNS/Run12/intermediates
eq "P8 exit" "$RC" 0; eq "P8 sbatch calls" "$NSB" 1
for f in mesh.dat resistivity_block_iter0.dat output.6.femtic.vtk; do eq "P8 product $f in the run folder" "$([ -s "$RUNS/Run12/$f" ] && echo yes || echo no)" yes; done
eq "P8 output.poly + output.1-6.{node,ele,face,neigh}" "$(cd "$I" && ls output.poly output.[1-6].node output.[1-6].ele output.[1-6].face output.[1-6].neigh 2>/dev/null | wc -l | tr -d ' ')" 25
eq "P8 .mtr: makeMtr's 1-5, tetgen's 2-5 apart" "$(cd "$I" && ls output.[1-5].mtr output.[2-5].tetgen.mtr 2>/dev/null | wc -l | tr -d ' ')" 9
has "P8 output.poly seeded" "$I/output.poly" "2 0 0 10 20 1e9"
eq "P8 timings.tsv: 16 steps, all rc 0" "$(awk -F'\t' 'NR > 1 && $2 == 0' "$I/timings.tsv" | wc -l | tr -d ' ') of $(( $(wc -l < "$I/timings.tsv") - 1 ))" "16 of 16"
eq "P8 a .timev with the max RSS per step" "$(grep -l 'Maximum resident set size (kbytes): 4242' "$I"/logs/*.timev | wc -l | tr -d ' ')" 16
has "P8 counts" "$RUNS/Run12/mesh_summary.txt" "MESH COUNTS: nodes 12  tets 12  cells 7  surface_faces 2  outer_faces 20"
has "P8 DONE line" "$RUNS/Run12/mesh_summary.txt" "MESH CHAIN DONE: OK, exit 0 (stp1 0, stp2 0, stp3 0, stp4 0, tetgen_1 0, makeMtr_1 0, tetgen_r1 0, makeMtr_2 0, tetgen_r2 0, makeMtr_3 0, tetgen_r3 0, makeMtr_4 0, tetgen_r4 0, makeMtr_5 0, tetgen_r5 0, t2f 0)"
eq "P8 job_outcomes.tsv row: job, script, outcome, exit, kit" "$(awk -F'\t' -v j="$J" '$1 == j {print $1, $2, $6, $9, $NF}' "$RUNS/Run12/job_outcomes.tsv")" "$J mesh_chain mesh_ok 0 abc1234"
eq "P8 job log: kit banner in its first 5 lines" "$(head -5 "$RUNS/Run12/slurm-Run12-$J.out" | grep -c 'KIT VERSION: abc1234 (2026-10-06 12:00)')" 1
eq "P8 files/ unchanged" "$(cat "$RUNS/Run12/files"/* | cksum)" "$FS0"
crit S2 "status.sh for the mesh run does not show the counts and DONE lines of mesh_summary.txt and the mesh_ok outcome"
( env "PATH=$BIN:$PATH" VF="$VF" bash "$KIT/status.sh" Run12 > "$WORK/s2.out" 2>&1 ); rc=$?
eq "S2 exit" "$rc" 0
has "S2 counts" "$WORK/s2.out" "mesh:    MESH COUNTS: nodes 12  tets 12  cells 7  surface_faces 2  outer_faces 20"
has "S2 DONE" "$WORK/s2.out" "mesh:    MESH CHAIN DONE: OK, exit 0"
has "S2 outcome" "$WORK/s2.out" "outcome: job $J (mesh_chain): mesh_ok, exit 0"
crit L1 "mesh_chain.sh outside Slurm runs without LOGIN=1 (must refuse and write nothing), LOGIN=1 with LOGIN_MAX_S=2 and a tetgen that sleeps 6 s does not stop with exit 124 and a 'DONE: FAILED, exit 124 at the login-node cap' line, or LOGIN=1 on a fresh folder does not finish OK with a job_outcomes.tsv row for job 'login'"
mkmesh Run14; ( cd "$RUNS/Run14" && env -u SLURM_JOB_ID "PATH=$BIN:$PATH" KIT="$KIT" BIN="$BIN" bash "$KIT/mesh_chain.sh" "$RUNS/Run14" > "$WORK/l1.out" 2>&1 ); rc=$?
eq "L1 no LOGIN: exit" "$rc" 1; has "L1 no LOGIN" "$WORK/l1.out" "REFUSED: not inside a Slurm job"; eq "L1 no LOGIN: nothing written" "$(ls "$RUNS/Run14" | tr '\n' ' ')" "RUN.md files run.env "
( cd "$RUNS/Run14" && env -u SLURM_JOB_ID "PATH=$BIN:$PATH" KIT="$KIT" BIN="$BIN" LOGIN=1 LOGIN_MAX_S=2 FAKE_TETGEN_SLEEP=6 bash "$KIT/mesh_chain.sh" "$RUNS/Run14" > "$WORK/l2.out" 2>&1 ); rc=$?
eq "L1 cap: exit" "$rc" 124; has "L1 cap" "$WORK/l2.out" "MESH CHAIN DONE: FAILED, exit 124 at the login-node cap: LOGIN_MAX_S=2 s reached"; eq "L1 cap: no product" "$(nobuild Run14)" none
mkmesh Run14; ( cd "$RUNS/Run14" && env -u SLURM_JOB_ID "PATH=$BIN:$PATH" KIT="$KIT" BIN="$BIN" LOGIN=1 bash "$KIT/mesh_chain.sh" "$RUNS/Run14" > "$WORK/l3.out" 2>&1 ); rc=$?
eq "L1 LOGIN=1: exit" "$rc" 0; has "L1 LOGIN=1: DONE" "$WORK/l3.out" "MESH CHAIN DONE: OK, exit 0"
eq "L1 LOGIN=1: outcome row" "$(awk -F'\t' 'NR > 1 {print $1, $6}' "$RUNS/Run14/job_outcomes.tsv")" "login mesh_ok"
crit C1 "mesh_chain.sh --counts prints a line (instead of exit 1) for a mesh.dat without its last line, with one line too many, for a block file whose element count is 13, or a folder without mesh.dat; or, for the fake build of P8, does not print 'nodes 12  tets 12  cells 7  surface_faces 2  outer_faces 20'"
cnt() { local d=$WORK/cnt_$1; rm -rf "$d"; mkdir -p "$d"; cp "$RUNS/Run12/mesh.dat" "$RUNS/Run12/resistivity_block_iter0.dat" "$d/"; echo "$d"; }
d=$(cnt short); sed -i '$d' "$d/mesh.dat"; o=$(bash "$KIT/mesh_chain.sh" --counts "$d" 2>&1); rc=$?
eq "C1 last line missing: exit" "$rc" 1; eq "C1 last line missing: message" "$(echo "$o" | grep -c 'mesh.dat ends at line')" 1
d=$(cnt long); echo "         0         1" >> "$d/mesh.dat"; o=$(bash "$KIT/mesh_chain.sh" --counts "$d" 2>&1); rc=$?
eq "C1 extra line: exit" "$rc" 1; eq "C1 extra line: no count line" "$(echo "$o" | grep -c '^nodes ')" 0
d=$(cnt blk); sed -i '1s/.*/        13         7/' "$d/resistivity_block_iter0.dat"; o=$(bash "$KIT/mesh_chain.sh" --counts "$d" 2>&1); rc=$?
eq "C1 block says 13 elements: exit" "$rc" 1; eq "C1 block: message" "$(echo "$o" | grep -c 'lists 13 elements, mesh.dat 12')" 1
d=$(cnt none); rm "$d/mesh.dat"; bash "$KIT/mesh_chain.sh" --counts "$d" > /dev/null 2>&1; eq "C1 no mesh.dat: exit" "$?" 1
eq "C1 the fake build" "$(bash "$KIT/mesh_chain.sh" --counts "$RUNS/Run12")" "nodes 12  tets 12  cells 7  surface_faces 2  outer_faces 20"

# ================================================================ mail and BIN defaults
crit M1 "03, 04, 06 or mesh_chain.sh still has an #SBATCH --mail-type or --mail-user line (a job submitted by hand, not by run.sh, would email that address)"
for s in 03_mesh.slurm 04_inversion.slurm 06_forward_only.slurm mesh_chain.sh; do eq "M1 $s: #SBATCH --mail lines" "$(grep -c '^#SBATCH --mail' "$KIT/$s")" 0; done
crit B1 "run.sh without BIN submits when \$VF/bin holds no FEMTIC, or with \$VF/bin linked to a FEMTIC build (RUNBOOK S1) does not export BIN=\$VF/bin and run the gate with it"
mkrun Run10 gate; runsh BIN= Run10
eq "B1 no \$VF/bin: exit" "$RC" 1; has "B1 no \$VF/bin: message" "$OUT" "no FEMTIC at $VF/bin"; eq "B1 no \$VF/bin: sbatch calls" "$NSB" 0
MSYS=winsymlinks:native ln -s "$BIN" "$VF/bin"
runsh BIN= MOCK_SBATCH_RUN=1 Run10
J10=$(( 7000 + $(wc -l < "$WORK/sbatch_calls.txt") ))
eq "B1 exit" "$RC" 0; eq "B1 sbatch calls" "$NSB" 1
eq "B1 sbatch arguments" "$(lastcall)" "--parsable -J Run10 -p icelake --ntasks-per-node=3 --cpus-per-task=24 --time=02:00:00 --mail-type=NONE --export=ALL,KIT=$KIT,BIN=$VF/bin,START_RHO=100 $KIT/06_forward_only.slurm"
has "B1 the job launched \$VF/bin/femtic" "$RUNS/Run10/slurm-Run10-$J10.out" "$VF/bin/femtic"
has "B1 the gate ran with \$VF/bin" "$RUNS/Run10/logs/fwd0_report_$J10.txt" "GATE (half-space, START_RHO=100): PASS"
crit B2 "03, 04, 05, 06 or mesh_chain.sh, started without BIN, do not take \$VF/bin (VF set: \$VF/bin; VF unset: /hpcfs/users/\$USER/vulcan_femtic/bin)"
for s in 03_mesh.slurm 04_inversion.slurm 05_chain.sh 06_forward_only.slurm mesh_chain.sh; do
  L=$(grep -E '^(VF|BIN)=' "$KIT/$s")
  eq "B2 $s, VF set" "$(env -u BIN VF=/x/vf USER=u bash -c "$L"$'\n''echo "$BIN"')" /x/vf/bin
  eq "B2 $s, VF unset" "$(env -u BIN -u VF USER=u bash -c "$L"$'\n''echo "$BIN"')" /hpcfs/users/u/vulcan_femtic/bin
done

echo; echo "SUMMARY: $npass passed, $nfail failed   (PLAN=$PLAN)"
[ "$nfail" = 0 ]
