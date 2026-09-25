cd /home/tara/femtic_wsl/bin
ls -l --time-style=full-iso
for f in *; do echo "== $f"; env -i PATH=/usr/bin:/bin ldd ./$f | grep -E "not found|mkl|mpi|gomp|omp|stdc" ; done
echo "== femtic strings compiler"; readelf -p .comment femtic | head
cd /home/tara/femtic_wsl/run_INV_MT_01_Tetra
cat exit_code.txt start.iso end.iso; cat time_v.log; cat rss_samples.log | head -30
grep -n -iE "process|PE|rank|thread" femtic_0.log | head -15; grep -n -iE "process|rank|thread" femtic_1.log | head -8
tail -5 femtic_0.log
grep -ciE "error|warn" femtic_0.log femtic_1.log
cmp resistivity_block_iter0.dat resistivity_block_iter5.dat | head -2
head -5 resistivity_block_iter0.dat; head -5 resistivity_block_iter5.dat
awk 'NR>1' femtic.cnv >/dev/null
ls -l --time-style=full-iso /home/tara/femtic_wsl/*/Makefile* 2>/dev/null | head; find /home/tara/femtic_wsl -name "*.o" -newermt "2026-09-25 00:00" | wc -l; find /home/tara/femtic_wsl -name "*.o" | wc -l
