#!/bin/bash
source /home/tara/miniforge3/etc/profile.d/conda.sh
conda activate femticpy
export PYTHONPATH=/mnt/c/Users/joint/AppData/Local/Temp/claude/D--BEN-FEMTIC-2026/4e858f54-ea4e-47a8-9815-7766aca9830d/scratchpad/femticPy/src
which python; python --version
python -c 'import femticPy; print("import femticPy OK:", femticPy.__file__)'; echo "import exit=$?"
python -c 'import numpy, scipy, pandas, matplotlib, pyproj, shapely, rdp, tabulate, yaml; print("numpy",numpy.__version__,"scipy",scipy.__version__,"pandas",pandas.__version__,"matplotlib",matplotlib.__version__,"pyproj",pyproj.__version__,"shapely",shapely.__version__)'
python - <<'PY'
import io, pandas as pd
try:
    pd.read_csv(io.StringIO("1 2\n3 4\n"), delim_whitespace=True, header=None)
    print("delim_whitespace: accepted")
except TypeError as e:
    print("delim_whitespace: REJECTED ->", e)
PY
