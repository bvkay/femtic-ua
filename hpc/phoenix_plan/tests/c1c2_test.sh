#!/bin/bash
# =============================================================================
# c1c2_test.sh -- self-test of the 2026-09-28 changes to the Phoenix kit (docs/STATUS.md items C1, C2):
#   C1  femtic_pardiso_kb / femtic_pardiso_max_gb read FEMTIC's %g numbers; FEMTIC_LIB_VERSION 3 and the gates
#   C2  two-array sensitivity-step model (femtic_sens_mem_mb), the layout rule that 04 and 06 enforce
#       (femtic_layout_check), and 06's half-space gate (START_RHO + tools/halfspace_eval.py)
#   (d) the version gates: 01 SMOKE_ONLY, 03, 04, 05 and 06 all need FEMTIC_LIB_VERSION >= 5 in their kit (KIT)
#       (2026-10-06: since version 5 the scripts read femtic_lib.sh from KIT, not from BIN; d1, d2, d4 pass KIT)
#   (f) follow-ups from the kit verdict: N_iv behind FEMTIC's DIV_NUM_RHS_FWD warning, 06's job_outcomes.tsv exit
#       column, station names in the gate report, 06's walltime and SU text, and the LAYOUT hand-over to 05
# No real femtic, mpirun or Slurm: a fake femtic writes the log lines, result csv files and model files that 04
# and 06 read; fake mpirun, squeue, sacct, rcstat, hostname and sbatch stand in for the rest. Nothing heavy runs.
#
#   bash c1c2_test.sh [PLAN_DIR]        PLAN_DIR = the kit to test (default: the directory above this script)
#   env: WORK=<dir> (default mktemp -d), STALE_LIB=<a version-2 femtic_lib.sh, e.g. the fa58604 copy>,
#        PYTHON=<python 3> (default: the first of python3, python that runs),
#        ACC_ROOT=<.../mesh with the WSL gate runs> (f5 reads T_f from their logs; default /d/BEN/FEMTIC_2026/mesh,
#        else 755 s), REAL_INV_LOG=<a real FEMTIC log with a sensitivity step> (f1; default the WSL INV_MT_01 run)
# Every check prints its failure criterion ("fails if ...") before its result. Exit 0 only if every check
# passes. Run against the pre-change kit (a copy of commit 55bbf44's hpc/phoenix_plan), the C1/C2 checks fail.
# Portable: GNU bash 4.4+ (Phoenix login node), 5.x (WSL, Git Bash); gawk.
# =============================================================================
PLAN=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
PLAN=$(cd "$PLAN" && pwd) || exit 2
WORK=${WORK:-$(mktemp -d)}
mkdir -p "$WORK" || exit 2
WORK=$(cd "$WORK" && pwd)
if [ -z "${PYTHON:-}" ]; then
  for p in python3 python; do
    if [ "$("$p" -c 'import sys; print(sys.version_info[0])' 2>/dev/null)" = 3 ]; then PYTHON=$p; break; fi
  done
fi
echo "c1c2_test: PLAN=$PLAN  WORK=$WORK  PYTHON=${PYTHON:-none}  bash $BASH_VERSION  $(awk --version 2>/dev/null | head -1)"
npass=0; nfail=0
crit() { echo; echo "CHECK $1: fails if $2"; }
ok()   { echo "  PASS $*"; npass=$((npass + 1)); }
bad()  { echo "  FAIL $*"; nfail=$((nfail + 1)); }
eq()   { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got '$2', want '$3'"; fi; }
has()  { if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1: '$3' found"; else bad "$1: '$3' not in $2"; fi; }
hasnt(){ if grep -qF -- "$3" "$2" 2>/dev/null; then bad "$1: '$3' present in $2"; else ok "$1: no '$3'"; fi; }

# ---------------------------------------------------------------- fake bin
BIN=$WORK/bin; mkdir -p "$BIN"
cp "$PLAN/femtic_lib.sh" "$BIN/femtic_lib.sh"
printf 'export PATH=%s:$PATH FEMTIC_TOOLCHAIN=foss FEMTIC_BIN=%s\n. %s/femtic_lib.sh\n' "$BIN" "$BIN" "$BIN" > "$BIN/femtic_env.sh"
cat > "$BIN/mpirun" <<'EOF'
#!/bin/bash
echo "$*" > mpirun_args.txt
np=1; a=("$@"); for ((i = 0; i < ${#a[@]}; i++)); do [ "${a[i]}" = -np ] && np=${a[i+1]}; done
FAKE_NP=$np exec "${@: -1}"
EOF
printf '#!/bin/bash\necho "${MOCK_TL:-1:00:00}"\n' > "$BIN/squeue"
printf '#!/bin/bash\nexit 0\n' > "$BIN/rcstat"; printf '#!/bin/bash\nexit 0\n' > "$BIN/sacct"
printf '#!/bin/bash\necho mocknode\n' > "$BIN/hostname"
# fake sbatch: records its arguments; MOCK_SBATCH_OK=1 answers like --parsable (job id 5000 + call number), else fails
printf '#!/bin/bash\necho "fake sbatch $*" >> "%s/sbatch_calls.txt"\n[ "${MOCK_SBATCH_OK:-0}" = 1 ] || exit 1\necho $(( 5000 + $(wc -l < "%s/sbatch_calls.txt") ))\n' "$WORK" "$WORK" > "$BIN/sbatch"
REAL_DF=$(command -v df)
printf '#!/bin/bash\nif [ "${MOCK_TMPFS:-0}" = 1 ]; then echo "Filesystem Type 1024-blocks Used Available Capacity Mounted on"; echo "tmpfs tmpfs 209715200 0 209715200 0%% /tmp"; else exec %s "$@"; fi\n' "$REAL_DF" > "$BIN/df"
cat > "$BIN/femtic" <<'EOF'
#!/bin/bash
# fake femtic: np ranks (FAKE_NP from the fake mpirun), frequencies and MT stations from observe.dat, the
# resistivity of block 1 of resistivity_block_iter0.dat as a uniform half-space for result_<rank>_iter0.csv.
# FAKE_PARDISO = PARDISO values (KB, as FEMTIC prints them) per rank, cycled; FAKE_NIV = right-hand sides
# logged per interpolator solve when ITERATION a < b; FAKE_PERTURB="sta freq factor" scales one Re(Zxy)_Cal.
# FAKE_DIVWARN=1 logs each interpolator solve as FEMTIC does when DIV_NUM_RHS_FWD > N_iv (Forward3D.cpp:183-195):
# the two "Warning" lines, then FAKE_NIV lines "for 1 right-hand sides". FAKE_RC=<n> exits n without the end line.
NP=${FAKE_NP:-1}
read -r A B < <(awk '$1=="ITERATION"{getline; print; exit}' control.dat)
echo "ARGS np=$NP ITERATION=$A $B THREADS=$(awk '$1=="NUM_THREADS"{getline; print; exit}' control.dat)" >> fake_calls.txt
NST=$(awk '$1=="MT"{print $2; exit}' observe.dat)
read -r -a FR < <(awk '$1=="MT"{s=1; next} s==1{s=2; next} s==2{n=$1; s=3; next} s==3{printf "%s ", $1; if (++k==n) {print ""; exit}}' observe.dat)
RHO=$(awk 'NR==1{ne=$1; next} NR==ne+3{print $2; exit}' resistivity_block_iter0.dat)
read -r -a PV <<< "${FAKE_PARDISO:-2.74856e+07}"
F=${#FR[@]}; q=$(( F / NP )); x=$(( F % NP ))
printf '%10s%10s%15s%15s%15s%15s%15s%15s\n' 'Iter#' 'Retrial#' Alpha Damp Roughness Misfit RMS ObjFunc > femtic.cnv
for ((r = 0; r < NP; r++)); do
  if [ "$r" -lt $(( NP - x )) ]; then s=$(( r * q )); n=$q; else s=$(( (NP - x) * q + (r - NP + x) * (q + 1) )); n=$(( q + 1 )); fi
  { if [ "$r" = 0 ]; then
      echo "#++++++++++"; echo "# Forward calculation is performed for the frequencies/periods below."
      echo "#   Freq#  Frequency[Hz]    Period[sec]"
      for ((i = 0; i < F; i++)); do echo "#  $i  ${FR[i]}  1.0"; done; echo "#++++++++++"
    fi
    echo "# Total number of stations : $(( 2 * NST )) ."; echo "#  - Number of impedance tensor stations : $NST ."
    echo "#  - Number of VTF stations : $NST ."; echo "# Total number of model parameter : 68654."
    echo "# Calculate Roughening Matrix .( 1 sec )"; echo "# Start Forward Computation.  Iteration : $A,  Retrial : 0"
    t=1
    for ((i = s; i < s + n; i++)); do
      echo "# Start forward calculation. Frequency : ${FR[i]} [Hz], Polarization : Ex-polarization"
      echo "# Number of equation = 3572389, Number of equation after degeneration = 3568555"
      echo "# Total memory consumed by in-core forward solver for internal float point arrays    : ${PV[r % ${#PV[@]}]} [KByte]"
      if [ "$A" -lt "$B" ]; then
        echo "# Calulate right-hand sides vectors consisting of interpolator vectors.( $t sec )"
        echo "# Solve phase of matrix solver for right-hand sides consisting of interpolator vectors.( $t sec )"
        if [ "${FAKE_DIVWARN:-0}" = 1 ]; then
          echo "Warning : Division number of right-hand sides ( 1000 ) is greater than the total number of right-hand sides ( ${FAKE_NIV:-480} )."
          echo "          Thus, the division number is set the total number of right-hand sides."
          for ((k = 0; k < ${FAKE_NIV:-480}; k++)); do echo "# Solve phase is performed simultaneously for 1 right-hand sides( $t sec )"; done
        else
          echo "# Solve phase is performed simultaneously for ${FAKE_NIV:-480} right-hand sides( $t sec )"
        fi
        echo "# Calculate derivatives of EM field.( $t sec )"
      fi
      echo "# Start forward calculation. Frequency : ${FR[i]} [Hz], Polarization : Ey-polarization"
      t=$(( t + 5 )); echo "# Calculate response functions. ( $t sec )"
    done
    echo "# Release memory of coefficient matrix and sparse solver. ( $t sec )"; } > "femtic_$r.log"
  { echo "MT,"; echo "     StaID,        Freq[Hz],     Re(Zxx)_Cal,     Im(Zxx)_Cal,     Re(Zxy)_Cal,     Im(Zxy)_Cal,     Re(Zyx)_Cal,     Im(Zyx)_Cal,     Re(Zyy)_Cal,     Im(Zyy)_Cal,"
    for ((i = s; i < s + n; i++)); do
      awk -v f="${FR[i]}" -v rho="$RHO" -v nst="$NST" -v pert="${FAKE_PERTURB:-}" 'BEGIN {
        pi = atan2(0, -1); a = sqrt(2 * pi * f * 4e-7 * pi * rho) / sqrt(2); split(pert, p, " ")
        for (k = 1; k <= nst; k++) { re = a; if (p[1] + 0 == k && (p[2] - f) * (p[2] - f) < 1e-12 * f * f) re = a * p[3]
          printf "%10d, %15.6e, %15.6e, %15.6e, %15.6e, %15.6e, %15.6e, %15.6e, %15.6e, %15.6e,\n", k, f, 0, 0, re, -a, -a, a, 0, 0 } }'
    done; } > "result_${r}_iter$A.csv"
done
printf '%10d%10d%15e%15e%15e%15e%15e%15e\n' "$A" 0 3 0.5 1 1000 12.5 1 >> femtic.cnv
for ((it = A + 1; it <= B; it++)); do cp "resistivity_block_iter$A.dat" "resistivity_block_iter$it.dat"; done
[ "${FAKE_RC:-0}" = 0 ] || exit "$FAKE_RC"
echo "# Reach maximum iteration number." >> femtic_0.log
exit 0
EOF
chmod +x "$BIN"/*

# ---------------------------------------------------------------- a Vulcan-v3-sized inversion directory
# mesh.dat: the header counts of v3 (502,982 nodes, 3,068,130 elements; element lines omitted, nothing reads them);
# resistivity_block_iter0.dat: 68,655 blocks (air + 68,654 free at 20 ohm-m) over 10 elements;
# observe.dat: 120 MT stations x 21 bands (100 Hz .. 1/797 s) plus the 120 dummy VTF stations of OWNER_ELEMENT -1.
P=$WORK/proto; mkdir -p "$P"
awk 'BEGIN { print "TETRA"; print "    502982"; for (i = 0; i < 502982; i++) printf "%10d 0 0 0\n", i; print "   3068130" }' > "$P/mesh.dat"
awk 'BEGIN { printf "%10d%10d\n", 10, 68655; for (i = 0; i < 10; i++) printf "%10d%10d\n", i, i
             printf "%10d   %.6e   %.6e   %.6e   %.6e%10d\n", 0, 1e9, 1e-20, 1e20, 1, 1
             for (k = 1; k < 68655; k++) printf "%10d   %.6e   %.6e   %.6e   %.6e%10d\n", k, 20, 1e-20, 1e20, 1, 0 }' > "$P/resistivity_block_iter0.dat"
awk 'BEGIN { print "MT    120"
             for (s = 1; s <= 120; s++) { printf "%d  %d  0  %.3f  %.3f\n", s, 1000 + s, s * 0.1, -s * 0.1; print 21
               for (k = 0; k < 21; k++) { f = 100 * 10 ^ (-k * log(100 * 797) / log(10) / 20)
                 printf "%.6e 0 0 1e-2 -1e-2 -1e-2 1e-2 0 0 1e-3 1e-3 1e-3 1e-3 1e-3 1e-3 1e-3 1e-3\n", f } }
             print "VTF    120"; for (s = 1; s <= 120; s++) { printf "%d  %d  1  %.3f  %.3f\n", 1000 + s, 1000 + s, s * 0.1, -s * 0.1; print 0 }
             print "END" }' > "$P/observe.dat"
printf 'NUM_THREADS\n8\nMESH_TYPE\n1\nDISTORTION\n0\nINV_METHOD\n1\nITERATION\n0 1\nOWNER_ELEMENT\n-1\nEND\n' > "$P/control.dat"
{ echo "femtic_station_id,h_station_id,site_id,edi_file"; for s in $(seq 1 120); do echo "$s,$((1000 + s)),S$s,S$s.edi"; done; } > "$P/station_map.csv"
newinv() { rm -rf "$WORK/inv_$1"; mkdir -p "$WORK/inv_$1"; cp "$P"/* "$WORK/inv_$1/"; echo "$WORK/inv_$1"; }
JOBN=100
run06() {   # run06 DIR RANKS_PER_NODE CPUS_PER_TASK [ENV=VAL ...] -> RC, JOB, OUT
  local d=$1 n=$2 c=$3; shift 3; JOBN=$((JOBN + 1)); JOB=$JOBN; OUT=$d/slurm-06-$JOB.out
  ( cd "$d" && env "PATH=$BIN:$PATH" SLURM_JOB_ID=$JOB SLURM_JOB_NAME=vulcan_fwd0 SLURM_JOB_PARTITION=icelake \
      SLURM_SUBMIT_DIR="$d" SLURM_JOB_NUM_NODES=1 SLURM_NTASKS=$n SLURM_NTASKS_PER_NODE=$n SLURM_CPUS_PER_TASK=$c \
      SLURM_MEM_PER_NODE=254952 BIN="$BIN" PLAN="$PLAN" PYTHON="${PYTHON:-python3}" WATCH_S=1 "$@" \
      timeout 300 bash "$PLAN/06_forward_only.slurm" > "$OUT" 2>&1 ); RC=$?
}
run04() {   # run04 DIR RANKS_PER_NODE CPUS_PER_TASK [ENV=VAL ...] -> RC, JOB, OUT
  local d=$1 n=$2 c=$3; shift 3; JOBN=$((JOBN + 1)); JOB=$JOBN; OUT=$d/slurm-04-$JOB.out; mkdir -p "$WORK/tmp_$JOB"
  ( cd "$d" && env "PATH=$BIN:$PATH" SLURM_JOB_ID=$JOB SLURM_JOB_NAME=vulcan_inv01 SLURM_JOB_PARTITION=icelake \
      SLURM_SUBMIT_DIR="$d" SLURM_JOB_NUM_NODES=1 SLURM_JOB_NODELIST=n1 SLURM_NTASKS=$n SLURM_NTASKS_PER_NODE=$n \
      SLURM_CPUS_PER_TASK=$c SLURM_MEM_PER_NODE=254952 TMPDIR="$WORK/tmp_$JOB" BIN="$BIN" KIT="$PLAN" SCRATCH_SHARED="$WORK/shared" \
      WATCH_S=1 "$@" timeout 300 bash "$PLAN/04_inversion.slurm" > "$OUT" 2>&1 ); RC=$?
}
calls() { [ -f "$1/fake_calls.txt" ] && wc -l < "$1/fake_calls.txt" | tr -d ' ' || echo 0; }

# ================================================================ (a) C1: PARDISO memory parser
# Expected values are KB / 1024^2 worked by hand: 216125 -> 0.206; 1.23456e+06 -> 1.177; 2.5e+07 -> 23.842;
# 2.74856e+07 (v3's real line) -> 26.212; 9.87654e+07 -> 94.190; 1.5e+08 -> 143.051 GiB.
source "$BIN/femtic_lib.sh"
crit a1 "femtic_pardiso_max_gb misreads a PARDISO line FEMTIC printed as a plain integer or in %g e-notation (one mock log per value)"
for pair in 216125:0.2 1.23456e+06:1.2 2.5e+07:23.8 2.74856e+07:26.2 9.87654e+07:94.2 1.5e+08:143.1; do
  v=${pair%%:*}; want=${pair#*:}; d=$WORK/pardiso_$v; mkdir -p "$d"
  echo "# Total memory consumed by in-core forward solver for internal float point arrays    : $v [KByte]" > "$d/femtic_0.log"
  eq "a1 $v KB -> GiB" "$(femtic_pardiso_max_gb "$d" 2>&1)" "$want"
done
crit a2 "the largest value over several ranks is not the numerically largest (rank logs 9.87654e+07, 1.5e+08, 1.23456e+06 -> 143.1 GiB)"
d=$WORK/pardiso_ranks; mkdir -p "$d"; r=0
for v in 9.87654e+07 1.5e+08 1.23456e+06; do
  echo "# Total memory consumed by in-core forward solver for internal float point arrays    : $v [KByte]" > "$d/femtic_$r.log"; r=$((r + 1))
done
eq "a2 max over 3 ranks" "$(femtic_pardiso_max_gb "$d" 2>&1)" 143.1
crit a3 "femtic_pardiso_kb does not return the exact KB (1.5e+08 -> 150000000) or femtic_pardiso_log_gb the per-rank GiB (1.23456e+06 -> 1.18)"
eq "a3 kb 1.5e+08" "$(femtic_pardiso_kb "$WORK/pardiso_1.5e+08/femtic_0.log" 2>&1)" 150000000
eq "a3 per-rank 1.23456e+06" "$(femtic_pardiso_log_gb "$WORK/pardiso_1.23456e+06/femtic_0.log" 2>&1)" 1.18

# ================================================================ (b) C2: sensitivity-step memory, two arrays
# Hand calculation (bytes): 2 x 3568555 x 480 x 16 = 54,813,004,800; 2 x 480 x 68655 x 16 = 1,054,540,800;
# 960 x 68655 x 8 = 527,270,400; total 56,394,816,000 B = 53,782.3 MiB -> 53783 (rounded up), 56.39 GB.
# The one-array model of version 2 gave 28,988,313,600 B = 28.99 GB.
crit b1 "femtic_sens_mem_mb N_eq=3568555 N_iv=480 M=68655 Nd_f=960 is not 53783 MiB (two N_eq x N_iv x 16 B arrays)"
eq "b1 two-array MiB" "$(femtic_sens_mem_mb 3568555 480 68655 960 2>&1)" 53783
crit b2 "N_iv=840 (the pessimistic OWNER_ELEMENT -1 case) is not 93742 MiB (hand: 98,295,440,640 B incl. M=68654)"
eq "b2 N_iv 840" "$(femtic_sens_mem_mb 3568555 840 68654 960 2>&1)" 93742

# ================================================================ (c) C2: the layout rule
crit c1 "the layout rule accepts 8 x 9 on v3 (FWD 32869 + 53783 MiB per rank, --mem 254952) or refuses 2 x 36"
femtic_layout_check 8 32869 53783 254952 > "$WORK/c1_8.txt" 2>&1; eq "c1 8 ranks v3 exit" "$?" 1
has "c1 8 ranks v3" "$WORK/c1_8.txt" "REFUSED"
femtic_layout_check 2 32869 53783 254952 > "$WORK/c1_2.txt" 2>&1; eq "c1 2 ranks v3 exit" "$?" 0
has "c1 2 ranks v3" "$WORK/c1_2.txt" ": OK"
crit c2 "v2 (FWD 1.25 x 22,902 = 28629, NONP 43109 MiB) is not accepted at 3 ranks and refused at 4; or v3 with N_iv 840 (93742) fits 2 ranks"
femtic_layout_check 3 28629 43109 254952 > /dev/null 2>&1; eq "c2 v2 3 ranks" "$?" 0
femtic_layout_check 4 28629 43109 254952 > /dev/null 2>&1; eq "c2 v2 4 ranks" "$?" 1
femtic_layout_check 2 33552 93742 254952 > /dev/null 2>&1; eq "c2 v3 N_iv 840 2 ranks" "$?" 1
femtic_layout_check 1 33552 93742 254952 > /dev/null 2>&1; eq "c2 v3 N_iv 840 1 rank" "$?" 0

# ---------------------------------------------------------------- end-to-end through 06 and 04
crit c3 "06 at 8 x 9 on the v3-sized directory launches femtic or exits 0 (it must refuse before launch, exit 1)"
D=$(newinv c3); run06 "$D" 8 9
eq "c3 06 8x9 exit" "$RC" 1; has "c3 06 8x9" "$OUT" "layout REFUSED"; eq "c3 06 8x9 femtic calls" "$(calls "$D/fwd0_$JOB")" 0
crit c4 "06 at 8 x 9 with LAYOUT_CHECK=forward is accepted (before any log FWD_MB = 11,000 MiB x 3.571112 = 39,283; 8 x 39,283 > 95 % of 254,952)"
run06 "$D" 8 9 LAYOUT_CHECK=forward
eq "c4 06 8x9 forward exit" "$RC" 1; eq "c4 femtic calls" "$(calls "$D/fwd0_$JOB")" 0
has "c4 forward-only rule" "$OUT" "8 ranks/node x (39283 forward + 0 sensitivity-step MiB)"
crit c5 "06 at 2 x 36 is refused, T6 does not PASS, the report lacks the two-array sum (56.39 GB for N_eq 3568555, M 68654) or its per-rank PARDISO column misreads rank 1's 1.23456e+06 KB"
run06 "$D" 2 36 FAKE_PARDISO="2.74856e+07 1.23456e+06"
R6=$D/logs/fwd0_report_$JOB.txt
eq "c5 06 2x36 exit" "$RC" 0; eq "c5 femtic calls" "$(calls "$D/fwd0_$JOB")" 1
has "c5 T6" "$R6" "T6 (forward-only): PASS"
has "c5 two-array sum" "$R6" "sum 56.39 GB = 53783 MiB"
has "c5 N_eq from mesh.dat before any log" "$D/slurm-06-$JOB.out" "N_eq 3571112 (mesh.dat nodes + elements"
eq "c5 rank-1 PARDISO column" "$(awk '$1 == "1" && NF >= 5 {print $5; exit}' "$R6")" 1.18
eq "c5 rank-0 PARDISO column" "$(awk '$1 == "0" && NF >= 5 {print $5; exit}' "$R6")" 26.21
crit c6 "06 does not leave logs/fwd_rank_mb = 33552 (1.25 x 26,841.4 MiB, the larger PARDISO line; the fake's RSS is tiny)"
eq "c6 fwd_rank_mb" "$(awk '{print $1}' "$D/logs/fwd_rank_mb" 2>/dev/null)" 33552
crit c7 "04 at 8 x 9 launches femtic (it must refuse: 8 x (33552 + 53783) MiB > 242,204) or uses anything but 06's measurement and the logged N_eq"
run04 "$D" 8 9
eq "c7 04 8x9 exit" "$RC" 1; has "c7 04 8x9" "$OUT" "layout REFUSED"; eq "c7 femtic calls" "$(calls "$D")" 0
has "c7 FWD_MB from 06" "$OUT" "FWD_MB = 33552 MiB (measured_by_06_job"
has "c7 NONPARDISO from the logged N_eq" "$OUT" "NONPARDISO_MB = 53783 MiB"
crit c8 "04 at 2 x 36 is refused, does not launch femtic, or its sizing report does not show the logged N_iv 480"
run04 "$D" 2 36
eq "c8 04 2x36 exit" "$RC" 0; eq "c8 femtic calls" "$(calls "$D")" 1
has "c8 layout OK" "$OUT" "2 ranks/node x (33552 forward + 53783 sensitivity-step MiB) + 0 extra = 174670 MiB <= 95 % of 254952 MiB (--mem) = 242204 MiB: OK"
has "c8 N_iv measured" "$OUT" "measured 480; the layout rule used 480"
crit c9 "04 does not add the sensitivity files when \$TMPDIR is tmpfs (2 x Nd 20160 x M 68654 x 8 B = 21120 MiB, data space) and refuse 3 ranks"
D9=$(newinv c9); mkdir -p "$D9/logs"; cp "$D/logs/fwd_rank_mb" "$D9/logs/"
run04 "$D9" 2 36 MOCK_TMPFS=1
eq "c9 04 2x36 tmpfs exit" "$RC" 0; has "c9 tmpfs extra" "$OUT" "+ 21120 extra"
run04 "$D9" 3 24 MOCK_TMPFS=1
eq "c9 04 3x24 tmpfs exit" "$RC" 1; has "c9 refused" "$OUT" "layout REFUSED"

crit c10 "06 at 8 x 9 is refused on a small mesh (10,000 nodes + 50,000 elements: FWD_MB = 660 MiB before any log), i.e. the rule is not scaled to the mesh"
DS=$(newinv c10); awk 'BEGIN { print "TETRA"; print "     10000"; for (i = 0; i < 10000; i++) printf "%10d 0 0 0\n", i; print "     50000" }' > "$DS/mesh.dat"
run06 "$DS" 8 9
eq "c10 06 8x9 small mesh exit" "$RC" 0; has "c10 FWD_MB from N_eq" "$OUT" "FWD_MB = 660 MiB (no_log_yet:_11000_MiB_per_1e6_equations_x_N_eq)"

# ================================================================ (d) C1: version gate
# A version-2 femtic_lib.sh: STALE_LIB (the copy installed on Phoenix from fa58604), else this kit's own with the
# version line set to 2.
B2=$WORK/bin_v2; mkdir -p "$B2"; cp "$BIN"/* "$B2/"
if [ -n "${STALE_LIB:-}" ]; then cp "$STALE_LIB" "$B2/femtic_lib.sh"; else sed 's/^FEMTIC_LIB_VERSION=.*/FEMTIC_LIB_VERSION=2/' "$BIN/femtic_lib.sh" > "$B2/femtic_lib.sh"; fi
printf 'export PATH=%s:$PATH FEMTIC_TOOLCHAIN=foss FEMTIC_BIN=%s\n. %s/femtic_lib.sh\n' "$B2" "$B2" "$B2" > "$B2/femtic_env.sh"
printf '#!/bin/bash\necho "$PWD" >> %s/b2_femtic_calls.txt\nexit 0\n' "$WORK" > "$B2/femtic"; chmod +x "$B2"/*
echo; echo "version-2 library for (d): $B2/femtic_lib.sh ($(wc -c < "$B2/femtic_lib.sh" | tr -d ' ') B, $(grep -m1 '^FEMTIC_LIB_VERSION=' "$B2/femtic_lib.sh"))"
GATE_MSG="needs FEMTIC_LIB_VERSION >= "   # 01 SMOKE_ONLY, 03, 04, 05 and 06 all need >= 5
# The scripts read femtic_lib.sh from KIT (version 5 on), so the stale library is passed as KIT=$B2 (B2 holds
# femtic_lib.sh), and BIN=$B2 keeps the stale copy in BIN too, as Phoenix's femtic/bin still has one.
crit d1 "04, 06, 03 or 05 runs with a version-2 femtic_lib.sh (must exit 1 with '$GATE_MSG' and start nothing)"
DD=$(newinv d)
for s in 04_inversion.slurm 06_forward_only.slurm 03_mesh.slurm; do
  ( cd "$DD" && env "PATH=$B2:$PATH" SLURM_JOB_ID=900 SLURM_SUBMIT_DIR="$DD" SLURM_NTASKS=2 SLURM_CPUS_PER_TASK=36 SLURM_MEM_PER_NODE=254952 \
      BIN="$B2" KIT="$B2" TMPDIR="$WORK" MESHDIR="$DD" timeout 300 bash "$PLAN/$s" > "$WORK/d1_$s.out" 2>&1 ); rc=$?
  eq "d1 $s exit" "$rc" 1; has "d1 $s" "$WORK/d1_$s.out" "$GATE_MSG"
done
( env "PATH=$B2:$PATH" BIN="$B2" KIT="$B2" timeout 300 bash "$PLAN/05_chain.sh" "$DD" 1 1 > "$WORK/d1_05.out" 2>&1 ); rc=$?
eq "d1 05_chain.sh exit" "$rc" 1; has "d1 05_chain.sh" "$WORK/d1_05.out" "$GATE_MSG"
eq "d1 femtic launched by a gated script" "$(cat "$WORK/b2_femtic_calls.txt" 2>/dev/null | wc -l | tr -d ' ')" 0
crit d2 "01 SMOKE_ONLY=1 runs its tests with a version-2 femtic_lib.sh installed (must stop with '$GATE_MSG')"
S=$WORK/src; mkdir -p "$S/femtic/examples/INV_MT_01/Tetra"; for f in control.dat mesh.dat observe.dat resistivity_block_iter0.dat; do : > "$S/femtic/examples/INV_MT_01/Tetra/$f"; done
( env "PATH=$B2:$PATH" SRC="$S" BIN="$B2" KIT="$B2" SMOKE_ONLY=1 TOOLCHAIN=foss timeout 300 bash "$PLAN/01_build_femtic.sh" > "$WORK/d2_01.out" 2>&1 ); rc=$?
sleep 1; cat "$S"/smoke_foss_*.log >> "$WORK/d2_01.out" 2>/dev/null   # 01 tees into its own log; read both
eq "d2 01 SMOKE_ONLY exit" "$rc" 1; has "d2 01 SMOKE_ONLY" "$WORK/d2_01.out" "$GATE_MSG"
crit d3 "the kit's own femtic_lib.sh is not version 5 (the gates of 04/05/06 would then reject the current kit)"
eq "d3 version" "$(sed -n 's/^FEMTIC_LIB_VERSION=//p' "$PLAN/femtic_lib.sh")" 5
crit d4 "04, 06 or 05 runs with a version-4 femtic_lib.sh in its kit (the 2026-09-28 kit, before the kit layout of version 5; one below the gate): must exit 1 with 'needs FEMTIC_LIB_VERSION >= 5' and start nothing"
B3=$WORK/bin_v3; mkdir -p "$B3"; cp "$BIN"/* "$B3/"
sed 's/^FEMTIC_LIB_VERSION=.*/FEMTIC_LIB_VERSION=4/' "$BIN/femtic_lib.sh" > "$B3/femtic_lib.sh"
printf 'export PATH=%s:$PATH FEMTIC_TOOLCHAIN=foss FEMTIC_BIN=%s\n. %s/femtic_lib.sh\n' "$B3" "$B3" "$B3" > "$B3/femtic_env.sh"
printf '#!/bin/bash\necho "$PWD" >> %s/b3_femtic_calls.txt\nexit 0\n' "$WORK" > "$B3/femtic"; chmod +x "$B3"/*
for s in 04_inversion.slurm 06_forward_only.slurm; do
  ( cd "$DD" && env "PATH=$B3:$PATH" SLURM_JOB_ID=901 SLURM_SUBMIT_DIR="$DD" SLURM_NTASKS=2 SLURM_CPUS_PER_TASK=36 SLURM_MEM_PER_NODE=254952 \
      BIN="$B3" KIT="$B3" TMPDIR="$WORK" timeout 300 bash "$PLAN/$s" > "$WORK/d4_$s.out" 2>&1 ); rc=$?
  eq "d4 $s exit" "$rc" 1; has "d4 $s" "$WORK/d4_$s.out" "needs FEMTIC_LIB_VERSION >= 5"
done
( env "PATH=$B3:$PATH" BIN="$B3" KIT="$B3" SBATCH_EXTRA='--ntasks-per-node=2 --cpus-per-task=36' timeout 300 bash "$PLAN/05_chain.sh" "$DD" 1 1 > "$WORK/d4_05.out" 2>&1 ); rc=$?
eq "d4 05_chain.sh exit" "$rc" 1; has "d4 05_chain.sh" "$WORK/d4_05.out" "needs FEMTIC_LIB_VERSION >= 5"
eq "d4 femtic launched by a gated script" "$(cat "$WORK/b3_femtic_calls.txt" 2>/dev/null | wc -l | tr -d ' ')" 0

# ================================================================ (e) C2: the half-space gate in 06
crit e1 "06 START_RHO=100 does not run a uniform 100 ohm-m model (every non-air block 1.000000e+02, air 1e9 kept), touches the inversion directory's model, or does not report GATE PASS with exit 0"
DE=$(newinv e); SUM0=$(cksum < "$DE/resistivity_block_iter0.dat")
run06 "$DE" 2 36 START_RHO=100
RE=$DE/logs/fwd0_report_$JOB.txt; UF=$DE/fwd0_$JOB/resistivity_block_iter0.dat
eq "e1 exit" "$RC" 0
eq "e1 blocks at 100 / air kept / others" "$(awk 'NR==1{ne=$1; next} NR>ne+1 {if ($2 == "1.000000e+02") a++; else if ($2+0 == 1e9 && $6 == 1) b++; else c++} END {print a+0 "/" b+0 "/" c+0}' "$UF")" "68654/1/0"
eq "e1 inversion model untouched" "$(cksum < "$DE/resistivity_block_iter0.dat")" "$SUM0"
has "e1 GATE PASS" "$RE" "GATE (half-space, START_RHO=100): PASS"
has "e1 evaluator saw all 2520 pairs" "$RE" "COMPLETENESS: 2520 expected (site, band) pairs, 0 missing"
crit e2 "06 START_RHO=100 with one Re(Zxy) 10 % high (site 7, 100 Hz) does not exit 4 with GATE FAIL naming site 7 (S7)"
run06 "$DE" 2 36 START_RHO=100 FAKE_PERTURB="7 100 1.1"
RE=$DE/logs/fwd0_report_$JOB.txt
eq "e2 exit" "$RC" 4; has "e2 GATE FAIL" "$RE" "GATE (half-space, START_RHO=100): FAIL"
has "e2 worst rho_a" "$RE" "LIMIT rho_a       5 %  : FAIL  worst 10.500 % at site 7 (S7), 100 Hz"
has "e2 T6 still PASS" "$RE" "T6 (forward-only): PASS"
crit e3 "06 START_RHO=abc is accepted (must exit 1 before launching)"
run06 "$DE" 2 36 START_RHO=abc
eq "e3 exit" "$RC" 1; has "e3 message" "$OUT" "START_RHO=abc"

# ================================================================ (f) kit follow-ups (2026-09-28, kit verdict "missed")
# f1-f2  femtic_niv_measured across FEMTIC's DIV_NUM_RHS_FWD warning (Forward3D.cpp:183-186)
crit f1 "femtic_niv_measured does not return 6 for a mock log with the two 'Warning : Division number ...' lines between the interpolator header and six '1 right-hand sides' lines (DIV_NUM_RHS_FWD 8 > N_iv 6), or adds a later solve of 99 right-hand sides that follows '# Calculate derivatives of EM field.'"
d=$WORK/niv_warn; mkdir -p "$d"
{ echo "# Calulate right-hand sides vectors consisting of interpolator vectors.( 2 sec )"
  echo "# Solve phase of matrix solver for right-hand sides consisting of interpolator vectors.( 2 sec )"
  echo "Warning : Division number of right-hand sides ( 8 ) is greater than the total number of right-hand sides ( 6 )."
  echo "          Thus, the division number is set the total number of right-hand sides."
  for k in 1 2 3 4 5 6; do echo "# Solve phase is performed simultaneously for 1 right-hand sides( 2 sec )"; done
  echo "# Calculate derivatives of EM field.( 2 sec )"
  echo "# Solve phase is performed simultaneously for 99 right-hand sides( 3 sec )"; } > "$d/femtic_0.log"
eq "f1 N_iv behind the warning" "$(femtic_niv_measured "$d/femtic_0.log" 2>&1)" 6
{ echo "# Solve phase of matrix solver for right-hand sides consisting of interpolator vectors.( 2 sec )"
  echo "# Solve phase is performed simultaneously for 240 right-hand sides( 2 sec )"
  echo "# Solve phase is performed simultaneously for 240 right-hand sides( 3 sec )"
  echo "# Calculate derivatives of EM field.( 3 sec )"; } > "$d/femtic_1.log"
eq "f1 N_iv of a 2-call split, no warning" "$(femtic_niv_measured "$d/femtic_1.log" 2>&1)" 480
REAL=${REAL_INV_LOG:-//wsl.localhost/Ubuntu/home/tara/femtic_wsl/run_INV_MT_01_Tetra/femtic_0.log}
if [ -f "$REAL" ]; then eq "f1 real FEMTIC log (INV_MT_01, 36 stations)" "$(femtic_niv_measured "$REAL" 2>&1)" 144
else echo "  (f1 real-log case skipped: $REAL not readable here)"; fi
crit f2 "04 on a run whose logs carry the DIV_NUM_RHS_FWD warning does not report 'measured 480' (it printed '?' with FEMTIC_LIB_VERSION 3)"
DF=$(newinv f2); mkdir -p "$DF/logs"; cp "$D/logs/fwd_rank_mb" "$DF/logs/"
run04 "$DF" 2 36 FAKE_DIVWARN=1
eq "f2 04 exit" "$RC" 0; has "f2 warning lines present in the fake log" "$DF/femtic_0.log" "Warning : Division number of right-hand sides"
has "f2 N_iv measured" "$OUT" "measured 480; the layout rule used 480"

# f3  06's job_outcomes.tsv exit column = the exit code
rowexit() { awk -F'\t' -v j="$2" '$1 == j && $6 !~ /^walltime/ {e = $9} END {print e}' "$1/job_outcomes.tsv"; }
crit f3 "the exit column of 06's job_outcomes.tsv row differs from 06's exit code: gate FAIL (exit 4), gate PASS (0) or T6 FAIL (femtic exit 3, no end line: 1)"
DX=$(newinv f3)
run06 "$DX" 2 36 START_RHO=100 FAKE_PERTURB="7 100 1.1"; eq "f3 gate FAIL: exit" "$RC" 4; eq "f3 gate FAIL: row exit" "$(rowexit "$DX" "$JOB")" 4
run06 "$DX" 2 36 START_RHO=100; eq "f3 gate PASS: exit" "$RC" 0; eq "f3 gate PASS: row exit" "$(rowexit "$DX" "$JOB")" 0
run06 "$DX" 2 36 FAKE_RC=3; eq "f3 T6 FAIL: exit" "$RC" 1; eq "f3 T6 FAIL: row exit" "$(rowexit "$DX" "$JOB")" 1

# f4  site names in the gate report; station_map.csv in every mesh-copy list
crit f4 "without station_map.csv 06's gate report does not say so (NOTE) or names the site other than by bare id; with it, e2 above names 'site 7 (S7)'; README step 7 or the 01 next-step hint omits station_map.csv"
DN=$(newinv f4); rm -f "$DN/station_map.csv"
run06 "$DN" 2 36 START_RHO=100 FAKE_PERTURB="7 100 1.1"
eq "f4 exit" "$RC" 4; RN=$DN/logs/fwd0_report_$JOB.txt
has "f4 note" "$RN" "NOTE: no station_map.csv in $DN"
has "f4 bare id" "$RN" "worst 10.500 % at site 7, 100 Hz"
eq "f4 README step 7 lists station_map.csv" "$(awk '/^7\. \*\*Mesh: copy the gated mesh/ {s = 1} /^8\. / {s = 0} s' "$PLAN/README_phoenix.md" | grep -c 'station_map.csv' | awk '{print ($1 > 0)}')" 1
eq "f4 01 next-step hint lists station_map.csv" "$(grep -c 'next: copy the gated WSL mesh.*station_map.csv' "$PLAN/01_build_femtic.sh")" 1

# f5  06 walltime sized for its header layout; SU text follows the walltime
# T_f = the slowest single frequency of the WSL v3 gate runs (femtic_fwd_times on their logs), else 755 s from them.
ACC_ROOT=${ACC_ROOT:-/d/BEN/FEMTIC_2026/mesh}
TF=$(for L in "$ACC_ROOT"/vulcan_v3/halfspace/acc_*/b*/femtic_0.log; do [ -f "$L" ] && femtic_fwd_times "$L"; done | awk '$2 > m {m = $2} END {print m + 0}')
TF_SRC="femtic_fwd_times over $ACC_ROOT/vulcan_v3/halfspace/acc_*/b*/femtic_0.log"; [ "$TF" -gt 0 ] || { TF=755; TF_SRC="755 s (2026-09-25 WSL v3 logs, not readable here)"; }
H06=$(sed -n 's/^#SBATCH --time=//p' "$PLAN/06_forward_only.slurm")
R06=$(sed -n 's/^#SBATCH --ntasks-per-node=//p' "$PLAN/06_forward_only.slurm")
TS=$(echo "$H06" | awk -F: 'NF == 3 {print $1 * 3600 + $2 * 60 + $3}')
NEED=$(( (21 + R06 - 1) / R06 * TF + 360 ))
crit f5 "06's header --time ($H06 = ${TS}s) is shorter than ceil(21 / $R06 ranks) x T_f + 6 min = $NEED s (T_f = $TF s: $TF_SRC), or the SU given for the header walltime (06 header, README step 8 and section 5) is not 72 x hours x 1.2"
eq "f5 header walltime covers the header layout" "$([ "${TS:-0}" -ge "$NEED" ] && echo yes || echo "no: $TS < $NEED")" yes
HRS=$(awk -v t="$TS" 'BEGIN {printf "%g", t / 3600}'); SU=$(awk -v t="$TS" 'BEGIN {printf "%.1f", 72 * t / 3600 * 1.2}')
has "f5 06 header SU" "$PLAN/06_forward_only.slurm" "Header: 1 x 72 x $HRS h x 1.2 = $SU SU at most"
has "f5 README section 5 row" "$PLAN/README_phoenix.md" "icelake, 1 node, $HRS h | 72 | $HRS | 1.2 | $SU |"
has "f5 README step 8" "$PLAN/README_phoenix.md" "$SU SU for the header"

# f6  05 needs a layout: explicit (both options) or the LAYOUT file of a passing 06
N05=0
run05() {   # run05 DIR [ENV=VAL ...] -> RC, OUT, SB (this run's sbatch calls), NSB
  local d=$1; shift; N05=$((N05 + 1)); OUT=$WORK/05_$N05.out; SB=$WORK/sb_$N05.txt; : > "$WORK/sbatch_calls.txt"
  ( env "PATH=$BIN:$PATH" BIN="$BIN" MOCK_SBATCH_OK=1 "$@" timeout 300 bash "$PLAN/05_chain.sh" "$d" 2 5 > "$OUT" 2>&1 ); RC=$?
  cp "$WORK/sbatch_calls.txt" "$SB"; NSB=$(grep -c . "$SB")
}
crit f6a "05 submits anything, or exits 0, with neither a LAYOUT file nor a layout in SBATCH_EXTRA (the 04 header's 2 x 36 would run v2 at 2 ranks)"
DL=$(newinv f6); run05 "$DL"
eq "f6a exit" "$RC" 1; has "f6a message" "$OUT" "ERROR: no layout for the chain"; eq "f6a sbatch calls" "$NSB" 0
crit f6b "05 accepts half a layout (only --ntasks-per-node=3)"
run05 "$DL" SBATCH_EXTRA='--ntasks-per-node=3'
eq "f6b exit" "$RC" 1; has "f6b message" "$OUT" "sets only one of --ntasks-per-node and --cpus-per-task"; eq "f6b sbatch calls" "$NSB" 0
crit f6c "05 with an explicit layout (--ntasks-per-node=3 --cpus-per-task=24, or '--ntasks-per-node 3 -c 24') does not submit 2 chained jobs carrying it"
run05 "$DL" SBATCH_EXTRA='--ntasks-per-node=3 --cpus-per-task=24'
eq "f6c exit" "$RC" 0; eq "f6c sbatch calls" "$NSB" 2
eq "f6c both carry the layout" "$(grep -c -- '--ntasks-per-node=3 --cpus-per-task=24' "$SB")" 2
has "f6c second waits for the first" "$SB" "--dependency=afterok:5001"
run05 "$DL" SBATCH_EXTRA='--ntasks-per-node 3 -c 24'; eq "f6c separate-word form exit" "$RC" 0; eq "f6c separate-word form calls" "$NSB" 2
crit f6d "06 T6 PASS (2 x 36, LAYOUT_CHECK=full) does not write LAYOUT with its sbatch layout, or 05 then does not submit with it"
run06 "$DL" 2 36; eq "f6d 06 exit" "$RC" 0
has "f6d LAYOUT sbatch line" "$DL/LAYOUT" "sbatch=-p icelake -N 1 --ntasks-per-node=2 --cpus-per-task=36 --mem=254952M"
has "f6d LAYOUT names the 06 job" "$DL/LAYOUT" "# written by 06_forward_only.slurm job $JOB on"
run05 "$DL"
eq "f6d 05 exit" "$RC" 0; eq "f6d sbatch calls with the 06 layout" "$(grep -c -- '-p icelake -N 1 --ntasks-per-node=2 --cpus-per-task=36 --mem=254952M' "$SB")" 2
has "f6d 05 names the source" "$OUT" "from $DL/LAYOUT (06_forward_only.slurm job $JOB on"
crit f6e "an explicit SBATCH_EXTRA layout does not take precedence over LAYOUT"
run05 "$DL" SBATCH_EXTRA='--ntasks-per-node=3 --cpus-per-task=24'
eq "f6e exit" "$RC" 0; eq "f6e calls with the explicit layout only" "$(grep -- '--ntasks-per-node=3 --cpus-per-task=24' "$SB" | grep -vc -- '--ntasks-per-node=2')" 2
crit f6h "05 accepts half a layout (only --ntasks-per-node=3) when a LAYOUT file exists (it would override the tested 2 x 36 ranks and keep 36 cpus per task)"
run05 "$DL" SBATCH_EXTRA='--ntasks-per-node=3'
eq "f6h exit" "$RC" 1; eq "f6h sbatch calls" "$NSB" 0
crit f6f "06 with THREADS=18 on a 2 x 36 allocation does not put RANKS=2,THREADS=18 in LAYOUT, or 05 does not export them"
DT=$(newinv f6f); run06 "$DT" 2 36 THREADS=18; eq "f6f 06 exit" "$RC" 0
has "f6f LAYOUT export line" "$DT/LAYOUT" "export=RANKS=2,THREADS=18"
run05 "$DT"; eq "f6f exit" "$RC" 0; eq "f6f --export carries RANKS/THREADS" "$(grep -c -- ',RANKS=2,THREADS=18 ' "$SB")" 2
crit f6g "a 06 run that did not check the full rule (LAYOUT_CHECK=forward) or failed T6 (femtic exit 3) writes or changes LAYOUT"
SUM_L=$(cksum < "$DL/LAYOUT"); run06 "$DL" 2 36 LAYOUT_CHECK=forward
eq "f6g forward-only run exit" "$RC" 0; eq "f6g LAYOUT unchanged" "$(cksum < "$DL/LAYOUT")" "$SUM_L"
DG=$(newinv f6g); run06 "$DG" 2 36 FAKE_RC=3; eq "f6g T6 FAIL exit" "$RC" 1; eq "f6g no LAYOUT after T6 FAIL" "$([ -e "$DG/LAYOUT" ] && echo present || echo absent)" absent

echo; echo "SUMMARY: $npass passed, $nfail failed   (PLAN=$PLAN)"
[ "$nfail" = 0 ]
