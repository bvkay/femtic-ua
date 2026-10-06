"""Shared helpers for the femtic_mesh tests (plain scripts: python tests/mesh/run_all.py).

Every test states "This test fails if ..." in its docstring and first shows that its check CAN fail (a mutant
writer, a perturbed input or a mutated port function) before it checks the real thing (Invariant 10).
Data: the gitignored mesh products live in Ben's checkout. Set FEMTIC_MESH_DATA to the folder that holds
chain_proof/ and vulcan_v2/; by default the repo's own mesh/ is tried, then D:/BEN/FEMTIC_2026/mesh.
"""
import contextlib
import gzip
import os
import shutil
import sys
import tempfile
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "src"))
FIXTURE = os.path.join(HERE, "data", "chain_proof_round0")


TALLY = {"pass": 0, "fail": 0, "skip": 0}


class Skip(Exception):
    """Raised when a test's data is not present; reported as SKIP, never as PASS."""


def mesh_data():
    cands = [os.environ.get("FEMTIC_MESH_DATA"), os.path.join(REPO, "mesh"), "D:/BEN/FEMTIC_2026/mesh"]
    for c in cands:
        if c and os.path.isfile(os.path.join(c, "chain_proof", "mesh.dat")):
            return c
    return None


def need(*rel):
    """Absolute path of a data file under the mesh data root, or Skip."""
    if rel and rel[0].startswith("vulcan") and os.environ.get("FEMTIC_SKIP_V2"):
        raise Skip("FEMTIC_SKIP_V2 is set (Vulcan-size tests skipped)")
    root = mesh_data()
    if root is None:
        raise Skip("no mesh data root with chain_proof/mesh.dat (set FEMTIC_MESH_DATA)")
    p = os.path.join(root, *rel)
    if not os.path.exists(p):
        raise Skip(f"missing {p}")
    return p


def repo_file(*rel):
    return os.path.join(REPO, *rel)


@contextlib.contextmanager
def tmpdir():
    d = tempfile.mkdtemp(prefix="femtic_mesh_test_")
    try:
        yield d
    finally:
        shutil.rmtree(d, ignore_errors=True)


def unpack_fixture(dst):
    """The tetgen round-0 fixture as plain files dst/output.1.{node,ele,face,neigh}; returns the prefix."""
    for e in ("node", "ele", "face", "neigh"):
        with gzip.open(os.path.join(FIXTURE, f"output.1.{e}.gz"), "rb") as fi:
            data = fi.read()
        with open(os.path.join(dst, f"output.1.{e}"), "wb") as fo:
            fo.write(data)
    return os.path.join(dst, "output.1")


def link_or_copy(src, dst):
    try:
        os.link(src, dst)
    except OSError:
        shutil.copyfile(src, dst)


def same_bytes(a, b):
    """(equal, first differing byte offset or None)."""
    with open(a, "rb") as fa, open(b, "rb") as fb:
        x, y = fa.read(), fb.read()
    if x == y:
        return True, None
    import numpy as np
    n = min(len(x), len(y))
    d = np.flatnonzero(np.frombuffer(x, np.uint8, n) != np.frombuffer(y, np.uint8, n))
    return False, int(d[0]) if d.size else n


def expect_fail(what, fn, *a, **k):
    """Run a check on a broken case and require it to fail (return False or raise AssertionError/ValueError)."""
    try:
        ok = fn(*a, **k)
    except (AssertionError, ValueError, RuntimeError) as exc:
        print(f"    negative control OK ({what}): check failed as it must: {type(exc).__name__}: {str(exc)[:120]}")
        return
    if ok is False:
        print(f"    negative control OK ({what}): check returned False as it must")
        return
    raise AssertionError(f"negative control {what!r} did NOT fail: the check cannot detect this defect")


def peak_rss_mb():
    try:
        import psutil
        mi = psutil.Process().memory_info()
        return round(getattr(mi, "peak_wset", getattr(mi, "rss", 0)) / 2**20, 1)
    except Exception:
        try:
            import resource
            return round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024, 1)
        except Exception:
            return None


def run(module_globals, only=None):
    """Run the test_ functions of a module in file order; prints PASS / FAIL / SKIP; returns the failure count."""
    tests = [(n, f) for n, f in module_globals.items() if n.startswith("test_") and callable(f)]
    tests.sort(key=lambda t: t[1].__code__.co_firstlineno)
    fails = 0
    for name, fn in tests:
        if only and name not in only:
            continue
        doc = (fn.__doc__ or "").strip().splitlines()
        crit, on = [], False
        for ln in doc:
            on = on or ln.strip().startswith("This test fails if")
            if on and not ln.strip():
                break
            if on:
                crit.append(ln.strip())
        crit = " ".join(crit) or None
        print(f"--- {name}")
        print(f"    {crit or 'NO FAILURE CRITERION STATED'}")
        t0 = time.perf_counter()
        try:
            if crit is None:
                raise AssertionError("the docstring must state 'This test fails if ...'")
            fn()
            print(f"PASS {name} ({time.perf_counter() - t0:.1f} s)")
            TALLY["pass"] += 1
        except Skip as s:
            print(f"SKIP {name}: {s}")
            TALLY["skip"] += 1
        except Exception:
            fails += 1
            TALLY["fail"] += 1
            traceback.print_exc()
            print(f"FAIL {name}")
    return fails
