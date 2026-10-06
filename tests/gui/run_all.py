# -*- coding: utf-8 -*-
"""run_all.py - run every GUI test script, each in its own Python process; exit 1 on any FAIL, 2 on NOT RUN.

    python tests/gui/run_all.py          (about 30 s; reads the 312 MB v2 mesh from FEMTIC_MAIN if present)

Plain scripts, no pytest. Each script prints its tests' "This test fails if" lines, the failing case it shows
first and the real case. Nothing heavy runs: prep_vulcan.py once into a temporary folder, make_run.sh into a
temporary RUNS, 'python -c' one-liners; the GUI's own jobs are intercepted in gui_smoke.py.

@author ben kay
:license: MIT
"""
from __future__ import annotations

import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPTS = ["test_config_io.py", "test_prep_api.py", "test_static.py", "test_mtcalc.py", "test_readers.py",
           "test_state.py", "test_jobs.py", "test_mesh_reader.py", "test_viewer3d.py", "gui_smoke.py"]

if __name__ == "__main__":
    t0 = time.perf_counter()
    total = {"PASS": 0, "FAIL": 0, "NOT RUN": 0}
    worst = 0
    for name in SCRIPTS:
        r = subprocess.run([sys.executable, str(HERE / name)], cwd=str(HERE.parents[1]), capture_output=True,
                           text=True)
        out = r.stdout + r.stderr
        m = re.search(r"=== (\d+) PASS, (\d+) FAIL, (\d+) NOT RUN", out)
        counts = [int(v) for v in m.groups()] if m else [0, 1, 0]
        for k, v in zip(total, counts):
            total[k] += v
        status = "FAIL" if r.returncode == 1 or not m else "NOT RUN" if r.returncode == 2 else "PASS"
        worst = max(worst, {"PASS": 0, "NOT RUN": 2, "FAIL": 3}[status])
        print("%-22s %-7s %d pass, %d fail, %d not run" % (name, status, *counts))
        if status != "PASS":
            print(out[-3000:])
    print("=== %d PASS, %d FAIL, %d NOT RUN in %.0f s" % (total["PASS"], total["FAIL"], total["NOT RUN"],
                                                       time.perf_counter() - t0))
    sys.exit(1 if worst == 3 else 2 if worst == 2 else 0)
