#!/bin/bash
# Run A, part 1: femticPy projects/synthetic inputs, makeTetraMesh steps 1-4 exactly as meshGen.sh
set -u
export PATH=/home/tara/femtic_wsl/bin:$PATH
SP=/mnt/c/Users/joint/AppData/Local/Temp/claude/D--BEN-FEMTIC-2026/4e858f54-ea4e-47a8-9815-7766aca9830d/scratchpad
SRC=$SP/femticPy/projects/synthetic
R=/home/tara/femtic_wsl/mesh_runs/chain_proof
rm -rf $R; mkdir -p $R/files $R/logs
# meshGen.sh line 5: cp input_data/{topography.dat,bathymetry.dat,coast_line.dat} meshGen/files/
cp $SRC/meshGen/files/{analysis_domain.dat,control.dat,makeMtr.param,observing_site.dat,obs_site.dat,resistivity_attr.dat} $R/files/
cp $SRC/input_data/{topography.dat,bathymetry.dat,coast_line.dat} $R/files/
cd $R
( cd files; for f in *; do printf '%s\t%s\n' "$f" "$(file -b $f)"; done ) > logs/input_types_raw.txt
( cd files; md5sum * ) > logs/input_md5_raw.txt
sed -i 's/\r$//' files/*
( cd files; for f in *; do printf '%s\t%s\n' "$f" "$(file -b $f)"; done ) > logs/input_types_lf.txt
( cd files; md5sum * ) > logs/input_md5_lf.txt
: > logs/timings.tsv
step() { # step <name> <cmd...>
  local name=$1; shift
  local t0=$(date +%s.%N)
  /usr/bin/time -f "%e s wall, %M KB maxrss" -o logs/$name.time "$@" > logs/$name.log 2>&1
  local rc=$?
  local t1=$(date +%s.%N)
  printf '%s\t%d\t%.2f\t%s\n' "$name" "$rc" "$(echo "$t1 - $t0" | bc -l)" "$(cat logs/$name.time | tail -1)" >> logs/timings.tsv
  return $rc
}
cp files/{control.dat,coast_line.dat,analysis_domain.dat,observing_site.dat} .
step stp1 makeTetraMesh -stp 1 || echo "stp1 FAILED"
step stp2 makeTetraMesh -stp 2 || echo "stp2 FAILED"
cp files/{topography.dat,bathymetry.dat} .
step stp3 makeTetraMesh -stp 3 || echo "stp3 FAILED"
step stp4 makeTetraMesh -stp 4 || echo "stp4 FAILED"
cat logs/timings.tsv
ls -la
head -2 output.poly; echo ...; tail -6 output.poly
grep -ci "error" makeTetraMesh.log
