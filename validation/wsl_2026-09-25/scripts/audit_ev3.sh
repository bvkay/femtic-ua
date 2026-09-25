cd /home/tara/femtic_wsl/run_INV_MT_01_Tetra
for r in 0 1; do echo "== rank $r"; grep -n -iE "Frequency|freq" femtic_$r.log | sed -n '1,4p;6,12p' | head -12; head -3 result_${r}_iter0.csv | cut -c1-200; cut -d, -f2 result_${r}_iter0.csv | sort -u | head; done
