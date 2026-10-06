# -*- coding: utf-8 -*-
"""state.py - State, the hub every tab shares: the open config, prep's view of its inputs, the selected site
and the job runner, with signals for each change. Tabs only read State and call its methods; MainWindow wires
the signals to the tabs' reload().

@author ben kay
:license: MIT
"""
from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from PySide6 import QtCore

from . import config_io, prep_api, repo_root
from .jobs import JobRunner


class State(QtCore.QObject):
    """The session: one config file, its inputs as prep reads them, the selection and the job runner.

    Signals:
        config_changed(): a config was opened or saved as; every tab reloads.
        edited(): a value of the open config was changed in memory (not saved yet).
        dirty_changed(bool): the config now has (True) or no longer has (False) unsaved edits.
        site_changed(str): another site was selected.
        job_state_changed(bool): a job started (True) or ended (False).
    """

    config_changed = QtCore.Signal()
    edited = QtCore.Signal()
    dirty_changed = QtCore.Signal(bool)
    site_changed = QtCore.Signal(str)
    job_state_changed = QtCore.Signal(bool)

    def __init__(self, repo: str | os.PathLike | None = None, parent: QtCore.QObject | None = None) -> None:
        super().__init__(parent)
        self.repo = Path(repo) if repo else repo_root()
        self.doc: config_io.ConfigDoc | None = None
        self.c: dict | None = None
        self.survey: prep_api.Survey | None = None
        self.site = ""
        self.runner = JobRunner(self.repo, self)
        self.runner.started.connect(lambda _label: self.job_state_changed.emit(True))
        self.runner.finished.connect(lambda _ok: self.job_state_changed.emit(False))

    @property
    def dirty(self) -> bool:
        """True while the open config has unsaved edits."""
        return bool(self.doc and self.doc.dirty)

    @property
    def job_running(self) -> bool:
        """True while the runner has a job."""
        return self.runner.busy

    def get(self, dotted: str, default: Any = None) -> Any:
        """A plain value of the open config (with unsaved edits), or default."""
        return default if self.doc is None else self.doc.get(dotted, default)

    def open_config(self, path: str | os.PathLike) -> None:
        """Open a config: read it, let prep load and check it, read its sites and EDIs.

        Nothing changes if any step fails.

        Raises:
            config_io.ConfigError: the file cannot be read.
            prep_api.PrepFailure: prep refuses the config, the site table or an EDI.
        """
        doc = config_io.load(path)
        c = prep_api.load_config(doc.path)
        sv = prep_api.load_survey(c)
        was_dirty = self.dirty
        self.doc, self.c, self.survey = doc, c, sv
        if self.site not in sv.edis:
            self.site = sv.ids[0] if sv.ids else ""
        self.config_changed.emit()
        if was_dirty:
            self.dirty_changed.emit(False)

    def set_value(self, dotted: str, value: Any) -> None:
        """Change one value of the open config in memory (config_io.set_value: only that value's text).

        Raises:
            config_io.ConfigError: if the edit is refused; nothing changes then.
        """
        if self.doc is None:
            raise config_io.ConfigError("no config is open")
        was = self.dirty
        new = config_io.set_value(self.doc, dotted, value)
        if new.text == self.doc.text:
            return
        self.doc = new
        self.edited.emit()
        if self.dirty != was:
            self.dirty_changed.emit(self.dirty)

    def save_as(self, target: str | os.PathLike) -> Path:
        """Save the open config under a new name (config_io.save_as) and continue with that file.

        Returns:
            The saved path.

        Raises:
            config_io.ConfigError: refused (exists, prep refuses it, ...); nothing is written then.
        """
        if self.doc is None:
            raise config_io.ConfigError("no config is open")
        saved = config_io.save_as(self.doc, target)
        self.open_config(saved.path)
        return saved.path

    def select_site(self, sid: str) -> None:
        """Select a site by id (emits site_changed if it changed)."""
        if sid and sid != self.site and self.survey is not None and sid in self.survey.edis:
            self.site = sid
            self.site_changed.emit(sid)

    def rel(self, path: str | os.PathLike) -> str:
        """path relative to the repository root with forward slashes when inside it, else absolute."""
        p = Path(os.path.abspath(path))
        try:
            return p.relative_to(self.repo.resolve()).as_posix()
        except ValueError:
            try:
                return p.relative_to(self.repo).as_posix()
            except ValueError:
                return p.as_posix()

    def run_dir(self) -> str:
        """paths.run_dir of the open config, repository-relative (prep's default --out)."""
        return self.rel(self.c["run_dir"]) if self.c else ""
