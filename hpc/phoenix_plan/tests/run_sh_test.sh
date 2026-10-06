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
# --mail-user in 03/04/06 (M1), and BIN's default $VF/bin in run.sh and in 03/04/05/06 (B1, B2).
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

# ================================================================ mail and BIN defaults
crit M1 "03, 04 or 06 still has an #SBATCH --mail-type or --mail-user line (a job submitted by hand, not by run.sh, would email that address)"
for s in 03_mesh.slurm 04_inversion.slurm 06_forward_only.slurm; do eq "M1 $s: #SBATCH --mail lines" "$(grep -c '^#SBATCH --mail' "$KIT/$s")" 0; done
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
crit B2 "03, 04, 05 or 06, started without BIN, do not take \$VF/bin (VF set: \$VF/bin; VF unset: /hpcfs/users/\$USER/vulcan_femtic/bin)"
for s in 03_mesh.slurm 04_inversion.slurm 05_chain.sh 06_forward_only.slurm; do
  L=$(grep -E '^(VF|BIN)=' "$KIT/$s")
  eq "B2 $s, VF set" "$(env -u BIN VF=/x/vf USER=u bash -c "$L"$'\n''echo "$BIN"')" /x/vf/bin
  eq "B2 $s, VF unset" "$(env -u BIN -u VF USER=u bash -c "$L"$'\n''echo "$BIN"')" /hpcfs/users/u/vulcan_femtic/bin
done

echo; echo "SUMMARY: $npass passed, $nfail failed   (PLAN=$PLAN)"
[ "$nfail" = 0 ]
