# -*- coding: utf-8 -*-
"""common.py - helpers the tabs share: read-only text windows, table filling and the lazy 3D viewer launch.

The 3D viewer (viewer3d.py, the only module that imports VTK) is imported here only when a student presses a
3D button; viewer_missing() checks for VTK with importlib.util.find_spec, which does not import it.

@author ben kay
:license: MIT
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

from PySide6 import QtCore, QtWidgets

from .. import theme

_OPEN_WINDOWS: list[QtWidgets.QWidget] = []
VIEWER_MODULES = ("vtk", "vtkmodules", "pyvista", "pyvistaqt", "femtic_mesh")   # pyvista imports vtkmodules


def viewer_missing() -> str:
    """'' if the 3D viewer can run, else the reason (which module is missing), for a disabled button's tooltip."""
    missing = []
    for m in VIEWER_MODULES:
        try:
            if importlib.util.find_spec(m) is None:
                missing.append(m)
        except (ImportError, ValueError):
            missing.append(m)
    if not missing:
        return ""
    return ("3D viewer unavailable: %s not installed in this Python (environment-gui.yml); the rest of the GUI "
            "works without it" % ", ".join(missing))


def open_viewer(parent: QtWidgets.QWidget, mesh_path: Path, block_path: Path | None = None,
                station_map: Path | None = None) -> QtWidgets.QWidget | None:
    """Import viewer3d now and open a viewer window on a mesh (and optional model and stations).

    Returns:
        The window, or None if VTK is missing (a warning says why).
    """
    why = viewer_missing()
    if why:
        QtWidgets.QMessageBox.warning(parent, "3D viewer", why)
        return None
    try:                                             # find_spec cannot see a broken VTK DLL or a missing OpenGL
        from .. import viewer3d                      # noqa: PLC0415 - imported on demand only
        w = viewer3d.ViewerWindow(mesh_path, block_path, station_map)
    except (ImportError, OSError, RuntimeError) as e:
        QtWidgets.QMessageBox.warning(parent, "3D viewer", "3D viewer unavailable: %s" % e)
        return None
    _keep(w)
    w.show()
    return w


def _keep(w: QtWidgets.QWidget) -> None:
    _OPEN_WINDOWS.append(w)
    w.setAttribute(QtCore.Qt.WidgetAttribute.WA_DeleteOnClose)
    w.destroyed.connect(lambda *_: _OPEN_WINDOWS.remove(w) if w in _OPEN_WINDOWS else None)


def show_text(parent: QtWidgets.QWidget | None, title: str, path: Path) -> QtWidgets.QWidget:
    """Open a non-modal read-only window on a text file (Markdown rendered for .md)."""
    w = QtWidgets.QWidget(parent, QtCore.Qt.WindowType.Window)
    w.setWindowTitle(title)
    w.resize(900, 700)
    lay = QtWidgets.QVBoxLayout(w)
    lay.addWidget(QtWidgets.QLabel(str(path)))
    view = QtWidgets.QTextBrowser()
    view.setOpenLinks(False)
    try:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError as e:
        text = "cannot read %s: %s" % (path, e)
    if str(path).lower().endswith(".md"):
        view.setMarkdown(text)
    else:
        view.setFont(theme.mono_font())
        view.setPlainText(text)
    lay.addWidget(view)
    w.text_view = view
    _keep(w)
    w.show()
    return w


def fill_table(table: QtWidgets.QTableWidget, headers: list[str], rows: list[list], sortable: bool = False) -> None:
    """Fill a read-only table (signals blocked while filling); numbers sort as numbers."""
    table.blockSignals(True)
    table.setSortingEnabled(False)
    table.clear()
    table.setColumnCount(len(headers))
    table.setHorizontalHeaderLabels(headers)
    table.setRowCount(len(rows))
    for r, row in enumerate(rows):
        for c, v in enumerate(row):
            it = QtWidgets.QTableWidgetItem()
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                it.setData(QtCore.Qt.ItemDataRole.DisplayRole, v)
            else:
                it.setText("" if v is None else str(v))
            it.setFlags(it.flags() & ~QtCore.Qt.ItemFlag.ItemIsEditable)
            table.setItem(r, c, it)
    table.setSortingEnabled(sortable)
    table.resizeColumnsToContents()
    table.blockSignals(False)


def new_table(parent: QtWidgets.QWidget | None = None) -> QtWidgets.QTableWidget:
    """A single-row-select, read-only table as every tab uses it."""
    t = QtWidgets.QTableWidget(parent)
    t.setSelectionBehavior(QtWidgets.QAbstractItemView.SelectionBehavior.SelectRows)
    t.setSelectionMode(QtWidgets.QAbstractItemView.SelectionMode.SingleSelection)
    t.setAlternatingRowColors(True)
    t.verticalHeader().setVisible(False)
    t.horizontalHeader().setStretchLastSection(True)
    return t


def set_enabled(button: QtWidgets.QAbstractButton, why_not: str, tooltip: str) -> None:
    """Enable a button with its tooltip (the command it runs), or disable it with the reason first."""
    button.setEnabled(not why_not)
    button.setToolTip(tooltip if not why_not else "Disabled: %s\n\n%s" % (why_not, tooltip))
