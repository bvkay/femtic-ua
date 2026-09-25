#!/bin/bash
# Mock-harness test of 04_inversion.slurm + 05_chain.sh control flow (no real femtic, no Slurm).
# Each scenario states its expected outcome; the harness FAILS if any observable differs.
PLAN=/mnt/c/Users/joint/AppData/Local/Temp/claude/D--BEN-FEMTIC-2026/4e858f54-ea4e-47a8-9815-7766aca9830d/scratchpad/phoenix_plan
EX=/mnt/c/Users/joint/AppData/Local/Temp/claude/D--BEN-FEMTIC-2026/4e858f54-ea4e-47a8-9815-7766aca9830d/scratchpad/femtic/examples/INV_MT_01/Tetra
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
# fake femtic: honours ITERATION "a b"; FAKE=normal|converge|stall|crash|slow_progress|slow_noprogress
read -r A B < <(awk '$1=="ITERATION"{getline; print; exit}' control.dat)
{ echo "#+++"; echo "# Forward calculation is performed for the frequencies/periods below."; echo "#   Freq#  Frequency[Hz]    Period[sec]"
  for i in $(seq 0 15); do echo "#  $i  1.0  1.0"; done; echo "#++++++++++"
  echo "# Total number of model parameter : 288."
  echo "# Total memory consumed by in-core forward solver for internal float point arrays    : 1048576 [KByte]"; } > femtic_0.log
printf '%10s%10s%15s%15s%15s%15s%15s%15s\n' 'Iter#' 'Retrial#' Alpha Damp Roughness Misfit RMS ObjFunc > femtic.cnv
echo "ARGS ITERATION=$A $B THREADS=$(awk '$1=="NUM_THREADS"{getline;print;exit}' control.dat)" >> fake_calls.txt
case "$FAKE" in crash) echo "Error : boom" >> femtic_0.log; exit 1;; slow_noprogress) sleep 30; exit 0;; esac
for it in $(seq "$A" "$B"); do
  echo "# Start Forward Computation.  Iteration : $it,  Retrial : 0" >> femtic_0.log
  printf '%10d%10d%15e%15e%15e%15e%15e%15e\n' $it 0 3 0.5 1 $((1000-it)) 1 1 >> femtic.cnv
  [ "$it" -gt "$A" ] && cp resistivity_block_iter$A.dat resistivity_block_iter$it.dat
  if [ "$FAKE" = converge ] && [ "$it" -ge "${CONV_AT:-4}" ]; then echo "# Converged." >> femtic_0.log; exit 0; fi
  if [ "$FAKE" = stall ] && [ "$it" -gt "$A" ]; then echo "# Reach maximum retrial number." >> femtic_0.log; exit 0; fi
  if [ "$FAKE" = slow_progress ] && [ "$it" -gt "$A" ]; then sleep 30; fi
  [ "$it" -ge "$B" ] && { echo "# Reach maximum iteration number." >> femtic_0.log; exit 0; }
done
EOF
chmod +x $BIN/*
fail=0
chk(){ if [ "$2" = "$3" ]; then echo "  PASS $1 ($2)"; else echo "  FAIL $1: got '$2' want '$3'"; fail=1; fi; }
newdir(){ D=$R/inv_$1; mkdir -p $D; cp $EX/{control.dat,mesh.dat,observe.dat,resistivity_block_iter0.dat} $D/; }
job(){  # job <dir> <jobid> [ENV=VAL ...]  -> runs 04 as Slurm would; sets RC
  local d=$1 id=$2; shift 2
  ( cd $d && env "PATH=$BIN:$PATH" SLURM_JOB_ID=$id SLURM_SUBMIT_DIR=$d SLURM_JOB_NUM_NODES=1 SLURM_JOB_NODELIST=n1 \
      SLURM_NTASKS=8 SLURM_NTASKS_PER_NODE=8 SLURM_CPUS_PER_TASK=9 SLURM_MEM_PER_NODE=245760 TMPDIR=$R/tmp \
      BIN=$BIN AUTO_RESTART=1 ITER_STEP=3 SCRATCH_SHARED=$R/shared "$@" \
      bash $PLAN/04_inversion.slurm > $d/slurm-$id.out 2>&1 ); RC=$?
}
get(){ awk -v k=$2 '$1==k{getline;print;exit}' $1/control.dat; }

echo "S1 fresh start: expect exit 0, ITERATION '0 3', last iter 3, NUM_THREADS 9, SENSE in TMPDIR, MEM_LIMIT 26112, PE=9 mapping"
newdir a; job $R/inv_a 101 FAKE=normal
chk rc "$RC" 0; chk iteration "$(get $R/inv_a ITERATION)" "0 3"; chk last "$(. $BIN/femtic_lib.sh; femtic_last_iter $R/inv_a)" 3
chk threads "$(get $R/inv_a NUM_THREADS)" 9; chk sense "$(get $R/inv_a SENSE_MAT_DIRECTORY)" "$R/tmp/sense"; chk memlimit "$(get $R/inv_a MEM_LIMIT)" 26112
chk mpirun "$(cat $R/inv_a/mpirun_args.txt)" "-np 8 --map-by ppr:8:node:PE=9 --bind-to core --report-bindings $BIN/femtic"
echo "S2 second job continues: expect ITERATION '3 6', last 6, previous logs archived, nfreq read from archive"
job $R/inv_a 102 FAKE=normal
chk rc "$RC" 0; chk iteration "$(get $R/inv_a ITERATION)" "3 6"; chk last "$(. $BIN/femtic_lib.sh; femtic_last_iter $R/inv_a)" 6
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
chk rc "$RC" 0; chk last "$(. $BIN/femtic_lib.sh; femtic_last_iter $R/inv_e)" 1; chk guard_msg "$(grep -c 'wall-clock guard after progress' $R/inv_e/slurm-501.out)" 1
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
cp $PLAN/04_inversion.slurm $R/job.slurm; sed -i 's/YOUR_EMAIL@adelaide.edu.au/test@example.org/' $R/job.slurm
cat > $BIN/sbatch <<'EOF'
#!/bin/bash
n=$(( $(cat /tmp/sbatch_n 2>/dev/null || echo 900) + 1 )); echo $n > /tmp/sbatch_n
echo "$*" >> /tmp/sbatch_calls; echo "$n;phoenix"
EOF
chmod +x $BIN/sbatch; rm -f /tmp/sbatch_n /tmp/sbatch_calls
( export PATH=$BIN:$PATH BIN=$BIN; JOB_SCRIPT=$R/job.slurm bash $PLAN/05_chain.sh $R/inv_i 3 4 20 > $R/chain.out 2>&1 ); RC=$?
chk rc "$RC" 0; chk ncalls "$(wc -l < /tmp/sbatch_calls)" 3
chk call1_nodep "$(sed -n 1p /tmp/sbatch_calls | grep -c dependency)" 0
chk call2_dep "$(sed -n 2p /tmp/sbatch_calls | grep -oE 'dependency=afterok:[0-9]+ --kill-on-invalid-dep=yes')" "dependency=afterok:901 --kill-on-invalid-dep=yes"
chk call3_dep "$(sed -n 3p /tmp/sbatch_calls | grep -oE 'dependency=afterok:[0-9]+')" "dependency=afterok:902"
chk exports "$(sed -n 1p /tmp/sbatch_calls | grep -oE 'AUTO_RESTART=1,ITER_STEP=4,ITER_MAX=20')" "AUTO_RESTART=1,ITER_STEP=4,ITER_MAX=20"
chk ids_logged "$(awk '{print $2,$3,$4}' $R/inv_i/chain_jobs.txt)" "901 902 903"
echo "S12 05_chain.sh refuses the placeholder e-mail"
( export PATH=$BIN:$PATH BIN=$BIN; JOB_SCRIPT=$PLAN/04_inversion.slurm bash $PLAN/05_chain.sh $R/inv_i 2 4 > $R/chain2.out 2>&1 ); chk rc_refuse "$?" 1
echo; echo "OVERALL: $([ $fail = 0 ] && echo PASS || echo FAIL)"
[ $fail = 0 ] || { echo "--- S1 slurm output for debugging:"; head -60 $R/inv_a/slurm-101.out; }
rm -rf $R /tmp/sbatch_n /tmp/sbatch_calls
