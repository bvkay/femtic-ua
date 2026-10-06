# -*- coding: utf-8 -*-
"""app.py - MainWindow: the tabs over the console strip in a splitter, the menus, and the cross-tab wiring.

File: Open config (Ctrl+O), Save as (the open file is never overwritten), recent configs and run folders
(QSettings), Quit (Ctrl+Q). Help: the student runbook (hpc/phoenix_plan/RUNBOOK.md, read-only). Tabs never import
each other: this window connects State's signals to their reload(). Dialog paths are local only (UNC refused).

@author ben kay
:license: MIT
"""
from __future__ import annotations

import getpass
import re
from pathlib import Path

from loguru import logger
from PySide6 import QtCore, QtGui, QtWidgets

from . import __version__, config_io, prep_api
from .console import ConsoleStrip, install_loguru, remove_loguru
from .state import State
from .tabs.common import show_text
from .tabs.data import DataTab
from .tabs.femtic import FemticTab
from .tabs.mesh import MeshTab
from .tabs.results import ResultsTab
from .tabs.runs import RunsTab

MAX_RECENT = 8


class MainWindow(QtWidgets.QMainWindow):
    """The GUI's one window."""

    def __init__(self, state: State | None = None, settings: QtCore.QSettings | None = None) -> None:
        super().__init__()
        self.state = state or State(parent=self)
        self.settings = settings or QtCore.QSettings(QtCore.QSettings.Format.IniFormat,
                                                     QtCore.QSettings.Scope.UserScope, "femtic_gui", "femtic_gui")
        self.resize(1500, 950)
        self.tabs = QtWidgets.QTabWidget()
        self.data_tab = DataTab(self.state)
        self.mesh_tab = MeshTab(self.state)
        self.femtic_tab = FemticTab(self.state)
        self.runs_tab = RunsTab(self.state)
        self.results_tab = ResultsTab(self.state)
        for w, name in ((self.data_tab, "Data"), (self.mesh_tab, "Mesh"), (self.femtic_tab, "FEMTIC"),
                        (self.runs_tab, "Runs"), (self.results_tab, "Results")):
            self.tabs.addTab(w, name)
        self.console = ConsoleStrip()
        self.job_label = QtWidgets.QLabel("no job running")
        self.cancel_btn = QtWidgets.QPushButton("Cancel job")
        self.cancel_btn.setToolTip("Kill the running job (waits up to 3 s); its output stays in the console")
        self.cancel_btn.setEnabled(False)
        bottom = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(bottom)
        v.setContentsMargins(0, 0, 0, 0)
        row = QtWidgets.QHBoxLayout()
        row.addWidget(self.job_label, 1)
        row.addWidget(self.cancel_btn)
        v.addLayout(row)
        v.addWidget(self.console)
        split = QtWidgets.QSplitter(QtCore.Qt.Orientation.Vertical)
        split.addWidget(self.tabs)
        split.addWidget(bottom)
        split.setStretchFactor(0, 4)
        split.setStretchFactor(1, 1)
        self.setCentralWidget(split)
        self._loguru = install_loguru(self.console)
        self._build_menus()
        self._wire()
        self._update_title()
        self.statusBar().showMessage("Open a config: File > Open config... (Ctrl+O)")

    # ------------------------------------------------------------------ menus
    def _build_menus(self) -> None:
        m = self.menuBar().addMenu("&File")
        self.open_act = m.addAction("&Open config...", QtGui.QKeySequence.StandardKey.Open, self.open_dialog)
        self.save_act = m.addAction("Save &as...", QtGui.QKeySequence("Ctrl+Shift+S"), self.save_as_dialog)
        self.save_act.setToolTip("Save the config under a new name (the open file is never overwritten)")
        self.recent_menu = m.addMenu("Recent configs")
        self.recent_runs_menu = m.addMenu("Recent run folders")
        m.addSeparator()
        m.addAction("&Quit", QtGui.QKeySequence.StandardKey.Quit, self.close)
        h = self.menuBar().addMenu("&Help")
        h.addAction("Runbook (hpc/phoenix_plan/RUNBOOK.md)", self.show_runbook)
        h.addAction("About", lambda: QtWidgets.QMessageBox.about(
            self, "FEMTIC GUI", "femtic_gui %s: a thin shell over prep_vulcan.py and make_run.sh.\n"
            "docs/dev/gui_design_2026-10-06.md" % __version__))
        self._fill_recent()

    def _wire(self) -> None:
        s = self.state
        s.runner.line.connect(self.console.append_line)
        tabs = (self.data_tab, self.mesh_tab, self.femtic_tab, self.runs_tab, self.results_tab)
        self.results_tab.folder_opened.connect(lambda p: self._add_recent(p, "recent_runs"))
        s.config_changed.connect(lambda: [t.reload() for t in tabs])
        s.config_changed.connect(self._update_title)
        s.dirty_changed.connect(lambda _d: self._update_title())
        s.runner.finished.connect(lambda _ok: (self.mesh_tab.reload(), self.femtic_tab.reload()))
        s.runner.started.connect(lambda label: self._job_state(True, label))
        s.runner.finished.connect(lambda ok: self._job_state(False, "last job %s" % ("done" if ok else "failed")))
        self.cancel_btn.clicked.connect(s.runner.cancel)

    def _job_state(self, running: bool, text: str) -> None:
        self.job_label.setText("running: %s" % text if running else text)
        self.cancel_btn.setEnabled(running)

    def _update_title(self) -> None:
        doc = self.state.doc
        name = self.state.rel(doc.path) if doc else "no config"
        self.setWindowTitle("FEMTIC GUI - %s%s" % (name, " *" if self.state.dirty else ""))
        self.save_act.setEnabled(doc is not None)

    # ------------------------------------------------------------------ open / save
    def _discard_ok(self, what: str) -> bool:
        if not self.state.dirty:
            return True
        ans = QtWidgets.QMessageBox.question(self, what, "The config has unsaved edits. Discard them?")
        return ans == QtWidgets.QMessageBox.StandardButton.Yes

    def open_dialog(self) -> None:
        """File > Open config: choose a .yml under config/."""
        start = str(self.state.doc.path.parent if self.state.doc else self.state.repo / "config")
        path, _ = QtWidgets.QFileDialog.getOpenFileName(self, "Open config", start, "Config (*.yml *.yaml)")
        if path:
            self.open_config(path)

    def open_config(self, path: str | Path) -> bool:
        """Open a config (asks first if there are unsaved edits). Returns True if it is now open."""
        if not self._discard_ok("Open config"):
            return False
        try:
            self.state.open_config(config_io.local_path(path))
        except (config_io.ConfigError, prep_api.PrepFailure) as e:
            QtWidgets.QMessageBox.warning(self, "Open config", "Cannot open %s:\n\n%s" % (path, e))
            return False
        self._add_recent(str(self.state.doc.path))
        logger.info("opened {}", self.state.rel(self.state.doc.path))
        self.statusBar().showMessage("%s: %d sites, %d EDIs" % (self.state.rel(self.state.doc.path),
                                                               len(self.state.survey.sites),
                                                               len(self.state.survey.edis)))
        return True

    def save_as_dialog(self) -> None:
        """File > Save as: a new .yml next to the open one; an existing file is refused, never replaced."""
        doc = self.state.doc
        if doc is None:
            return
        user = re.sub(r"[^a-z0-9]", "", getpass.getuser().lower())[:8] or "copy"
        suggest = doc.path.parent / ("%s_%s.yml" % (doc.path.stem, user))
        path, _ = QtWidgets.QFileDialog.getSaveFileName(
            self, "Save config as (a new file)", str(suggest), "Config (*.yml)",
            options=QtWidgets.QFileDialog.Option.DontConfirmOverwrite)
        if path:
            self.save_as(path)

    def save_as(self, path: str | Path) -> bool:
        """Save the open config as path (config_io.save_as rules). Returns True if saved."""
        try:
            saved = self.state.save_as(path)
        except (config_io.ConfigError, prep_api.PrepFailure) as e:
            QtWidgets.QMessageBox.warning(self, "Save as", str(e))
            return False
        self._add_recent(str(saved))
        logger.info("saved {}", self.state.rel(saved))
        self.statusBar().showMessage("saved %s" % self.state.rel(saved))
        return True

    def _add_recent(self, path: str, key: str = "recent_configs") -> None:
        rec = [p for p in self._recent(key) if p != path]
        self.settings.setValue(key, ([path] + rec)[:MAX_RECENT])
        self._fill_recent()

    def _recent(self, key: str = "recent_configs") -> list[str]:
        v = self.settings.value(key, [])
        return [v] if isinstance(v, str) else list(v or [])

    def _fill_recent(self) -> None:
        for menu, key, action in ((self.recent_menu, "recent_configs", self.open_config),
                                  (self.recent_runs_menu, "recent_runs", self.open_run_folder)):
            menu.clear()
            for p in self._recent(key):
                menu.addAction(p, lambda p=p, action=action: action(p))
            menu.setEnabled(bool(self._recent(key)))

    def open_run_folder(self, path: str) -> None:
        """File > Recent run folders: show the folder in the Results tab."""
        self.tabs.setCurrentWidget(self.results_tab)
        self.results_tab.open_folder(path)

    def show_runbook(self) -> None:
        """Help > Runbook: the student runbook, read-only."""
        show_text(self, "Runbook", self.state.repo / "hpc" / "phoenix_plan" / "RUNBOOK.md")

    def closeEvent(self, event: QtGui.QCloseEvent) -> None:  # noqa: N802 (Qt name)
        """Ask before discarding edits or killing a running job; detach the console's log sink."""
        if self.state.job_running:
            ans = QtWidgets.QMessageBox.question(self, "Quit", "A job is running. Cancel it and quit?")
            if ans != QtWidgets.QMessageBox.StandardButton.Yes:
                event.ignore()
                return
            self.state.runner.cancel()
        if not self._discard_ok("Quit"):
            event.ignore()
            return
        remove_loguru(self._loguru)
        event.accept()
