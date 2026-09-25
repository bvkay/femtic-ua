cd /home/tara/femtic_wsl/run_INV_MT_01_Tetra
for i in 1 2 3 4 5; do printf "iter$i vs iter0 differing lines (CR stripped): "; diff <(tr -d '\r' < resistivity_block_iter0.dat) <(tr -d '\r' < resistivity_block_iter$i.dat) | grep -c '^>'; done
tr -d '\r' < resistivity_block_iter0.dat | sed -n '34562,34566p'; echo ---; sed -n '34562,34566p' resistivity_block_iter5.dat
diff <(tr -d '\r' < resistivity_block_iter4.dat) resistivity_block_iter5.dat | grep -c '^>'
echo "== rank1 freq"; sed -n '84,95p' femtic_1.log; echo "== rank0 freq"; sed -n '84,95p' femtic_0.log
echo "== md5 bins vs build tree"; md5sum /home/tara/femtic_wsl/bin/femtic; find /home/tara/femtic_wsl -maxdepth 3 -type f -name femtic -not -path "*/bin/*" -exec md5sum {} \; -exec ls -l --time-style=full-iso {} \;
readelf -d /home/tara/femtic_wsl/bin/femtic | grep -iE "rpath|runpath|NEEDED"
