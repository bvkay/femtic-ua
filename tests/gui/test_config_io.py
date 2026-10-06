# -*- coding: utf-8 -*-
"""test_config_io.py - config_io: byte-faithful edits and saves, prep's validation, UNC refusal (T1, T2, T3, T13).

    python tests/gui/test_config_io.py

@author ben kay
:license: MIT
"""
from __future__ import annotations

import io
import os
from pathlib import Path

import _common as C
import yaml
from ruamel.yaml import YAML

from femtic_gui import config_io

BS = chr(92)


def _changed_lines(a: str, b: str) -> list[int]:
    la, lb = a.splitlines(keepends=True), b.splitlines(keepends=True)
    if len(la) != len(lb):
        return list(range(max(len(la), len(lb))))
    return [i for i, (x, y) in enumerate(zip(la, lb)) if x != y]


def _ruamel_dump(text: str) -> str:
    y = YAML(typ="rt")
    buf = io.StringIO()
    y.dump(y.load(text), buf)
    return buf.getvalue()


def test_noop_text_is_the_file():
    """This test fails if loading CFG and saving it without an edit would write anything but the file's own bytes
    (trailing newline aside). Failing case: saving through a plain ruamel.yaml round-trip dump."""
    original = CFG_TEXT

    def check(saved: str):
        n = _changed_lines(original.rstrip("\n"), saved.rstrip("\n"))
        return not n, "%d line(s) differ from config/vulcan_mesh_v2_rot.yml" % len(n)

    C.fails_first(check, _ruamel_dump(original))
    C.passes(check, config_io.load(C.CFG).text)


def test_set_value_touches_only_the_value():
    """This test fails if set_value on data.error_floor_Z changes any byte of CFG outside line 52's value text, or
    the value re-read by ruamel.yaml and PyYAML differs from the one set (T1). Failing case: the same edit saved
    through a plain ruamel.yaml dump."""
    new = [0.2, 0.08, 0.05, 0.25]
    original = CFG_TEXT
    line52 = original.splitlines(keepends=True)[51]
    col = line52.index("[")

    def check(text: str):
        n = _changed_lines(original, text)
        if n != [51]:
            return False, "lines changed: %s (only line 52 may change)" % [i + 1 for i in n[:8]]
        got = text.splitlines(keepends=True)[51]
        same_prefix = got[:col] == line52[:col]
        r1 = YAML(typ="rt").load(text)["data"]["error_floor_Z"]
        r2 = yaml.safe_load(text)["data"]["error_floor_Z"]
        ok = same_prefix and list(r1) == new and r2 == new
        return ok, "line 52 now %r; ruamel %s, PyYAML %s" % (got.rstrip(), list(r1), r2)

    y = YAML(typ="rt")
    d = y.load(original)
    d["data"]["error_floor_Z"] = new
    buf = io.StringIO()
    y.dump(d, buf)
    C.fails_first(check, buf.getvalue())
    C.passes(check, config_io.set_value(config_io.load(C.CFG), "data.error_floor_Z", new).text)


def test_set_value_keeps_comment_column():
    """This test fails if editing a value that has a comment on its line moves that comment or loses it.
    Failing case: a text whose comment was dropped."""
    doc = config_io.load(C.CFG)
    old = doc.text.splitlines()[204]                    # TRADE_OFF_PARAM: [3.0]   # one value ...
    new_text = config_io.set_value(doc, "inversion.TRADE_OFF_PARAM", [10.0]).text

    def check(text: str):
        ln = text.splitlines()[204]
        ok = "#" in ln and ln.index("#") == old.index("#") and ln[ln.index("#"):] == old[old.index("#"):]
        return ok, "line 205 %r" % ln

    C.fails_first(check, new_text.replace(old[old.index("#"):], ""))
    C.passes(check, new_text)


def test_validate_refuses_bad_floor_and_leaves_target():
    """This test fails if validate accepts a 3-value error floor, or changes the target file or leaves a temporary
    file next to it (T2). Failing case: a validate that skips prep (accepts anything)."""
    with C.temp_dir("validate") as d:
        base = C.abs_root_copy(Path(d))
        target = Path(d) / "target.yml"
        target.write_text("sentinel\n", encoding="utf-8")
        doc = config_io.set_value(config_io.load(base), "data.error_floor_Z", [0.2, 0.05, 0.05])

        def check(validate):
            msg = validate(doc, target)
            left = sorted(p.name for p in Path(d).iterdir())
            ok = (msg is not None and "error_floor_Z" in msg and target.read_text(encoding="utf-8") == "sentinel\n"
                  and left == ["base.yml", "target.yml"])
            return ok, "message %r; folder %s" % (msg, left)

        C.fails_first(check, lambda doc, target: None)
        C.passes(check, config_io.validate)


def test_local_path_refuses_unc():
    """This test fails if local_path accepts a UNC, WSL or //host path, or refuses a plain local one (T3).
    Failing case: os.path.abspath, which accepts them all."""
    unc = [BS * 2 + "server" + BS + "share" + BS + "x.yml", BS * 2 + "wsl$" + BS + "Ubuntu" + BS + "x.yml",
           BS * 2 + "wsl.localhost" + BS + "Ubuntu" + BS + "x.yml", "//host/share/x.yml",
           BS * 2 + "?" + BS + "UNC" + BS + "server" + BS + "x.yml"]

    def check(fn):
        refused = []
        for p in unc:
            try:
                fn(p)
            except config_io.ConfigError:
                refused.append(p)
        try:
            fn("config/x.yml")
            local_ok = True
        except config_io.ConfigError:
            local_ok = False
        return len(refused) == len(unc) and local_ok, "%d of %d UNC paths refused; local path accepted: %s" % (
            len(refused), len(unc), local_ok)

    C.fails_first(check, os.path.abspath)
    C.passes(check, config_io.local_path)


def test_save_as_never_overwrites():
    """This test fails if Save as writes over an existing file or leaves a temporary file (T13). Failing case: a
    save that replaces the target as QFileDialog's own 'Replace?' prompt would let it."""
    with C.temp_dir("saveas") as d:
        base = C.abs_root_copy(Path(d))
        doc = config_io.load(base)
        target = Path(d) / "existing.yml"

        def check(save):
            target.write_text("keep me\n", encoding="utf-8")
            try:
                save(doc, target)
                raised = ""
            except config_io.ConfigError as e:
                raised = str(e)
            left = sorted(p.name for p in Path(d).iterdir())
            ok = target.read_text(encoding="utf-8") == "keep me\n" and bool(raised) and len(left) == 2
            return ok, "refused: %r; folder %s" % (raised[:60], left)

        C.fails_first(check, lambda doc, t: Path(t).write_text(doc.text, encoding="utf-8"))
        C.passes(check, config_io.save_as)
        saved = config_io.save_as(doc, Path(d) / "new_name.yml")
        changed = _changed_lines(doc.text, saved.path.read_text(encoding="utf-8"))
        assert changed == [19, 26], "Save as must change only name (line 20) and paths.run_dir (line 27): %s" % changed
        print("    Save as to a new name changed lines %s only" % [i + 1 for i in changed])


def test_format_value_reads_back_in_both_parsers():
    """This test fails if a float written by format_value reads back as anything but that float in PyYAML (prep's
    parser) or ruamel.yaml. Failing case: plain repr, which PyYAML reads as a string for 1e-05."""
    vals = [1e-05, 1.0e20, 0.1, 100.0, -2.5e-07, 3.0, 0.05]

    def check(fmt):
        bad = []
        for v in vals:
            t = "v: %s\n" % fmt(v)
            if yaml.safe_load(t)["v"] != v or YAML(typ="rt").load(t)["v"] != v:
                bad.append(fmt(v))
        return not bad, "misread: %s" % bad

    C.fails_first(check, repr)
    C.passes(check, config_io.format_value)


CFG_TEXT = C.CFG.read_text(encoding="utf-8")

if __name__ == "__main__":
    C.main(globals())
