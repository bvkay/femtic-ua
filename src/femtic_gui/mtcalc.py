# -*- coding: utf-8 -*-
"""mtcalc.py - apparent resistivity and phase from impedances, in EDI units and in FEMTIC's ohm (numpy only).

EDI: Z in mV/km/nT with the exp(+i omega t) convention, rho_a = 0.2 T |Z|^2 (docs/mesh_tetra_pipeline.md).
observe.dat and FEMTIC's result csv: Z in ohm with exp(-i omega t) (prep writes conj(Z_EDI) / (10000 / 4 pi)),
so rho_a = |Z|^2 / (2 pi f mu0) and the phase is that of conj(Z). Both give the same rho_a and phase for the
same datum (tests/gui/test_mtcalc.py ties them to prep's written observe.dat).

@author ben kay
:license: MIT
"""
from __future__ import annotations

import math

import numpy as np

MU0 = 4.0e-7 * math.pi
C_OHM = 10000.0 / (4.0 * math.pi)     # 1 ohm = 10000/(4 pi) mV/km/nT


def rho_phase_edi(freq, z):
    """rho_a (ohm-m) and phase (deg) of EDI impedances.

    Args:
        freq: Frequencies in Hz (array-like).
        z: Complex impedances in mV/km/nT, exp(+i omega t), same shape as freq.

    Returns:
        (rho_a, phase_deg) arrays.
    """
    f, zz = np.asarray(freq, dtype=float), np.asarray(z, dtype=complex)
    return 0.2 / f * np.abs(zz) ** 2, np.degrees(np.angle(zz))


def rho_phase_ohm(freq, z):
    """rho_a (ohm-m) and phase (deg, EDI sign convention) of impedances in ohm with exp(-i omega t).

    Args:
        freq: Frequencies in Hz.
        z: Complex impedances in ohm as observe.dat and FEMTIC's result csv hold them.

    Returns:
        (rho_a, phase_deg) arrays, the phase of conj(Z) so that it matches rho_phase_edi.
    """
    f, zz = np.asarray(freq, dtype=float), np.asarray(z, dtype=complex)
    return np.abs(zz) ** 2 / (2.0 * math.pi * f * MU0), np.degrees(np.angle(np.conj(zz)))


def error_bars(z, sd, rho):
    """Error bars of rho_a and phase from a standard error of Z (same units as Z).

    Returns:
        (rho_err = 2 rho SD / |Z| in ohm-m, phase_err = SD / |Z| in degrees).
    """
    a = np.abs(np.asarray(z, dtype=complex))
    with np.errstate(divide="ignore", invalid="ignore"):
        r = np.asarray(sd, dtype=float) / a
    return 2.0 * np.asarray(rho, dtype=float) * r, np.degrees(r)


def wrap_yx(phase_deg):
    """Shift a yx phase by 180 deg into (-180, 180], so it plots in the same quadrant as xy."""
    p = np.asarray(phase_deg, dtype=float) + 180.0
    return (p + 180.0) % 360.0 - 180.0
