# -*- coding: utf-8 -*-
"""gui_smoke.py - headless smoke test of the whole GUI (T11, T13): QT_QPA_PLATFORM=offscreen, no real job.

It opens a copy of config/vulcan_mesh_v2_rot.yml (paths.root made absolute, in a temporary folder), visits every
tab, clicks a site, changes per_decade and a floor, saves as a new file, presses every job button and fills the
New-run form from RUNBOOK.md's own Run06 line. JobRunner._start is replaced by a recorder (no process starts),
QFileDialog and QMessageBox are stubbed (no modal dialog blocks), socket connections are recorded and refused,
runs/ is a temporary copy ($RUNS) and QSettings a temporary file. Every step reports "fails if" and its failing
case first. Exceptions raised inside Qt slots are caught through sys.excepthook and fail the step.

    python tests/gui/gui_smoke.py

@author ben kay
:license: MIT
"""
from __future__ import annotations

import os
import shlex
import shutil
import subprocess
import sys

from _smoke_harness import (  # first: it sets up the offscreen platform and the stubs
    ANSWER, APP, BASE, BEFORE, CONNECTS, DIALOGS, EXC, RECORDED, STUDENT, TMP, C, MainWindow, QtCore, QtTest,
    click, fill_form, new_window, no_exceptions, pump, runbook_line, snapshot, tree_items)

from femtic_gui.jobs import display_command  # noqa: E402

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


def test_new_run_form_types_the_runbook_command():
    """This test fails unless the New-run form, filled with the values of RUNBOOK.md's Run06 line, records exactly
    that command's argv (Git Bash as argv[0]) and previews it character for character as the RUNBOOK types it.
    Failing case: RUNBOOK.md's Run07 line as the expectation."""
    W.tabs.setCurrentWidget(W.runs_tab)
    form = W.runs_tab.form
    assert form.name.text() == "Run06", "next free run name %r, expected Run06" % form.name.text()
    fill_form(form, runbook_line("Run06"))
    pump()
    del RECORDED[:]
    click(form.button)
    no_exceptions("make run")
    print("    preview: %s" % form.preview.toPlainText())

    def check(run):
        line = runbook_line(run)
        ok = (len(RECORDED) == 1 and RECORDED[0][0] == W.runs_tab.bash and RECORDED[0][1:] == shlex.split(line)[1:]
              and display_command(RECORDED[0]) == line == form.preview.toPlainText())
        return ok, "recorded vs RUNBOOK %s line: equal %s" % (run, ok)

    C.fails_first(check, "Run07")
    C.passes(check, "Run06")


def test_record_result_in_temp_runs():
    """This test fails unless Record result writes the job ids and verdict into the Run01 line of the temporary
    INDEX.md only and shows R6's git line. Failing case: the repository's own INDEX.md, which must not change."""
    t = W.runs_tab.table
    row = next(r for r in range(t.rowCount()) if t.item(r, 0).text() == "Run01")
    QtTest.QTest.mouseClick(t.viewport(), QtCore.Qt.MouseButton.LeftButton,
                            pos=t.visualItemRect(t.item(row, 0)).center())
    pump()
    W.runs_tab.rec_jobs.setText("123456")
    W.runs_tab.rec_verdict.setText("PASS smoke")
    click(W.runs_tab.rec_button)
    no_exceptions("record result")

    def check(index):
        line = next(ln for ln in index.read_text(encoding="utf-8").splitlines() if ln.startswith("| Run01 |"))
        git = W.runs_tab.git_line.text()
        ok = line.endswith("| 123456 | PASS smoke |") and git == ('git add runs/Run01 runs/INDEX.md && git commit '
                                                                 '-m "Run01: PASS smoke"')
        return ok, "%s: %s" % (index.parent.name, line[-40:])

    C.fails_first(check, C.REPO / "runs" / "INDEX.md")
    C.passes(check, TMP / "runs" / "INDEX.md")


def test_mesh_tab_counts_and_runbook():
    """This test fails unless the Mesh tab shows v2's measured counts (2446095 elements) and no design warning, and
    Help > Runbook opens the runbook. Failing case: a config whose mesh.reuse_from is v3."""
    def check(mesh_dir_text):
        return "elements 2446095" in mesh_dir_text and W.mesh_tab.warnings.text() == "none", \
            "counts: %s" % mesh_dir_text.splitlines()[1][:60]

    v3 = "mesh/vulcan_v3\n" + "\n".join((C.REPO / "mesh" / "vulcan_v3" / "mesh_logs" / "mesh_stats.txt")
                                        .read_text(encoding="utf-8").splitlines()[:2])
    C.fails_first(check, v3)
    W.tabs.setCurrentWidget(W.mesh_tab)
    C.passes(check, W.mesh_tab.counts.text())
    W.show_runbook()
    pump()
    texts = [w.text_view.toPlainText() for w in APP.topLevelWidgets() if hasattr(w, "text_view")]
    assert any("Runbook" in x for x in texts), "Help > Runbook showed no runbook"
    no_exceptions("mesh tab and runbook")


def test_results_tab_on_fixture():
    """This test fails unless the Results tab, opened (Open folder...) on a copy of tests/gui/fixtures/b1 with its
    station_map.csv and a model file, lists one model, one data fit and one convergence entry; the fit shows an
    overall RMS equal to femtic.cnv's (21.8032), 120 sites in the residual table and four curves for a clicked
    site; the convergence plots femtic.cnv's one iteration; the model page disables its 3D button with the reason
    (no mesh known); and the folder joins File > Recent run folders. Failing case: the tab before the folder opens."""
    b1 = TMP / "b1"
    b1.mkdir()
    shutil.copy(C.HERE / "fixtures" / "b1" / "b1_result_0_iter0.csv", b1 / "result_0_iter0.csv")
    shutil.copy(C.HERE / "fixtures" / "b1" / "femtic.cnv", b1 / "femtic.cnv")
    shutil.copy(C.REPO / "mesh" / "vulcan_v1" / "inversion" / "station_map.csv", b1 / "station_map.csv")
    (b1 / "resistivity_block_iter3.dat").write_text("never read by the 2D steps", encoding="utf-8")
    R = W.results_tab
    W.tabs.setCurrentWidget(R)

    def check(_when):
        groups = {g: len(tree_items(R.tree, g)) for g in ("model", "data fit", "convergence")}
        if groups != {"model": 1, "data fit": 1, "convergence": 1}:
            return False, "list %s" % groups
        R.tree.setCurrentItem(tree_items(R.tree, "data fit")[0])
        pump()
        t = R.residuals
        QtTest.QTest.mouseClick(t.viewport(), QtCore.Qt.MouseButton.LeftButton,
                                pos=t.visualItemRect(t.item(1, 0)).center())
        pump()
        curves = len([i for i in R.fit_curves.rho.listDataItems() if i.name()])
        fit = (R.misfit_note.text().split(";")[0], t.rowCount(), curves, len(R.misfit_map._sel.data))
        R.tree.setCurrentItem(tree_items(R.tree, "convergence")[0])
        pump()
        cnv = [len(d.getData()[0]) for d in R.rms_plot.listDataItems()]
        R.tree.setCurrentItem(tree_items(R.tree, "model")[0])
        pump()
        view = (R.view_btn.isEnabled(), "choose it" in R.view_btn.toolTip())
        recent = str(b1) in [a.text() for a in W.recent_runs_menu.actions()]
        ok = (fit == ("iteration 0: overall RMS 21.8032 over 240 data lines", 120, 4, 1) and cnv == [1]
              and view == (False, True) and recent)
        return ok, "fit %s; convergence points %s; 3D button (enabled, reason) %s; recent %s" % (fit, cnv, view,
                                                                                               recent)

    C.fails_first(check, "before")
    ANSWER["dir"] = b1
    click(R.open_folder_btn)
    no_exceptions("results tab")
    C.passes(check, "after")


VTK_MODULES = ("vtk", "vtkmodules", "pyvista", "pyvistaqt", "femtic_gui.viewer3d")
MODULE_CHECK = ("import sys; mods = %r; print(sorted(m for m in sys.modules if m in mods or "
                "m == 'PySide6.QtNetwork'))" % (VTK_MODULES,))


def test_no_vtk_no_network_after_2d_clicks():
    """This test fails if vtk, vtkmodules, pyvista, pyvistaqt or femtic_gui.viewer3d is in sys.modules after all the
    2D steps, PySide6.QtNetwork was loaded, or any socket connection was attempted (T11). Failing case: a child
    process that imports femtic_gui.viewer3d, as a tab importing it at module level would."""
    def check(mods):
        ok = not mods and not CONNECTS
        return ok, "loaded %s; connections %s" % (mods, CONNECTS)

    child = subprocess.run([sys.executable, "-c", "import femtic_gui.viewer3d; " + MODULE_CHECK],
                           capture_output=True, text=True, env=dict(os.environ, PYTHONPATH=str(C.REPO / "src")))
    C.fails_first(check, eval(child.stdout.strip() or "['child failed']"))
    C.passes(check, sorted(m for m in sys.modules if m in VTK_MODULES or m == "PySide6.QtNetwork"))


def test_without_vtk_3d_buttons_disabled():
    """This test fails unless, with vtkmodules unimportable (sys.modules['vtkmodules'] = None; pyvista imports it),
    a new window opens the config, both 3D buttons are disabled with a tooltip naming the missing module, and a
    3D Load still called shows '3D viewer unavailable' instead of failing. Failing case: the first window, where
    VTK is installed."""
    from femtic_gui.tabs.common import open_viewer

    def check(win):
        m = win.mesh_tab
        n = len(DIALOGS)
        opened = open_viewer(m, C.REPO / "mesh.dat") if not m.open_btn.isEnabled() else "skipped"
        warned = any("3D viewer unavailable" in t for _k, _ti, t in DIALOGS[n:])
        ok = (not m.view_btn.isEnabled() and not m.open_btn.isEnabled() and opened is None and warned
              and "3D viewer unavailable: vtkmodules" in m.open_btn.toolTip())
        return ok, "Open mesh button enabled %s; Load warned %s; tooltip %r" % (
            m.open_btn.isEnabled(), warned, m.open_btn.toolTip()[:70])

    C.fails_first(check, W)
    sys.modules["vtkmodules"] = None
    try:
        w2 = new_window()
        w2.open_config(STUDENT)
        no_exceptions("second window without VTK")
        C.passes(check, w2)
        w2.close()
    finally:
        del sys.modules["vtkmodules"]


def test_no_file_outside_temp_changed():
    """This test fails if any file under config/, runs/, scripts/, mesh/vulcan_v2_rot/, mesh/vulcan_v1/inversion/,
    tests/gui/fixtures/ or the runbook, or the user's own femtic_gui settings file, changed during the smoke test.
    Failing case: a snapshot with one file's time changed."""
    def check(after):
        diff = sorted(k for k in set(BEFORE) | set(after) if BEFORE.get(k) != after.get(k))
        return not diff, "%d of %d watched files changed %s" % (len(diff), len(after), diff[:3])

    fake = dict(BEFORE)
    k = next(iter(fake))
    fake[k] = (0, 0)
    C.fails_first(check, fake)
    C.passes(check, snapshot())


if __name__ == "__main__":
    try:
        C.run(globals())
    finally:
        for w in list(APP.topLevelWidgets()):
            w.close()
        shutil.rmtree(TMP, ignore_errors=True)
    print("=== %d PASS, %d FAIL, %d NOT RUN" % (C.TALLY["PASS"], C.TALLY["FAIL"], C.TALLY["NOT RUN"]))
    sys.exit(1 if C.TALLY["FAIL"] else 2 if C.TALLY["NOT RUN"] else 0)
