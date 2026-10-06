"""Run every femtic_mesh test script; exit 1 if any test fails.

  python tests/mesh/run_all.py            (about 1 minute with the Vulcan v2 tests, 256 MB mesh.dat)
  FEMTIC_SKIP_V2=1 python tests/mesh/run_all.py     (chain_proof and fixture tests only, a few seconds)

SKIP means the data was not found (set FEMTIC_MESH_DATA); it is never counted as a pass.
"""
import importlib
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C  # noqa: E402

MODULES = ["test_io_femtic", "test_io_tetgen", "test_tetgen2femtic", "test_repartition"]

if __name__ == "__main__":
    t0 = time.perf_counter()
    fails = 0
    for name in MODULES:
        print(f"===== {name}")
        fails += C.run(vars(importlib.import_module(name)))
    t = C.TALLY
    print(f"===== {t['pass']} passed, {t['fail']} failed, {t['skip']} skipped in {time.perf_counter() - t0:.0f} s, "
          f"peak RSS {C.peak_rss_mb()} MB, mesh data {C.mesh_data()}")
    sys.exit(1 if fails else 0)
