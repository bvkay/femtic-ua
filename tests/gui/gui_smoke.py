# -*- coding: utf-8 -*-
"""gui_smoke.py - headless smoke test of the whole GUI (T11, T13): QT_QPA_PLATFORM=offscreen, no real job.

It opens a copy of config/vulcan_mesh_v2_rot.yml (paths.root made absolute, in a temporary folder), visits every
tab, checks every button's tooltip, clicks a site, checks the map's labels, changes per_decade and a floor, saves
as a new file and presses every job button; gui_smoke_steps.py, run after these steps on the same window, does the
Runs, Mesh and Results tabs and the VTK, network and file checks. JobRunner._start is replaced by a recorder
(no process starts), QFileDialog and QMessageBox are stubbed (no modal dialog blocks), socket connections are
recorded and refused, runs/ is a temporary copy ($RUNS) and QSettings a temporary file. Every step reports
"fails if" and its failing case first. Exceptions raised inside Qt slots are caught through sys.excepthook and
fail the step.

    python tests/gui/gui_smoke.py

@author ben kay
:license: MIT
"""
from __future__ import annotations

import shutil
import sys

from _smoke_harness import (  # first: it sets up the offscreen platform and the stubs
    ANSWER, APP, BASE, DIALOGS, EXC, RECORDED, STUDENT, TMP, C, MainWindow, QtCore, QtTest, click, new_window,
    no_exceptions, pump)
from PySide6 import QtWidgets

import gui_smoke_steps
from femtic_gui import plots
from femtic_gui.jobs import display_command

W: MainWindow = None  # type: ignore[assignment]


def test_open_and_visit_every_tab():
    """This test fails if File > Open does not open the config (120 sites in the Data tab, the title naming it) or
    any tab raises while it reloads or is shown. Failing case: a Mesh tab whose reload raises."""
    global W
    W = new_window()
    ANSWER["open"] = BASE
    W.open_dialog()
    pump()

    def check(_label):
        n = len(EXC)
        W.state.config_changed.emit()
        for i in range(W.tabs.count()):
            W.tabs.setCurrentIndex(i)
            pump()
        new = EXC[n:]
        del EXC[n:]
        ok = not new and W.data_tab.sites.rowCount() == 120 and "base.yml" in W.windowTitle()
        return ok, "%d tabs visited; exceptions %s; title %r" % (W.tabs.count(), new, W.windowTitle())

    real = W.mesh_tab.reload
    W.mesh_tab.reload = lambda: 1 / 0
    C.fails_first(check, "broken")
    W.mesh_tab.reload = real
    C.passes(check, "real")


def test_every_button_has_a_tooltip():
    """This test fails if any push button of the open window has no tooltip (what it runs, or why it is disabled),
    or the Results tab's 'Open 3D viewer' does not say to select a model before one is selected. Failing case: the
    Results tab's 'Choose mesh.dat...' and 'Open 3D viewer' as phase 1 left them (no tooltip; verifier 10-06)."""
    R = W.results_tab

    def check(_when):
        buttons = W.findChildren(QtWidgets.QPushButton)
        bare = [b.text() for b in buttons if not b.toolTip()]
        ok = not bare and "select a model" in R.view_btn.toolTip()
        return ok, "%d push buttons, without a tooltip %s; Open 3D viewer: %r" % (
            len(buttons), bare, R.view_btn.toolTip()[:60])

    saved = [(b, b.toolTip()) for b in (R.choose_mesh_btn, R.view_btn)]
    for b, _t in saved:
        b.setToolTip("")
    try:
        C.fails_first(check, "phase 1")
    finally:
        for b, t in saved:
            b.setToolTip(t)
    C.passes(check, "real")


def test_click_a_site_draws_it():
    """This test fails unless clicking a site's row selects it in State, rings it on the map and draws its xy and yx
    curves (two frames each). Failing case: the check before the click."""
    W.tabs.setCurrentWidget(W.data_tab)
    t = W.data_tab.sites
    target = "A10"
    row = next(r for r in range(t.rowCount()) if t.item(r, 0).text() == target)

    def check(_when):
        curves = [i for i in W.data_tab.curves.rho.listDataItems() if i.name()]
        ok = W.state.site == target and len(curves) == 4 and len(W.data_tab.map._sel.data) == 1
        return ok, "site %s, %d named curves" % (W.state.site, len(curves))

    C.fails_first(check, "before")
    QtTest.QTest.mouseClick(t.viewport(), QtCore.Qt.MouseButton.LeftButton,
                            pos=t.visualItemRect(t.item(row, 0)).center())
    no_exceptions("site click")
    C.passes(check, "after")


def test_site_map_labels_selected_only():
    """This test fails unless the Data tab's map keeps all 120 markers and, at its default whole-survey view, shows
    at most 1 label, the selected site's, while a view zoomed to a few sites labels every site in it. Failing
    case: every label shown, as phase 1 drew them (the zoom threshold above the 120 sites)."""
    m = W.data_tab.map

    def check(_when):
        m.autoRange()
        pump()
        default = m.visible_labels()
        x, y = m._xy[W.state.site]
        m.setRange(xRange=(x - 1.2, x + 1.2), yRange=(y - 1.2, y + 1.2), padding=0)
        pump()
        (x0, x1), (y0, y1) = m.getViewBox().viewRange()
        in_view = sorted(i for i, (a, b) in m._xy.items() if x0 <= a <= x1 and y0 <= b <= y1)
        zoomed = sorted(m.visible_labels())
        m.autoRange()
        pump()
        ok = len(m._points.data) == 120 and default == [W.state.site] and 1 < len(in_view) and zoomed == in_view
        return ok, "%d markers; %d label(s) at the default view %s; zoomed in: %d of %d sites labelled" % (
            len(m._points.data), len(default), default[:3], len(zoomed), len(in_view))

    saved = plots.LABEL_ALL_AT_MOST
    plots.LABEL_ALL_AT_MOST = 10 ** 6
    try:
        C.fails_first(check, "phase 1")
    finally:
        plots.LABEL_ALL_AT_MOST = saved
    C.passes(check, "real")
    no_exceptions("site map labels")


def test_per_decade_and_floor_update_previews():
    """This test fails unless a Zxy floor of 0.1 turns the readout to 2514/2503/2413/2511 of 2520 and then
    per_decade 5 selects 26 bands (26 band lines on the curves) and recounts the readout over them, with the config
    now unsaved. Failing case: the values before the edits."""
    from femtic_gui import prep_api
    p = W.data_tab.panel

    def check(_when):
        lines = [i for i in W.data_tab.curves.rho.items() if type(i).__name__ == "InfiniteLine"]
        counts, total = prep_api.floor_counts(W.state.survey, W.data_tab.chosen, [0.2, 0.1, 0.05, 0.2])
        want = "(%s of %d site-band pairs)" % ("/".join(str(k) for k in counts), total)
        ok = len(W.data_tab.chosen) == 26 and len(lines) == 26 and want in p.floor_readout.text() and W.state.dirty
        return ok, "%d bands, %d lines; %s; dirty %s" % (len(W.data_tab.chosen), len(lines),
                                                         p.floor_readout.text(), W.state.dirty)

    C.fails_first(check, "before")
    p.floors[1].setValue(0.1)
    pump()
    assert "(2514/2503/2413/2511 of 2520 site-band pairs)" in p.floor_readout.text(), p.floor_readout.text()
    print("    Zxy floor 0.1: %s" % p.floor_readout.text())
    p.per_decade.setValue(5)
    no_exceptions("per_decade and floor edits")
    C.passes(check, "after")


def test_job_buttons_disabled_while_unsaved():
    """This test fails if Check or Run prep is enabled, or records a command when clicked, while the config has unsaved
    edits (T13). Failing case: the buttons as a panel that ignored the unsaved state would leave them."""
    p = W.data_tab.panel

    def check(_when):
        n = len(RECORDED)
        click(p.check_btn)
        click(p.prep_btn)
        ok = (W.state.dirty and not p.check_btn.isEnabled() and not p.prep_btn.isEnabled() and len(RECORDED) == n
              and p.prep_btn.toolTip().startswith("Disabled: unsaved edits"))
        return ok, "enabled: Check %s, Run prep %s; commands recorded %d" % (
            p.check_btn.isEnabled(), p.prep_btn.isEnabled(), len(RECORDED) - n)

    p.check_btn.setEnabled(True)
    p.prep_btn.setEnabled(True)
    C.fails_first(check, "mutant")
    del RECORDED[:]
    p.update_buttons()
    C.passes(check, "real")


def test_save_as_new_file_then_refuse_existing():
    """This test fails unless File > Save as writes a new file that differs from the opened one only in name,
    paths.run_dir, per_decade and error_floor_Z, and a second Save as onto that existing file is refused with a
    warning and leaves its bytes unchanged (T13). Failing case: the check applied to the first save (a write)."""
    base_lines = BASE.read_text(encoding="utf-8").splitlines()

    def check(before):
        now = STUDENT.read_bytes() if STUDENT.exists() else None
        warned = any(k == "warning" and "exists" in t for k, _ti, t in DIALOGS)
        return now == before and warned, "file %s; refusal warning %s" % (
            "unchanged" if now == before else "written", warned)

    ANSWER["save"] = STUDENT
    W.save_as_dialog()
    no_exceptions("save as")
    C.fails_first(check, None)
    changed = [i + 1 for i, (a, b) in enumerate(zip(base_lines, STUDENT.read_text(encoding="utf-8").splitlines()))
               if a != b]
    assert changed == [20, 27, 52, 82] and not W.state.dirty, "lines changed %s, dirty %s" % (changed, W.state.dirty)
    print("    saved %s: lines %s changed (name, run_dir, error_floor_Z, per_decade)" % (STUDENT.name, changed))
    before = STUDENT.read_bytes()
    W.data_tab.panel.per_decade.setValue(4)
    W.save_as_dialog()
    no_exceptions("second save as")
    C.passes(check, before)


def test_prep_buttons_record_exact_commands():
    """This test fails unless Check and Run prep, once the config is saved, record exactly
    [python, scripts/prep_vulcan.py, <config>, --check-only|--out, <dir>] and their tooltips show that command.
    Failing case: the Check command expected with --out."""
    W.state.open_config(STUDENT)                 # drop the unsaved per_decade edit of the previous step
    p = W.data_tab.panel
    cfg = STUDENT.as_posix()
    p.out_dir.setText("mesh/vulcan_v2_rot")
    out = (TMP / "prep_out").as_posix()

    def check(flag_check):
        del RECORDED[:]
        p.out_dir.setText("mesh/vulcan_v2_rot")
        click(p.check_btn)
        p.out_dir.setText(out)
        tip = p.prep_btn.toolTip()
        click(p.prep_btn)
        want = [[sys.executable, "scripts/prep_vulcan.py", cfg, flag_check, "mesh/vulcan_v2_rot"],
                [sys.executable, "scripts/prep_vulcan.py", cfg, "--out", out]]
        ok = RECORDED == want and tip == display_command(want[1])
        return ok, "recorded %s" % [display_command(a) for a in RECORDED]

    C.fails_first(check, "--out")
    C.passes(check, "--check-only")
    no_exceptions("prep buttons")


def test_femtic_curated_edit():
    """This test fails unless a curated FEMTIC value typed into the table (TRADE_OFF_PARAM 10) reaches the config
    and a non-number is refused with the value kept, and read-only rows are not editable. Failing case: the
    MESH_TYPE row."""
    W.tabs.setCurrentWidget(W.femtic_tab)
    t = W.femtic_tab.table
    rows = {t.item(r, 0).text(): r for r in range(t.rowCount())}

    def check(key):
        it = t.item(rows[key], 1)
        editable = bool(it.flags() & QtCore.Qt.ItemFlag.ItemIsEditable)
        if editable:
            it.setText("10")
            pump()
            got = W.state.get("inversion.TRADE_OFF_PARAM")
            t.item(rows[key], 1).setText("abc")
            pump()
            kept = W.state.get("inversion.TRADE_OFF_PARAM")
            ok = got == [10.0] and kept == [10.0]
        else:
            ok, got, kept = False, None, None
        return ok, "%s editable %s; after '10': %s; after 'abc': %s" % (key, editable, got, kept)

    C.fails_first(check, "MESH_TYPE")
    C.passes(check, "TRADE_OFF_PARAM")
    no_exceptions("FEMTIC edit")


if __name__ == "__main__":
    try:
        C.run(globals())
        gui_smoke_steps.W = W
        C.run(vars(gui_smoke_steps))
    finally:
        for w in list(APP.topLevelWidgets()):
            w.close()
        shutil.rmtree(TMP, ignore_errors=True)
    print("=== %d PASS, %d FAIL, %d NOT RUN" % (C.TALLY["PASS"], C.TALLY["FAIL"], C.TALLY["NOT RUN"]))
    sys.exit(1 if C.TALLY["FAIL"] else 2 if C.TALLY["NOT RUN"] else 0)
