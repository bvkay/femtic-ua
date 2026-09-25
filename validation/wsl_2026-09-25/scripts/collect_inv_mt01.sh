#!/bin/bash
cd /home/tara/femtic_wsl/run_INV_MT_01_Tetra || exit 1
OUT=/mnt/c/Users/joint/AppData/Local/Temp/claude/D--BEN-FEMTIC-2026/4e858f54-ea4e-47a8-9815-7766aca9830d/scratchpad/run_logs
echo "exit=$(cat exit_code.txt)"; echo "start=$(cat start.iso) end=$(cat end.iso)"
echo "wall=$(( $(cat end.epoch) - $(cat start.epoch) ))s"
echo "--- time -v"; grep -E 'Command being|Elapsed|Maximum resident|Exit status|Percent of CPU|User time|System time' time_v.log
echo "--- rss sampler peak"; tail -1 rss_samples.log; echo "samples: $(wc -l < rss_samples.log)"; grep -o 'nlwp=\[[^]]*\]' rss_samples.log | sort | uniq -c
echo "--- run.log ($(wc -c < run.log) bytes)"; cat run.log
echo "--- outputs"; ls -1 resistivity_block_iter* *.vtk 2>&1; ls | wc -l
echo "--- grep error/warning in run.log and femtic_*.log"; grep -n -i -E 'error|warning' run.log femtic_*.log | head -20; echo "count: $(grep -i -c -E 'error|warning' run.log femtic_0.log femtic_1.log | tr '\n' ' ')"
echo "--- process/thread info from femtic_0.log"; grep -n -i -E 'process|thread|PE' femtic_0.log | head -20
echo "--- head femtic_0.log"; head -30 femtic_0.log
echo "--- tail femtic_0.log"; tail -15 femtic_0.log
cp run.log femtic.cnv femtic_0.log femtic_1.log time_v.log rss_samples.log control.dat "$OUT"/
mkdir -p "$OUT/results_csv"; cp result_0_iter*.csv result_1_iter*.csv "$OUT/results_csv"/
echo copied
