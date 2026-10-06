# -*- coding: utf-8 -*-
"""femtic_gui - the FEMTIC student GUI: a thin PySide6 shell over the repository's own scripts.

It edits the prep_vulcan YAML config (only the values a student types, in place) and launches the existing
commands exactly as a student would type them (prep_vulcan.py, make_run.sh). Nothing heavy runs in the GUI
process, and nothing touches the network. Design: docs/dev/gui_design_2026-10-06.md.

@author ben kay
:license: MIT
"""
from __future__ import annotations

from pathlib import Path

__version__ = "0.1.0"


def repo_root() -> Path:
    """Return the repository root (the GUI runs from an editable install of this repository).

    Returns:
        The folder that holds scripts/prep_vulcan.py, i.e. two levels above this package.

    Raises:
        RuntimeError: if scripts/prep_vulcan.py is not there (the package was installed without the repo).
    """
    root = Path(__file__).resolve().parents[2]
    if not (root / "scripts" / "prep_vulcan.py").is_file():
        raise RuntimeError("femtic_gui must run from the repository (pip install -e .): no scripts/prep_vulcan.py "
                           "under %s" % root)
    return root
