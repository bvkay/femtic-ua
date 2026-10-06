# -*- coding: utf-8 -*-
"""__main__.py - start the FEMTIC GUI: femtic-gui [config.yml]  or  python -m femtic_gui [config.yml].

@author ben kay
:license: MIT
"""
from __future__ import annotations

import argparse
import os
import sys


def main(argv: list[str] | None = None) -> int:
    """Parse the command line, apply the theme, open the window (and the config, if given), run Qt.

    Returns:
        Qt's exit code.
    """
    ap = argparse.ArgumentParser(
        prog="femtic-gui",
        description="FEMTIC student GUI: edit a prep_vulcan config, run prep_vulcan.py, make run folders "
                    "with make_run.sh. Local files only; nothing heavy runs in the GUI.")
    ap.add_argument("config", nargs="?", help="prep_vulcan YAML config to open, e.g. config/vulcan_mesh_v2_rot.yml")
    a = ap.parse_args(argv)
    os.environ.setdefault("QT_API", "pyside6")        # QtPy (pyvistaqt) uses the binding the GUI uses
    from PySide6 import QtWidgets

    from . import theme
    from .app import MainWindow

    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(sys.argv[:1])
    app.setApplicationName("femtic_gui")
    theme.apply(app)
    w = MainWindow()
    w.show()
    if a.config:
        w.open_config(a.config)
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
