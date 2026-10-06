# -*- coding: utf-8 -*-
"""tabs - one module per tab (data, mesh, femtic, runs, results), each a (state, parent) QWidget with reload().

Tabs never import each other; MainWindow (app.py) does the cross-tab wiring. data_panel.py (the Data tab's
settings and job buttons) and runs_form.py (the Runs tab's New-run form) are parts of their tabs; common.py holds
the helpers the tabs share (job buttons, the text viewer window, the lazy 3D viewer launch).

@author ben kay
:license: MIT
"""
from __future__ import annotations
