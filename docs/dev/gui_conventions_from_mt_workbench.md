# GUI conventions to follow, from Ben's mt_workbench (read 2026-10-06)

Source: D:\BEN\BBMT_Processing_2026\src\mt_workbench (PySide6 + pyqtgraph). Read-only survey by an Opus agent;
paths below are relative to src/mt_workbench/gui/. Decision context: the FEMTIC prep GUI is a thin PySide6 shell that
edits the YAML config and launches the existing scripts (prep_vulcan.py, mesh build, make_run.sh). 2D plots in
pyqtgraph; 3D mesh/model views in pyvistaqt (VTK). Nothing heavy runs inside the GUI process.

## How mt_workbench is built
- Entry: `__main__.py:29-57` argparse(optional survey.yaml) -> QApplication -> theme.apply(app) -> MainWindow.
  Console script `mt-workbench` and `python -m mt_workbench` both work.
- `app.py:92-130` `State(QObject)` is the shared hub (survey, selection) with signals survey_changed, site_changed,
  selection_changed. `app.py:397-448` MainWindow = QTabWidget over a ConsoleStrip in a vertical QSplitter; no docks.
- One file and one QWidget per tab in tabs/, constructed as (state, parent), each with reload(). Tabs never import
  each other; MainWindow does all cross-tab wiring (app.py:420-430). Hand-written layouts, no .ui files, no
  Model/View models.
- Long-running work: `jobs.py:81-275` one JobRunner (QProcess FIFO) on State; Job dataclass (label, argv, status,
  kind); add() queues only, run_queue() drains, run_now() for utility jobs. stdout+stderr merged, PYTHONUNBUFFERED=1,
  ANSI stripped, `$ cmd` before and `--- label: status (exit N)` after each job; cancel kills and waits 3 s.
  argv = [sys.executable, repo/scripts/x.py, survey.yaml, ...], cwd = repo root.
- ConsoleStrip (console.py:47-87) shows all job output; a loguru sink feeds it via a queued signal.
- In-process reads: QThread subclasses emitting result(tag, out)/failed(tag, msg), latest request wins, joined in
  closeEvent (reader.py:28-56; app.py:598-615).
- Config: the YAML file IS the session (open via argv or Ctrl+O; reopen re-parses, emits survey_changed, every tab
  reload()s). The GUI writes back only what a person typed; safe_dump(sort_keys=False). No QSettings, no recent files.
- Plotting: theme.py:181 sets pyqtgraph colours; linked PlotWidget stacks with fixed 72 px left axis, peak
  downsampling, clip-to-view, lock_view against panning past data; PColorMeshItem + ColorBarItem for images; site map
  = ScatterPlotItem + TextItem + ImageItem basemap, aspect locked to cos(lat), selection recolours via set_roles.
- Tables: QTableWidget with sortable items, single-row selection, F2/double-click edit, signals blocked while
  filling; QTreeWidget with lazy children; checkable tree items for multi-select; no context menus.
- Messages: QMessageBox.warning (missing inputs), critical (exceptions), question (destructive); status bar for
  survey-level messages; per-tab status_label coloured from theme constants; disabled buttons explain why in tooltip.
- Packaging: setuptools, requires-python>=3.10, environment.yml (Python 3.11, pip -e .). Tests are plain scripts with
  test_ functions and "This test fails if" docstrings; tests/gui_smoke.py runs headless (QT_QPA_PLATFORM=offscreen) and
  intercepts run_now so no real job starts.
- Style: module header docstring (utf-8 line, description, @author ben kay, :license: MIT), Google docstrings,
  British spelling, from __future__ import annotations, dark Fusion palette (#2b2b2b / #1f1f1f) with a QProxyStyle,
  no stylesheets, magnetics blue / electrics red, no hard-coded hex in tabs, ~350 lines per file, few shortcuts
  (Ctrl+O, Ctrl+Q), every button tooltip names the script it runs, no PNGs in the GUI.

## Copy
1. State hub with signals; tabs only reload().
2. One tab per file, (state, parent) constructor, cross-tab wiring in MainWindow.
3. One QProcess JobRunner with add / run_queue / run_now kept separate; merged channels; `$ cmd` / `--- status` lines.
4. Console strip under the tabs in a splitter; loguru-to-Qt sink.
5. The YAML config is the whole session: open, edit, save, reopen.
6. All colours and pens in theme.py; apply() before the window exists.
7. Linked pyqtgraph stacks with locked zoom.
8. QThread workers emitting (tag, result), latest wins, joined in closeEvent.
9. Headless smoke test that intercepts job launches.
10. Module header, docstring style, British spelling, dark palette, tooltips naming the script.

## Do not copy (and what to do instead)
1. Oversized files (crosspower.py 1382 lines, availability.py 1029): keep the 350-line rule.
2. loguru used but not declared in pyproject: declare every dependency; pin PySide6 / VTK / pyvistaqt together.
3. yaml.safe_dump drops comments: a config-editing GUI uses ruamel.yaml round-trip so the commented YAML survives.
4. Finding outputs by regex on `wrote <path>` lines: have scripts write a small JSON manifest the GUI reads.
5. No recent files / QSettings: add them for FEMTIC runs. On Windows, launch bash scripts with `bash` as argv[0].

## FEMTIC-specific additions
- 3D: a pyvistaqt QtInteractor tab for mesh and model views (slices, clipping, threshold, picking, colour bar); keep
  it isolated in its own module so the rest of the GUI runs without VTK (headless smoke test must not import it).
- Jobs the GUI launches: prep_vulcan.py <config>, the mesh build (whatever the port decides), make_run.sh RunNN ...,
  all with the repo root as cwd and the YAML as argument, exactly as a student would type them.
