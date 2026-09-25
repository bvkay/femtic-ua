#!/bin/bash
# libtest_v2.sh -- unit test of phoenix_plan/femtic_lib.sh (run in WSL: bash libtest_v2.sh).
# v2 (2026-09-25) versus libtest.sh (v1, kept unchanged): PLAN/EX/LOG are parameters (default: the edited
# D:\BEN\FEMTIC_2026\hpc\phoenix_plan); checks 1-15 are v1's, unchanged; checks from L16 on cover the helpers
# added for the restart-integrity, stop and 06 changes. Every expected value is derived by hand from the
# input (line counts, file formats, arithmetic), never by calling the function under test.
PLAN=${PLAN:-/mnt/d/BEN/FEMTIC_2026/hpc/phoenix_plan}
EX=${EX:-/mnt/c/Users/joint/AppData/Local/Temp/claude/D--BEN-FEMTIC-2026/4e858f54-ea4e-47a8-9815-7766aca9830d/scratchpad/femtic/examples/INV_MT_01/Tetra}
LOG=${LOG:-/mnt/d/BEN/FEMTIC_2026/validation/wsl_2026-09-25/run_logs/femtic_0.log}   # WSL INV_MT_01 run, 2 ranks, 4 freqs
[ -f "$EX/control.dat" ] && [ -f "$LOG" ] || { echo "inputs missing: EX=$EX LOG=$LOG"; exit 2; }
T=$(mktemp -d); cd $T; source <(sed 's/\r$//' $PLAN/femtic_lib.sh); fail=0; npass=0; nfail=0
chk(){ if [ "$2" = "$3" ]; then echo "PASS $1 ($2)"; npass=$((npass+1)); else echo "FAIL $1: got '$2' want '$3'"; fail=1; nfail=$((nfail+1)); fi; }
echo "sed: $(sed --version | head -1)  bash: $BASH_VERSION  awk: $(awk --version 2>&1 | head -1)"
echo "lib: $PLAN/femtic_lib.sh (FEMTIC_LIB_VERSION=$FEMTIC_LIB_VERSION)"
# ---------------------------------------------------------------- v1 checks (1-15)
cp $EX/control.dat c.dat
chk crlf_present "$(grep -c $'\r' c.dat)" "$(wc -l < c.dat)"
chk get_existing "$(femtic_ctl_get c.dat ITERATION)" "0 5"
n0=$(wc -l < c.dat)
femtic_ctl_set c.dat ITERATION "3 8"; chk set_existing "$(femtic_ctl_get c.dat ITERATION)" "3 8"
chk linecount_unchanged "$(wc -l < c.dat)" "$n0"
femtic_ctl_set c.dat NUM_THREADS 9; chk set_threads "$(femtic_ctl_get c.dat NUM_THREADS)" "9"
femtic_ctl_set c.dat SENSE_MAT_DIRECTORY /tmp/job123/sense; chk insert_absent "$(femtic_ctl_get c.dat SENSE_MAT_DIRECTORY)" "/tmp/job123/sense"
chk end_still_last "$(tail -1 c.dat)" "END"
chk no_crlf_left "$(grep -c $'\r' c.dat)" "0"
femtic_ctl_set c.dat SENSE_MAT_DIRECTORY /tmp/job456/sense; chk reset_inserted "$(femtic_ctl_get c.dat SENSE_MAT_DIRECTORY)" "/tmp/job456/sense"
chk single_occurrence "$(grep -c '^SENSE_MAT_DIRECTORY' c.dat)" "1"
chk step_length_untouched "$(sed -n '/^STEP_LENGTH/,/^END/p' c.dat | tr '\n' '|')" "STEP_LENGTH|0.5 0.1 1.0|3|0.5 1.25|SENSE_MAT_DIRECTORY|/tmp/job456/sense|END|"
touch resistivity_block_iter0.dat resistivity_block_iter9.dat resistivity_block_iter12.dat resistivity_block_iter99.dat.bak
chk last_iter "$(femtic_last_iter .)" "12"
squeue(){ echo "$MOCK"; }
MOCK=2-23:59:30; chk tl_days "$(femtic_time_left_s)" 259170
MOCK=08:09:07; chk tl_leading0 "$(femtic_time_left_s)" 29347
chk block_stats "$(femtic_block_stats $EX/resistivity_block_iter0.dat)" "34559 289 289 288 1"
unset -f squeue; rm -f resistivity_block_iter*.dat*
# ---------------------------------------------------------------- L16-L18 femtic_ctl_has (bare keyword)
yn(){ "$@" && echo yes || echo no; }
chk L16_has_absent "$(yn femtic_ctl_has c.dat HOLD_FWD_MEM)" no
sed '/^END/i HOLD_FWD_MEM' c.dat > c2.dat; chk L17_has_present "$(yn femtic_ctl_has c2.dat HOLD_FWD_MEM)" yes
printf 'ITERATION\n0 1\nEND\nHOLD_FWD_MEM\n' > c3.dat; chk L18_has_after_END_ignored "$(yn femtic_ctl_has c3.dat HOLD_FWD_MEM)" no
# ---------------------------------------------------------------- L19-L25 femtic_block_check
# example iter0: header "34559 289" (CRLF), lines 2..34560 elements, 34561..34849 blocks (34849 lines, see wc -l)
B0=$EX/resistivity_block_iter0.dat
chk L19_ok_example "$(femtic_block_check $B0)" "OK 34559 289"
chk L20_ok_vs_itself_as_ref "$(femtic_block_check $B0 $B0)" "OK 34559 289"
head -n 34700 $B0 > cut_blocks.dat         # 140 of 289 block lines survive
chk L21_cut_in_blocks "$(femtic_block_check cut_blocks.dat $B0)" "BAD 140 block lines, header says 289"
head -n 1000 $B0 > cut_elems.dat           # 999 of 34559 element lines survive
chk L22_cut_in_elements "$(femtic_block_check cut_elems.dat)" "BAD 999 element lines, header says 34559"
head -n 34848 $B0 > cut_midline.dat; printf '       288    1.000000000e+002 1.0e-06' >> cut_midline.dat
chk L23_cut_midline "$(femtic_block_check cut_midline.dat $B0)" "BAD block line 34849 has 3 field(s) (cut short?)"
{ printf '     34559       290\r\n'; tail -n +2 $B0; } > hdr.dat
chk L24_header_vs_ref "$(femtic_block_check hdr.dat $B0)" "BAD header 34559 290 differs from the reference 34559 289"
sed '$ s/1\.000000000e+002/nan/' $B0 > nan.dat
chk L25_nan_value "$(femtic_block_check nan.dat $B0 | cut -c1-37)" 'BAD block line 34849 field 2 "nan" is'
chk L25b_rc_nonzero "$(femtic_block_check nan.dat >/dev/null; echo $?)" 1
# ---------------------------------------------------------------- L26-L29 femtic_dist_check
printf '%10d\n%10d%15f%15f%15f%15f%10d\n%10d%15f%15f%15f%15f%10d\n' 2 1 1 0 0 1 0 2 1 0 0 1 0 > d0.dat
chk L26_dist_ok "$(femtic_dist_check d0.dat)" "OK 2"
head -n 2 d0.dat > d1.dat; chk L27_dist_cut "$(femtic_dist_check d1.dat d0.dat)" "BAD 1 station lines, header says 2"
printf '%10d\n%10d%15f%15f%10d\n%10d%15f%15f%10d\n' 2 1 1 1 0 2 1 1 0 > dg.dat; chk L28_dist_gains_only "$(femtic_dist_check dg.dat d0.dat)" "OK 2"
printf '%10d\n' 3 > d3.dat; chk L29_dist_count_vs_ref "$(femtic_dist_check d3.dat d0.dat)" "BAD station count 3 differs from the reference 2"
# ---------------------------------------------------------------- L30-L35 femtic_restart_pick
mkdir r1 r2 r3 r4
cp $B0 r1/resistivity_block_iter0.dat; cp $B0 r1/resistivity_block_iter1.dat; cp cut_blocks.dat r1/resistivity_block_iter2.dat
chk L30_pick_fallback "$(femtic_restart_pick r1 0 0 2>/dev/null)" 1
chk L31_no_rename_without_q "$(ls r1 | grep -c corrupt)" 0
SLURM_JOB_ID=77 femtic_restart_pick r1 0 1 >/dev/null 2>&1
chk L32_rename_with_q "$(ls r1 | tr '\n' ' ')" "resistivity_block_iter0.dat resistivity_block_iter1.dat resistivity_block_iter2.dat.corrupt_77 "
cp cut_elems.dat r2/resistivity_block_iter0.dat
chk L33_iter0_bad_fails "$(femtic_restart_pick r2 0 1 2>/dev/null; echo "rc=$?")" "rc=1"
chk L33b_iter0_kept "$(ls r2)" "resistivity_block_iter0.dat"
cp $B0 r3/resistivity_block_iter0.dat; cp cut_blocks.dat r3/resistivity_block_iter1.dat; cp cut_blocks.dat r3/resistivity_block_iter2.dat
chk L34_double_bad_fails_no_rename "$(femtic_restart_pick r3 0 1 2>/dev/null; echo "rc=$? $(ls r3 | grep -c corrupt)")" "rc=1 0"
cp $B0 r4/resistivity_block_iter0.dat; cp d0.dat r4/distortion_iter0.dat; cp $B0 r4/resistivity_block_iter1.dat
chk L35_dist_missing_falls_back "$(femtic_restart_pick r4 1 0 2>/dev/null)" 0
chk L35b_dist_ignored_when_0 "$(femtic_restart_pick r4 0 0 2>/dev/null)" 1
# ---------------------------------------------------------------- L36-L37 femtic_mem_limit_auto
# (254952*85/100 = 216709 integer; /8 = 27088; -10240 = 16848). With HOLD: (216709-50000)/8 = 20838; -10240 = 10598
chk L36_memlimit_no_hold_ignores_reserve "$(femtic_mem_limit_auto 254952 8 0 50000 10240)" 16848
chk L37_memlimit_hold_subtracts_reserve "$(femtic_mem_limit_auto 254952 8 1 50000 10240)" 10598
# ---------------------------------------------------------------- L38 femtic_fwd_times on a real FEMTIC log
# rank 0 of the WSL run: last stamp before "Start Forward Computation" is "( 1 sec )"; response lines at 4 s and 7 s
chk L38_fwd_times_real_log "$(femtic_fwd_times $LOG | tr '\n' '|')" "0.001 3|0.01 3|"
# ---------------------------------------------------------------- L39-L41 femtic_launch_cmd
( unset USE_SRUN; FEMTIC_TOOLCHAIN=foss; femtic_launch_cmd 8 8 9 /x/femtic; echo "${FEMTIC_LAUNCH[*]}" ) > l1.txt
chk L39_launch_foss "$(cat l1.txt)" "mpirun -np 8 --map-by ppr:8:node:PE=9 --bind-to core --report-bindings /x/femtic"
( unset USE_SRUN; FEMTIC_TOOLCHAIN=intel; femtic_launch_cmd 16 8 9 /x/femtic; echo "${FEMTIC_LAUNCH[*]} $I_MPI_PIN_DOMAIN" ) > l2.txt
chk L40_launch_intel "$(cat l2.txt)" "mpirun -np 16 -ppn 8 /x/femtic omp"
( USE_SRUN=1 SRUN_MPI=pmix; FEMTIC_TOOLCHAIN=foss; femtic_launch_cmd 8 8 9 /x/femtic; echo "${FEMTIC_LAUNCH[*]} $SRUN_CPUS_PER_TASK" ) > l3.txt
chk L41_launch_srun "$(cat l3.txt)" "srun --mpi=pmix --ntasks=8 --ntasks-per-node=8 --cpus-per-task=9 --cpu-bind=cores /x/femtic 9"
# ---------------------------------------------------------------- L42 femtic_outcome_row
femtic_outcome_row o.tsv 1 04_inversion h s e converged 0 3 0 "a b"; femtic_outcome_row o.tsv 2 04_inversion h s e stalled 3 5 2 x
chk L42_rows "$(wc -l < o.tsv) $(awk -F'\t' 'NR==2 {print NF, $6, $10}' o.tsv)" "3 10 converged a b"
# ---------------------------------------------------------------- L43-L44 femtic_wait_pid survives a trapped signal
# control: a plain 'wait' interrupted by a trapped USR1 returns 138 (128+10) while the child still runs
( trap 'echo trapped >> trap_plain.txt' USR1; ( sleep 2; exit 7 ) & c=$!; me=$BASHPID; ( sleep 0.5; kill -USR1 $me ) &
  wait $c; echo "plain_rc=$?"; wait $c ) > w0.txt
chk L43_control_plain_wait_interrupted "$(head -1 w0.txt) $(cat trap_plain.txt)" "plain_rc=138 trapped"
( trap 'echo trapped >> trap_lib.txt' USR1; ( sleep 2; exit 7 ) & c=$!; me=$BASHPID; ( sleep 0.5; kill -USR1 $me ) &
  femtic_wait_pid $c; echo "rc=$?" ) > w1.txt
chk L44_wait_pid_returns_child_rc "$(cat w1.txt) $(cat trap_lib.txt)" "rc=7 trapped"
# ---------------------------------------------------------------- L45 femtic_stop escalates to KILL
bash -c 'trap "" TERM; while :; do sleep 0.2; done' & c=$!
sleep 0.3; FEMTIC_STOP_GRACE_S=2 femtic_stop $c unit_test stop.txt 2>/dev/null; wait $c; rc=$?
chk L45_stop_kill_after_grace "$rc $(awk '{print $1}' stop.txt)" "137 unit_test"
echo "--- final control.dat (cat -A, first 6 + last 4 lines)"; head -6 c.dat | cat -A; tail -4 c.dat | cat -A
echo "CHECKS: $npass passed, $nfail failed"
echo "OVERALL: $([ $fail = 0 ] && echo PASS || echo FAIL)"; cd /; rm -rf $T
[ $fail = 0 ]
