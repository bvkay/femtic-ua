# -*- coding: utf-8 -*-
"""test_state.py - State: opening configs, unsaved-edit tracking, site selection and job state signals.

    python tests/gui/test_state.py

@author ben kay
:license: MIT
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

import _common as C
from PySide6 import QtCore

from femtic_gui import config_io, prep_api
from femtic_gui.state import State

APP = QtCore.QCoreApplication.instance() or QtCore.QCoreApplication([])


def _record(state: State) -> list:
    ev = []
    state.config_changed.connect(lambda: ev.append("config"))
    state.dirty_changed.connect(lambda d: ev.append(("dirty", d)))
    state.site_changed.connect(lambda s: ev.append(("site", s)))
    state.job_state_changed.connect(lambda r: ev.append(("job", r)))
    return ev


def test_open_loads_inputs_and_bad_config_changes_nothing():
    """This test fails unless opening CFG loads 120 sites and 120 EDIs with one config_changed, and opening a config
    prep refuses raises PrepFailure and leaves the open config, its inputs and the signals untouched.
    Failing case: the refused config checked as if it were the good one."""
    with C.temp_dir("state") as d:
        bad = C.abs_root_copy(Path(d), "bad.yml", {"data.error_floor_Z": [0.2, 0.05]})
        s = State(C.REPO)
        ev = _record(s)
        s.open_config(C.CFG)

        def check(path):
            before = (s.doc.path, len(ev))
            try:
                s.open_config(path)
                refused = False
            except prep_api.PrepFailure:
                refused = True
            ok = refused and (s.doc.path, len(ev)) == before and len(s.survey.edis) == 120
            return ok, "refused %s; open file %s; events %s" % (refused, s.doc.path.name, ev)

        C.fails_first(check, C.CFG)
        assert ev[0] == "config" and len(s.survey.sites) == 120, ev
        C.passes(check, bad)


def test_dirty_follows_the_text():
    """This test fails unless an edit sets dirty with one dirty_changed(True), and editing the value back clears it
    with one dirty_changed(False). Failing case: a State whose set_value skips the signal."""
    class Mute(State):
        def set_value(self, dotted, value):
            self.doc = config_io.set_value(self.doc, dotted, value)

    def check(cls):
        s = cls(C.REPO)
        s.open_config(C.CFG)
        ev = _record(s)
        s.set_value("frequencies.per_decade", 5)
        mid = s.dirty
        s.set_value("frequencies.per_decade", 4)
        ok = mid and not s.dirty and ev == [("dirty", True), ("dirty", False)] and s.doc.text == s.doc.saved_text
        return ok, "dirty after edit %s, after undo %s; events %s" % (mid, s.dirty, ev)

    C.fails_first(check, Mute)
    C.passes(check, State)


def test_site_selection_signal():
    """This test fails unless select_site emits site_changed once for a new known site and never for an unknown or
    the current one. Failing case: an unknown site id expected to select."""
    s = State(C.REPO)
    s.open_config(C.CFG)
    ev = _record(s)

    def check(sid):
        n = len(ev)
        s.select_site(sid)
        s.select_site(sid)
        return ev[n:] == [("site", sid)] and s.site == sid, "events %s, site %s" % (ev[n:], s.site)

    C.fails_first(check, "NOT_A_SITE")
    C.passes(check, "A10")


def test_job_state_signals():
    """This test fails unless a job toggles job_state_changed True then False and job_running follows it.
    Failing case: checking before the job has ended."""
    s = State(C.REPO)
    ev = _record(s)
    seen = []
    s.runner.started.connect(lambda _l: seen.append(s.job_running))

    def check(wait):
        del ev[:]
        s.runner.run("t", [sys.executable, "-c", "pass"])
        t0 = time.perf_counter()
        while wait and s.job_running and time.perf_counter() - t0 < 30:
            APP.processEvents(QtCore.QEventLoop.ProcessEventsFlag.AllEvents, 50)
        ok = ev == [("job", True), ("job", False)] and not s.job_running and seen[-1] is True
        detail = "events %s, running %s" % (list(ev), s.job_running)
        while s.job_running:                       # let the failing case's job end before the real case
            APP.processEvents(QtCore.QEventLoop.ProcessEventsFlag.AllEvents, 50)
        return ok, detail

    C.fails_first(check, False)
    C.passes(check, True)


if __name__ == "__main__":
    C.main(globals())
