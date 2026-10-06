# -*- coding: utf-8 -*-
"""test_mtcalc.py - the curves' rho_a and phase formulas against prep's written observe.dat (T7).

The same datum must give the same rho_a and phase from the EDI (mV/km/nT, exp(+i omega t), rotated by prep's
rotate_Z) through mtcalc.rho_phase_edi, and from observe.dat (ohm, exp(-i omega t)) through
mtcalc.rho_phase_ohm, within the bound the '%.4e' writing of observe.dat allows.

    python tests/gui/test_mtcalc.py

@author ben kay
:license: MIT
"""
from __future__ import annotations

import math

import _common as C
import numpy as np
from test_prep_api import read_observe_mt

from femtic_gui import mtcalc, prep_api, readers


def _e4(v):
    v = np.abs(np.asarray(v, dtype=float))
    with np.errstate(divide="ignore"):
        return np.where(v > 0, 0.5e-4 * 10.0 ** np.floor(np.log10(np.where(v > 0, v, 1.0))), 0.0)


def compare(ohm_fn, rotated: bool) -> tuple[bool, str]:
    """Worst rho_a and phase mismatch over every (site, band, xx..yy) of observe.dat, in units of its bound."""
    sv = prep_api.load_survey(prep_api.load_config(C.CFG))
    smap = readers.read_station_map(C.OBSERVE.parent / "station_map.csv")
    worst_r = worst_p = 0.0
    n = 0
    for st, rows in zip(smap, read_observe_mt(C.OBSERVE)):
        sid = st["site_id"]
        e = sv.edis[sid]
        for row in rows:
            f = row[0]
            j = int(np.argmin(np.abs(e["freq"] - f)))
            df = abs(e["freq"][j] - f) / f
            z_edi = sv.zrot[sid][j] if rotated else np.array([e["z"][c][j] for c in ("XX", "XY", "YX", "YY")])
            z_obs = row[1:9:2] + 1j * row[2:9:2]
            r_e, p_e = mtcalc.rho_phase_edi(e["freq"][j], z_edi)
            r_o, p_o = ohm_fn(f, z_obs)
            dz = np.hypot(_e4(z_obs.real), _e4(z_obs.imag)) / np.abs(z_obs)     # relative |Z| bound
            bound_r = 2.0 * dz + dz ** 2 + 2.0 * df + 1e-9
            bound_p = np.degrees(dz) * 1.01 + 1e-9
            dp = np.abs((p_e - p_o + 180.0) % 360.0 - 180.0)
            worst_r = max(worst_r, float(np.max(np.abs(r_o / r_e - 1.0) / bound_r)))
            worst_p = max(worst_p, float(np.max(dp / bound_p)))
            n += 1
    ok = n == 2520 and worst_r <= 1.0 and worst_p <= 1.0
    return ok, "%d site-bands; worst rho_a %.4f x bound, worst phase %.4f x bound" % (n, worst_r, worst_p)


def _no_conjugation(f, z):
    """Mutant: the phase of Z itself (forgets FEMTIC's exp(-i omega t) convention)."""
    z = np.asarray(z, dtype=complex)
    return np.abs(z) ** 2 / (2.0 * math.pi * f * mtcalc.MU0), np.degrees(np.angle(z))


def test_rho_phase_ohm_matches_rotated_edi():
    """This test fails if rho_a or phase from observe.dat (mtcalc.rho_phase_ohm) differs from that of the rotated
    EDI tensor (mtcalc.rho_phase_edi) beyond the observe.dat write bound at any of the 2,520 site-bands, for any of
    xx, xy, yx, yy (T7). Failing cases: no conjugation; no rotation."""
    C.fails_first(compare, _no_conjugation, True)
    C.fails_first(compare, mtcalc.rho_phase_ohm, False)
    C.passes(compare, mtcalc.rho_phase_ohm, True)


if __name__ == "__main__":
    C.main(globals())
