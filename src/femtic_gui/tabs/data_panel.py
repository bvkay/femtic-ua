# -*- coding: utf-8 -*-
"""data_panel.py - the Data tab's control column: band selection, error floors, rotation and the prep buttons.

Each control is bound to one config key and writes it through State.set_value (only that value's text in the
file changes). The two buttons run prep_vulcan.py on the SAVED config, so they are disabled while edits are
unsaved: 'Check' = python scripts/prep_vulcan.py <config> --check-only <dir>, 'Run prep' = ... --out <dir>.
prep refuses a non-empty --out folder and the GUI never passes --force; the folder field says so beforehand.

@author ben kay
:license: MIT
"""
from __future__ import annotations

import sys
from pathlib import Path

from PySide6 import QtWidgets

from .. import config_io, prep_api, theme
from ..jobs import display_command
from ..state import State
from .common import set_enabled, show_text

FMAX_LIMIT_HZ = 100.0
FMAX_WHY = ("fmax_hz stops at 100 Hz: above it neither mesh v2 nor v3 meets the site-size rule delta_min/20 "
            "(docs/mesh_tetra_pipeline.md), and prep's design warnings do not test it (design finding 12)")
FLOOR_KEYS = ("Zxx", "Zxy", "Zyx", "Zyy")


def _form_group(title: str) -> tuple[QtWidgets.QGroupBox, QtWidgets.QFormLayout]:
    g = QtWidgets.QGroupBox(title)
    return g, QtWidgets.QFormLayout(g)


def _wrap_label() -> QtWidgets.QLabel:
    lab = QtWidgets.QLabel()
    lab.setWordWrap(True)
    return lab


class DataPanel(QtWidgets.QWidget):
    """Controls bound to frequencies.*, data.error_floor_Z, plus the rotation text and the prep buttons."""

    def __init__(self, state: State, parent: QtWidgets.QWidget | None = None) -> None:
        super().__init__(parent)
        self.state = state
        self._job_out: Path | None = None
        lay = QtWidgets.QVBoxLayout(self)

        g, f = _form_group("Frequencies (frequencies.*)")
        self.fmax = QtWidgets.QDoubleSpinBox(decimals=4, minimum=1e-4, maximum=FMAX_LIMIT_HZ, singleStep=10.0)
        self.fmax.setToolTip(FMAX_WHY)
        self.fmin = QtWidgets.QDoubleSpinBox(decimals=6, minimum=1e-6, maximum=FMAX_LIMIT_HZ, singleStep=0.001)
        self.per_decade = QtWidgets.QSpinBox(minimum=1, maximum=20)
        self.all_sites = QtWidgets.QCheckBox()
        self.all_sites.setToolTip("candidates are only the bands unmasked at every site (as prep's check C05)")
        self.explicit, self.fmax_note = _wrap_label(), _wrap_label()
        for name, w in (("fmax_hz", self.fmax), ("", self.fmax_note), ("fmin_hz", self.fmin),
                        ("per_decade", self.per_decade), ("require_all_sites", self.all_sites),
                        ("explicit_hz", self.explicit)):
            f.addRow(name, w)
        lay.addWidget(g)

        g, f = _form_group("Error floors (data.error_floor_Z)")
        self.floors = []
        for k in FLOOR_KEYS:
            sb = QtWidgets.QDoubleSpinBox(decimals=3, minimum=0.0, maximum=1.0, singleStep=0.01)
            sb.setToolTip("floor x sqrt(|Z'xy| |Z'yx|) is the smallest SE of %s (the config's comment on "
                          "error_floor_Z)" % k)
            self.floors.append(sb)
            f.addRow(k, sb)
        self.floor_readout = _wrap_label()
        f.addRow(self.floor_readout)
        lay.addWidget(g)

        g, f = _form_group("Rotation (data.rotation, read-only)")
        self.rotation = _wrap_label()
        f.addRow(self.rotation)
        lay.addWidget(g)

        g, f = _form_group("prep_vulcan.py")
        self.out_dir = QtWidgets.QLineEdit()
        self.out_dir.setToolTip("prep's output folder, repository-relative (default: paths.run_dir)")
        self.out_note = _wrap_label()
        row = QtWidgets.QHBoxLayout()
        self.check_btn = QtWidgets.QPushButton("Check")
        self.prep_btn = QtWidgets.QPushButton("Run prep")
        row.addWidget(self.check_btn)
        row.addWidget(self.prep_btn)
        f.addRow("folder", self.out_dir)
        f.addRow("", self.out_note)
        f.addRow(row)
        lay.addWidget(g)
        lay.addStretch(1)
        self.status = _wrap_label()
        lay.addWidget(self.status)

        self.fmax.valueChanged.connect(lambda v: self._set("frequencies.fmax_hz", round(float(v), 4)))
        self.fmin.valueChanged.connect(lambda v: self._set("frequencies.fmin_hz", round(float(v), 6)))
        self.per_decade.valueChanged.connect(lambda v: self._set("frequencies.per_decade", int(v)))
        self.all_sites.toggled.connect(lambda v: self._set("frequencies.require_all_sites", bool(v)))
        for sb in self.floors:
            sb.valueChanged.connect(lambda _v: self._set("data.error_floor_Z",
                                                         [round(float(b.value()), 3) for b in self.floors]))
        self.out_dir.textChanged.connect(lambda _t: self.update_buttons())
        self.check_btn.clicked.connect(lambda: self._run(check=True))
        self.prep_btn.clicked.connect(lambda: self._run(check=False))
        state.dirty_changed.connect(lambda _d: self.update_buttons())
        state.job_state_changed.connect(lambda _r: self.update_buttons())
        state.runner.finished.connect(self._job_finished)

    # ------------------------------------------------------------------ config -> widgets
    def reload(self) -> None:
        """Fill every control from the open config (signals blocked) and reset the folder field."""
        s = self.state
        widgets = [self.fmax, self.fmin, self.per_decade, self.all_sites] + self.floors
        for w in widgets:
            w.blockSignals(True)
        fmax = float(s.get("frequencies.fmax_hz", FMAX_LIMIT_HZ))
        self.fmax.setMaximum(max(FMAX_LIMIT_HZ, fmax))
        self.fmax.setValue(fmax)
        theme.set_status(self.fmax_note, "" if fmax <= FMAX_LIMIT_HZ else
                         "%g Hz is above 100 Hz: lower it. %s" % (fmax, FMAX_WHY), "warn")
        self.fmin.setValue(float(s.get("frequencies.fmin_hz", 0.001)))
        self.per_decade.setValue(int(round(float(s.get("frequencies.per_decade", 4)))))
        self.all_sites.setChecked(bool(s.get("frequencies.require_all_sites", True)))
        for sb, v in zip(self.floors, s.get("data.error_floor_Z", [0.0] * 4)):
            sb.setValue(float(v))
        for w in widgets:
            w.blockSignals(False)
        ex = s.get("frequencies.explicit_hz")
        self.explicit.setText("null: the rule above selects the bands" if ex is None else
                              "%s: replaces the rule (edit it in a text editor)" % ex)
        prov = s.get("data.rotation.provenance")
        self.rotation.setText(prep_api.rotation_line(s.survey) +
                              ("\n\nprovenance: %s" % " ".join(str(prov).split()) if prov else ""))
        self.out_dir.setText(s.run_dir())
        theme.set_status(self.status, "")
        self.update_buttons()

    def show_floor_counts(self, counts: list[int], total: int) -> None:
        """Show the floor readout, worded and counted as prep's check C09."""
        pct = "/".join("%.0f" % (100.0 * k / max(total, 1)) for k in counts)
        self.floor_readout.setText("floor active in %s %% of Zxx/Zxy/Zyx/Zyy (%s of %d site-band pairs)"
                                   % (pct, "/".join(str(k) for k in counts), total))

    # ------------------------------------------------------------------ widgets -> config
    def _set(self, key: str, value) -> None:
        try:
            self.state.set_value(key, value)
            theme.set_status(self.status, "unsaved: %s = %s (File > Save as... keeps it)" % (key, value), "warn")
        except config_io.ConfigError as e:
            theme.set_status(self.status, str(e), "error")
            self.reload()

    # ------------------------------------------------------------------ prep buttons
    def _out_path(self) -> Path | None:
        text = self.out_dir.text().strip()
        if not text:
            return None
        p = Path(text)
        return config_io.local_path(p if p.is_absolute() else self.state.repo / p)

    def _argv(self, flag: str) -> list[str]:
        s = self.state
        cfg = s.rel(s.doc.path) if s.doc else "<config>"
        out = self.out_dir.text().strip().replace("\\", "/") or "<dir>"
        return [sys.executable, "scripts/prep_vulcan.py", cfg, flag, out]

    def update_buttons(self) -> None:
        """Enable Check and Run prep only when they can run; the tooltip says the command or why not."""
        s = self.state
        why = ("no config is open" if s.doc is None else "a job is running" if s.job_running else
               "unsaved edits: Save as first, prep reads the saved file, not the screen" if s.dirty else "")
        try:
            out = self._out_path()
        except config_io.ConfigError as e:
            out, why = None, why or str(e)
        if out is None:
            why = why or "give the output folder"
        busy_out = out is not None and out.exists() and (not out.is_dir() or any(out.iterdir()))
        prep_why = ("%s exists and is not empty: prep refuses it and the GUI never passes --force; choose a new "
                    "folder" % self.out_dir.text().strip()) if busy_out else ""
        check_why = "" if out is not None and (out / "inversion").is_dir() else \
            "no inversion/ folder there: Check re-runs the self-checks on a folder prep wrote"
        set_enabled(self.check_btn, why or check_why, display_command(self._argv("--check-only")))
        set_enabled(self.prep_btn, why or prep_why, display_command(self._argv("--out")))
        note = prep_why or ("new folder: Run prep writes it; Check needs a folder prep wrote" if check_why else
                            "prep folder: Check re-runs its self-checks")
        theme.set_status(self.out_note, note, "warn" if prep_why else "info")

    def _run(self, check: bool) -> None:
        argv = self._argv("--check-only" if check else "--out")
        self._job_out = None if check else self._out_path()
        self._mine = True
        if not self.state.runner.run("prep check" if check else "prep", argv):
            self._mine = False
            theme.set_status(self.status, "a job is running; wait or cancel it", "warn")

    def _job_finished(self, ok: bool) -> None:
        if not getattr(self, "_mine", False):
            return
        self._mine = False
        out, self._job_out = self._job_out, None
        theme.set_status(self.status, "prep %s" % ("passed" if ok else "failed: read the console"),
                         "ok" if ok else "error")
        if ok and out is not None and (out / "README.md").is_file():
            show_text(self, "prep: %s" % (out / "README.md"), out / "README.md")
        self.update_buttons()
