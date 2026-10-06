# -*- coding: utf-8 -*-
"""gui_smoke_steps.py - the second half of the headless smoke test; gui_smoke.py runs it (not a script itself).

Runs tab (RUNBOOK.md's Run06 line typed in, a second click after a made run, the mesh-build job, Record result),
the Mesh tab and Help > Runbook, Results on the b1 fixture, no VTK or network after the 2D steps, the 3D buttons
without VTK, and no watched file changed. W is the window gui_smoke.py opened: it sets W before these steps run.
Same rules as gui_smoke.py: every step reports "fails if" and its failing case first; no real job starts.

@author ben kay
:license: MIT
"""
from __future__ import annotations

import os
import re
import shlex
import shutil
import subprocess
import sys

from _smoke_harness import (
    ANSWER, APP, BEFORE, CONNECTS, DIALOGS, RECORDED, STUDENT, TMP, C, MainWindow, QtCore, QtTest, click,
    fill_form, new_window, no_exceptions, pump, runbook_line, snapshot, tree_items)

from femtic_gui.jobs import display_command

W: MainWindow = None  # type: ignore[assignment]      # set by gui_smoke.py once its first step opened the window
MESH_ROWS = ("--files", "--seeds", "--mesh", "--data", "--niv")


def header_line(job: str) -> str:
    """make_run.sh's own example command for a job, from its header comment."""
    text = (C.REPO / "scripts" / "make_run.sh").read_text(encoding="utf-8")
    return next(ln.lstrip("# ").strip() for ln in text.splitlines()
                if ln.lstrip("# ").startswith("bash scripts/make_run.sh ") and "--job %s " % job in ln)


def run04_line() -> str:
    """Run04's make_run.sh command rebuilt from its RUN.md (files and seeds; its run.env has the default 1x8 and
    04:00:00, so --layout and --time were not typed)."""
    md = (C.REPO / "runs" / "Run04" / "RUN.md").read_text(encoding="utf-8")
    purpose = re.search(r"^- purpose: (.*)$", md, re.M).group(1)
    m = re.search(r'^- files: (\S+) \(copied into files/\); files/region_seeds.dat written from --seeds "(.*)"$',
                  md, re.M)
    return 'bash scripts/make_run.sh Run04 --job mesh --files %s --seeds "%s" --purpose "%s"' % (
        m.group(1), m.group(2), purpose)


def test_new_run_form_types_the_runbook_command():
    """This test fails unless the New-run form, filled with the values of RUNBOOK.md's Run06 line, records exactly
    that command's argv (Git Bash as argv[0]) and previews it, as shown when clicked, character for character as
    the RUNBOOK types it. Failing case: RUNBOOK.md's Run07 line as the expectation."""
    W.tabs.setCurrentWidget(W.runs_tab)
    form = W.runs_tab.form
    assert form.name.text() == "Run06", "next free run name %r, expected Run06" % form.name.text()
    fill_form(form, runbook_line("Run06"))
    pump()
    shown = form.preview.toPlainText()            # a made run clears the form, so the preview is read before
    del RECORDED[:]
    click(form.button)
    no_exceptions("make run")
    print("    preview: %s" % shown)

    def check(run):
        line = runbook_line(run)
        ok = (len(RECORDED) == 1 and RECORDED[0][0] == W.runs_tab.bash and RECORDED[0][1:] == shlex.split(line)[1:]
              and display_command(RECORDED[0]) == line == shown)
        return ok, "recorded vs RUNBOOK %s line: equal %s" % (run, ok)

    C.fails_first(check, "Run07")
    C.passes(check, "Run06")


def test_second_make_needs_a_new_purpose():
    """This test fails if two successive 'Make run folder' clicks, the first one succeeding, record the same
    --purpose or the same --start-rho: a made run clears --purpose and the job-specific fields, so the second
    click cannot make a duplicate-purpose run (make_run.sh refuses the empty --purpose). Failing case: a form whose
    clear_after_make does nothing (phase 1 kept --purpose, --time and --start-rho)."""
    form = W.runs_tab.form

    def check(_when):
        fill_form(form, runbook_line("Run07"))
        pump()
        del RECORDED[:]
        click(form.button)
        click(form.button)
        got = [(o.get("--purpose"), o.get("--start-rho")) for o in (dict(zip(a[3::2], a[4::2])) for a in RECORDED)]
        ok = len(got) == 2 and got[0][0] != got[1][0] and got[0][1] != got[1][1]
        return ok, "(purpose, start-rho) of the two clicks %s" % got

    form.clear_after_make = lambda: None
    try:
        C.fails_first(check, "mutant")
    finally:
        del form.clear_after_make
    C.passes(check, "real")
    no_exceptions("two makes")


def test_new_run_form_mesh_job():
    """This test fails unless the form hides --files and --seeds for a gate and, for --job mesh, shows them and
    hides --mesh, --data and --niv (make_run.sh refuses those for a mesh build); the folder picker fills --files
    relative to the repository; and the recorded argv and the preview equal make_run.sh's own header line for
    Run05 and Run04's line rebuilt from its RUN.md (with --seeds). Failing case: the Run05 line with the --mesh v2
    --data ... that the phase-1 form would have typed."""
    form = W.runs_tab.form
    form.job.setCurrentText("gate")
    pump()
    gate_rows = [form.row_visible(o) for o in MESH_ROWS]
    assert gate_rows == [False, False, True, True, True], "gate rows %s" % gate_rows

    def check(line):
        a = shlex.split(line)
        fill_form(form, line)
        files = dict(zip(a[3::2], a[4::2]))["--files"]
        form.files.clear()
        ANSWER["dir"] = C.REPO / files
        click(form.files_btn)
        picked, shown = form.files.text(), form.preview.toPlainText()
        rows = [form.row_visible(o) for o in MESH_ROWS]
        del RECORDED[:]
        click(form.button)
        ok = (rows == [True, True, False, False, False] and picked == files and len(RECORDED) == 1
              and RECORDED[0][0] == W.runs_tab.bash and RECORDED[0][1:] == a[1:]
              and display_command(RECORDED[0]) == line == shown)
        return ok, "rows shown %s; picked %r; equal to the expected line %s; typed %s" % (
            rows, picked, len(RECORDED) == 1 and RECORDED[0][1:] == a[1:], shown)

    C.fails_first(check, header_line("mesh").replace("--job mesh", "--mesh v2 --data mesh/vulcan_v2_rot/inversion "
                                                                    "--job mesh"))
    C.passes(check, header_line("mesh"))
    C.passes(check, run04_line())
    no_exceptions("mesh job form")


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
