# -*- coding: utf-8 -*-
"""test_mesh_reader.py - readers.read_mesh and read_block on the real v2 mesh (T10; reads 312 MB, about 5 s).

readers.read_mesh and read_block (thin calls into femtic_mesh.io.femtic; the 3D viewer uses them) are the
contract T10 holds whichever package parses the files. The
independent observables: mesh/vulcan_v2/mesh_logs/mesh_stats.txt (counts measured when the mesh was built), the
analysis domain (the element volumes must fill the 1000 km cube, run_mesh_chain.sh's rule) and the config's two
region resistivities (air 1e9, earth 20 ohm-m). Needs Ben's checkout (FEMTIC_MAIN): NOT RUN without it. No Qt.

    python tests/gui/test_mesh_reader.py

@author ben kay
:license: MIT
"""
from __future__ import annotations

import re
import time

import _common as C
import numpy as np

from femtic_gui import readers

MESH = C.MAIN / "mesh" / "vulcan_v2" / "inversion" / "mesh.dat"
BLOCK = MESH.with_name("resistivity_block_iter0.dat")
STATS = C.REPO / "mesh" / "vulcan_v2" / "mesh_logs" / "mesh_stats.txt"


def _volumes(nodes, tets) -> float:
    p0, p1, p2, p3 = (nodes[tets[:, k]] for k in range(4))
    return float(np.sum(np.abs(np.einsum("ij,ij->i", p1 - p0, np.cross(p2 - p0, p3 - p0)))) / 6.0)


def test_v2_model_counts_volume_and_regions():
    """This test fails unless the v2 mesh and model read by readers.read_mesh / read_block have the node and
    element counts of mesh_stats.txt line 1 (401,334 and 2,446,095), the element volumes sum to the (1000 km)^3
    analysis domain within 1e-6, and iteration 0 puts 1,149,539 elements at 1e9 ohm-m and 1,296,556 at
    20 ohm-m (T10). Failing case: node coordinates read one column to the left."""
    if not (MESH.is_file() and BLOCK.is_file()):
        raise C.NotRun("no %s (set FEMTIC_MAIN to Ben's checkout)" % MESH)
    line1 = STATS.read_text(encoding="utf-8").splitlines()[0]
    nn, ne, air, earth = (int(v) for v in re.findall(r"\d+", line1)[:4])
    t0 = time.perf_counter()
    nodes, tets = readers.read_mesh(MESH)
    cell, rho = readers.read_block(BLOCK, len(tets))
    model = {"nodes": nodes, "tets": tets, "rho": rho[cell]}
    print("    read in %.1f s: %s" % (time.perf_counter() - t0, line1))

    def check(m):
        vol = _volumes(m["nodes"], m["tets"])
        n_air = int(np.sum(m["rho"] == 1.0e9))
        n_20 = int(np.sum(m["rho"] == 20.0))
        ok = (len(m["nodes"]) == nn and len(m["tets"]) == ne and abs(vol / 1.0e18 - 1.0) <= 1e-6
              and (n_air, n_20) == (air, earth))
        return ok, "%d nodes, %d elements, volume / (1000 km)^3 - 1 = %.1e, %d at 1e9, %d at 20 ohm-m" % (
            len(m["nodes"]), len(m["tets"]), vol / 1.0e18 - 1.0, n_air, n_20)

    shifted = dict(model)
    idx = np.arange(len(model["nodes"]), dtype=float)
    shifted["nodes"] = np.column_stack([idx, model["nodes"][:, 0], model["nodes"][:, 1]])
    C.fails_first(check, shifted)
    C.passes(check, model)


if __name__ == "__main__":
    C.main(globals())
