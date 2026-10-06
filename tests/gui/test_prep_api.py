# -*- coding: utf-8 -*-
"""test_prep_api.py - the Data tab's previews against what prep actually wrote (T4 floor readout, T5 bands).

The independent observable is observe.dat: the bands it holds, and for every data line which SE equals the
floor (floor_i x sqrt(|Zxy| |Zyx|) of the written, rotated Z). T4 also runs prep itself (light: about 3 s, into a
temporary --out) on a variant with require_all_sites false.

    python tests/gui/test_prep_api.py

@author ben kay
:license: MIT
"""
from __future__ import annotations

import copy
import subprocess
import sys
from pathlib import Path

import _common as C
import numpy as np

from femtic_gui import prep_api

FLOORS = [0.2, 0.05, 0.05, 0.2]
EXPECTED = ([2514, 2443, 2413, 2511], 2520)


def read_observe_mt(path: Path) -> list[np.ndarray]:
    """The MT data lines of an observe.dat, one (nf, 17) array per station (a reader written for this test)."""
    lines = [ln.split() for ln in Path(path).read_text(encoding="utf-8").splitlines()]
    assert lines[0][0] == "MT", lines[0]
    i, out = 1, []
    for _ in range(int(lines[0][1])):
        nf = int(lines[i + 1][0])
        out.append(np.array([[float(v) for v in ln] for ln in lines[i + 2:i + 2 + nf]]).reshape(nf, 17))
        i += 2 + nf
    return out


def floors_in_observe(path: Path, floors: list[float]) -> tuple[list[int], int]:
    """Recover from observe.dat how many SEs equal the floor (within the '%.4e' write rounding)."""
    counts, total = np.zeros(4, dtype=int), 0
    for rows in read_observe_mt(path):
        z = rows[:, 1:9:2] + 1j * rows[:, 2:9:2]
        se = rows[:, 9:17:2]
        gm = np.sqrt(np.abs(z[:, 1]) * np.abs(z[:, 2]))
        fl = np.asarray(floors)[None, :] * gm[:, None]
        counts += np.sum(np.abs(se - fl) <= 3e-4 * fl, axis=0)
        total += len(rows)
    return [int(k) for k in counts], total


def _survey(edits: dict | None = None, folder: Path | None = None):
    c = prep_api.load_config(C.abs_root_copy(folder, edits=edits) if edits else C.CFG)
    return prep_api.load_survey(c)


def test_floor_readout_equals_observe_dat():
    """This test fails unless the floor readout's four counts on CFG equal those recovered from
    mesh/vulcan_v2_rot/inversion/observe.dat (2514/2443/2413/2511 of 2520) (T4). Failing cases: VAR instead of
    sqrt(VAR); no rotation."""
    want = floors_in_observe(C.OBSERVE, FLOORS)
    print("    recovered from observe.dat: %s of %d" % want)
    assert want == EXPECTED, "observe.dat itself no longer gives the design's counts: %s" % (want,)
    sv = _survey()
    chosen = prep_api.select(sv, 100.0, 0.001, 4, None, True)

    def check(survey):
        got = prep_api.floor_counts(survey, chosen, FLOORS)
        return got == want, "readout %s of %d" % got

    var = copy.copy(sv)
    var.vrot = {k: v ** 2 for k, v in sv.vrot.items()}          # sqrt(VAR**2) = VAR: compares VAR, not sqrt(VAR)
    C.fails_first(check, var)
    norot = copy.copy(sv)
    norot.zrot = {k: np.column_stack([e["z"][c] for c in ("XX", "XY", "YX", "YY")]) for k, e in sv.edis.items()}
    norot.vrot = {k: np.column_stack([e["var"][c] for c in ("XX", "XY", "YX", "YY")]) for k, e in sv.edis.items()}
    C.fails_first(check, norot)
    C.passes(check, sv)


def raised_floors_in_observe(path: Path, old: list[float], new: list[float]) -> tuple[list[int], int, int]:
    """Counts for floors raised above the written ones, recovered from observe.dat alone.

    SE = max(sqrt(VAR), old x gm), so for new > old the new floor is active exactly where SE < new x gm. Lines
    within the write rounding of new x gm are ambiguous; their number is returned too.
    """
    counts, total, amb = np.zeros(4, dtype=int), 0, 0
    for rows in read_observe_mt(path):
        z = rows[:, 1:9:2] + 1j * rows[:, 2:9:2]
        se = rows[:, 9:17:2]
        gm = np.sqrt(np.abs(z[:, 1]) * np.abs(z[:, 2]))
        fl = np.asarray(new)[None, :] * gm[:, None]
        counts += np.sum(se < fl * (1 - 3e-4), axis=0)
        amb += int(np.sum(np.abs(se - fl) <= 3e-4 * fl))
        total += len(rows)
    assert all(b > a for a, b in zip(old, new))
    return [int(k) for k in counts], total, amb


def test_floor_readout_for_raised_floors():
    """This test fails unless, for floors raised to [0.3, 0.1, 0.1, 0.3], the readout equals the counts recovered
    from observe.dat (SE < new floor x sqrt(|Zxy| |Zyx|), since SE = max(sqrt(VAR), old floor x ...)), with no
    ambiguous line. Failing case: a readout left at the written floors."""
    new = [0.3, 0.1, 0.1, 0.3]
    counts, total, amb = raised_floors_in_observe(C.OBSERVE, FLOORS, new)
    print("    recovered from observe.dat: %s of %d, %d ambiguous" % (counts, total, amb))
    assert amb == 0, "%d lines lie within rounding of the new floor" % amb
    sv = _survey()
    chosen = prep_api.select(sv, 100.0, 0.001, 4, None, True)

    def check(floors):
        got = prep_api.floor_counts(sv, chosen, floors)
        return got == (counts, total), "readout %s of %d" % got

    C.fails_first(check, FLOORS)
    C.passes(check, new)


def _nearest_band_counts(sv, chosen, floors):
    """Mutant: takes the nearest band at every site, whether the site has it or not."""
    counts, total = np.zeros(4, dtype=int), 0
    for sid, e in sv.edis.items():
        idx = [int(np.argmin(np.abs(e["freq"] - f))) for f in chosen]
        z, v = sv.zrot[sid][idx], sv.vrot[sid][idx]
        gm = np.sqrt(np.abs(z[:, 1]) * np.abs(z[:, 2]))
        counts += np.sum(np.asarray(floors)[None, :] * gm[:, None] > np.sqrt(v), axis=0)
        total += len(idx)
    return [int(k) for k in counts], total


def test_floor_readout_equals_a_prep_run_with_all_sites_false():
    """This test fails unless, with require_all_sites false, the floor readout equals the counts recovered from the
    observe.dat that prep_vulcan.py itself writes for that variant into a temporary --out (T4). Failing case: the
    nearest band at a site that lacks it."""
    with C.temp_dir("prep_variant") as d:
        cfg = C.abs_root_copy(Path(d), "variant.yml", {"frequencies.require_all_sites": False})
        out = Path(d) / "out"
        r = subprocess.run([sys.executable, str(C.REPO / "scripts" / "prep_vulcan.py"), str(cfg), "--out", str(out)],
                           cwd=str(C.REPO), capture_output=True, text=True)
        print("    prep exit %d: %s" % (r.returncode, (r.stdout.strip().splitlines() or ["-"])[-1][:100]))
        assert r.returncode == 0, r.stdout[-2000:] + r.stderr[-2000:]
        want = floors_in_observe(out / "inversion" / "observe.dat", FLOORS)
        sv = prep_api.load_survey(prep_api.load_config(cfg))
    chosen = prep_api.select(sv, 100.0, 0.001, 4, None, False)
    print("    prep's observe.dat: %s of %d" % want)

    def check(fn):
        got = fn(sv, chosen, FLOORS)
        return got == want, "readout %s of %d" % got

    C.fails_first(check, _nearest_band_counts)
    C.passes(check, prep_api.floor_counts)


def test_selected_bands_equal_observe_dat():
    """This test fails unless the bands the Data tab selects for CFG equal the 21 bands of
    mesh/vulcan_v2_rot/inversion/observe.dat (T5). Failing case: per_decade 5."""
    written = sorted({float(f) for rows in read_observe_mt(C.OBSERVE) for f in rows[:, 0]}, reverse=True)
    sv = _survey()

    def check(per_decade):
        got = prep_api.select(sv, 100.0, 0.001, per_decade, None, True)
        same = len(got) == len(written) and all(abs(a - b) <= 5e-6 * a for a, b in zip(got, written))
        return same, "%d bands selected, observe.dat holds %d" % (len(got), len(written))

    C.fails_first(check, 5)
    C.passes(check, 4)


if __name__ == "__main__":
    C.main(globals())
