#!/bin/bash
set -u
SRC=/mnt/c/Users/joint/AppData/Local/Temp/claude/D--BEN-FEMTIC-2026/4e858f54-ea4e-47a8-9815-7766aca9830d/scratchpad/femtic/examples/INV_MT_01/Tetra
RUN=/home/tara/femtic_wsl/run_INV_MT_01_Tetra
ITER_END=${ITER_END:-5}
source /home/tara/miniforge3/etc/profile.d/conda.sh && conda activate femtic-build
rm -rf "$RUN"; mkdir -p "$RUN"
cp "$SRC"/* "$RUN"/
cd "$RUN"
# control.dat has CRLF endings; values are on the line after each keyword
sed -i -E '/^NUM_THREADS/{n;s/^1(\r?)$/2\1/}' control.dat
sed -i -E "/^ITERATION/{n;s/^0 5(\r?)$/0 ${ITER_END}\1/}" control.dat
nt=$(grep -A1 '^NUM_THREADS' control.dat | tail -1 | tr -d '\r')
it=$(grep -A1 '^ITERATION' control.dat | tail -1 | tr -d '\r')
echo "NUM_THREADS=$nt ITERATION=$it"
[ "$nt" = "2" ] || { echo "NUM_THREADS edit FAILED"; exit 3; }
[ "$it" = "0 ${ITER_END}" ] || { echo "ITERATION edit FAILED"; exit 3; }
export OMP_NUM_THREADS=2
( peak=0; while [ ! -f DONE.marker ]; do s=$(ps -C femtic -o rss= 2>/dev/null | awk '{t+=$1} END{print t+0}'); n=$(ps -C femtic --no-headers 2>/dev/null | wc -l); th=$(ps -C femtic -o nlwp= 2>/dev/null | tr '\n' ' '); [ "$s" -gt "$peak" ] && peak=$s; echo "$(date +%s) nproc=$n nlwp=[$th] rss_sum_kib=$s peak_kib=$peak" >> rss_samples.log; sleep 2; done ) &
SAMP=$!
date +%s > start.epoch; date -Is > start.iso
/usr/bin/time -v -o time_v.log timeout 2700 mpirun -np 2 --oversubscribe --bind-to none /home/tara/femtic_wsl/bin/femtic > run.log 2>&1
RC=$?
date +%s > end.epoch; date -Is > end.iso
echo "$RC" > exit_code.txt
echo DONE > DONE.marker
wait $SAMP 2>/dev/null
echo "exit=$RC wall=$(( $(cat end.epoch) - $(cat start.epoch) ))s"
