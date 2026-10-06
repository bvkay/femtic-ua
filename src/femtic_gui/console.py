# -*- coding: utf-8 -*-
"""console.py - the console strip under the tabs: every job's output and the GUI's own log lines.

JobRunner lines arrive through its line signal; the GUI's own messages go through loguru, whose sink here
forwards them to the strip with a Qt signal (queued when they come from another thread).

@author ben kay
:license: MIT
"""
from __future__ import annotations

from loguru import logger
from PySide6 import QtCore, QtGui, QtWidgets

from . import theme


class ConsoleStrip(QtWidgets.QPlainTextEdit):
    """Read-only text strip holding the last 5000 lines."""

    def __init__(self, parent: QtWidgets.QWidget | None = None) -> None:
        super().__init__(parent)
        self.setReadOnly(True)
        self.setMaximumBlockCount(5000)
        self.setFont(theme.mono_font())
        self.setLineWrapMode(QtWidgets.QPlainTextEdit.LineWrapMode.NoWrap)
        self.setPlaceholderText("Job output and messages appear here.")

    @QtCore.Slot(str)
    def append_line(self, text: str) -> None:
        """Append one line and keep the end in view."""
        self.appendPlainText(text)
        self.moveCursor(QtGui.QTextCursor.MoveOperation.End)

    def text(self) -> str:
        """The whole console text (tests read it)."""
        return self.toPlainText()


class _Bridge(QtCore.QObject):
    line = QtCore.Signal(str)


def install_loguru(console: ConsoleStrip) -> int:
    """Send loguru messages (INFO and above) to the console strip.

    Returns:
        The loguru handler id; pass it to remove_loguru() when the window closes.
    """
    bridge = _Bridge(console)
    bridge.line.connect(console.append_line)
    console._loguru_bridge = bridge          # keep it alive as long as the console
    return logger.add(lambda m: bridge.line.emit(str(m).rstrip("\n")), level="INFO", colorize=False,
                      format="{time:HH:mm:ss} {level}: {message}")


def remove_loguru(handler_id: int) -> None:
    """Detach the console sink (closeEvent)."""
    try:
        logger.remove(handler_id)
    except ValueError:
        pass
