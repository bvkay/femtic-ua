# -*- coding: utf-8 -*-
"""_common.py - shared helpers of the GUI tests (plain scripts; python tests/gui/run_all.py runs them all).

Every test states "This test fails if ..." in its docstring and first shows that its check CAN fail, on a
mutant or a broken input, before it checks the real thing (Invariant 10). A test whose data is missing raises
NotRun: it is reported NOT RUN, never PASS, and the script exits 2.
Data: the gitignored meshes live in Ben's checkout; set FEMTIC_MAIN to it (default D:/BEN/FEMTIC_2026).

@author ben kay
:license: MIT
"""
from __future__ import annotations

import os
import sys
import tempfile
import time
import traceback
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO / "src"))
MAIN = Path(os.environ.get("FEMTIC_MAIN", "D:/BEN/FEMTIC_2026"))
CFG = REPO / "config" / "vulcan_mesh_v2_rot.yml"
OBSERVE = REPO / "mesh" / "vulcan_v2_rot" / "inversion" / "observe.dat"
TALLY = {"PASS": 0, "FAIL": 0, "NOT RUN": 0}


class NotRun(Exception):
    """The test's data is not on this PC; reported NOT RUN, never PASS."""


def fails_first(check, *bad_args) -> str:
    """Run a check on a broken input and require it to report failure; returns its detail line.

    Args:
        check: Callable returning (ok, detail).
        bad_args: The mutant or broken input.

    Raises:
        AssertionError: if the check passes the broken input (the test could not fail).
    """
    ok, detail = check(*bad_args)
    print("    failing case -> %s" % detail)
    assert not ok, "the check PASSED a broken input, so it cannot fail: %s" % detail
    return detail


def passes(check, *args) -> str:
    """Run a check on the real input and require it to pass; returns its detail line."""
    ok, detail = check(*args)
    print("    real case    -> %s" % detail)
    assert ok, detail
    return detail


def abs_root_copy(folder: Path, name: str = "base.yml", edits: dict | None = None) -> Path:
    """Write CFG into folder with paths.root made absolute (so the copy resolves to this repository), plus edits."""
    from femtic_gui import config_io
    doc = config_io.load(CFG)
    doc = config_io.set_value(doc, "paths.root", REPO.as_posix())
    for k, v in (edits or {}).items():
        doc = config_io.set_value(doc, k, v)
    p = Path(folder) / name
    p.write_text(doc.text, encoding="utf-8", newline="")
    return p


def temp_dir(tag: str) -> tempfile.TemporaryDirectory:
    """A temporary folder (system temp), removed when the context ends."""
    return tempfile.TemporaryDirectory(prefix="femtic_gui_%s_" % tag)


def run(ns: dict) -> int:
    """Run every test_ function of a module namespace in order; return the number of failures."""
    fails = 0
    for name, fn in list(ns.items()):
        if not (name.startswith("test_") and callable(fn)):
            continue
        doc = " ".join((fn.__doc__ or "").split())
        print("--- %s: %s" % (name, doc))
        t0 = time.perf_counter()
        try:
            fn()
            status = "PASS"
        except NotRun as e:
            status = "NOT RUN"
            print("    %s" % e)
        except Exception:
            status = "FAIL"
            traceback.print_exc(file=sys.stdout)
            fails += 1
        TALLY[status] += 1
        print("    %s (%.1f s)" % (status, time.perf_counter() - t0))
    return fails


def main(ns: dict) -> None:
    """Run the module's tests and exit 1 on any FAIL, 2 if any test was NOT RUN, else 0."""
    run(ns)
    print("=== %d PASS, %d FAIL, %d NOT RUN" % (TALLY["PASS"], TALLY["FAIL"], TALLY["NOT RUN"]))
    sys.exit(1 if TALLY["FAIL"] else 2 if TALLY["NOT RUN"] else 0)
