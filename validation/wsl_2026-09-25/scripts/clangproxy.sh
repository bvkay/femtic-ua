#!/bin/bash
source /home/tara/miniforge3/etc/profile.d/conda.sh
conda activate femtic-foss2023a
export MKLROOT=$CONDA_PREFIX
cd /home/tara/femtic_wsl/femtic/src
for f in $(ls *.cpp | grep -v '^InversionGaussNewtonDataSpace.cpp$' | grep -v NodeBased); do
  mpicxx -std=gnu++17 -fsyntax-only -fopenmp -D_LINUX -DMKL_ILP64 -D_USE_OMP -DNDEBUG -I$MKLROOT/include -Wall -Wextra -Wpedantic $f 2>&1
done | grep -E "[-Wextra]|sizeof-pointer-div|sequence-point" | sed -E "s/^[^:]+:[0-9]+:[0-9]+: //" | sort | uniq -c | sort -rn | head
