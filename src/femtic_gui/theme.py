# -*- coding: utf-8 -*-
"""theme.py - the dark Fusion theme and every colour, pen and status colour of the GUI.

apply() runs before the main window exists. Tabs never hard-code a colour: they use the names here
(magnetic blue, electric red, one colour per impedance component, status colours). No stylesheets.

@author ben kay
:license: MIT
"""
from __future__ import annotations

import pyqtgraph as pg
from PySide6 import QtCore, QtGui, QtWidgets

WINDOW = "#2b2b2b"
BASE = "#1f1f1f"
ALT_BASE = "#262626"
TEXT = "#dcdcdc"
DISABLED_TEXT = "#7a7a7a"
HIGHLIGHT = "#3d6fa5"
LINK = "#6fa8dc"
GRID_ALPHA = 0.25

ELECTRIC_RED = "#e0574f"
MAGNETIC_BLUE = "#4f8fd8"
COMPONENT = {"xx": "#9ccc65", "xy": ELECTRIC_RED, "yx": MAGNETIC_BLUE, "yy": "#ffb74d"}
SITE = "#bdbdbd"
SITE_SELECTED = "#ffd54f"
BAND_SELECTED = "#ffd54f"
STATUS = {"ok": "#7cc47c", "warn": "#e0b04f", "error": "#ef6a6a", "info": TEXT}


class _Style(QtWidgets.QProxyStyle):
    """Fusion with a quicker tooltip: every button explains itself in its tooltip."""

    def styleHint(self, hint, option=None, widget=None, returnData=None):  # noqa: N802 (Qt name)
        if hint == QtWidgets.QStyle.StyleHint.SH_ToolTip_WakeUpDelay:
            return 400
        return super().styleHint(hint, option, widget, returnData)


def apply(app: QtWidgets.QApplication) -> None:
    """Set the dark Fusion palette on the application and pyqtgraph's colours."""
    app.setStyle(_Style("Fusion"))
    pal = QtGui.QPalette()
    role = QtGui.QPalette.ColorRole
    for r, c in ((role.Window, WINDOW), (role.WindowText, TEXT), (role.Base, BASE), (role.AlternateBase, ALT_BASE),
                 (role.ToolTipBase, BASE), (role.ToolTipText, TEXT), (role.Text, TEXT), (role.Button, WINDOW),
                 (role.ButtonText, TEXT), (role.BrightText, STATUS["error"]), (role.Highlight, HIGHLIGHT),
                 (role.HighlightedText, "#ffffff"), (role.Link, LINK), (role.PlaceholderText, DISABLED_TEXT)):
        pal.setColor(r, QtGui.QColor(c))
    for r in (role.WindowText, role.Text, role.ButtonText):
        pal.setColor(QtGui.QPalette.ColorGroup.Disabled, r, QtGui.QColor(DISABLED_TEXT))
    app.setPalette(pal)
    pg.setConfigOptions(background=BASE, foreground=TEXT, antialias=True)


def pen(component: str, dashed: bool = False, width: float = 2.0) -> QtGui.QPen:
    """The pen of an impedance component ('xx', 'xy', 'yx', 'yy'); dashed for the unrotated EDI frame."""
    style = QtCore.Qt.PenStyle.DashLine if dashed else QtCore.Qt.PenStyle.SolidLine
    return pg.mkPen(COMPONENT[component], width=width, style=style)


def brush(name: str) -> QtGui.QBrush:
    """A brush from a colour constant of this module or a component name."""
    return pg.mkBrush(COMPONENT.get(name, name))


def colour(name: str) -> QtGui.QColor:
    """A QColor from a status name ('ok', 'warn', 'error', 'info') or a colour constant."""
    return QtGui.QColor(STATUS.get(name, name))


def set_status(label: QtWidgets.QLabel, text: str, kind: str = "info") -> None:
    """Show text on a status label in the colour of kind ('ok', 'warn', 'error', 'info')."""
    pal = label.palette()
    pal.setColor(QtGui.QPalette.ColorRole.WindowText, colour(kind))
    label.setPalette(pal)
    label.setText(text)


def mono_font() -> QtGui.QFont:
    """The fixed-width font of the console and the file viewers."""
    f = QtGui.QFontDatabase.systemFont(QtGui.QFontDatabase.SystemFont.FixedFont)
    f.setPointSize(9)
    return f


def scale_colour(value: float, vmax: float) -> QtGui.QColor:
    """A colour for value on 0..vmax (viridis, clipped), for the misfit map."""
    x = 0.0 if vmax <= 0 else min(max(value / vmax, 0.0), 1.0)
    return pg.colormap.get("viridis").map(x, mode="qcolor")
