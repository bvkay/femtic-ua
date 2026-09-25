#!/bin/bash
SP=/mnt/c/Users/joint/AppData/Local/Temp/claude/D--BEN-FEMTIC-2026/4e858f54-ea4e-47a8-9815-7766aca9830d/scratchpad
T=$(mktemp -d); cd $T; source <(sed 's/\r$//' $SP/phoenix_plan/femtic_lib.sh); fail=0
chk(){ if [ "$2" = "$3" ]; then echo "PASS $1 ($2)"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
echo "sed: $(sed --version | head -1)  bash: $BASH_VERSION"
cp $SP/femtic/examples/INV_MT_01/Tetra/control.dat c.dat
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
chk block_stats "$(femtic_block_stats $SP/femtic/examples/INV_MT_01/Tetra/resistivity_block_iter0.dat)" "34559 289 289 288 1"
echo "--- final control.dat (cat -A, first 6 + last 4 lines)"; head -6 c.dat | cat -A; tail -4 c.dat | cat -A
echo "OVERALL: $([ $fail = 0 ] && echo PASS || echo FAIL)"; rm -rf $T
