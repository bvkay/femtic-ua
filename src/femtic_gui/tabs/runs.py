# -*- coding: utf-8 -*-
"""runs.py - the Runs tab: runs/INDEX.md, the selected run's RUN.md, the New-run form and Record result.

'Make run folder' runs scripts/make_run.sh through Git Bash exactly as RUNBOOK.md R1 types it; make_run.sh
alone validates. After it, R2-R6 happen outside the GUI (WinSCP, Phoenix; Help > Runbook). 'Record result'
fills the job id(s) and verdict cells of the run's INDEX.md line (RUNBOOK.md R6) and shows R6's git line to copy;
the GUI runs no git. The runs folder is runs/ (or $RUNS, as make_run.sh reads it).

@author ben kay
:license: MIT
"""
from __future__ import annotations

import os
import re
from pathlib import Path

from PySide6 import QtCore, QtWidgets

from .. import readers, theme
from ..jobs import display_command, find_bash
from ..state import State
from .common import fill_table, new_table, set_enabled
from .runs_form import NewRunForm

REC_TIP = ("Writes the job id(s) and verdict cells of this run's line in runs/INDEX.md; nothing else "
           "changes and no git runs")


class RunsTab(QtWidgets.QWidget):
    """Index table, RUN.md viewer, New-run form, Record result."""

    def __init__(self, state: State, parent: QtWidgets.QWidget | None = None) -> None:
        super().__init__(parent)
        self.state = state
        self.bash = find_bash()
        self.rows: list[dict] = []
        self._form_for: Path | None = None
        self._mine = False
        self.table = new_table()
        self.run_md = QtWidgets.QTextBrowser()
        self.form = NewRunForm(state.repo / "scripts" / "make_run.sh")
        rec = QtWidgets.QGroupBox("Record result (runs/INDEX.md, RUNBOOK.md R6)")
        f = QtWidgets.QFormLayout(rec)
        self.rec_run = QtWidgets.QLabel("-")
        self.rec_jobs = QtWidgets.QLineEdit(placeholderText="job id(s), e.g. 123456 or 123456, 123460")
        self.rec_verdict = QtWidgets.QLineEdit(placeholderText="PASS or FAIL, a few words")
        self.rec_button = QtWidgets.QPushButton("Record")
        self.git_line = QtWidgets.QLineEdit(readOnly=True)
        self.git_line.setToolTip("RUNBOOK.md R6: copy this into Git Bash after checking the run folder")
        for label, w in (("run", self.rec_run), ("job id(s)", self.rec_jobs), ("verdict", self.rec_verdict),
                         ("", self.rec_button), ("then, in Git Bash", self.git_line)):
            f.addRow(label, w)
        self.status = QtWidgets.QLabel()
        self.status.setWordWrap(True)

        left = QtWidgets.QSplitter(QtCore.Qt.Orientation.Vertical)
        left.addWidget(self.table)
        left.addWidget(self.run_md)
        right = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(right)
        v.addWidget(self.form)
        v.addWidget(rec)
        v.addWidget(self.status)
        v.addStretch(1)
        scroll = QtWidgets.QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setWidget(right)
        split = QtWidgets.QSplitter(QtCore.Qt.Orientation.Horizontal)
        split.addWidget(left)
        split.addWidget(scroll)
        split.setStretchFactor(0, 3)
        split.setStretchFactor(1, 2)
        split.setSizes([860, 560])
        QtWidgets.QVBoxLayout(self).addWidget(split)

        self.table.itemSelectionChanged.connect(self._selected)
        self.form.changed.connect(self.update_buttons)
        self.form.button.clicked.connect(self.make_run)
        self.rec_button.clicked.connect(self.record)
        state.job_state_changed.connect(lambda _r: self.update_buttons())
        state.runner.finished.connect(self._job_finished)

    def runs_dir(self) -> Path:
        """runs/ of the repository, or $RUNS (as make_run.sh)."""
        return Path(os.environ.get("RUNS") or self.state.repo / "runs")

    def reload(self) -> None:
        """Re-read INDEX.md; reset the form for a newly opened config or when its run name is taken."""
        self.rows = readers.read_index(self.runs_dir() / "INDEX.md")
        fill_table(self.table, ["run", "mesh", "purpose", "layout", "job id(s)", "verdict"],
                   [[r[k] for k in readers.INDEX_COLUMNS] for r in self.rows])
        self.table.setColumnWidth(2, min(self.table.columnWidth(2), 420))     # purpose: full text in RUN.md
        nxt = readers.next_run_name(self.runs_dir(), self.rows)
        doc = self.state.doc
        taken = {r["run"] for r in self.rows} | ({p.name for p in self.runs_dir().iterdir()}
                                                  if self.runs_dir().is_dir() else set())
        if doc is not None and (self._form_for != doc.path or self.form.name.text() in taken
                                or not self.form.name.text()):
            m = re.search(r"vulcan_(v\d+)", str(self.state.get("mesh.reuse_from") or ""))
            self.form.reset(nxt, m.group(1) if m else "v2", self.state.run_dir() + "/inversion")
            self._form_for = doc.path
        self.update_buttons()

    def select_run(self, run: str) -> None:
        """Select a run's row (shows its RUN.md)."""
        for r in range(self.table.rowCount()):
            if self.table.item(r, 0).text() == run:
                self.table.selectRow(r)
                return

    def _selected(self) -> None:
        rows = self.table.selectionModel().selectedRows()
        run = self.table.item(rows[0].row(), 0).text() if rows else ""
        self.rec_run.setText(run or "-")
        md = self.runs_dir() / run / "RUN.md" if run else None
        if md is not None and md.is_file():
            self.run_md.setMarkdown(md.read_text(encoding="utf-8", errors="replace"))
        else:
            self.run_md.setPlainText("%s: no RUN.md" % run if run else "")
        self.update_buttons()

    def update_buttons(self) -> None:
        """Refresh the command preview and enable the buttons that can act now (tooltips say why not)."""
        cmd = self.form.show_command(self.bash)
        why = ("Git Bash not found (Git for Windows' bin/bash.exe); the WSL bash is never used" if not self.bash
               else "a job is running" if self.state.job_running else
               "open a config first" if self.state.doc is None else "")
        set_enabled(self.form.button, why, cmd)
        run = self.rec_run.text()
        set_enabled(self.rec_button, "" if run != "-" else "select a run in the table", REC_TIP)

    def make_run(self) -> None:
        """Run make_run.sh with the form's command."""
        argv = self.form.argv(self.bash or "bash")
        self._mine = self.state.runner.run("make_run.sh", argv)
        if not self._mine:
            theme.set_status(self.status, "a job is running; wait or cancel it", "warn")

    def _job_finished(self, ok: bool) -> None:
        mine, self._mine = self._mine, False
        run = self.form.name.text().strip()
        self.reload()
        if mine:
            theme.set_status(self.status, ("%s made: next WinSCP it to Phoenix (RUNBOOK.md R2, R3)" % run) if ok else
                             "make_run.sh refused: its REFUSED line in the console says why", "ok" if ok else "error")
            if ok:
                self.select_run(run)

    def record(self) -> None:
        """Fill the selected run's job id(s) and verdict in INDEX.md and show R6's git line."""
        run = self.rec_run.text()
        row = next((r for r in self.rows if r["run"] == run), None)
        if row is None:
            return
        if (row["jobs"], row["verdict"]) != ("-", "-"):
            ans = QtWidgets.QMessageBox.question(self, "Record result", "%s already has job id(s) '%s' and verdict "
                                                 "'%s'. Replace them?" % (run, row["jobs"], row["verdict"]))
            if ans != QtWidgets.QMessageBox.StandardButton.Yes:
                return
        try:
            readers.record_result(self.runs_dir() / "INDEX.md", run, self.rec_jobs.text(), self.rec_verdict.text())
        except (readers.ReaderError, OSError) as e:
            theme.set_status(self.status, str(e), "error")
            return
        verdict = " ".join(self.rec_verdict.text().split())
        self.git_line.setText(display_command(["git", "add", "runs/%s" % run, "runs/INDEX.md"]) + " && " +
                              display_command(["git", "commit", "-m", "%s: %s" % (run, verdict)]))
        theme.set_status(self.status, "recorded in runs/INDEX.md; commit it with the git line (R6)", "ok")
        self.reload()
        self.select_run(run)
