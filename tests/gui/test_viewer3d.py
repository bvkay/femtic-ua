# -*- coding: utf-8 -*-
"""test_viewer3d.py - the 3D viewer window builds its scene (offscreen; rendering itself is not tested).

Opens viewer3d.ViewerWindow on the small chain_proof mesh of Ben's checkout (27,501 tets) with its block file and
the v2_rot stations, waits for the loader thread and checks the actors the window draws. The offscreen Qt
platform has no OpenGL, so pixels are never looked at: the M5 demo on the PC's screen is the rendering check.
NOT RUN without the mesh (FEMTIC_MAIN) or without VTK.

    python tests/gui/test_viewer3d.py

@author ben kay
:license: MIT
"""
from __future__ import annotations

import importlib.util
import os
import sys
import time

os.environ["QT_QPA_PLATFORM"] = "offscreen"
import _common as C  # noqa: E402
from PySide6 import QtWidgets  # noqa: E402

APP = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
EXC: list = []
sys.excepthook = lambda t, v, tb: EXC.append("%s: %s" % (t.__name__, v))
CHAIN = C.MAIN / "mesh" / "chain_proof"
V2_BLOCK = C.MAIN / "mesh" / "vulcan_v2" / "inversion" / "resistivity_block_iter0.dat"
STATIONS = C.REPO / "mesh" / "vulcan_v2_rot" / "inversion" / "station_map.csv"
WANT = {"block", "slice_x", "slice_y", "slice_z", "threshold", "sites"}


def test_viewer_builds_its_scene():
    """This test fails unless the viewer, opened on chain_proof's mesh.dat and its own block file, loads the site
    area (5,830 of 27,501 elements) and draws the surface, three slices, the threshold surface and the sites, in
    both colour modes, without an exception. Failing case: v2's block file, whose element count is not this
    mesh's (the window must say so and draw nothing)."""
    if any(importlib.util.find_spec(m) is None for m in ("vtk", "pyvista", "pyvistaqt")):
        raise C.NotRun("VTK is not installed")
    if not (CHAIN / "mesh.dat").is_file() or not V2_BLOCK.is_file():
        raise C.NotRun("no %s (set FEMTIC_MAIN to Ben's checkout)" % CHAIN)
    from femtic_gui import viewer3d

    def check(block):
        w = viewer3d.ViewerWindow(CHAIN / "mesh.dat", block, STATIONS)
        w.thr.setValue(15)                          # log10 rho 1.5: the 100 ohm-m earth is above it
        t0 = time.perf_counter()
        while w.grid is None and "Error" not in w.status.text() and time.perf_counter() - t0 < 60:
            APP.processEvents()
            time.sleep(0.02)
        actors = set(w.plotter.actors) & WANT if w.grid is not None else set()
        w.colour_by.setCurrentIndex(1)
        APP.processEvents()
        actors_cell = set(w.plotter.actors) & WANT if w.grid is not None else set()
        n = w.grid.n_cells if w.grid is not None else 0
        status = w.status.text()
        w.close()
        ok = n == 5830 and actors == WANT and actors_cell == WANT and not EXC
        return ok, "%d cells; actors %s; exceptions %s; status %r" % (n, sorted(actors), EXC, status[:90])

    C.fails_first(check, V2_BLOCK)
    C.passes(check, CHAIN / "resistivity_block_iter0.dat")


if __name__ == "__main__":
    C.main(globals())
