# -*- coding: utf-8 -*-
"""test_readers.py - runs/INDEX.md editing, make_run.sh option tooltips and the next run name.

    python tests/gui/test_readers.py

@author ben kay
:license: MIT
"""
from __future__ import annotations

import re
import shutil
from pathlib import Path

import _common as C

from femtic_gui import readers

INDEX = C.REPO / "runs" / "INDEX.md"
MAKE_RUN = C.REPO / "scripts" / "make_run.sh"


def _rewrite_whole_line(path, run, jobs, verdict):
    """Mutant: rebuilds the line from stripped cells (collapses the purpose's spacing, changes other bytes)."""
    lines = Path(path).read_text(encoding="utf-8").splitlines(keepends=True)
    for i, ln in enumerate(lines):
        cells = [c.strip() for c in ln.split("|")[1:-1]]
        if cells and cells[0] == run:
            cells[4:6] = [jobs, verdict]
            lines[i] = "| " + " | ".join(" ".join(c.split()) for c in cells) + " |\n"
    Path(path).write_text("".join(lines), encoding="utf-8")


def test_record_result_changes_only_two_cells():
    """This test fails if recording a result changes any byte of INDEX.md other than the job-id and verdict cells
    of that run's line, or the re-read row does not hold them. Failing case: a writer that rebuilds the line."""
    with C.temp_dir("index") as d:
        idx = Path(d) / "INDEX.md"
        original = INDEX.read_text(encoding="utf-8").replace("| Run02 | v2 | Half-space", "| Run02 | v2 |  Half-space")

        def check(record):
            idx.write_text(original, encoding="utf-8")
            record(idx, "Run02", "123456, 123457", "PASS gate 3 ohm-m")
            new = idx.read_text(encoding="utf-8")
            a, b = original.splitlines(), new.splitlines()
            diff = [i for i, (x, y) in enumerate(zip(a, b)) if x != y]
            row = next(r for r in readers.read_index(idx) if r["run"] == "Run02")
            head_same = len(diff) == 1 and b[diff[0]].rsplit("|", 3)[0] == a[diff[0]].rsplit("|", 3)[0]
            ok = (len(a) == len(b) and head_same and row["jobs"] == "123456, 123457"
                  and row["verdict"] == "PASS gate 3 ohm-m")
            return ok, "%d line(s) changed; first four cells unchanged: %s" % (len(diff), head_same)

        C.fails_first(check, _rewrite_whole_line)
        C.passes(check, readers.record_result)


def test_make_run_tooltips_cover_every_option():
    """This test fails unless every option make_run.sh's argument loop accepts ('--x)' cases) has a tooltip line
    from its header. Failing case: a copy of make_run.sh whose header lost its option lines."""
    script = MAKE_RUN.read_text(encoding="utf-8")
    accepted = sorted(set(re.findall(r"(--[a-z-]+)\)", script)))

    def check(path):
        tips = readers.make_run_options(path)
        missing = [o for o in accepted if o not in tips]
        return not missing, "%d options accepted, %d tooltips, missing %s" % (len(accepted), len(tips), missing)

    with C.temp_dir("makerun") as d:
        cut = Path(d) / "make_run.sh"
        cut.write_text("\n".join(ln for ln in script.splitlines() if not ln.startswith("#   --")) + "\n",
                       encoding="utf-8")
        C.fails_first(check, cut)
    C.passes(check, MAKE_RUN)


def test_next_run_name_skips_folders_and_index_lines():
    """This test fails unless the next run name is one above the highest RunNN among both the run folders and the
    INDEX.md lines. Failing case: a folder Run12 that INDEX.md does not list."""
    with C.temp_dir("next") as d:
        runs = Path(d)
        shutil.copy(INDEX, runs / "INDEX.md")
        rows = readers.read_index(runs / "INDEX.md")
        top = max(int(r["run"][3:]) for r in rows)

        def check(expect):
            got = readers.next_run_name(runs, rows)
            return got == expect, "next %s, expected %s" % (got, expect)

        (runs / "Run12").mkdir()
        C.fails_first(check, "Run%02d" % (top + 1))
        C.passes(check, "Run13")


B1 = C.HERE / "fixtures" / "b1"
CNV_LEGS = C.REPO / "validation" / "phoenix_2026-09-28"


def _cnv_iter0(path: Path) -> tuple[str, str]:
    row = next(ln.split() for ln in path.read_text(encoding="utf-8").splitlines() if ln.split()[:1] == ["0"])
    return row[5], row[6]                                  # Misfit, RMS as FEMTIC printed them


def _sd_for_res(paths):
    """Mutant: takes the _SD columns for _Res."""
    f = readers.read_result_csv(paths)
    return dict(f, res=f["sd"])


def _past_vtf(paths):
    """Mutant: keeps reading numeric lines after the 'VTF,' line."""
    import numpy as np
    rows = []
    for p in paths:
        for ln in Path(p).read_text(encoding="utf-8").splitlines()[2:]:
            v = [x for x in ln.split(",") if x.strip()]
            if v and v[0].strip().isdigit():
                rows.append([float(x) for x in v][:34] + [0.0] * max(0, 34 - len(v)))
    a = np.array(rows)
    return {"sta": a[:, 0].astype(int), "freq": a[:, 1], "res": a[:, 10:18]}


def test_result_csv_rms_equals_femtic_cnv():
    """This test fails unless sqrt(mean _Res^2) over the b1 fixture csv, and the per-site RMS recombined over the
    sites, both equal femtic.cnv's iteration-0 RMS and Misfit as FEMTIC printed them (7 digits) (T8). Failing cases:
    a reader that takes _SD for _Res; one that runs past the 'VTF,' line (on a copy with one VTF data row added)."""
    misfit, rms = _cnv_iter0(B1 / "femtic.cnv")
    import numpy as np

    def check(reader, csv):
        try:
            f = reader([csv])
        except Exception as e:                             # a broken reader fails the check, it is not an error
            return False, "%s: %s" % (type(e).__name__, e)
        got_rms = "%.6e" % float(np.sqrt(np.mean(f["res"] ** 2)))
        per = readers.site_misfit(f)
        n = {s: int(np.sum(f["sta"] == s)) * 8 for s in set(f["sta"].tolist())}
        got_misfit = "%.6e" % sum(n[r["sta"]] * r["rms"] ** 2 for r in per)
        ok = got_rms == rms and got_misfit == misfit
        return ok, "RMS %s (cnv %s), Misfit from site RMS %s (cnv %s), %d rows" % (got_rms, rms, got_misfit, misfit,
                                                                                  len(f["sta"]))

    csv = B1 / "b1_result_0_iter0.csv"
    C.fails_first(check, _sd_for_res, csv)
    with C.temp_dir("vtf") as d:
        extra = Path(d) / "result_0_iter0.csv"
        extra.write_text(csv.read_text(encoding="utf-8") + "      1001,    2.000000e+02," + "    5.0e-01," * 12
                         + chr(10), encoding="utf-8")
        C.fails_first(check, _past_vtf, extra)
        C.passes(check, readers.read_result_csv, extra)
    C.passes(check, readers.read_result_csv, csv)


def test_cnv_merge_equals_the_straight_run():
    """This test fails unless merging the restarted run's femtic.cnv.leg1 and .leg2 gives exactly the rows of the
    straight run's femtic.cnv (validation/phoenix_2026-09-28) (T9). Failing case: plain concatenation (two
    iteration-1 rows)."""
    straight = readers.read_cnv([CNV_LEGS / "straight" / "femtic.cnv"])
    legs = [CNV_LEGS / "restart" / "femtic.cnv.leg1", CNV_LEGS / "restart" / "femtic.cnv.leg2"]

    def concat(paths):
        return [r for p in paths for r in readers.read_cnv([p])]

    def check(merge):
        got = merge(legs)
        return got == straight, "iterations %s (straight %s)" % ([r[0] for r in got], [r[0] for r in straight])

    C.fails_first(check, concat)
    C.passes(check, readers.read_cnv)


if __name__ == "__main__":
    C.main(globals())
