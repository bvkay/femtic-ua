#!/bin/bash
# chaintest_v2.sh -- mock-harness test of 04_inversion.slurm, 05_chain.sh and 06_forward_only.slurm
# control flow (no real femtic, no Slurm). Each scenario states its expected outcome; the harness
# FAILS if any observable differs. Run in WSL:  bash chaintest_v2.sh
#
# v2 (2026-09-25) versus chaintest.sh (v1, kept unchanged next to this file as the record of the first run):
#   * PLAN defaults to the edited D:\BEN\FEMTIC_2026\hpc\phoenix_plan (override: PLAN=... bash chaintest_v2.sh).
#   * S1 MEM_LIMIT expectation 26112 -> 16848. Requirement F changed the formula to
#     (0.85 x mem) / R - NONPARDISO_MB (10240), with the rank-0 reserve only under HOLD_FWD_MEM, and the node
#     memory to the icelake cap 254,952 MiB (72 x 3541). 16848 = floor(floor(254952*85/100)/8) - 10240, computed
#     by hand, not by the code under test. S10 keeps v1's 245,760 MiB.
#   * S12: 04 no longer contains the YOUR_EMAIL placeholder (mail goes to ben.kay@adelaide.edu.au), so the refusal
#     is tested on a copy with the placeholder put back; the behaviour under test (05 refuses it) is unchanged.
#   * mock sbatch state lives in the run directory instead of /tmp.
#   * the fake femtic gains modes silent, timed, fwd, fwd_missing, and copies distortion files like FEMTIC does.
#   * new scenarios S13-S22 (restart integrity and fallback, silent exit-0 death, COMPLETED marker, SIGUSR1 trap,
#     safe-point stop, 05 integrity note, 06 forward-only report pass and fail).
PLAN=${PLAN:-/mnt/d/BEN/FEMTIC_2026/hpc/phoenix_plan}
EX=${EX:-/mnt/c/Users/joint/AppData/Local/Temp/claude/D--BEN-FEMTIC-2026/4e858f54-ea4e-47a8-9815-7766aca9830d/scratchpad/femtic/examples/INV_MT_01/Tetra}
[ -f "$EX/resistivity_block_iter0.dat" ] || { echo "FEMTIC example not found at EX=$EX"; exit 2; }
R=$(mktemp -d); BIN=$R/bin; mkdir -p $BIN $R/tmp
cp $PLAN/femtic_lib.sh $BIN/
cat > $BIN/femtic_env.sh <<EOF
export PATH=$BIN:\$PATH FEMTIC_TOOLCHAIN=foss FEMTIC_BIN=$BIN
. $BIN/femtic_lib.sh
EOF
# ---- mocks
cat > $BIN/mpirun <<'EOF'
#!/bin/bash
echo "$*" > mpirun_args.txt
exec "${@: -1}"
EOF
cat > $BIN/squeue <<'EOF'
#!/bin/bash
echo "${MOCK_TL:-2-23:00:00}"
EOF
printf '#!/bin/bash\nexit 0\n' > $BIN/rcstat; printf '#!/bin/bash\nexit 0\n' > $BIN/sacct
cat > $BIN/femtic <<'EOF'
#!/bin/bash
# fake femtic: honours ITERATION "a b".
# FAKE=normal|converge|stall|crash|slow_progress|slow_noprogress|silent|timed|fwd|fwd_missing
read -r A B < <(awk '$1=="ITERATION"{getline; print; exit}' control.dat)
freqhdr() { echo "#+++"; echo "# Forward calculation is performed for the frequencies/periods below."; echo "#   Freq#  Frequency[Hz]    Period[sec]"
  for i in $(seq 0 15); do echo "#  $i  $((i+1)).0  1.0"; done; echo "#++++++++++"; }
echo "ARGS ITERATION=$A $B THREADS=$(awk '$1=="NUM_THREADS"{getline;print;exit}' control.dat)" >> fake_calls.txt
printf '%10s%10s%15s%15s%15s%15s%15s%15s\n' 'Iter#' 'Retrial#' Alpha Damp Roughness Misfit RMS ObjFunc > femtic.cnv
case "$FAKE" in
  fwd|fwd_missing)   # forward only: 8 rank logs, 2 frequencies each (5 s and 6 s), PARDISO 2 GiB + r KiB
    for r in 0 1 2 3 4 5 6 7; do
      { [ "$r" = 0 ] && freqhdr
        echo "# Total number of stations : 120 ."; echo "#  - Number of impedance tensor stations : 120 ."
        echo "# Total number of model parameter : 288."; echo "# Calculate Roughening Matrix .( 1 sec )"
        echo "# Start Forward Computation.  Iteration : 0,  Retrial : 0"
        t=1; nk=2; [ "$FAKE" = fwd_missing ] && [ "$r" = 7 ] && nk=1
        for k in $(seq 0 $((nk - 1))); do
          f=$(( r * 2 + k + 1 ))
          echo "# Start forward calculation. Frequency : $f [Hz], Polarization : Ex-polarization"
          echo "# Number of equation = 700000, Number of equation after degeneration = 600000"
          echo "# Total memory consumed by in-core forward solver for internal float point arrays    : $(( 2097152 + r )) [KByte]"
          echo "# Start forward calculation. Frequency : $f [Hz], Polarization : Ey-polarization"
          t=$(( t + 5 + k )); echo "# Calculate response functions. ( $t sec )"
        done
        echo "# Release memory of coefficient matrix and sparse solver. ( $t sec )"; } > femtic_$r.log
    done
    printf '%10d%10d%15e%15e%15e%15e%15e%15e\n' 0 0 3 0.5 1 1000 12.5 1 >> femtic.cnv
    echo "# Reach maximum iteration number." >> femtic_0.log; exit 0 ;;
esac
{ freqhdr; echo "# Total number of model parameter : 288."
  echo "# Total memory consumed by in-core forward solver for internal float point arrays    : 1048576 [KByte]"; } > femtic_0.log
case "$FAKE" in crash) echo "Error : boom" >> femtic_0.log; exit 1;; slow_noprogress) sleep 30; exit 0;; esac
for it in $(seq "$A" "$B"); do
  echo "# Start Forward Computation.  Iteration : $it,  Retrial : 0" >> femtic_0.log
  printf '%10d%10d%15e%15e%15e%15e%15e%15e\n' $it 0 3 0.5 1 $((1000-it)) 1 1 >> femtic.cnv
  if [ "$it" -gt "$A" ]; then
    cp resistivity_block_iter$A.dat resistivity_block_iter$it.dat
    [ -f distortion_iter$A.dat ] && cp distortion_iter$A.dat distortion_iter$it.dat
  fi
  if [ "$FAKE" = converge ] && [ "$it" -ge "${CONV_AT:-4}" ]; then echo "# Converged." >> femtic_0.log; exit 0; fi
  if [ "$FAKE" = stall ] && [ "$it" -gt "$A" ]; then echo "# Reach maximum retrial number." >> femtic_0.log; exit 0; fi
  if [ "$FAKE" = silent ] && [ "$it" -gt "$A" ]; then exit 0; fi
  if [ "$FAKE" = slow_progress ] && [ "$it" -gt "$A" ]; then sleep 30; fi
  [ "$it" -ge "$B" ] && { echo "# Reach maximum iteration number." >> femtic_0.log; exit 0; }
  if [ "$FAKE" = timed ]; then echo "# Start Inversion.  Iteration : $it" >> femtic_0.log; sleep "${ITER_SLEEP:-10}"; fi
done
EOF
chmod +x $BIN/*
fail=0; npass=0; nfail=0
chk(){ if [ "$2" = "$3" ]; then echo "  PASS $1 ($2)"; npass=$((npass+1)); else echo "  FAIL $1: got '$2' want '$3'"; fail=1; nfail=$((nfail+1)); fi; }
newdir(){ D=$R/inv_$1; mkdir -p $D; cp $EX/{control.dat,mesh.dat,observe.dat,resistivity_block_iter0.dat} $D/; }
job(){  # job <dir> <jobid> [ENV=VAL ...]  -> runs 04 as Slurm would; sets RC
  local d=$1 id=$2; shift 2
  ( cd $d && env "PATH=$BIN:$PATH" SLURM_JOB_ID=$id SLURM_SUBMIT_DIR=$d SLURM_JOB_NUM_NODES=1 SLURM_JOB_NODELIST=n1 \
      SLURM_NTASKS=8 SLURM_NTASKS_PER_NODE=8 SLURM_CPUS_PER_TASK=9 SLURM_MEM_PER_NODE=254952 TMPDIR=$R/tmp \
      BIN=$BIN AUTO_RESTART=1 ITER_STEP=3 SCRATCH_SHARED=$R/shared "$@" \
      bash $PLAN/04_inversion.slurm > $d/slurm-$id.out 2>&1 ); RC=$?
}
get(){ awk -v k=$2 '$1==k{getline;print;exit}' $1/control.dat; }
last(){ ( . $BIN/femtic_lib.sh; femtic_last_iter $1 ); }
yn(){ [ -e "$1" ] && echo yes || echo no; }

echo "S1 fresh start: expect exit 0, ITERATION '0 3', last iter 3, NUM_THREADS 9, SENSE in TMPDIR, MEM_LIMIT 16848, PE=9 mapping"
newdir a; job $R/inv_a 101 FAKE=normal
chk rc "$RC" 0; chk iteration "$(get $R/inv_a ITERATION)" "0 3"; chk last "$(last $R/inv_a)" 3
chk threads "$(get $R/inv_a NUM_THREADS)" 9; chk sense "$(get $R/inv_a SENSE_MAT_DIRECTORY)" "$R/tmp/sense"; chk memlimit "$(get $R/inv_a MEM_LIMIT)" 16848
chk mpirun "$(cat $R/inv_a/mpirun_args.txt)" "-np 8 --map-by ppr:8:node:PE=9 --bind-to core --report-bindings $BIN/femtic"
echo "S2 second job continues: expect ITERATION '3 6', last 6, previous logs archived, nfreq read from archive"
job $R/inv_a 102 FAKE=normal
chk rc "$RC" 0; chk iteration "$(get $R/inv_a ITERATION)" "3 6"; chk last "$(last $R/inv_a)" 6
chk archived "$(ls -d $R/inv_a/logs/run_* | wc -l)" 1; chk nfreq_msg "$(grep -c 'frequencies (from logs/run_' $R/inv_a/slurm-102.out)" 1
echo "S3 ITER_MAX cap: expect ITERATION '6 7' with ITER_MAX=7, then a further job exits 0 without running femtic"
job $R/inv_a 103 FAKE=normal ITER_MAX=7; chk rc "$RC" 0; chk iteration "$(get $R/inv_a ITERATION)" "6 7"
n=$(wc -l < $R/inv_a/fake_calls.txt); job $R/inv_a 104 FAKE=normal ITER_MAX=7; chk rc "$RC" 0; chk no_run "$(wc -l < $R/inv_a/fake_calls.txt)" "$n"
echo "S4 convergence: expect exit 0 + CONVERGED; next job exits 0 without running femtic"
newdir b; job $R/inv_b 201 FAKE=converge CONV_AT=2; chk rc "$RC" 0; chk marker "$([ -f $R/inv_b/CONVERGED ] && echo yes)" yes
n=$(wc -l < $R/inv_b/fake_calls.txt); job $R/inv_b 202 FAKE=normal; chk rc "$RC" 0; chk no_run "$(wc -l < $R/inv_b/fake_calls.txt)" "$n"
echo "S5 stall (max retrials): expect exit 2 + STALLED; next job exits 2"
newdir c; job $R/inv_c 301 FAKE=stall; chk rc "$RC" 2; chk marker "$([ -f $R/inv_c/STALLED ] && echo yes)" yes
job $R/inv_c 302 FAKE=normal; chk rc_next "$RC" 2
echo "S6 crash: expect non-zero exit"
newdir d; job $R/inv_d 401 FAKE=crash; chk rc_nonzero "$([ $RC -ne 0 ] && echo yes)" yes
echo "S7 guard stops job after progress: expect exit 0, last iter 1"
newdir e; job $R/inv_e 501 FAKE=slow_progress MOCK_TL=0:05 WALL_MARGIN_MIN=0 GUARD_MIN_S=0
chk rc "$RC" 0; chk last "$(last $R/inv_e)" 1; chk guard_msg "$(grep -c 'wall-clock guard after progress' $R/inv_e/slurm-501.out)" 1
echo "S8 guard stops job with no progress: expect exit 3"
newdir f; job $R/inv_f 601 FAKE=slow_noprogress MOCK_TL=0:05 WALL_MARGIN_MIN=0 GUARD_MIN_S=0; chk rc "$RC" 3
echo "S9 DISTORTION=1 without distortion_iter0.dat: expect exit 1 before femtic runs"
newdir g; sed -i 's/\r$//' $R/inv_g/control.dat; sed -i '/^DISTORTION/{n;s/.*/1/}' $R/inv_g/control.dat; job $R/inv_g 701 FAKE=normal
chk rc "$RC" 1; chk no_run "$([ -f $R/inv_g/fake_calls.txt ] && echo ran || echo none)" none
echo "S10 multi-node: expect SENSE_MAT_DIRECTORY on shared scratch, removed after the job"
newdir h; ( cd $R/inv_h && env "PATH=$BIN:$PATH" SLURM_JOB_ID=801 SLURM_SUBMIT_DIR=$R/inv_h SLURM_JOB_NUM_NODES=2 SLURM_NTASKS=16 SLURM_NTASKS_PER_NODE=8 \
   SLURM_CPUS_PER_TASK=9 SLURM_MEM_PER_NODE=245760 TMPDIR=$R/tmp BIN=$BIN AUTO_RESTART=1 ITER_STEP=1 SCRATCH_SHARED=$R/shared FAKE=normal \
   bash $PLAN/04_inversion.slurm > $R/inv_h/slurm-801.out 2>&1 ); RC=$?
chk rc "$RC" 0; chk sense "$(get $R/inv_h SENSE_MAT_DIRECTORY)" "$R/shared/sense_801"; chk cleaned "$([ -d $R/shared/sense_801 ] && echo left || echo removed)" removed
chk mpirun16 "$(cut -d' ' -f1-4 $R/inv_h/mpirun_args.txt)" "-np 16 --map-by ppr:8:node:PE=9"
echo "S11 05_chain.sh with mocked sbatch: expect 3 submissions, jobs 2-3 with afterok on previous id + kill-on-invalid-dep"
newdir i
cp $PLAN/04_inversion.slurm $R/job.slurm
cat > $BIN/sbatch <<EOF
#!/bin/bash
n=\$(( \$(cat $R/sbatch_n 2>/dev/null || echo 900) + 1 )); echo \$n > $R/sbatch_n
echo "\$*" >> $R/sbatch_calls; echo "\$n;phoenix"
EOF
chmod +x $BIN/sbatch; rm -f $R/sbatch_n $R/sbatch_calls
( export PATH=$BIN:$PATH BIN=$BIN; JOB_SCRIPT=$R/job.slurm bash $PLAN/05_chain.sh $R/inv_i 3 4 20 > $R/chain.out 2>&1 ); RC=$?
chk rc "$RC" 0; chk ncalls "$(wc -l < $R/sbatch_calls)" 3
chk call1_nodep "$(sed -n 1p $R/sbatch_calls | grep -c dependency)" 0
chk call2_dep "$(sed -n 2p $R/sbatch_calls | grep -oE 'dependency=afterok:[0-9]+ --kill-on-invalid-dep=yes')" "dependency=afterok:901 --kill-on-invalid-dep=yes"
chk call3_dep "$(sed -n 3p $R/sbatch_calls | grep -oE 'dependency=afterok:[0-9]+')" "dependency=afterok:902"
chk exports "$(sed -n 1p $R/sbatch_calls | grep -oE 'AUTO_RESTART=1,ITER_STEP=4,ITER_MAX=20')" "AUTO_RESTART=1,ITER_STEP=4,ITER_MAX=20"
chk ids_logged "$(awk '{print $2,$3,$4}' $R/inv_i/chain_jobs.txt)" "901 902 903"
echo "S12 05_chain.sh refuses the placeholder e-mail (on a copy of 04 with the placeholder put back)"
sed 's/ben\.kay@adelaide\.edu\.au/YOUR_EMAIL@adelaide.edu.au/' $PLAN/04_inversion.slurm > $R/job_placeholder.slurm
chk placeholder_present "$(grep -c 'YOUR_EMAIL@' $R/job_placeholder.slurm)" 1
( export PATH=$BIN:$PATH BIN=$BIN; JOB_SCRIPT=$R/job_placeholder.slurm bash $PLAN/05_chain.sh $R/inv_i 2 4 > $R/chain2.out 2>&1 ); chk rc_refuse "$?" 1

echo "S13 truncated last model (iter2 cut inside its block section): expect restart from 1, iter2 renamed *.corrupt_1301, ITERATION '1 4', exit 0"
newdir j; cp $R/inv_j/resistivity_block_iter0.dat $R/inv_j/resistivity_block_iter1.dat
head -n 34700 $R/inv_j/resistivity_block_iter0.dat > $R/inv_j/resistivity_block_iter2.dat
job $R/inv_j 1301 FAKE=normal
chk rc "$RC" 0; chk iteration "$(get $R/inv_j ITERATION)" "1 4"; chk quarantined "$(yn $R/inv_j/resistivity_block_iter2.dat.corrupt_1301)" yes
chk reason_logged "$(grep -c 'iteration 2 rejected -- resistivity_block_iter2.dat: BAD 140 block lines, header says 289' $R/inv_j/slurm-1301.out)" 1
chk last_after "$(last $R/inv_j)" 4
echo "S14 only iteration 0, and it is truncated: expect exit 1, femtic not run, iter0 NOT renamed"
newdir k; head -n 1000 $R/inv_k/resistivity_block_iter0.dat > $R/inv_k/x && mv $R/inv_k/x $R/inv_k/resistivity_block_iter0.dat
job $R/inv_k 1401 FAKE=normal
chk rc "$RC" 1; chk no_run "$([ -f $R/inv_k/fake_calls.txt ] && echo ran || echo none)" none; chk iter0_kept "$(yn $R/inv_k/resistivity_block_iter0.dat)" yes
echo "S15 DISTORTION=1: distortion_iter1.dat missing next to a valid block 1 -> restart from 0 (block 1 renamed), ITERATION '0 3'"
newdir l; sed -i 's/\r$//' $R/inv_l/control.dat; sed -i '/^DISTORTION/{n;s/.*/1/}' $R/inv_l/control.dat
printf '%10d\n%10d%15f%15f%15f%15f%10d\n%10d%15f%15f%15f%15f%10d\n' 2 1 1 0 0 1 0 2 1 0 0 1 0 > $R/inv_l/distortion_iter0.dat
cp $R/inv_l/resistivity_block_iter0.dat $R/inv_l/resistivity_block_iter1.dat
job $R/inv_l 1501 FAKE=normal
chk rc "$RC" 0; chk iteration "$(get $R/inv_l ITERATION)" "0 3"; chk quarantined "$(yn $R/inv_l/resistivity_block_iter1.dat.corrupt_1501)" yes
chk dist_written "$(yn $R/inv_l/distortion_iter3.dat)" yes
echo "S16 silent exit-0 death (femtic exits 0 with no end line): expect exit 1, no COMPLETED marker, outcome silent_exit0"
newdir m; job $R/inv_m 1601 FAKE=silent
chk rc "$RC" 1; chk completed "$(yn $R/inv_m/logs/COMPLETED_1601)" no; chk outcome "$(awk -F'\t' '$1==1601 {o=$6} END {print o}' $R/inv_m/job_outcomes.tsv)" silent_exit0
echo "S17 COMPLETED marker: present after S1's normal end (job 101), absent after S6's crash (job 401)"
chk completed_101 "$(yn $R/inv_a/logs/COMPLETED_101)" yes; chk completed_line "$(grep -c '^end_line # Reach maximum iteration number\.' $R/inv_a/logs/COMPLETED_101)" 1
chk completed_401 "$(yn $R/inv_d/logs/COMPLETED_401)" no
echo "S18 SIGUSR1 mid-run (femtic busy after writing model 1): expect WALLTIME marker, walltime_usr1 row, stop reason usr1, exit 0"
newdir n
( cd $R/inv_n && exec env "PATH=$BIN:$PATH" SLURM_JOB_ID=1801 SLURM_SUBMIT_DIR=$R/inv_n SLURM_JOB_NUM_NODES=1 SLURM_JOB_NODELIST=n1 \
    SLURM_NTASKS=8 SLURM_NTASKS_PER_NODE=8 SLURM_CPUS_PER_TASK=9 SLURM_MEM_PER_NODE=254952 TMPDIR=$R/tmp BIN=$BIN AUTO_RESTART=1 \
    ITER_STEP=3 SCRATCH_SHARED=$R/shared FAKE=slow_progress bash $PLAN/04_inversion.slurm > $R/inv_n/slurm-1801.out 2>&1 ) & P=$!
sleep 3; kill -USR1 $P; T0=$(date +%s); wait $P; RC=$?; TW=$(( $(date +%s) - T0 ))
chk rc "$RC" 0; chk walltime_marker "$(yn $R/inv_n/logs/WALLTIME_1801)" yes
chk usr1_row "$(awk -F'\t' '$1==1801 && $6=="walltime_usr1"' $R/inv_n/job_outcomes.tsv | wc -l)" 1
chk stop_reason "$(awk 'NR==1{print $1}' $R/inv_n/logs/stop_reason_1801)" usr1; chk last "$(last $R/inv_n)" 1
chk ended_promptly "$([ $TW -lt 20 ] && echo yes || echo "no ($TW s)")" yes
echo "S19 safe-point stop (10 s per iteration, 26 s to the hard stop, 1 s polls): expect stop at the safe point after model 2, exit 0"
newdir o; job $R/inv_o 1901 FAKE=timed ITER_SLEEP=10 ITER_STEP=10 MOCK_TL=0:26 WALL_MARGIN_MIN=0 GUARD_MIN_S=0 WATCH_S=1
chk rc "$RC" 0; chk stop_reason "$(awk 'NR==1{print $1}' $R/inv_o/logs/stop_reason_1901)" safe_point_iter2; chk last "$(last $R/inv_o)" 2
chk safe_msg "$(grep -c 'stopped at a safe point after progress' $R/inv_o/slurm-1901.out)" 1
chk safe_rows "$(awk -F'\t' '$1==1901' $R/inv_o/logs/safe_points.tsv | wc -l)" 3
echo "S20 05_chain.sh with a truncated last model: expect a note, start from the previous iteration, no renaming"
newdir p; cp $R/inv_p/resistivity_block_iter0.dat $R/inv_p/resistivity_block_iter1.dat; head -n 34700 $R/inv_p/resistivity_block_iter0.dat > $R/inv_p/resistivity_block_iter2.dat
rm -f $R/sbatch_n $R/sbatch_calls
( export PATH=$BIN:$PATH BIN=$BIN; JOB_SCRIPT=$R/job.slurm bash $PLAN/05_chain.sh $R/inv_p 1 4 > $R/chain3.out 2>&1 ); RC=$?
chk rc "$RC" 0; chk note "$(grep -c 'model 2 fails the integrity check' $R/chain3.out)" 1; chk from "$(grep -c 'from iteration 1,' $R/chain3.out)" 1
chk not_renamed "$(yn $R/inv_p/resistivity_block_iter2.dat)" yes
echo "S21 06 forward-only (8 ranks x 2 frequencies, 5 s + 6 s each): expect exit 0, T6 PASS, 16 rows = F, report + COMPLETED, inversion dir untouched"
newdir q; md5_before=$(md5sum $R/inv_q/control.dat | cut -d' ' -f1)
( cd $R/inv_q && env "PATH=$BIN:$PATH" SLURM_JOB_ID=2101 SLURM_SUBMIT_DIR=$R/inv_q SLURM_JOB_NUM_NODES=1 SLURM_NTASKS=8 SLURM_NTASKS_PER_NODE=8 \
   SLURM_CPUS_PER_TASK=9 SLURM_MEM_PER_NODE=254952 BIN=$BIN FAKE=fwd bash $PLAN/06_forward_only.slurm > $R/inv_q/slurm-2101.out 2>&1 ); RC=$?
chk rc "$RC" 0; chk t6 "$(grep -c '^T6 (forward-only): PASS' $R/inv_q/logs/fwd0_report_2101.txt)" 1
chk rows "$(grep -c 'frequency rows over all ranks: 16 (must equal F = 16)' $R/inv_q/logs/fwd0_report_2101.txt)" 1
chk tfwd "$(grep -c 'slowest rank): 11 s' $R/inv_q/logs/fwd0_report_2101.txt)" 1
chk rank7 "$(awk '$1=="7" && $2=="2" && $3=="11" && $4=="6"' $R/inv_q/logs/fwd0_report_2101.txt | wc -l)" 1
chk iteration00 "$(get $R/inv_q/fwd0_2101 ITERATION)" "0 0"; chk inv_control_untouched "$(md5sum $R/inv_q/control.dat | cut -d' ' -f1)" "$md5_before"
chk completed "$(yn $R/inv_q/logs/COMPLETED_2101)" yes; chk no_iter1_in_inv "$(yn $R/inv_q/resistivity_block_iter1.dat)" no
chk interp_pred "$(grep -c 'interpolator N_eq x N_iv x 16 B = 4.61 GB' $R/inv_q/logs/fwd0_report_2101.txt)" 1
echo "S22 06 forward-only with one frequency missing on rank 7: expect exit 1, T6 FAIL (15 rows), no COMPLETED"
newdir s
( cd $R/inv_s && env "PATH=$BIN:$PATH" SLURM_JOB_ID=2201 SLURM_SUBMIT_DIR=$R/inv_s SLURM_JOB_NUM_NODES=1 SLURM_NTASKS=8 SLURM_NTASKS_PER_NODE=8 \
   SLURM_CPUS_PER_TASK=9 SLURM_MEM_PER_NODE=254952 BIN=$BIN FAKE=fwd_missing bash $PLAN/06_forward_only.slurm > $R/inv_s/slurm-2201.out 2>&1 ); RC=$?
chk rc "$RC" 1; chk t6_fail "$(grep -c '^T6 (forward-only): FAIL.*freq_rows=15/F=16' $R/inv_s/logs/fwd0_report_2201.txt)" 1
chk completed "$(yn $R/inv_s/logs/COMPLETED_2201)" no

echo; echo "CHECKS: $npass passed, $nfail failed"
echo "OVERALL: $([ $fail = 0 ] && echo PASS || echo FAIL)"
if [ $fail != 0 ] && [ -n "${KEEP:-}" ]; then echo "kept $R for debugging"; else rm -rf $R; fi
[ $fail = 0 ]
