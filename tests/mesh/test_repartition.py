"""femtic_mesh.repartition and femtic_mesh.cells: the D3 instrument.

  python tests/mesh/test_repartition.py [test_name ...]
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C  # noqa: E402
import numpy as np  # noqa: E402
from femtic_mesh import cells  # noqa: E402
from femtic_mesh import repartition as RP  # noqa: E402
from femtic_mesh.io import femtic as F  # noqa: E402

ATTR = {"chain_proof": C.repo_file("mesh", "chain_proof", "inputs", "resistivity_attr.dat"),
        "vulcan_v2": C.repo_file("mesh", "vulcan_v2", "files", "resistivity_attr.dat")}
SUB = {"chain_proof": (), "vulcan_v2": ("inversion",)}


def _paths(case):
    d = os.path.dirname(C.need(case, *SUB[case], "mesh.dat"))
    return os.path.join(d, "mesh.dat"), os.path.join(d, "resistivity_block_iter0.dat")


def _cli_reproduces(case, d):
    mesh, gold = _paths(case)
    out = os.path.join(d, case + ".blk")
    rc = RP.main([mesh, "--attr", ATTR[case], "--out", out, "--compare", gold])
    ok, at = C.same_bytes(gold, out)
    assert rc == 0 and ok, f"{case}: rc {rc}, block file differs at byte {at}"
    return True


class _Mutant:
    """Temporarily replace one function of femtic_mesh.cells (the study's N1 mutants)."""
    def __init__(self, name, fn):
        self.name, self.fn = name, fn

    def __enter__(self):
        self.keep = getattr(cells, self.name)
        setattr(cells, self.name, self.fn)

    def __exit__(self, *a):
        setattr(cells, self.name, self.keep)


MUTANTS = {"floor split (iMid = n/2)": ("_median_cut", lambda n: n // 2),
           "no element tie-break": ("_sorted_along", lambda g, c: g[np.argsort(c, kind="stable")])}


def _moved(case, mutant=None, rule=cells.USUI):
    mesh_p, gold = _paths(case)
    m = F.read_mesh_dat(mesh_p)
    a = F.read_resistivity_attr(ATTR[case])
    g = F.read_resistivity_blocks(gold)
    if mutant:
        with _Mutant(*MUTANTS[mutant]):
            e2b, _, _ = RP.repartition(m, a, rule)
    else:
        e2b, _, _ = RP.repartition(m, a, rule)
    return int((e2b != g.elem2blk).sum())


def test_usui_reproduces_chain_proof():
    """This test fails if `python -m femtic_mesh.repartition chain_proof/mesh.dat --attr ... --out X` does not
    write X byte-identical to TetGen2Femtic's chain_proof/resistivity_block_iter0.dat (regions from the flood
    fill, not from the block file; coordinates from mesh.dat).

    Negative controls (study N1): the floor-split mutant, the no-tie-break mutant and B at the group centroid
    must each put at least one element in a different cell."""
    for name in MUTANTS:
        n = _moved("chain_proof", name)
        C.expect_fail(f"{name}: {n} elements moved", lambda: n == 0)
    n = _moved("chain_proof", rule=cells.CellRule(b_at="centroid"))
    C.expect_fail(f"B at the group centroid: {n} elements moved", lambda: n == 0)
    with C.tmpdir() as d:
        _cli_reproduces("chain_proof", d)
    print("    chain_proof block file rewritten byte for byte from mesh.dat (3,842 cells)")


def test_usui_reproduces_v2():
    """This test fails if the re-partition of vulcan_v2/inversion/mesh.dat (2,446,095 elements, 9 ellipsoids,
    120 two-circle sites) does not write a block file byte-identical to TetGen2Femtic's (65,342 cells).

    Negative control: the floor-split mutant must move at least one v2 element."""
    n = _moved("vulcan_v2", "floor split (iMid = n/2)")
    C.expect_fail(f"floor split on v2: {n} elements moved", lambda: n == 0)
    with C.tmpdir() as d:
        _cli_reproduces("vulcan_v2", d)
    print("    v2 block file rewritten byte for byte from mesh.dat (65,342 cells)")


def _stats_cells(txt):
    out = {"earth_cells": int(re.search(r"earth_cells: (\d+)", txt)[1]),
           "cells_1_element": int(re.search(r"cells_with_1_element: (\d+)", txt)[1]),
           "cells_le5_elements": int(re.search(r"cells_with_le_5_elements: (\d+)", txt)[1]), "bands": []}
    pat = (r"depth\s+(\S+):\s+(\d+) cells; equiv size n=\s*\d+\s+min [\d.]+\s+p10 [\d.]+"
           r"\s+median ([\d.]+)")
    for m in re.finditer(pat, txt):
        out["bands"].append((int(m[2]), m[3]))
    return out


def _report_view(rep):
    return {"earth_cells": rep["earth_cells"], "cells_1_element": rep["cells_1_element"],
            "cells_le5_elements": rep["cells_le5_elements"],
            "bands": [(b["cells"], "%.3f" % b["size_km"]["median"]) for b in rep["by_depth"]]}


def test_cell_report_matches_mesh_stats():
    """This test fails if cells.cell_report on TetGen2Femtic's v2 block file differs from the cell figures of
    mesh/vulcan_v2/mesh_logs/mesh_stats.txt (scripts/mesh_stats.py in WSL): 65,341 earth cells, 1,040 with one
    element, 18,393 with <= 5, and the cell count and median size of each of the six depth bands.

    Negative control: the report after merging cell 2 into cell 1 must differ."""
    mesh_p, gold = _paths("vulcan_v2")
    m, g = F.read_mesh_dat(mesh_p), F.read_resistivity_blocks(gold)
    exp = _stats_cells(open(C.repo_file("mesh", "vulcan_v2", "mesh_logs", "mesh_stats.txt")).read())
    assert len(exp["bands"]) == 6, exp
    e2b = g.elem2blk.astype(np.int64)
    merged = np.where(e2b == 2, 1, e2b)
    merged = np.where(merged > 2, merged - 1, merged)
    rep_bad = cells.cell_report(m.nodes, m.tets, merged, np.arange(g.n_cells - 1) != 0)
    C.expect_fail("cell 2 merged into cell 1", lambda: _report_view(rep_bad) == exp)
    rep = cells.cell_report(m.nodes, m.tets, e2b, np.arange(g.n_cells) != 0)
    assert _report_view(rep) == exp, (_report_view(rep), exp)
    print(f"    report equals mesh_stats.txt: {_report_view(rep)}")


def test_flood_fill_regions():
    """This test fails if the air found by flooding from the top face list differs from cell 0 of TetGen2Femtic's
    block file (chain_proof and v2), or if a mesh with one Earth-surface face dropped from its list is accepted.

    Negative control: that mesh (the flood leaks into the earth) must raise."""
    for case in ("chain_proof", "vulcan_v2"):
        mesh_p, gold = _paths(case)
        m = F.read_mesh_dat(mesh_p)
        if case == "chain_proof":
            bad = F.read_mesh_dat(mesh_p)
            bad.faces[6] = bad.faces[6][1:]
            C.expect_fail("one Earth-surface face dropped", RP.air_from_surface, bad)
        air = RP.air_from_surface(m)
        blk = F.read_resistivity_blocks(gold).elem2blk
        assert np.array_equal(air, blk == 0), f"{case}: {int((air != (blk == 0)).sum())} elements disagree"
        print(f"    {case}: {int(air.sum()):,} air elements, equal to cell 0")


def test_alternative_rules_differ():
    """This test fails if any alternative rule of repartition.TABLE_RULES gives chain_proof exactly the usui
    partition (it would not be an alternative), or if B x 1.5 does not give fewer cells than usui.

    Negative control: the usui rule itself, put through the same comparison, must be reported identical."""
    mesh_p, _ = _paths("chain_proof")
    m, a = F.read_mesh_dat(mesh_p), F.read_resistivity_attr(ATTR["chain_proof"])
    ref, ref_rows, _ = RP.repartition(m, a, cells.USUI)

    def differs(rule):
        e2b, rows, _ = RP.repartition(m, a, rule)
        return rows.size, (rows.size != ref_rows.size or not np.array_equal(e2b, ref))
    C.expect_fail("usui compared with itself", lambda: differs(cells.CellRule())[1])
    counts = {}
    for rule in RP.TABLE_RULES[1:]:
        n, dif = differs(rule)
        assert dif, f"rule {rule.name} reproduces usui"
        counts[rule.name] = n - 1
    assert counts["Bx1.5"] < ref_rows.size - 1, counts
    print(f"    chain_proof earth cells: usui {ref_rows.size - 1}, " + ", ".join(f"{k} {v}" for k, v in counts.items()))


if __name__ == "__main__":
    sys.exit(1 if C.run(globals(), sys.argv[1:]) else 0)
