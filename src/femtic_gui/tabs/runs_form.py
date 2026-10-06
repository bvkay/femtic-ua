# -*- coding: utf-8 -*-
"""runs_form.py - the Runs tab's New-run form: one field per scripts/make_run.sh option, nothing more.

The form only assembles the command; make_run.sh alone validates it (its 'make_run.sh: REFUSED: ...' line).
Each field's tooltip is that option's line of make_run.sh's own header, read at start-up. Built against the
committed make_run.sh (jobs gate, forward, t4, inversion); a mesh-build job is not offered here.
The command, as a student would type it (RUNBOOK.md R1):
    bash scripts/make_run.sh RunNN --mesh v2 --data mesh/vulcan_v2_rot/inversion --job gate --start-rho 100
         --layout 3x24 --time 02:00:00 --purpose "why"

@author ben kay
:license: MIT
"""
from __future__ import annotations

import re
from pathlib import Path

from PySide6 import QtCore, QtWidgets

from .. import readers
from ..jobs import display_command

JOBS = ("gate", "forward", "t4", "inversion")
LAYOUTS = {"v2": "3x24", "v3": "2x36"}


class NewRunForm(QtWidgets.QGroupBox):
    """Fields for make_run.sh; argv(bash) returns the command list, the preview shows it as typed."""

    changed = QtCore.Signal()

    def __init__(self, make_run: Path, parent: QtWidgets.QWidget | None = None) -> None:
        super().__init__("New run (scripts/make_run.sh)", parent)
        try:
            tips = readers.make_run_options(make_run)
        except OSError:
            tips = {}
        f = QtWidgets.QFormLayout(self)
        self.name = QtWidgets.QLineEdit()
        self.name.setToolTip("Run01, Run02, ...: the next free number; a name is never reused")
        self.mesh = QtWidgets.QComboBox()
        self.mesh.addItems(list(LAYOUTS))
        self.data = QtWidgets.QLineEdit()
        self.job = QtWidgets.QComboBox()
        self.job.addItems(list(JOBS))
        self.start_rho = QtWidgets.QLineEdit(placeholderText="ohm-m, e.g. 100")
        self.iter_step = QtWidgets.QLineEdit(placeholderText="N")
        self.iter_max = QtWidgets.QLineEdit(placeholderText="N")
        self.layout_ = QtWidgets.QLineEdit()
        self.time = QtWidgets.QLineEdit(placeholderText="HH:MM:SS")
        self.partition = QtWidgets.QComboBox()
        self.partition.addItems(["icelake", "highmem"])
        self.niv = QtWidgets.QLineEdit(placeholderText="optional")
        self.mail = QtWidgets.QLineEdit(placeholderText="optional: your address")
        self.purpose = QtWidgets.QLineEdit(placeholderText="required: why this run exists")
        self.preview = QtWidgets.QPlainTextEdit(readOnly=True)
        self.preview.setMaximumHeight(70)
        self.button = QtWidgets.QPushButton("Make run folder")
        for label, w, opt in (("name", self.name, None), ("--mesh", self.mesh, "--mesh"),
                              ("--data", self.data, "--data"), ("--job", self.job, "--job"),
                              ("--start-rho", self.start_rho, "--start-rho"),
                              ("--iter-step", self.iter_step, "--iter-step"),
                              ("--iter-max", self.iter_max, "--iter-max"), ("--layout", self.layout_, "--layout"),
                              ("--time", self.time, "--time"), ("--partition", self.partition, "--partition"),
                              ("--niv", self.niv, "--niv"), ("--mail", self.mail, "--mail"),
                              ("--purpose", self.purpose, "--purpose")):
            if opt:
                w.setToolTip(tips.get(opt, opt))
            f.addRow(label, w)
        f.addRow("command", self.preview)
        f.addRow(self.button)
        for w in (self.name, self.data, self.start_rho, self.iter_step, self.iter_max, self.layout_, self.time,
                  self.niv, self.mail, self.purpose):
            w.textChanged.connect(self._changed)
        for w in (self.job, self.partition):
            w.currentTextChanged.connect(self._changed)
        self.mesh.currentTextChanged.connect(self._mesh_changed)

    def reset(self, name: str, mesh: str, data: str) -> None:
        """Start a new form: the next run name, the config's mesh and data folder, that mesh's layout."""
        self.name.setText(name)
        if mesh in LAYOUTS:
            self.mesh.setCurrentText(mesh)
        self.layout_.setText(LAYOUTS.get(self.mesh.currentText(), ""))
        self.data.setText(data)
        self._changed()

    def _mesh_changed(self, mesh: str) -> None:
        if self.layout_.text() in LAYOUTS.values():
            self.layout_.setText(LAYOUTS[mesh])
        self._changed()

    def _changed(self, *_args) -> None:
        job = self.job.currentText()
        self.start_rho.setEnabled(job == "gate")
        self.iter_step.setEnabled(job == "inversion")
        self.iter_max.setEnabled(job == "inversion")
        self.changed.emit()

    def argv(self, bash: str) -> list[str]:
        """The make_run.sh command as an argv list, options in the RUNBOOK's order, empty optional ones left out."""
        job = self.job.currentText()
        a = [bash, "scripts/make_run.sh", self.name.text().strip(), "--mesh", self.mesh.currentText(),
             "--data", self.data.text().strip().replace("\\", "/"), "--job", job]
        if job == "gate":
            a += ["--start-rho", self.start_rho.text().strip()]
        if job == "inversion":
            a += ["--iter-step", self.iter_step.text().strip(), "--iter-max", self.iter_max.text().strip()]
        a += ["--layout", self.layout_.text().strip(), "--time", self.time.text().strip(),
              "--purpose", re.sub(r"\s+", " ", self.purpose.text()).strip()]
        if self.partition.currentText() != "icelake":
            a += ["--partition", self.partition.currentText()]
        for opt, w in (("--niv", self.niv), ("--mail", self.mail)):
            if w.text().strip():
                a += [opt, w.text().strip()]
        return a

    def show_command(self, bash: str | None) -> str:
        """Put the command as typed into the preview box and return it."""
        text = display_command(self.argv(bash or "bash"))
        self.preview.setPlainText(text)
        return text
