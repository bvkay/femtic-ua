#!/bin/bash
set -u
S=/home/tara/femtic_wsl/mesh_runs
D=/mnt/d/BEN/FEMTIC_2026/mesh
V=/mnt/d/BEN/FEMTIC_2026/validation/mesh_2026-09-25
mkdir -p $D $V
for run in chain_proof chain_proof_meshgen; do
  src=$S/$run; dst=$D/$run; rm -rf $dst; mkdir -p $dst
  if [ -d $src/files ]; then cp -r $src/files $dst/inputs; else mkdir -p $dst/inputs; cp $src/{analysis_domain.dat,control.dat,makeMtr.param,observing_site.dat,obs_site.dat,resistivity_attr.dat,topography.dat,bathymetry.dat,coast_line.dat} $dst/inputs/; fi
  cp -r $src/logs $dst/logs
  cp $src/output.poly $src/mesh.dat $src/resistivity_block_iter0.dat $src/output.6.femtic.vtk $dst/
  [ -f $src/region_seeds.used ] && cp $src/region_seeds.used $dst/
  cp $src/makeTetraMesh.log $dst/logs/makeTetraMesh_last.log
  ( cd $dst && md5sum mesh.dat resistivity_block_iter0.dat > products.md5 )
  echo "$run -> $dst ($(du -sh $dst | cut -f1))"
done
cp /home/tara/femtic_wsl/mesh_runs/env_create.log /home/tara/femtic_wsl/mesh_runs/env_pin.log $V/
source /home/tara/miniforge3/etc/profile.d/conda.sh
conda env export -n femticpy --no-builds | grep -v '^prefix:' > $V/femticpy_environment.yml
conda env export -n femticpy --from-history | grep -v '^prefix:' > $V/femticpy_env_from_history.yml
cat $V/femticpy_env_from_history.yml
wc -l $V/femticpy_environment.yml
grep -E "^  - (python|numpy|pandas|scipy|matplotlib|pyproj|shapely|rdp|tabulate|pyyaml|jupyterlab)=" $V/femticpy_environment.yml
ls -la $V $D/*
