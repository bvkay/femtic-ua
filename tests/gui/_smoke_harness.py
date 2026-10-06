# -*- coding: utf-8 -*-
"""_smoke_harness.py - the harness of gui_smoke.py: imported first, before Qt and the GUI.

Sets QT_QPA_PLATFORM=offscreen, records and refuses every socket connection, stubs QFileDialog and QMessageBox
(answers in ANSWER, calls in DIALOGS), catches exceptions raised inside Qt slots (EXC), makes the temporary
folder (config copy with an absolute paths.root, runs/ copy as $RUNS, QSettings file) and the window factory
whose JobRunner._start only records argv (RECORDED). BEFORE is the snapshot of the watched repository files.

@author ben kay
:license: MIT
"""
from __future__ import annotations

import os
import shlex
import shutil
import socket
import sys
import tempfile
from pathlib import Path

os.environ["QT_QPA_PLATFORM"] = "offscreen"
CONNECTS: list = []


def _refuse_network(*args, **_kw):
    CONNECTS.append(repr(args[-1] if args else None)[:80])
    raise OSError("gui_smoke.py: network refused")


socket.socket.connect = lambda self, addr: _refuse_network(addr)
socket.socket.connect_ex = lambda self, addr: _refuse_network(addr)
socket.create_connection = lambda addr, *a, **k: _refuse_network(addr)
socket.getaddrinfo = lambda host, *a, **k: _refuse_network(host)

import _common as C  # noqa: E402
from PySide6 import QtCore, QtTest, QtWidgets  # noqa: E402

from femtic_gui import theme  # noqa: E402
from femtic_gui.app import MainWindow  # noqa: E402

EXC: list = []
sys.excepthook = lambda t, v, tb: EXC.append("%s: %s" % (t.__name__, v))
APP = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
theme.apply(APP)
TMP = Path(tempfile.mkdtemp(prefix="femtic_gui_smoke_"))
(TMP / "config").mkdir()
(TMP / "runs").mkdir()
shutil.copy(C.REPO / "runs" / "INDEX.md", TMP / "runs" / "INDEX.md")
os.environ["RUNS"] = str(TMP / "runs")
BASE = C.abs_root_copy(TMP / "config", "base.yml")
STUDENT = TMP / "config" / "student.yml"
DIALOGS: list = []
ANSWER = {"open": "", "save": "", "dir": "", "question": QtWidgets.QMessageBox.StandardButton.Yes}
RECORDED: list = []
WATCH = [C.REPO / "config", C.REPO / "runs", C.REPO / "scripts", C.REPO / "mesh" / "vulcan_v2_rot",
         C.REPO / "hpc" / "phoenix_plan" / "RUNBOOK.md", C.HERE / "fixtures",
         C.REPO / "mesh" / "vulcan_v1" / "inversion"]


def _dialog(kind):
    def f(_parent, title, text="", *a, **k):
        DIALOGS.append((kind, title, str(text)))
        return ANSWER["question"] if kind == "question" else QtWidgets.QMessageBox.StandardButton.Ok
    return f


QtWidgets.QFileDialog.getOpenFileName = lambda *a, **k: (str(ANSWER["open"]), "")
QtWidgets.QFileDialog.getSaveFileName = lambda *a, **k: (str(ANSWER["save"]), "")
QtWidgets.QFileDialog.getExistingDirectory = lambda *a, **k: str(ANSWER["dir"])
for _kind in ("warning", "critical", "information", "question", "about"):
    setattr(QtWidgets.QMessageBox, _kind, _dialog(_kind))


def snapshot() -> dict:
    """(size, mtime) of every file the GUI could touch outside the temporary folder."""
    snap = {}
    for root in WATCH:
        files = [root] if root.is_file() else [p for p in root.rglob("*") if p.is_file()]
        for p in files:
            if "__pycache__" not in p.parts:
                st = p.stat()
                snap[str(p)] = (st.st_size, st.st_mtime_ns)
    user_ini = QtCore.QSettings(QtCore.QSettings.Format.IniFormat, QtCore.QSettings.Scope.UserScope,
                                "femtic_gui", "femtic_gui").fileName()
    snap[user_ini] = Path(user_ini).stat().st_mtime_ns if Path(user_ini).exists() else None
    return snap


BEFORE = snapshot()


def pump(n: int = 5) -> None:
    for _ in range(n):
        APP.processEvents()


def new_window() -> MainWindow:
    w = MainWindow(settings=QtCore.QSettings(str(TMP / "settings.ini"), QtCore.QSettings.Format.IniFormat))
    runner = w.state.runner

    def fake_start(argv, env):
        RECORDED.append(list(argv))
        runner._done(True, "done (exit 0)")
    runner._start = fake_start
    w.show()
    pump()
    return w


def no_exceptions(step: str) -> None:
    pump()
    assert not EXC, "%s raised inside Qt: %s" % (step, EXC)


def click(widget) -> None:
    QtTest.QTest.mouseClick(widget, QtCore.Qt.MouseButton.LeftButton)
    pump()


def runbook_line(run: str) -> str:
    text = (C.REPO / "hpc" / "phoenix_plan" / "RUNBOOK.md").read_text(encoding="utf-8")
    return next(ln.strip() for ln in text.splitlines() if ln.startswith("bash scripts/make_run.sh %s " % run))


def fill_form(form, line: str) -> None:
    """Type a make_run.sh command line into the New-run form, field by field (a mesh build has no --mesh)."""
    a = shlex.split(line)[2:]
    form.name.setText(a[0])
    opts = dict(zip(a[1::2], a[2::2]))
    if "--mesh" in opts:
        form.mesh.setCurrentText(opts["--mesh"])
    form.job.setCurrentText(opts["--job"])
    for opt, w in (("--data", form.data), ("--start-rho", form.start_rho), ("--layout", form.layout_),
                   ("--time", form.time), ("--purpose", form.purpose), ("--iter-step", form.iter_step),
                   ("--iter-max", form.iter_max), ("--niv", form.niv), ("--mail", form.mail),
                   ("--files", form.files), ("--seeds", form.seeds)):
        w.setText(opts.get(opt, ""))


def tree_items(tree, group: str) -> list:
    tops = [tree.topLevelItem(t) for t in range(tree.topLevelItemCount())]
    return [top.child(i) for top in tops if top.text(0) == group for i in range(top.childCount())]
