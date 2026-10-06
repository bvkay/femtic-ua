# -*- coding: utf-8 -*-
"""viewer3d.py - the 3D mesh and model viewer (pyvistaqt); the only module of the GUI that imports VTK.

VTK, pyvista and pyvistaqt are imported inside functions only, and no other module imports this one at load
time (tabs/common.py imports it when a 3D button is pressed), so the rest of the GUI and the headless smoke
test run without VTK. mesh.dat and resistivity_block_iter<N>.dat are read by readers.read_mesh / read_block,
thin calls into femtic_mesh.io.femtic (no second parser); TetGen2Femtic's .femtic.vtk with pyvista.read. Loading
runs in a QThread; the plotter is touched on the GUI thread only. Only the site area is shown, never the full
1000 km grid: the earth cells whose centroids
lie within +-12 km (x, y) and -2..10 km (z) of the centre, as a surface, three slices with sliders, a log10 rho
threshold, the sites of station_map.csv and one colour bar. Display axes: east, north, up = (y, x, -z) of
FEMTIC's frame, metres.

@author ben kay
:license: MIT
"""
from __future__ import annotations

import csv
from pathlib import Path

import numpy as np
from PySide6 import QtCore, QtWidgets

from . import readers, theme

HALF_KM = 12.0
Z_KM = (-2.0, 10.0)
AIR_RHO = 1.0e9
VTK_MISSING = ("The 3D viewer needs vtk, pyvista and pyvistaqt (environment-gui.yml); the rest of the GUI works "
               "without them.")


def read_model(mesh_path: str | Path, block_path: str | Path | None = None) -> dict:
    """Read a mesh (mesh.dat or TetGen2Femtic .vtk) and, for mesh.dat, an optional resistivity block file.

    Returns:
        {'nodes': (N, 3) FEMTIC frame (x north, y east, z down) in m, 'tets': (M, 4) int,
         'rho': (M,) ohm-m per element or None, 'cell': (M,) parameter cell per element or None}.

    Raises:
        readers.ReaderError: if the block file's element count differs from the mesh's (both numbers named).
    """
    p = Path(mesh_path)
    if p.suffix.lower() == ".vtk":
        import pyvista as pv                       # noqa: PLC0415 - VTK only on demand
        g = pv.read(str(p))
        tets = np.asarray(g.cells_dict[pv.CellType.TETRA])
        rho = g.cell_data["Resistivity[Ohm-m]"] if "Resistivity[Ohm-m]" in g.cell_data else None
        cell = g.cell_data["BlockSerial"] if "BlockSerial" in g.cell_data else None
        return {"nodes": np.asarray(g.points, dtype=float), "tets": tets,
                "rho": None if rho is None else np.asarray(rho, dtype=float),
                "cell": None if cell is None else np.asarray(cell)}
    nodes, tets = readers.read_mesh(p)
    out = {"nodes": nodes, "tets": tets, "rho": None, "cell": None}
    if block_path is not None:
        cell, rho = readers.read_block(block_path, len(tets))
        out["cell"], out["rho"] = cell, rho[cell]
    return out


def site_area_mask(model: dict, half_km: float = HALF_KM, z_km: tuple = Z_KM) -> np.ndarray:
    """Elements whose centroid lies in the site area box, air (1e9 ohm-m or cell 0) excluded."""
    nodes, tets = model["nodes"], model["tets"]
    keep = np.ones(len(tets), dtype=bool)
    for k, (lo, hi) in enumerate(((-half_km, half_km), (-half_km, half_km), z_km)):
        c = nodes[:, k][tets].mean(axis=1) / 1000.0
        keep &= (c >= lo) & (c <= hi)
    if model["rho"] is not None:
        keep &= model["rho"] < AIR_RHO
    elif model["cell"] is not None:
        keep &= model["cell"] != 0
    return keep


def build_grid(model: dict, mask: np.ndarray):
    """A pyvista UnstructuredGrid of the masked elements in display axes (east, north, up), metres.

    Cell data: 'log10_rho' (if the model has rho), 'cell' and 'cell_mod20' (if it has cells).
    """
    import pyvista as pv                           # noqa: PLC0415
    tets = model["tets"][mask]
    used, inv = np.unique(tets, return_inverse=True)
    nodes = model["nodes"][used]
    pts = np.column_stack([nodes[:, 1], nodes[:, 0], -nodes[:, 2]])
    grid = pv.UnstructuredGrid({pv.CellType.TETRA: inv.reshape(-1, 4)}, pts)
    if model["rho"] is not None:
        grid.cell_data["log10_rho"] = np.log10(model["rho"][mask])
    if model["cell"] is not None:
        grid.cell_data["cell"] = np.asarray(model["cell"][mask])
        grid.cell_data["cell_mod20"] = np.asarray(model["cell"][mask]) % 20
    return grid


def read_sites(station_map: str | Path | None) -> np.ndarray:
    """Site positions (east, north, up) in m from a prep station_map.csv; empty without a file."""
    if station_map is None or not Path(station_map).is_file():
        return np.zeros((0, 3))
    with open(station_map, encoding="utf-8", newline="") as fh:
        rows = list(csv.DictReader(fh))
    return np.array([[float(r["y_east_km"]) * 1000.0, float(r["x_north_km"]) * 1000.0, 10.0] for r in rows])


class _Loader(QtCore.QThread):
    """Reads the model and builds the display grid off the GUI thread."""

    loaded = QtCore.Signal(object, object, str)
    failed = QtCore.Signal(str)

    def __init__(self, mesh_path, block_path, station_map, parent=None) -> None:
        super().__init__(parent)
        self.args = (mesh_path, block_path, station_map)

    def run(self) -> None:  # noqa: D102 - QThread entry
        import time
        t0 = time.perf_counter()
        try:
            model = read_model(self.args[0], self.args[1])
            mask = site_area_mask(model)
            grid = build_grid(model, mask)
            sites = read_sites(self.args[2])
        except Exception as e:                    # shown to the student, never raised into Qt
            self.failed.emit("%s: %s" % (type(e).__name__, e))
            return
        self.loaded.emit(grid, sites, "%d of %d elements in the site area, %d sites; loaded in %.1f s" % (
            grid.n_cells, len(model["tets"]), len(sites), time.perf_counter() - t0))


def _surface(grid):
    """The outer surface of a cell set (pyvista's dataset_surface filter)."""
    return grid.extract_surface(algorithm="dataset_surface")


def _slider(lo: int, hi: int, value: int) -> QtWidgets.QSlider:
    s = QtWidgets.QSlider(QtCore.Qt.Orientation.Horizontal, minimum=lo, maximum=hi, value=value)
    s.setTracking(False)                           # redraw on release only: slicing ~1 M cells takes a moment
    return s


class ViewerWindow(QtWidgets.QMainWindow):
    """A pyvistaqt window: site-area surface, three slices, a threshold surface, sites and a colour bar."""

    def __init__(self, mesh_path, block_path=None, station_map=None, parent=None) -> None:
        super().__init__(parent)
        try:
            import pyvista as pv                   # noqa: PLC0415 - VTK is imported here, never at module load
            from pyvistaqt import QtInteractor     # noqa: PLC0415
        except ImportError as e:
            raise RuntimeError("%s (%s)" % (VTK_MISSING, e)) from None
        self.pv = pv
        self.grid = None
        self.setWindowTitle("3D: %s%s" % (Path(mesh_path).name, " + %s" % Path(block_path).name if block_path
                                         else ""))
        self.resize(1300, 850)
        self.plotter = QtInteractor(self)
        self.plotter.set_background(theme.BASE)
        panel = QtWidgets.QWidget()
        f = QtWidgets.QFormLayout(panel)
        self.colour_by = QtWidgets.QComboBox()
        self.colour_by.addItems(["log10 resistivity", "parameter cell"])
        self.show_block = QtWidgets.QCheckBox("site-area surface")
        self.show_block.setChecked(True)
        self.sl = {"east": _slider(-120, 120, 0), "north": _slider(-120, 120, 0), "depth": _slider(0, 100, 20)}
        self.thr = _slider(-10, 50, 30)
        self.status = QtWidgets.QLabel("loading %s ..." % Path(mesh_path).name)
        self.status.setWordWrap(True)
        f.addRow("colour", self.colour_by)
        f.addRow(self.show_block)
        f.addRow("slice east (x0.1 km)", self.sl["east"])
        f.addRow("slice north (x0.1 km)", self.sl["north"])
        f.addRow("slice depth (x0.1 km)", self.sl["depth"])
        f.addRow("threshold log10 rho (x0.1)", self.thr)
        f.addRow(self.status)
        split = QtWidgets.QSplitter()
        split.addWidget(self.plotter.interactor)
        split.addWidget(panel)
        split.setStretchFactor(0, 4)
        self.setCentralWidget(split)
        for w in (*self.sl.values(), self.thr):
            w.valueChanged.connect(lambda _v: self.draw())
        self.colour_by.currentIndexChanged.connect(lambda _i: self.draw())
        self.show_block.toggled.connect(lambda _v: self.draw())
        self._loader = _Loader(mesh_path, block_path, station_map, self)
        self._loader.loaded.connect(self._loaded)
        self._loader.failed.connect(lambda msg: theme.set_status(self.status, msg, "error"))
        self._loader.start()

    def _loaded(self, grid, sites, text: str) -> None:
        self.grid, self.sites = grid, sites
        theme.set_status(self.status, text, "ok")
        self.draw()
        self.plotter.view_isometric()
        self.plotter.reset_camera()

    def _scalars(self) -> tuple[str | None, dict]:
        g = self.grid
        if self.colour_by.currentIndex() == 0 and "log10_rho" in g.cell_data:
            lo, hi = float(g.cell_data["log10_rho"].min()), float(g.cell_data["log10_rho"].max())
            clim = [lo - 1.0, hi + 1.0] if hi - lo < 1e-6 else [lo, hi]
            return "log10_rho", {"cmap": "jet_r", "clim": clim}
        if "cell_mod20" in g.cell_data:
            return "cell_mod20", {"cmap": "tab20", "clim": [0, 19]}
        return None, {"color": theme.SITE}

    def draw(self) -> None:
        """(Re)draw every actor from the current controls; actors are replaced by name."""
        if self.grid is None:
            return
        p, g = self.plotter, self.grid
        name, kw = self._scalars()
        bar = {"title": "log10 rho (ohm-m)"} if name == "log10_rho" else None
        for a in ("block", "slice_x", "slice_y", "slice_z", "threshold", "sites"):
            p.remove_actor(a, render=False)
        if p.scalar_bars:
            p.remove_scalar_bar()
        if self.show_block.isChecked():
            p.add_mesh(_surface(g), scalars=name, opacity=0.35, name="block", show_scalar_bar=False, **kw)
        x0, y0 = self.sl["east"].value() * 100.0, self.sl["north"].value() * 100.0
        z0 = -self.sl["depth"].value() * 100.0
        for nm, normal in (("slice_x", "x"), ("slice_y", "y"), ("slice_z", "z")):
            s = g.slice(normal=normal, origin=(x0, y0, z0))
            if s.n_cells:
                p.add_mesh(s, scalars=name, name=nm, show_scalar_bar=bar is not None and nm == "slice_z",
                           scalar_bar_args=bar or {}, **kw)
        if "log10_rho" in g.cell_data:
            t = g.threshold(value=self.thr.value() / 10.0, scalars="log10_rho")
            if t.n_cells:
                p.add_mesh(_surface(t), scalars=name, name="threshold", show_scalar_bar=False, **kw)
        if len(self.sites):
            p.add_points(self.sites, color=theme.SITE_SELECTED, point_size=9, render_points_as_spheres=True,
                         name="sites")
        p.render()

    def closeEvent(self, event) -> None:  # noqa: N802 (Qt name)
        """Wait for the loader, then release the VTK window."""
        self._loader.wait(60000)
        self.plotter.close()
        super().closeEvent(event)
