# -*- coding: utf-8 -*-
"""jobs.py - JobRunner: runs one external command at a time with QProcess, exactly as a student types it.

argv is always a list, never a shell string: sys.executable for a .py script, Git Bash for a .sh script,
repository-relative paths with forward slashes, cwd = the repository root. stdout and stderr are merged,
PYTHONUNBUFFERED=1, ANSI escapes stripped, each line goes out through the line signal. Before a job the console
gets '$ <command>', after it '--- <label>: done (exit 0)', 'failed (exit N)' or 'failed to start (<program>)';
cancel() kills the job, waits up to 3 s and writes '--- cancelled: <label>'. While a job runs, run() refuses
another (returns False) and the tabs disable their start buttons: there is no queue.
find_bash() finds Git Bash and never the WSL launcher (the bash.exe under System32 or WindowsApps):
starting WSL is forbidden on this PC.

@author ben kay
:license: MIT
"""
from __future__ import annotations

import os
import re
import shutil
import sys
from pathlib import Path

from PySide6 import QtCore

ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
_PLAIN_ARG = re.compile(r"[A-Za-z0-9_./:=@%+,-]+")


def _refused_bash(path: str) -> bool:
    low = path.replace(chr(92), "/").lower()
    return any("/%s/" % d in low for d in ("windowsapps", "system32", "sysnative"))


def _bash_quote(a: str) -> str:
    """Escape the characters that stay special inside bash double quotes."""
    for ch in (chr(92), '"', "$", "`"):
        a = a.replace(ch, chr(92) + ch)
    return a


def find_bash() -> str | None:
    """Return Git Bash's bash.exe (beside the git.exe on PATH, else the default install), or None.

    Anything under WindowsApps or System32 is refused: that bash is the WSL launcher.
    """
    if os.name != "nt":
        b = shutil.which("bash")
        return b if b and not _refused_bash(b) else None
    cands = []
    git = shutil.which("git")
    if git:
        g = Path(git).resolve()
        cands += [g.parent.parent / "bin" / "bash.exe", g.parent.parent.parent / "bin" / "bash.exe"]
    cands.append(Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Git" / "bin" / "bash.exe")
    for c in cands:
        if c.is_file() and not _refused_bash(str(c)):
            return str(c)
    return None


def display_command(argv: list[str]) -> str:
    """The command as a student types it: 'python' or 'bash' for the program, arguments quoted if needed."""
    prog = Path(argv[0]).name.lower()
    if Path(argv[0]) == Path(sys.executable) or prog.startswith("python"):
        head = "python"
    elif prog in ("bash", "bash.exe"):
        head = "bash"
    else:
        head = argv[0]
    out = [head]
    for a in argv[1:]:
        if _PLAIN_ARG.fullmatch(a):
            out.append(a)
        else:
            out.append('"%s"' % _bash_quote(a))
    return " ".join(out)


class JobRunner(QtCore.QObject):
    """One external job at a time.

    Signals:
        started(str): a job started (its label).
        line(str): one line for the console ('$ ...', job output, '--- ...').
        finished(bool): the job ended; True only for exit 0.
    """

    started = QtCore.Signal(str)
    line = QtCore.Signal(str)
    finished = QtCore.Signal(bool)

    def __init__(self, cwd: str | os.PathLike, parent: QtCore.QObject | None = None) -> None:
        super().__init__(parent)
        self.cwd = Path(cwd)
        self._proc: QtCore.QProcess | None = None
        self._busy = False
        self._label = ""
        self._argv0 = ""
        self._buf = ""

    @property
    def busy(self) -> bool:
        """True while a job runs."""
        return self._busy

    def run(self, label: str, argv: list[str], env: dict[str, str] | None = None) -> bool:
        """Start a job unless one is running.

        Args:
            label: Short name for the '---' line, e.g. 'prep'.
            argv: Program and arguments; relative paths are relative to the repository root.
            env: Extra environment variables (e.g. RUNS for a test of make_run.sh).

        Returns:
            False if a job is already running (nothing started), else True.
        """
        if self._busy:
            return False
        self._busy, self._label, self._argv0, self._buf = True, label, argv[0], ""
        self.line.emit("$ " + display_command(argv))
        self.started.emit(label)
        self._start(list(argv), dict(env or {}))
        return True

    def _start(self, argv: list[str], env: dict[str, str]) -> None:
        p = QtCore.QProcess(self)
        p.setWorkingDirectory(str(self.cwd))
        p.setProcessChannelMode(QtCore.QProcess.ProcessChannelMode.MergedChannels)
        e = QtCore.QProcessEnvironment.systemEnvironment()
        e.insert("PYTHONUNBUFFERED", "1")
        for k, v in env.items():
            e.insert(k, v)
        p.setProcessEnvironment(e)
        p.readyReadStandardOutput.connect(lambda p=p: p is self._proc and self._read(p))
        p.finished.connect(lambda code, status, p=p: self._on_finished(p, code, status))
        p.errorOccurred.connect(lambda err, p=p: self._on_error(p, err))
        self._proc = p
        p.start(argv[0], argv[1:])

    def _read(self, p: QtCore.QProcess) -> None:
        self._buf += bytes(p.readAllStandardOutput()).decode("utf-8", errors="replace")
        *lines, self._buf = self._buf.split("\n")
        for ln in lines:
            self.line.emit(ANSI.sub("", ln.rstrip("\r")))

    def _flush(self, p: QtCore.QProcess) -> None:
        self._read(p)
        if self._buf:
            self.line.emit(ANSI.sub("", self._buf.rstrip("\r")))
            self._buf = ""

    def _on_error(self, p: QtCore.QProcess, err: QtCore.QProcess.ProcessError) -> None:
        if p is self._proc and err == QtCore.QProcess.ProcessError.FailedToStart:
            self._proc = None
            p.deleteLater()
            self._done(False, "failed to start (%s)" % self._argv0)

    def _on_finished(self, p: QtCore.QProcess, code: int, status: QtCore.QProcess.ExitStatus) -> None:
        if p is not self._proc:
            return
        self._flush(p)
        self._proc = None
        p.deleteLater()
        ok = status == QtCore.QProcess.ExitStatus.NormalExit and code == 0
        self._done(ok, "done (exit 0)" if ok else "failed (exit %d)" % code)

    def _done(self, ok: bool, text: str) -> None:
        self.line.emit("--- %s: %s" % (self._label, text))
        self._busy = False
        self.finished.emit(ok)

    def cancel(self) -> None:
        """Kill the running job (if any), wait up to 3 s for it, and report it cancelled."""
        p = self._proc
        if not self._busy or p is None:
            return
        self._proc = None                     # its own finished signal is ignored from here on
        p.kill()
        p.waitForFinished(3000)
        self._flush(p)
        p.deleteLater()
        self.line.emit("--- cancelled: %s" % self._label)
        self._busy = False
        self.finished.emit(False)
