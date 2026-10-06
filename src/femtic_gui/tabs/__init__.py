# -*- coding: utf-8 -*-
"""tabs - one module per tab (data, mesh, femtic, runs), each a (state, parent) QWidget with reload().

Tabs never import each other; MainWindow (app.py) does the cross-tab wiring. common.py holds the helpers
they share (job buttons, the text viewer window, the lazy 3D viewer launch).

@author ben kay
:license: MIT
"""
