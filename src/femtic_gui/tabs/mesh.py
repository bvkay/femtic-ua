# -*- coding: utf-8 -*-
"""mesh.py - the Mesh tab: the reused mesh's measured counts, prep's design warnings, and the 3D viewer.

Phase 1 edits no mesh setting: with mesh.reuse_from set, any change fails prep's check C17, and no mesh build is
tested on this PC (a Phoenix mesh build will be a make_run.sh job). The counts come from the reused mesh's
mesh_logs/mesh_stats.txt (measured when it was built); nothing is predicted. 'Open 3D viewer' imports
viewer3d (VTK) only when pressed, on <reuse_from>/inversion/mesh.dat and its resistivity_block_iter0.dat.

@author ben kay
:license: MIT
"""
from __future__ import annotations

from pathlib import Path

from PySide6 import QtWidgets

from .. import config_io, prep_api, readers, theme
from ..state import State
from .common import open_viewer, set_enabled, viewer_missing

READ_ONLY_WHY = ("Mesh settings are read-only in phase 1: with mesh.reuse_from set, any change fails prep's check "
                 "C17 (files/ must equal the inputs the mesh was built from), and the GUI builds no mesh.")


class MeshTab(QtWidgets.QWidget):
    """Counts, design warnings, the mesh keys (read-only) and the 3D viewer button."""

    def __init__(self, state: State, parent: QtWidgets.QWidget | None = None) -> None:
        super().__init__(parent)
        self.state = state
        self.counts = QtWidgets.QLabel()
        self.counts.setWordWrap(True)
        self.counts.setFont(theme.mono_font())
        self.warnings = QtWidgets.QLabel()
        self.warnings.setWordWrap(True)
        self.keys = QtWidgets.QPlainTextEdit(readOnly=True)
        self.keys.setFont(theme.mono_font())
        self.keys.setToolTip(READ_ONLY_WHY)
        self.view_btn = QtWidgets.QPushButton("Open 3D viewer")
        self.open_btn = QtWidgets.QPushButton("Open mesh.dat or .vtk...")
        lay = QtWidgets.QVBoxLayout(self)
        for title, w in (("Mesh (mesh.reuse_from)", self.counts), ("prep's design warnings", self.warnings)):
            g = QtWidgets.QGroupBox(title)
            QtWidgets.QVBoxLayout(g).addWidget(w)
            lay.addWidget(g)
        row = QtWidgets.QHBoxLayout()
        row.addWidget(self.view_btn)
        row.addWidget(self.open_btn)
        row.addStretch(1)
        lay.addLayout(row)
        note = QtWidgets.QLabel(READ_ONLY_WHY)
        note.setWordWrap(True)
        lay.addWidget(note)
        lay.addWidget(self.keys, 1)
        self.view_btn.clicked.connect(self.open_reused)
        self.open_btn.clicked.connect(self.open_file)

    def mesh_dir(self) -> Path | None:
        """The reused mesh's folder (mesh.reuse_from), or None."""
        c = self.state.c
        return Path(c["reuse_from"]) if c and c.get("reuse_from") else None

    def reload(self) -> None:
        """Re-read the counts and warnings and list the mesh keys."""
        s, md = self.state, self.mesh_dir()
        if s.survey is None:
            return
        if md is None:
            text = "mesh.reuse_from is not set: this config describes a new mesh, which the GUI does not build."
        else:
            lines = readers.mesh_stats_lines(md)
            text = "%s\n%s" % (s.rel(md), "\n".join(lines) if lines else "no mesh_logs/mesh_stats.txt there")
        self.counts.setText(text)
        w = prep_api.design_warnings(s.survey)
        theme.set_status(self.warnings, "\n".join("- " + x for x in w) if w else "none", "warn" if w else "ok")
        mesh = s.get("mesh", {}) or {}
        out = []
        for k, v in mesh.items():
            if isinstance(v, dict):
                for k2, v2 in v.items():
                    out.append("%s.%s: %s" % (k, k2, "%d rows" % len(v2) if _is_table(v2) else v2))
            else:
                out.append("%s: %s" % (k, "%d rows" % len(v) if _is_table(v) else v))
        self.keys.setPlainText("\n".join(out))
        missing = viewer_missing()
        mesh_dat = md / "inversion" / "mesh.dat" if md else None
        why = missing or ("" if mesh_dat and mesh_dat.is_file() else
                          "no %s here (the meshes are in Ben's checkout; use Open mesh.dat or .vtk...)"
                          % (s.rel(mesh_dat) if mesh_dat else "reused mesh"))
        set_enabled(self.view_btn, why, "3D view of %s with resistivity_block_iter0.dat (loads in about 5 s)"
                    % (s.rel(mesh_dat) if mesh_dat else "-"))
        set_enabled(self.open_btn, missing, "3D view of a FEMTIC mesh.dat (and its block file) or a .vtk file")

    def _stations(self) -> Path | None:
        p = self.state.repo / self.state.run_dir() / "inversion" / "station_map.csv"
        return p if p.is_file() else None

    def open_reused(self) -> None:
        """Open the reused mesh with its iteration-0 model in the 3D viewer."""
        inv = self.mesh_dir() / "inversion"
        block = inv / "resistivity_block_iter0.dat"
        open_viewer(self, inv / "mesh.dat", block if block.is_file() else None, self._stations())

    def open_file(self) -> None:
        """Choose a mesh.dat (its block file is taken from the same folder) or a .vtk file."""
        path, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Open a mesh", str(self.state.repo / "mesh"),
                                                        "FEMTIC mesh or VTK (mesh.dat *.vtk)")
        if not path:
            return
        try:
            p = config_io.local_path(path)
        except config_io.ConfigError as e:
            QtWidgets.QMessageBox.warning(self, "Open a mesh", str(e))
            return
        block = p.parent / "resistivity_block_iter0.dat"
        open_viewer(self, p, block if p.suffix != ".vtk" and block.is_file() else None, self._stations())


def _is_table(v) -> bool:
    return isinstance(v, list) and bool(v) and isinstance(v[0], list)
