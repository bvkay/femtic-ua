# -*- coding: utf-8 -*-
"""runs_form.py - the Runs tab's New-run form: one field per scripts/make_run.sh option, nothing more.

The form only assembles the command; make_run.sh alone validates it (its 'make_run.sh: REFUSED: ...' line).
Each field's tooltip is that option's line of make_run.sh's own header, read at start-up. The commands, as a
student types them (RUNBOOK.md R1 and F3; make_run.sh's header):
    bash scripts/make_run.sh RunNN --mesh v2 --data mesh/vulcan_v2_rot/inversion --job gate --start-rho 100
         --layout 3x24 --time 02:00:00 --purpose "why"
    bash scripts/make_run.sh RunNN --job mesh --files mesh/vulcan_v2/files --purpose "why"
A mesh build shows --files (a folder picker) and --seeds and hides --mesh, --data and --niv, which make_run.sh
refuses for it; its --layout and --time are left out while empty (make_run.sh's defaults 1x8 and 04:00:00).
After a run folder is made, clear_after_make() empties --purpose and the job-specific fields, so a second click
cannot make a second run with the same purpose.

@author ben kay
:license: MIT
"""
from __future__ import annotations

import re
from pathlib import Path

from PySide6 import QtCore, QtWidgets

from .. import config_io, readers
from ..jobs import display_command

JOBS = ("gate", "forward", "t4", "inversion", "mesh")
LAYOUTS = {"v2": "3x24", "v3": "2x36"}
MESH_DEFAULTS = {"layout": "1x8", "time": "04:00:00"}       # make_run.sh's defaults for --job mesh


class NewRunForm(QtWidgets.QGroupBox):
    """Fields for make_run.sh; argv(bash) returns the command list, the preview shows it as typed."""

    changed = QtCore.Signal()

    def __init__(self, make_run: Path, parent: QtWidgets.QWidget | None = None) -> None:
        super().__init__("New run (scripts/make_run.sh)", parent)
        self.repo = Path(make_run).resolve().parents[1]
        try:
            tips = readers.make_run_options(make_run)
        except OSError:
            tips = {}
        f = self._form = QtWidgets.QFormLayout(self)
        self.name = QtWidgets.QLineEdit()
        self.name.setToolTip("Run01, Run02, ...: the next free number; a name is never reused")
        self.mesh = QtWidgets.QComboBox()
        self.mesh.addItems(list(LAYOUTS))
        self.data = QtWidgets.QLineEdit()
        self.job = QtWidgets.QComboBox()
        self.job.addItems(list(JOBS))
        self.files = QtWidgets.QLineEdit(placeholderText="folder with the 10 mesh inputs, e.g. mesh/vulcan_v2/files")
        self.files_btn = QtWidgets.QPushButton("Choose...")
        self.files_btn.setToolTip("Pick the --files folder (a folder dialog; reads only, runs nothing)")
        files_row = QtWidgets.QWidget()
        h = QtWidgets.QHBoxLayout(files_row)
        h.setContentsMargins(0, 0, 0, 0)
        h.addWidget(self.files, 1)
        h.addWidget(self.files_btn)
        self.seeds = QtWidgets.QLineEdit(placeholderText="only if the folder has no region_seeds.dat")
        self.start_rho = QtWidgets.QLineEdit(placeholderText="ohm-m, e.g. 100")
        self.iter_step = QtWidgets.QLineEdit(placeholderText="N")
        self.iter_max = QtWidgets.QLineEdit(placeholderText="N")
        self.layout_ = QtWidgets.QLineEdit()
        self.time = QtWidgets.QLineEdit()
        self.partition = QtWidgets.QComboBox()
        self.partition.addItems(["icelake", "highmem"])
        self.niv = QtWidgets.QLineEdit(placeholderText="optional")
        self.mail = QtWidgets.QLineEdit(placeholderText="optional: your address")
        self.purpose = QtWidgets.QLineEdit(placeholderText="required: why this run exists")
        self.preview = QtWidgets.QPlainTextEdit(readOnly=True)
        self.preview.setMaximumHeight(70)
        self.button = QtWidgets.QPushButton("Make run folder")
        self._rows = {}
        for label, w, opt in (("name", self.name, None), ("--mesh", self.mesh, "--mesh"),
                              ("--data", self.data, "--data"), ("--job", self.job, "--job"),
                              ("--files", files_row, "--files"), ("--seeds", self.seeds, "--seeds"),
                              ("--start-rho", self.start_rho, "--start-rho"),
                              ("--iter-step", self.iter_step, "--iter-step"),
                              ("--iter-max", self.iter_max, "--iter-max"), ("--layout", self.layout_, "--layout"),
                              ("--time", self.time, "--time"), ("--partition", self.partition, "--partition"),
                              ("--niv", self.niv, "--niv"), ("--mail", self.mail, "--mail"),
                              ("--purpose", self.purpose, "--purpose")):
            if opt:
                (self.files if w is files_row else w).setToolTip(tips.get(opt, opt))
                self._rows[opt] = w
            f.addRow(label, w)
        f.addRow("command", self.preview)
        f.addRow(self.button)
        for w in (self.name, self.data, self.files, self.seeds, self.start_rho, self.iter_step, self.iter_max,
                  self.layout_, self.time, self.niv, self.mail, self.purpose):
            w.textChanged.connect(self._changed)
        self.partition.currentTextChanged.connect(self._changed)
        self.job.currentTextChanged.connect(self._job_changed)
        self.mesh.currentTextChanged.connect(self._mesh_changed)
        self.files_btn.clicked.connect(self._pick_files)
        self._job_changed(self.job.currentText())

    def row_visible(self, opt: str) -> bool:
        """True if the option's row is shown (e.g. '--files' only for a mesh build)."""
        return self._form.isRowVisible(self._rows[opt])

    def reset(self, name: str, mesh: str, data: str) -> None:
        """Start a new form: the next run name, the config's mesh and data folder, that mesh's layout."""
        self.name.setText(name)
        if mesh in LAYOUTS:
            self.mesh.setCurrentText(mesh)
        if self.job.currentText() != "mesh":
            self.layout_.setText(LAYOUTS.get(self.mesh.currentText(), ""))
        self.data.setText(data)
        self._changed()

    def clear_after_make(self) -> None:
        """After a run folder is made: empty --purpose and the job-specific fields (the next run needs its own)."""
        for w in (self.purpose, self.start_rho, self.iter_step, self.iter_max, self.files, self.seeds):
            w.clear()

    def _pick_files(self) -> None:
        d = QtWidgets.QFileDialog.getExistingDirectory(self, "--files: the folder with the mesh inputs",
                                                       str(self.repo / "mesh"))
        if not d:
            return
        try:
            p = config_io.local_path(d)
        except config_io.ConfigError as e:
            QtWidgets.QMessageBox.warning(self, "--files", str(e))
            return
        try:
            self.files.setText(p.resolve().relative_to(self.repo).as_posix())
        except ValueError:
            self.files.setText(p.as_posix())

    def _job_changed(self, job: str) -> None:
        mesh_job = job == "mesh"
        for opt in ("--files", "--seeds"):
            self._form.setRowVisible(self._rows[opt], mesh_job)
        for opt in ("--mesh", "--data", "--niv"):
            self._form.setRowVisible(self._rows[opt], not mesh_job)
        self.layout_.setPlaceholderText("default %s (make_run.sh)" % MESH_DEFAULTS["layout"] if mesh_job else "RxT")
        self.time.setPlaceholderText("default %s (make_run.sh)" % MESH_DEFAULTS["time"] if mesh_job else "HH:MM:SS")
        if mesh_job and self.layout_.text() in LAYOUTS.values():
            self.layout_.clear()
        elif not mesh_job and not self.layout_.text():
            self.layout_.setText(LAYOUTS[self.mesh.currentText()])
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
        a = [bash, "scripts/make_run.sh", self.name.text().strip()]
        if job == "mesh":
            a += ["--job", job, "--files", self.files.text().strip().replace("\\", "/")]
            if self.seeds.text().strip():
                a += ["--seeds", " ".join(self.seeds.text().split())]
        else:
            a += ["--mesh", self.mesh.currentText(), "--data", self.data.text().strip().replace("\\", "/"),
                  "--job", job]
        if job == "gate":
            a += ["--start-rho", self.start_rho.text().strip()]
        if job == "inversion":
            a += ["--iter-step", self.iter_step.text().strip(), "--iter-max", self.iter_max.text().strip()]
        for opt, w in (("--layout", self.layout_), ("--time", self.time)):
            if job != "mesh" or w.text().strip():
                a += [opt, w.text().strip()]
        a += ["--purpose", re.sub(r"\s+", " ", self.purpose.text()).strip()]
        if self.partition.currentText() != "icelake":
            a += ["--partition", self.partition.currentText()]
        for opt, w in (("--niv", self.niv), ("--mail", self.mail)):
            if w.text().strip() and not (opt == "--niv" and job == "mesh"):
                a += [opt, w.text().strip()]
        return a

    def show_command(self, bash: str | None) -> str:
        """Put the command as typed into the preview box and return it."""
        text = display_command(self.argv(bash or "bash"))
        self.preview.setPlainText(text)
        return text
