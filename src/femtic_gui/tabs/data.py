# -*- coding: utf-8 -*-
"""data.py - the Data tab: choose error floors and bands, see what they do to the data, and run prep.

Left: the sites (paths.coords_file and the EDIs, read by prep's own readers) and every EDI band with its site
count, candidate flag (as prep's check C05 builds it) and selected flag (prep's select_bands). Middle: the site
map and the apparent resistivity and phase of the selected site, EDI frame dashed and rotated into the mesh
frame solid (prep's rotate_Z), with the selected bands as dotted lines. Right: DataPanel (data_panel.py).
Nothing here writes a file except through State.set_value / Save as, and nothing runs but prep_vulcan.py.

@author ben kay
:license: MIT
"""
from __future__ import annotations

import numpy as np
from PySide6 import QtCore, QtWidgets

from .. import mtcalc, prep_api, theme
from ..plots import RhoPhaseStack, SiteMap
from ..state import State
from .common import fill_table, new_table
from .data_panel import DataPanel

COMPS = ("xx", "xy", "yx", "yy")


class DataTab(QtWidgets.QWidget):
    """Sites, bands, map, curves and the control column."""

    def __init__(self, state: State, parent: QtWidgets.QWidget | None = None) -> None:
        super().__init__(parent)
        self.state = state
        self.chosen: list[float] = []
        self.sites = new_table()
        self.sites.setToolTip("Sites of paths.coords_file; bands = unmasked bands in the site's EDI")
        self.bands = new_table()
        self.bands.setToolTip("Every EDI band: candidate = unmasked at every site (require_all_sites), as prep's "
                              "check C05; selected = prep's select_bands rule")
        self.band_summary = QtWidgets.QLabel()
        self.band_summary.setWordWrap(True)
        self.map = SiteMap()
        self.curves = RhoPhaseStack()
        self.diag = QtWidgets.QCheckBox("show xx and yy")
        self.panel = DataPanel(state)

        left = QtWidgets.QSplitter(QtCore.Qt.Orientation.Vertical)
        left.addWidget(self._boxed("Sites", self.sites))
        bw = self._boxed("Bands", self.bands)
        bw.layout().addWidget(self.band_summary)
        left.addWidget(bw)
        middle = QtWidgets.QSplitter(QtCore.Qt.Orientation.Vertical)
        middle.addWidget(self.map)
        cw = self._boxed("Selected site (EDI frame dashed, rotated solid)", self.curves)
        cw.layout().addWidget(self.diag)
        middle.addWidget(cw)
        right = QtWidgets.QScrollArea()
        right.setWidgetResizable(True)
        right.setWidget(self.panel)
        split = QtWidgets.QSplitter(QtCore.Qt.Orientation.Horizontal)
        for w, stretch in ((left, 3), (middle, 4), (right, 3)):
            split.addWidget(w)
            split.setStretchFactor(split.count() - 1, stretch)
        split.setSizes([420, 640, 440])
        lay = QtWidgets.QVBoxLayout(self)
        lay.addWidget(split)

        self.sites.itemSelectionChanged.connect(self._table_site)
        self.map.site_clicked.connect(state.select_site)
        state.site_changed.connect(self.show_site)
        state.edited.connect(self.refresh)
        self.diag.toggled.connect(lambda _v: self._draw_curves())

    @staticmethod
    def _boxed(title: str, w: QtWidgets.QWidget) -> QtWidgets.QWidget:
        box = QtWidgets.QGroupBox(title)
        v = QtWidgets.QVBoxLayout(box)
        v.setContentsMargins(4, 4, 4, 4)
        v.addWidget(w)
        return box

    def reload(self) -> None:
        """Refill everything from the State's config and inputs."""
        sv = self.state.survey
        if sv is None:
            return
        n_band = {sid: int(np.sum(e["ok"])) for sid, e in sv.edis.items()}
        rows = []
        for sid, east, north, elev in sv.sites:
            e = sv.edis.get(sid)
            f = e["freq"][e["ok"]] if e is not None else np.array([])
            rows.append([sid, round(east, 4), round(north, 4), round(elev, 4), n_band.get(sid, 0),
                         float("%.5g" % f.max()) if f.size else "", float("%.5g" % f.min()) if f.size else ""])
        fill_table(self.sites, ["id", "east km", "north km", "elev km", "bands", "f max Hz", "f min Hz"], rows,
                   sortable=True)
        e0, n0 = sv.origin
        self.map.set_sites({s[0]: (s[1] - e0, s[2] - n0) for s in sv.sites})
        self.panel.reload()
        self.refresh()
        self.show_site(self.state.site)

    def refresh(self) -> None:
        """Recompute the selected bands, the band table and the floor readout from the current values."""
        s, sv = self.state, self.state.survey
        if sv is None:
            return
        req = bool(s.get("frequencies.require_all_sites", True))
        try:
            self.chosen = prep_api.select(sv, float(s.get("frequencies.fmax_hz")), float(s.get("frequencies.fmin_hz")),
                                          float(s.get("frequencies.per_decade")), s.get("frequencies.explicit_hz"), req)
            err = ""
        except prep_api.PrepFailure as e:
            self.chosen, err = [], str(e)
        n = len(sv.edis)
        table = prep_api.band_table(sv)
        cands = prep_api.candidates(sv, req)
        sel = set(self.chosen)
        fill_table(self.bands, ["f Hz", "T s", "sites", "candidate", "selected"],
                   [[float("%.6g" % f), float("%.6g" % (1 / f)), "%d/%d" % (k, n), "yes" if (k == n or not req)
                     else "", "yes" if f in sel else ""] for f, k in table])
        for r, (f, _k) in enumerate(table):
            if f in sel:
                for c in range(5):
                    self.bands.item(r, c).setForeground(theme.colour(theme.BAND_SELECTED))
        theme.set_status(self.band_summary, err or "%d bands in the EDIs, %d candidates, %d selected" % (
            len(table), len(cands), len(self.chosen)), "error" if err else "info")
        counts, total = prep_api.floor_counts(sv, self.chosen, [float(v) for v in s.get("data.error_floor_Z")])
        self.panel.show_floor_counts(counts, total)
        self._draw_curves()

    def _table_site(self) -> None:
        rows = self.sites.selectionModel().selectedRows()
        if rows:
            self.state.select_site(self.sites.item(rows[0].row(), 0).text())

    def show_site(self, sid: str) -> None:
        """Select sid in the table and on the map, and draw its curves."""
        for r in range(self.sites.rowCount()):
            if self.sites.item(r, 0).text() == sid:
                self.sites.blockSignals(True)
                self.sites.selectRow(r)
                self.sites.blockSignals(False)
                break
        self.map.set_selected(sid)
        self._draw_curves()

    def _draw_curves(self) -> None:
        sv, sid = self.state.survey, self.state.site
        self.curves.clear()
        if sv is None or sid not in sv.edis:
            return
        e = sv.edis[sid]
        ok = e["ok"]
        f = e["freq"][ok]
        comps = COMPS if self.diag.isChecked() else ("xy", "yx")
        rotated = sv.angles.get(sid, 0.0) != 0.0
        for k, comp in enumerate(COMPS):
            if comp not in comps:
                continue
            frames = [("rotated %+g deg" % sv.angles[sid], sv.zrot[sid][ok, k], False)] if rotated else []
            frames.append(("EDI frame", e["z"][comp.upper()][ok], rotated))
            for name, z, dashed in frames:
                rho, ph = mtcalc.rho_phase_edi(f, z)
                if comp == "yx":
                    ph = mtcalc.wrap_yx(ph)
                self.curves.add_curve(1.0 / f, rho, ph, theme.pen(comp, dashed=dashed),
                                      "%s%s %s" % (comp, " (+180 deg)" if comp == "yx" else "", name))
        self.curves.add_period_lines([1.0 / x for x in self.chosen])
