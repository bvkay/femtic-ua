# -*- coding: utf-8 -*-
"""plots.py - the shared pyqtgraph widgets: the site map and the linked apparent-resistivity / phase stack.

The stack plots log10 values with logarithmic axis labels (the data are transformed here, so error bars stay
correct), a fixed 72 px left axis and the phase plot's x axis linked to the resistivity plot's.
The site map plots east across and north up in km about the survey centre with the aspect locked to 1:1 (UTM).

@author ben kay
:license: MIT
"""
from __future__ import annotations

import numpy as np
import pyqtgraph as pg
from PySide6 import QtCore, QtWidgets

from . import theme

LEFT_AXIS_PX = 72


class SiteMap(pg.PlotWidget):
    """Sites as points with their ids; clicking a point emits site_clicked(id)."""

    site_clicked = QtCore.Signal(str)

    def __init__(self, parent: QtWidgets.QWidget | None = None) -> None:
        super().__init__(parent)
        self.setAspectLocked(True)
        self.showGrid(x=True, y=True, alpha=theme.GRID_ALPHA)
        self.setLabel("bottom", "east (km)")
        self.setLabel("left", "north (km)")
        self.getAxis("left").setWidth(LEFT_AXIS_PX)
        self._xy: dict[str, tuple[float, float]] = {}
        self._labels: list[pg.TextItem] = []
        self._points = pg.ScatterPlotItem(size=8, pen=pg.mkPen(None), brush=theme.brush(theme.SITE))
        self._points.sigClicked.connect(self._clicked)
        self._sel = pg.ScatterPlotItem(size=14, pen=pg.mkPen(theme.SITE_SELECTED, width=2), brush=pg.mkBrush(None))
        self.addItem(self._points)
        self.addItem(self._sel)

    def set_sites(self, sites: dict[str, tuple[float, float]], colours: dict | None = None) -> None:
        """Show sites {id: (east_km, north_km)}; colours optionally {id: QColor or colour name}."""
        for t in self._labels:
            self.removeItem(t)
        self._labels = []
        self._xy = dict(sites)
        ids = list(sites)
        spots = []
        for i in ids:
            b = theme.brush(theme.SITE) if not colours or i not in colours else pg.mkBrush(colours[i])
            spots.append({"pos": sites[i], "data": i, "brush": b})
        self._points.setData(spots)
        for i in ids:
            t = pg.TextItem(i, color=theme.TEXT, anchor=(-0.15, 0.5))
            t.setPos(*sites[i])
            self.addItem(t)
            self._labels.append(t)
        self.autoRange()

    def set_selected(self, sid: str) -> None:
        """Ring the selected site."""
        self._sel.setData(pos=[self._xy[sid]] if sid in self._xy else [])

    def _clicked(self, _item, points, *_args) -> None:
        if len(points):
            self.site_clicked.emit(str(points[0].data()))


class RhoPhaseStack(QtWidgets.QWidget):
    """Apparent resistivity over phase, both against period, x axes linked."""

    def __init__(self, parent: QtWidgets.QWidget | None = None) -> None:
        super().__init__(parent)
        lay = QtWidgets.QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        self.rho = pg.PlotWidget()
        self.phase = pg.PlotWidget()
        for p in (self.rho, self.phase):
            p.showGrid(x=True, y=True, alpha=theme.GRID_ALPHA)
            p.getAxis("left").setWidth(LEFT_AXIS_PX)
            p.getAxis("bottom").setLogMode(True)
            lay.addWidget(p)
        self.rho.getAxis("left").setLogMode(True)
        self.rho.setLabel("left", "rho_a (ohm-m)")
        self.phase.setLabel("left", "phase (deg)")
        self.phase.setLabel("bottom", "period (s)")
        self.phase.setXLink(self.rho)
        self.legend = self.rho.addLegend(offset=(-10, 10))

    def clear(self) -> None:
        """Remove every curve, point and line."""
        self.rho.clear()
        self.phase.clear()
        self.legend.clear()

    def add_curve(self, period, rho, phase, pen, name: str | None = None) -> None:
        """Lines of rho_a and phase against period (non-finite or non-positive values are skipped)."""
        lp, lr, ph = self._log(period, rho, phase)
        self.rho.plot(lp, lr, pen=pen, name=name, connect="finite")
        self.phase.plot(lp, ph, pen=pen, connect="finite")

    def add_points(self, period, rho, phase, rho_err, phase_err, colour: str, name: str | None = None) -> None:
        """Points with error bars (rho_err in ohm-m, phase_err in degrees); non-finite points are skipped."""
        lp, lr, ph = self._log(period, rho, phase)
        r = np.asarray(rho, dtype=float)
        e = np.asarray(rho_err, dtype=float)
        pe = np.asarray(phase_err, dtype=float)
        ok = np.isfinite(lp) & np.isfinite(lr) & np.isfinite(ph) & np.isfinite(e) & np.isfinite(pe)
        lp, lr, ph, r, e, pe = lp[ok], lr[ok], ph[ok], r[ok], e[ok], pe[ok]
        with np.errstate(divide="ignore", invalid="ignore"):
            top = np.log10(r + e) - lr
            bot = lr - np.log10(np.where(r - e > 0, r - e, np.nan))
        bot = np.where(np.isfinite(bot), bot, 1.0)
        b = theme.brush(colour)
        self.rho.addItem(pg.ErrorBarItem(x=lp, y=lr, top=top, bottom=bot, pen=pg.mkPen(theme.COMPONENT.get(
            colour, colour))))
        self.rho.plot(lp, lr, pen=None, symbol="o", symbolSize=5, symbolBrush=b, symbolPen=None, name=name)
        self.phase.addItem(pg.ErrorBarItem(x=lp, y=ph, top=pe, bottom=pe, pen=pg.mkPen(theme.COMPONENT.get(
            colour, colour))))
        self.phase.plot(lp, ph, pen=None, symbol="o", symbolSize=5, symbolBrush=b, symbolPen=None)

    def add_period_lines(self, periods) -> None:
        """Dotted vertical lines at the given periods (the selected bands)."""
        pen = pg.mkPen(theme.BAND_SELECTED, width=1, style=QtCore.Qt.PenStyle.DotLine)
        for t in periods:
            for p in (self.rho, self.phase):
                p.addItem(pg.InfiniteLine(pos=float(np.log10(t)), angle=90, pen=pen))

    @staticmethod
    def _log(period, rho, phase):
        t = np.asarray(period, dtype=float)
        r = np.asarray(rho, dtype=float)
        with np.errstate(divide="ignore", invalid="ignore"):
            lr = np.where(r > 0, np.log10(r), np.nan)
        return np.log10(t), lr, np.asarray(phase, dtype=float)
