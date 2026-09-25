#!/bin/bash
source /home/tara/miniforge3/etc/profile.d/conda.sh
conda activate femtic-foss2023a
export MKLROOT=$CONDA_PREFIX
cd /home/tara/femtic_wsl/femtic/src 2>/dev/null || cd /home/tara/femtic_wsl/femtic
pwd
fail=0
for f in *.cpp; do
  mpicxx -std=c++17 -fsyntax-only -fopenmp -D_LINUX -DMKL_ILP64 -D_USE_OMP -DNDEBUG -I$MKLROOT/include -Wvla -Wno-conversion-null $f 2>&1 | grep -E 'error|vla' 
  [ ${PIPESTATUS[0]} -ne 0 ] && { echo "FAIL $f"; fail=1; }
done
echo "femtic c++17 fail=$fail"
cd /home/tara/femtic_wsl/makeTetraMesh/src 2>/dev/null || cd /home/tara/femtic_wsl/makeTetraMesh
for f in *.cpp; do g++ -std=c++17 -fsyntax-only -fopenmp -Wvla -D_USE_OMP -D_THICKNESS_FUNC $f 2>&1 | grep -E 'error|vla'; done
echo mtm done
