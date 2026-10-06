# -*- coding: utf-8 -*-
"""femtic.py - the FEMTIC tab: every control.dat key prep writes, what it does and where that is stated.

One row per key in femticPy's order (femticPy.py, write_inversion_control). Four rows are the config's to
edit (inversion.TRADE_OFF_PARAM, CONVERGE, ALPHA_WEIGHT, BOTTOM_RESISTIVITY); every other row is read-only and
says why. The GUI never writes control.dat: prep does, through femticPy, and its check C14 verifies the file.
The pane on the right shows the control.dat prep wrote into paths.run_dir/inversion/.

@author ben kay
:license: MIT
"""
from __future__ import annotations

import re

from PySide6 import QtCore, QtWidgets

from .. import config_io, theme
from ..state import State
from .common import new_table

# key, config key (None: fixed by femticPy), kind, meaning, source (a file and a keyword, never a line number:
# line numbers drift). FPY = femticPy.py DataGen.write_inversion_control; AC = FEMTIC src/AnalysisControl.cpp at
# 26c8606, the build in use.
FPY = "femticPy.py write_inversion_control"
AC = "FEMTIC AnalysisControl.cpp @26c8606"
KEYS = [
    ("NUM_THREADS", "NUM_THREADS", "read-only", "OpenMP threads per rank; every Phoenix job sets the layout's",
     "04_inversion.slurm, 06_forward_only.slurm (NUM_THREADS)"),
    ("MESH_TYPE", None, "read-only", "tetrahedral mesh", FPY + "; prep_vulcan.py check C14"),
    ("OUTPUT_PARAM_VTK", None, "read-only", "output fields: resistivity (0) and sensitivity (4)",
     FPY + "; config comment (inversion)"),
    ("OFILE_TYPE", None, "read-only", "0: ASCII, one VTK file per iteration; any other value, or no key (FEMTIC's "
     "default): binary EnSight case, as FEMTIC's example wrote", FPY + "; " + AC + " (OFILE_TYPE)"),
    ("DISTORTION", "DISTORTION", "read-only", "distortion correction; prep refuses anything but 0",
     "prep_vulcan.py load_config (DISTORTION)"),
    ("ALPHA_WEIGHT", "ALPHA_WEIGHT", "curated", "roughness weights in x (north), y (east), z; three numbers >= 0",
     "config inversion.ALPHA_WEIGHT; " + FPY),
    ("INV_METHOD", "INV_METHOD", "read-only", "0 model space, 1 data space; 1 here: 65,341 (v2) or 68,654 (v3) "
     "cells > 120 x 53 x 8 = 50,880 data at most", "docs/mesh_tetra_pipeline.md (INV_METHOD); FEMTIC manual.txt"),
    ("BOTTOM_RESISTIVITY", "BOTTOM_RESISTIVITY", "curated", "ohm-m below the mesh bottom, in the roughening "
     "matrix; one number > 0", "config inversion.BOTTOM_RESISTIVITY; " + FPY),
    ("BOTTOM_ROUGHNING_FACTOR", None, "read-only", "roughening factor at the mesh bottom; FEMTIC refuses a "
     "negative value", FPY + "; " + AC + " (BOTTOM_ROUGHNING_FACTOR)"),
    ("OUTPUT_OPTION", None, "read-only", "0 0: the backward element in x and in y (FEMTIC's "
     "m_useBackwardOrForwardElement)", FPY + "; " + AC + " (OUTPUT_OPTION)"),
    ("TRADE_OFF_PARAM", "TRADE_OFF_PARAM", "curated", "regularisation trade-off (femtic.cnv column Alpha); one "
     "number > 0 for DISTORTION 0; bracket it per run (1, 3, 10, 30)",
     "config inversion.TRADE_OFF_PARAM; prep_vulcan.py load_config"),
    ("ITERATION", "ITERATION", "read-only", "first and last iteration; every Phoenix job sets it",
     "make_run.sh (t4: ITERATION 0 1); 04_inversion.slurm, 06_forward_only.slurm (ITERATION)"),
    ("RETRIAL", None, "read-only", "maximum step-length cut-backs; reaching the limit ends the job STALLED (exit 2)",
     FPY + "; " + AC + " (RETRIAL); README_phoenix.md (STALLED)"),
    ("CONVERGE", "CONVERGE", "curated", "% change of the objective function that ends the iterations; one "
     "number > 0", "config inversion.CONVERGE; README_phoenix.md (CONVERGE)"),
    ("STEP_LENGTH", None, "read-only", "damping: start 0.5, min 0.1, max 1.0; x1.25 after 3 iterations, x0.5 to "
     "decrease; grew 0.5, 0.625, 0.78125 in FEMTIC's example; restarts at its start value",
     FPY + "; " + AC + " (STEP_LENGTH)"),
    ("OWNER_ELEMENT", "OWNER_ELEMENT", "read-only", "-1: H from the element above the site via dummy VTF "
     "stations; the meshes and the gate assume -1",
     "config comment (OWNER_ELEMENT); docs/mesh_tetra_pipeline.md (OWNER_ELEMENT)"),
]
FIXED = {"MESH_TYPE": "1", "OUTPUT_PARAM_VTK": "2 / 0 4", "OFILE_TYPE": "0", "BOTTOM_ROUGHNING_FACTOR": "1.0",
         "OUTPUT_OPTION": "0 0", "RETRIAL": "2", "STEP_LENGTH": "0.5 0.1 1.0 / 3 / 0.5 1.25"}
CURATED = {"TRADE_OFF_PARAM": (1, True), "CONVERGE": (1, False), "ALPHA_WEIGHT": (3, True),
           "BOTTOM_RESISTIVITY": (1, False)}         # key: (count, written as a list)
NOTE = ("The GUI never writes control.dat: prep_vulcan.py does (femticPy's writer) and its check C14 verifies it. "
        "Phoenix jobs also add SENSE_MAT_DIRECTORY, FWD_SOLVER and MEM_LIMIT (04_inversion.slurm).")


def parse_curated(key: str, text: str) -> float | list[float]:
    """Parse a curated value as typed ('3', '1 1 0.5', '1, 1, 0.5').

    Raises:
        ValueError: wrong count, not a number, or out of range (ALPHA_WEIGHT >= 0, the others > 0).
    """
    n, as_list = CURATED[key]
    vals = [float(v) for v in re.split(r"[\s,]+", text.strip().strip("[]")) if v]
    if len(vals) != n:
        raise ValueError("%s takes %d number%s, got %d" % (key, n, "s" if n > 1 else "", len(vals)))
    if any(v != v or v in (float("inf"), float("-inf")) for v in vals):
        raise ValueError("%s must be finite" % key)
    if any(v < 0 for v in vals) or (key != "ALPHA_WEIGHT" and any(v <= 0 for v in vals)):
        raise ValueError("%s must be %s" % (key, ">= 0" if key == "ALPHA_WEIGHT" else "> 0"))
    return vals if as_list else vals[0]


def _show(key: str, v) -> str:
    if v is None:
        return "(not written)"
    if key == "ITERATION":
        return "0 %s" % v
    if isinstance(v, list):
        return " ".join("%.10g" % x for x in v)
    return "%.10g" % v if isinstance(v, float) else str(v)


class FemticTab(QtWidgets.QWidget):
    """The control.dat key table (four curated rows editable) and prep's control.dat."""

    def __init__(self, state: State, parent: QtWidgets.QWidget | None = None) -> None:
        super().__init__(parent)
        self.state = state
        self.table = new_table()
        self.table.setEditTriggers(QtWidgets.QAbstractItemView.EditTrigger.DoubleClicked
                                   | QtWidgets.QAbstractItemView.EditTrigger.EditKeyPressed)
        self.note = QtWidgets.QLabel(NOTE)
        self.note.setWordWrap(True)
        self.status = QtWidgets.QLabel()
        self.status.setWordWrap(True)
        self.control_label = QtWidgets.QLabel()
        self.control_label.setWordWrap(True)
        self.control = QtWidgets.QPlainTextEdit(readOnly=True)
        self.control.setFont(theme.mono_font())
        left = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(left)
        v.addWidget(QtWidgets.QLabel("control.dat keys (double-click a curated value to edit it)"))
        v.addWidget(self.table)
        v.addWidget(self.note)
        v.addWidget(self.status)
        right = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(right)
        v.addWidget(self.control_label)
        v.addWidget(self.control)
        split = QtWidgets.QSplitter(QtCore.Qt.Orientation.Horizontal)
        split.addWidget(left)
        split.addWidget(right)
        split.setStretchFactor(0, 3)
        split.setStretchFactor(1, 1)
        split.setSizes([1100, 380])
        QtWidgets.QVBoxLayout(self).addWidget(split)
        self.table.itemChanged.connect(self._edited)
        # deferred: an edit arrives from inside the table's own itemChanged signal
        state.edited.connect(lambda: QtCore.QTimer.singleShot(0, self.reload))

    def reload(self) -> None:
        """Fill the key table from the config and show prep's control.dat."""
        s = self.state
        t = self.table
        t.blockSignals(True)
        t.clear()
        t.setColumnCount(5)
        t.setHorizontalHeaderLabels(["key", "value", "kind", "meaning", "source"])
        t.setRowCount(len(KEYS))
        for r, (key, ck, kind, meaning, source) in enumerate(KEYS):
            val = FIXED[key] if ck is None else _show(key, s.get("inversion." + ck))
            why = ("double-click to edit inversion.%s (saved with File > Save as...)" % ck if kind == "curated" else
                   "fixed by femticPy's writer" if ck is None else
                   "read-only here: %s" % meaning)
            for c, text in enumerate((key, val, kind, meaning, source)):
                it = QtWidgets.QTableWidgetItem(text)
                flags = it.flags() & ~QtCore.Qt.ItemFlag.ItemIsEditable
                if c == 1 and kind == "curated":
                    flags |= QtCore.Qt.ItemFlag.ItemIsEditable
                    it.setForeground(theme.colour(theme.LINK))
                it.setFlags(flags)
                it.setToolTip(why)
                t.setItem(r, c, it)
        t.resizeColumnsToContents()
        t.setColumnWidth(3, min(t.columnWidth(3), 430))       # meaning: wrapped
        t.setWordWrap(True)
        t.resizeRowsToContents()
        t.blockSignals(False)
        path = (s.repo / s.run_dir() / "inversion" / "control.dat") if s.c else None
        self.control_label.setText("control.dat prep wrote: %s" % (s.rel(path) if path else "-"))
        if path is not None and path.is_file():
            self.control.setPlainText(path.read_text(encoding="utf-8", errors="replace"))
        else:
            self.control.setPlainText("(not written yet: Run prep on the Data tab writes it)")

    def _edited(self, item: QtWidgets.QTableWidgetItem) -> None:
        if item.column() != 1:
            return
        key = KEYS[item.row()][0]
        if key not in CURATED:
            return
        try:
            self.state.set_value("inversion." + key, parse_curated(key, item.text()))
            theme.set_status(self.status, "unsaved: inversion.%s (File > Save as... keeps it)" % key, "warn")
        except (ValueError, config_io.ConfigError) as e:
            theme.set_status(self.status, str(e), "error")
            QtCore.QTimer.singleShot(0, self.reload)
