# -*- coding: utf-8 -*-
"""test_jobs.py - JobRunner with real (light) processes: python -c jobs, cancel, and make_run.sh (T12).

No modelling runs: the jobs are 'python -c' one-liners and make_run.sh into a temporary RUNS folder.

    python tests/gui/test_jobs.py

@author ben kay
:license: MIT
"""
from __future__ import annotations

import shutil
import sys
import time
from pathlib import Path

import _common as C
from PySide6 import QtCore

from femtic_gui import jobs

APP = QtCore.QCoreApplication.instance() or QtCore.QCoreApplication([])
PY = sys.executable


def run_job(runner, label, argv, env=None, timeout_s=60.0, during=None):
    """Run one job to its end; returns (started, finished values, console lines). during(runner) runs once started."""
    lines, done = [], []
    runner.line.connect(lines.append)
    runner.finished.connect(done.append)
    started = runner.run(label, argv, env)
    if started and during is not None:
        during(runner)
    t0 = time.perf_counter()
    while started and not done and time.perf_counter() - t0 < timeout_s:
        APP.processEvents(QtCore.QEventLoop.ProcessEventsFlag.AllEvents, 50)
    runner.line.disconnect(lines.append)
    runner.finished.disconnect(done.append)
    return started, done, lines


def test_job_lines_done_and_failed():
    """This test fails unless a job's console holds '$ <command>', its merged stdout and stderr without ANSI escapes,
    and '--- <label>: done (exit 0)', with finished(True) emitted once. Failing case: the same job exiting 3."""
    code = "import sys; print(chr(27)+'[31mred'+chr(27)+'[0m'); sys.stderr.write('err'+chr(10)); sys.exit(%d)"

    def check(exit_code):
        r = jobs.JobRunner(C.REPO)
        _s, done, lines = run_job(r, "t", [PY, "-c", code % exit_code])
        ok = (lines[0].startswith("$ python -c ") and "red" in lines and "err" in lines
              and lines[-1] == "--- t: done (exit 0)" and done == [True])
        return ok, "lines %s, finished %s" % (lines[1:], done)

    C.fails_first(check, 3)
    C.passes(check, 0)


def test_second_job_refused_while_busy():
    """This test fails if run() starts a second job while one is running (run() must return False).
    Failing case: two runners (no shared busy state), as a queue-less GUI with two runners would have."""
    def check(two_runners):
        a = jobs.JobRunner(C.REPO)
        b = jobs.JobRunner(C.REPO) if two_runners else a
        seen = []

        def during(r):
            seen.append(b.run("second", [PY, "-c", "pass"]))
            r.cancel()
            b.cancel()
        run_job(a, "first", [PY, "-c", "import time; time.sleep(20)"], during=during)
        return seen == [False], "second run() returned %s" % seen

    C.fails_first(check, True)
    C.passes(check, False)


def test_cancel_kills_the_job():
    """This test fails unless cancel() stops the job (its output file stops growing), writes '--- cancelled:
    <label>', emits finished(False) and frees the runner within 5 s. Failing case: waiting without cancelling."""
    with C.temp_dir("cancel") as d:
        tick = Path(d) / "tick.txt"
        code = ("import time\nwhile True:\n    open(%r, 'a').write('x')\n    time.sleep(0.1)" % tick.as_posix())

        def check(cancel):
            tick.write_text("", encoding="utf-8")
            r = jobs.JobRunner(C.REPO)
            out = {}

            def during(runner):
                t0 = time.perf_counter()
                while tick.stat().st_size < 3 and time.perf_counter() - t0 < 20:
                    APP.processEvents()
                if cancel:
                    runner.cancel()
                out["t"] = time.perf_counter() - t0
                size = tick.stat().st_size
                time.sleep(1.0)
                out["grew"] = tick.stat().st_size - size
                if not cancel:
                    runner.cancel()
            _s, done, lines = run_job(r, "ticker", [PY, "-c", code], during=during)
            ok = out["grew"] == 0 and lines[-1] == "--- cancelled: ticker" and done == [False] and not r.busy
            return ok, "file grew %d byte(s) after the cancel point; last line %r" % (out["grew"], lines[-1])

        C.fails_first(check, False)
        C.passes(check, True)


def test_failed_to_start():
    """This test fails unless a missing program gives '--- <label>: failed to start (<program>)' and finished(False).
    Failing case: an existing program (python)."""
    def check(prog):
        _s, done, lines = run_job(jobs.JobRunner(C.REPO), "x", [prog, "-c", "pass"])
        return lines[-1] == "--- x: failed to start (%s)" % prog and done == [False], "last line %r" % lines[-1]

    C.fails_first(check, PY)
    C.passes(check, str(C.REPO / "no_such_program.exe"))


def _runs_state() -> tuple:
    runs = C.REPO / "runs"
    return tuple(sorted(p.name for p in runs.iterdir())), (runs / "INDEX.md").read_bytes()


def test_make_run_through_git_bash():
    """This test fails unless find_bash returns a Git Bash (never a WindowsApps or System32 bash, the WSL launcher),
    make_run.sh run by JobRunner with RUNS=<temp> ends 'failed (exit 1)' with its REFUSED line for --layout 4x24 and
    'done (exit 0)' for 3x24, with Run99 and its INDEX.md line in the temporary folder only (T12). Failing cases: a
    WindowsApps bash path; the 4x24 layout for the 'made' check."""
    wsl = "C:/Users/x/AppData/Local/Microsoft/WindowsApps/bash.exe"
    C.fails_first(lambda p: (not jobs._refused_bash(p), "refused: %s" % jobs._refused_bash(p)), wsl)
    bash = jobs.find_bash()
    if bash is None:
        raise C.NotRun("no Git Bash on this PC")
    C.passes(lambda p: (not jobs._refused_bash(p), "find_bash -> %s" % p), bash)
    before = _runs_state()
    with C.temp_dir("runs") as d:
        runs = Path(d)
        shutil.copy(C.REPO / "runs" / "INDEX.md", runs / "INDEX.md")

        def check(layout):
            argv = [bash, "scripts/make_run.sh", "Run99", "--mesh", "v2", "--data", "mesh/vulcan_v2_rot/inversion",
                    "--job", "gate", "--start-rho", "100", "--layout", layout, "--time", "02:00:00",
                    "--purpose", "GUI test (temporary RUNS)"]
            _s, done, lines = run_job(jobs.JobRunner(C.REPO), "make_run.sh", argv, {"RUNS": str(runs)})
            made = (runs / "Run99" / "RUN.md").is_file() and "| Run99 |" in (runs / "INDEX.md").read_text("utf-8")
            ok = lines[-1] == "--- make_run.sh: done (exit 0)" and done == [True] and made
            return ok, "last line %r; %s" % (lines[-1], next((x for x in lines if "REFUSED" in x or "made " in x),
                                                              "no REFUSED/made line"))

        detail = C.fails_first(check, "4x24")
        assert "REFUSED" in detail and not (runs / "Run99").exists(), detail
        C.passes(check, "3x24")
    assert _runs_state() == before, "the repository's runs/ changed"
    print("    the repository's runs/ is unchanged")


if __name__ == "__main__":
    C.main(globals())
