# -*- coding: utf-8 -*-
"""results.py - the Results tab: open a copied-back run folder or file and see the model, the fit, the convergence.

Phase 1 reads and plots; it launches nothing. 'Open folder...' (default runs/) and 'Open file...' fill one list:
model (resistivity_block_iter<N>.dat, opened in the 3D viewer on the run's mesh.dat), data fit
(result_<rank>_iter<N>.csv, the ranks of one N together: curves, misfit map, residual table) and convergence
(logs/run_*/femtic.cnv then femtic.cnv, merged by readers.read_cnv). EnSight and unknown files are not listed.
Z in the csv is in ohm with exp(-i omega t): mtcalc.rho_phase_ohm, as for observe.dat.

@author ben kay
:license: MIT
"""
from __future__ import annotations

import re
from pathlib import Path

import numpy as np
import pyqtgraph as pg
from PySide6 import QtCore, QtWidgets

from .. import config_io, mtcalc, readers, theme
from ..plots import RhoPhaseStack, SiteMap
from ..state import State
from .common import fill_table, new_table, open_viewer, set_enabled, viewer_missing

COMPS = ("xx", "xy", "yx", "yy")
GROUP_TITLES = {"model": "model", "fit": "data fit", "convergence": "convergence"}


class ResultsTab(QtWidgets.QWidget):
    """Run-output browser: list, model page, fit page, convergence page."""

    folder_opened = QtCore.Signal(str)

    def __init__(self, state: State, parent: QtWidgets.QWidget | None = None) -> None:
        super().__init__(parent)
        self.state = state
        self.folder: Path | None = None
        self.groups: dict = {"model": {}, "fit": {}, "convergence": []}
        self.names: dict[int, tuple[str, float, float]] = {}
        self.fit: dict | None = None
        self.mesh_path: Path | None = None
        self.block_path: Path | None = None
        self.open_folder_btn = QtWidgets.QPushButton("Open folder...")
        self.open_file_btn = QtWidgets.QPushButton("Open file...")
        for b, t in ((self.open_folder_btn, "List a copied-back run folder's model, fit and convergence files"),
                     (self.open_file_btn, "Open one resistivity_block_iter<N>.dat, result_<rank>_iter<N>.csv or "
                                          "femtic.cnv")):
            b.setToolTip(t + " (reads only; runs nothing)")
        self.where = QtWidgets.QLabel("Open a run folder copied back from Phoenix (RUNBOOK.md R5).")
        self.tree = QtWidgets.QTreeWidget()
        self.tree.setHeaderLabels(["file"])
        self.where.setWordWrap(True)
        self.pages = QtWidgets.QStackedWidget()
        hint = QtWidgets.QLabel("Select a model, a data fit or the convergence in the list.")
        hint.setWordWrap(True)
        self.pages.addWidget(hint)
        self.pages.addWidget(self._model_page())
        self.pages.addWidget(self._fit_page())
        self.pages.addWidget(self._cnv_page())
        top = QtWidgets.QHBoxLayout()
        for w in (self.open_folder_btn, self.open_file_btn):
            top.addWidget(w)
        top.addWidget(self.where, 1)
        split = QtWidgets.QSplitter(QtCore.Qt.Orientation.Horizontal)
        split.addWidget(self.tree)
        split.addWidget(self.pages)
        split.setSizes([300, 1100])
        lay = QtWidgets.QVBoxLayout(self)
        lay.addLayout(top)
        lay.addWidget(split, 1)
        self.open_folder_btn.clicked.connect(self.open_folder_dialog)
        self.open_file_btn.clicked.connect(self.open_file_dialog)
        self.tree.currentItemChanged.connect(lambda cur, _prev: self._show(cur))

    # ------------------------------------------------------------------ pages
    def _model_page(self) -> QtWidgets.QWidget:
        w = QtWidgets.QWidget()
        f = QtWidgets.QFormLayout(w)
        self.model_label = QtWidgets.QLabel()
        self.model_label.setWordWrap(True)
        self.mesh_label = QtWidgets.QLabel()
        self.mesh_label.setWordWrap(True)
        self.choose_mesh_btn = QtWidgets.QPushButton("Choose mesh.dat...")
        self.view_btn = QtWidgets.QPushButton("Open 3D viewer")
        f.addRow("model", self.model_label)
        f.addRow("mesh", self.mesh_label)
        f.addRow("", self.choose_mesh_btn)
        f.addRow("", self.view_btn)
        self.choose_mesh_btn.setToolTip("Pick the mesh.dat this model was computed on (default: mesh/vulcan_<MESH>/"
                                        "inversion/mesh.dat, MESH from the run's run.env); reads only, runs nothing")
        set_enabled(self.view_btn, "select a model (resistivity_block_iter<N>.dat) in the list first",
                    "3D view of the selected model on its mesh.dat (viewer3d.py; reads only, runs nothing)")
        self.choose_mesh_btn.clicked.connect(self._choose_mesh)
        self.view_btn.clicked.connect(lambda: open_viewer(self, self.mesh_path, self.block_path, self._stations()))
        return w

    def _fit_page(self) -> QtWidgets.QWidget:
        self.residuals = new_table()
        self.residuals.setToolTip("Site RMS = sqrt(mean _Res^2) over its bands and the eight Re/Im residuals")
        self.misfit_map = SiteMap()
        self.misfit_note = QtWidgets.QLabel()
        self.misfit_note.setWordWrap(True)
        self.fit_curves = RhoPhaseStack()
        self.fit_diag = QtWidgets.QCheckBox("show xx and yy")
        left = QtWidgets.QSplitter(QtCore.Qt.Orientation.Vertical)
        left.addWidget(self.residuals)
        mw = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(mw)
        v.addWidget(self.misfit_map)
        v.addWidget(self.misfit_note)
        left.addWidget(mw)
        right = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(right)
        v.addWidget(self.fit_curves)
        v.addWidget(self.fit_diag)
        split = QtWidgets.QSplitter(QtCore.Qt.Orientation.Horizontal)
        split.addWidget(left)
        split.addWidget(right)
        self.residuals.itemSelectionChanged.connect(self._residual_row)
        self.misfit_map.site_clicked.connect(lambda name: self.show_station(self._sta_of(name)))
        self.fit_diag.toggled.connect(lambda _v: self.show_station(self.station))
        self.station = 0
        return split

    def _cnv_page(self) -> QtWidgets.QWidget:
        w = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(w)
        self.rms_plot, self.obj_plot = pg.PlotWidget(), pg.PlotWidget()
        for p, label in ((self.rms_plot, "RMS"), (self.obj_plot, "ObjFunc")):
            p.showGrid(x=True, y=True, alpha=theme.GRID_ALPHA)
            p.setLabel("left", label)
            p.setLabel("bottom", "iteration")
            v.addWidget(p)
        self.obj_plot.setLogMode(y=True)
        self.obj_plot.setXLink(self.rms_plot)
        self.cnv_note = QtWidgets.QLabel()
        self.cnv_note.setWordWrap(True)
        v.addWidget(self.cnv_note)
        return w

    # ------------------------------------------------------------------ opening
    def reload(self) -> None:
        """Nothing depends on the config except the default mesh; re-scan the open folder."""
        if self.folder is not None and self.folder.is_dir():
            self.open_folder(self.folder, announce=False)

    def open_folder_dialog(self) -> None:
        """'Open folder...': a copied-back run folder (default runs/)."""
        path = QtWidgets.QFileDialog.getExistingDirectory(self, "Open a run folder", str(self.state.repo / "runs"))
        if path:
            self.open_folder(path)

    def open_file_dialog(self) -> None:
        """'Open file...': one model, result csv or femtic.cnv."""
        path, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Open a FEMTIC output", str(self.state.repo / "runs"),
                                                        "FEMTIC outputs (*.dat *.csv *.cnv*)")
        if path:
            self.open_file(path)

    def open_folder(self, path, announce: bool = True) -> None:
        """List the folder's model, fit and convergence files."""
        try:
            d = config_io.local_path(path)
        except config_io.ConfigError as e:
            QtWidgets.QMessageBox.warning(self, "Open folder", str(e))
            return
        if d != self.folder:
            self.mesh_path = None
        self.folder, self.groups = d, readers.scan_results(d)
        self._fill_tree()
        if announce:
            self.folder_opened.emit(str(d))

    def open_file(self, path) -> None:
        """List one recognised file (its folder supplies station_map.csv and run.env)."""
        try:
            p = config_io.local_path(path)
        except config_io.ConfigError as e:
            QtWidgets.QMessageBox.warning(self, "Open file", str(e))
            return
        groups: dict = {"model": {}, "fit": {}, "convergence": []}
        if (m := readers.BLOCK_RE.match(p.name)):
            groups["model"][int(m.group(1))] = p
        elif (m := readers.RESULT_RE.match(p.name)):
            groups["fit"][int(m.group(2))] = [p]
        elif p.name.startswith("femtic.cnv"):
            groups["convergence"] = [p]
        else:
            QtWidgets.QMessageBox.warning(self, "Open file", "%s is not a model, result csv or femtic.cnv" % p.name)
            return
        if p.parent != self.folder:
            self.mesh_path = None
        self.folder, self.groups = p.parent, groups
        self._fill_tree()

    def _fill_tree(self) -> None:
        self.names = {}
        smap = self.folder / "station_map.csv"
        if smap.is_file():
            for r in readers.read_station_map(smap):
                self.names[int(r["femtic_station_id"])] = (r["site_id"], float(r["y_east_km"]),
                                                           float(r["x_north_km"]))
        self.where.setText("%s%s" % (self.state.rel(self.folder), "" if self.names else
                                     " (no station_map.csv here: stations are shown by number, no map)"))
        self.tree.clear()
        g = self.groups
        for kind, entries in (("model", ["iteration %d" % n for n in g["model"]]),
                              ("fit", ["iteration %d (%d rank file%s)" % (n, len(v), "s" if len(v) > 1 else "")
                                       for n, v in g["fit"].items()]),
                              ("convergence", ["%d femtic.cnv file%s" % (len(g["convergence"]), "s"
                                                                        if len(g["convergence"]) > 1 else "")]
                               if g["convergence"] else [])):
            top = QtWidgets.QTreeWidgetItem([GROUP_TITLES[kind]])
            keys = list(g[kind]) if kind != "convergence" else [0] * len(entries)
            for text, key in zip(entries, keys):
                it = QtWidgets.QTreeWidgetItem([text])
                it.setData(0, QtCore.Qt.ItemDataRole.UserRole, (kind, key))
                top.addChild(it)
            self.tree.addTopLevelItem(top)
            top.setExpanded(True)
        self.pages.setCurrentIndex(0)

    def _show(self, item: QtWidgets.QTreeWidgetItem | None) -> None:
        data = item.data(0, QtCore.Qt.ItemDataRole.UserRole) if item else None
        if not data:
            return
        kind, key = data
        try:
            if kind == "model":
                self._show_model(key)
            elif kind == "fit":
                self._show_fit(key)
            else:
                self._show_cnv()
        except (readers.ReaderError, OSError, ValueError, IndexError) as e:
            QtWidgets.QMessageBox.warning(self, "Results", "Cannot read it: %s" % e)

    # ------------------------------------------------------------------ model
    def _stations(self) -> Path | None:
        p = self.folder / "station_map.csv" if self.folder else None
        return p if p is not None and p.is_file() else None

    def _default_mesh(self) -> Path | None:
        env = self.folder / "run.env" if self.folder else None
        m = re.search(r"^MESH=(v\d+)\s*$", env.read_text(encoding="utf-8"), re.M) if env and env.is_file() else None
        return self.state.repo / "mesh" / ("vulcan_%s" % m.group(1)) / "inversion" / "mesh.dat" if m else None

    def _show_model(self, n: int) -> None:
        self.block_path = self.groups["model"][n]
        if self.mesh_path is None or not self.mesh_path.is_file():
            self.mesh_path = self._default_mesh()
        self.model_label.setText(self.state.rel(self.block_path))
        self._update_model()
        self.pages.setCurrentIndex(1)

    def _update_model(self) -> None:
        m = self.mesh_path
        self.mesh_label.setText(self.state.rel(m) if m else "not known: no run.env MESH here; choose the mesh.dat")
        why = viewer_missing() or ("" if m and m.is_file() else "no mesh.dat at %s: choose it" % (
            self.state.rel(m) if m else "-"))
        set_enabled(self.view_btn, why, "3D view of %s on %s; a model of another mesh is refused with both element "
                    "counts" % (self.block_path.name if self.block_path else "-", m.name if m else "-"))

    def _choose_mesh(self) -> None:
        path, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Choose the run's mesh.dat",
                                                        str(self.state.repo / "mesh"), "FEMTIC mesh (mesh.dat)")
        if path:
            try:
                self.mesh_path = config_io.local_path(path)
            except config_io.ConfigError as e:
                QtWidgets.QMessageBox.warning(self, "Choose mesh", str(e))
            self._update_model()

    # ------------------------------------------------------------------ data fit
    def _name(self, sta: int) -> str:
        return self.names[sta][0] if sta in self.names else "#%d" % sta

    def _sta_of(self, name: str) -> int:
        return next((s for s, v in self.names.items() if v[0] == name), 0)

    def _show_fit(self, n: int) -> None:
        self.fit = readers.read_result_csv(self.groups["fit"][n])
        per = sorted(readers.site_misfit(self.fit), key=lambda r: -r["rms"])
        fill_table(self.residuals, ["site", "RMS", "worst |Res|", "at Hz", "component"],
                   [[self._name(r["sta"]), round(r["rms"], 3), round(r["worst"], 3), float("%.5g" % r["worst_hz"]),
                     r["worst_comp"]] for r in per], sortable=True)
        vmax = max((r["rms"] for r in per), default=1.0)
        overall = float(np.sqrt(np.mean(self.fit["res"] ** 2)))
        if self.names:
            self.misfit_map.set_sites({self._name(r["sta"]): self.names[r["sta"]][1:] for r in per
                                       if r["sta"] in self.names},
                                      {self._name(r["sta"]): theme.scale_colour(r["rms"], vmax) for r in per})
        else:
            self.misfit_map.set_sites({})
        self.misfit_note.setText("iteration %d: overall RMS %.6g over %d data lines; colour = site RMS, 0 (dark) to "
                                 "%.3g (yellow)%s" % (n, overall, len(self.fit["sta"]), vmax,
                                                      "" if self.names else "; no station_map.csv, no map"))
        self.pages.setCurrentIndex(2)
        self.show_station(per[0]["sta"] if per else 0)

    def _residual_row(self) -> None:
        rows = self.residuals.selectionModel().selectedRows()
        if rows:
            name = self.residuals.item(rows[0].row(), 0).text()
            self.show_station(int(name[1:]) if name.startswith("#") else self._sta_of(name))

    def show_station(self, sta: int) -> None:
        """Observed (points with error bars) and calculated (lines) rho_a and phase of one station."""
        self.station = sta
        self.fit_curves.clear()
        if self.fit is None or sta not in set(self.fit["sta"].tolist()):
            return
        k = self.fit["sta"] == sta
        f = self.fit["freq"][k]
        order = np.argsort(f)
        for i, comp in enumerate(COMPS):
            if comp not in (COMPS if self.fit_diag.isChecked() else ("xy", "yx")):
                continue
            obs, cal, sd = self.fit["obs"][k, i], self.fit["cal"][k, i], self.fit["sd"][k, 2 * i]
            ro, po = mtcalc.rho_phase_ohm(f, obs)
            rc, pc = mtcalc.rho_phase_ohm(f, cal)
            rerr, perr = mtcalc.error_bars(obs, sd, ro)
            if comp == "yx":
                po, pc = mtcalc.wrap_yx(po), mtcalc.wrap_yx(pc)
            self.fit_curves.add_points(1.0 / f, ro, po, rerr, perr, comp, "%s observed" % comp)
            self.fit_curves.add_curve(1.0 / f[order], rc[order], pc[order], theme.pen(comp), "%s calculated" % comp)
        self.misfit_map.set_selected(self._name(sta))

    # ------------------------------------------------------------------ convergence
    def _show_cnv(self) -> None:
        rows = readers.read_cnv(self.groups["convergence"])
        it = [r[0] for r in rows]
        self.rms_plot.clear()
        self.obj_plot.clear()
        self.rms_plot.plot(it, [r[6] for r in rows], pen=theme.pen("xy"), symbol="o", symbolBrush=theme.brush("xy"))
        self.obj_plot.plot(it, [r[7] for r in rows], pen=theme.pen("yx"), symbol="o", symbolBrush=theme.brush("yx"))
        self.cnv_note.setText("%d iteration(s) from %s; last RMS %s" % (
            len(rows), ", ".join(self.state.rel(p) for p in self.groups["convergence"]),
            "%.6g" % rows[-1][6] if rows else "-"))
        self.pages.setCurrentIndex(3)
