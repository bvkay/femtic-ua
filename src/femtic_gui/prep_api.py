# -*- coding: utf-8 -*-
"""prep_api.py - the GUI's only door into scripts/prep_vulcan.py, imported in-process (no Qt here).

Every preview the GUI shows is computed by prep's own functions: load_config, read_site_table, parse_edi,
select_bands, rotation_angles, rotate_Z, rotation_text and design_warnings. prep needs only numpy and PyYAML
to import (femticPy is loaded only by a full prep run, which the GUI launches as a separate process). The
floor readout reproduces how check C09 counts floored components, over the bands prep would write (C07).

@author ben kay
:license: MIT
"""
from __future__ import annotations

import importlib.util
import os
import sys
from dataclasses import dataclass, field
from typing import Any

import numpy as np

from . import repo_root

_PREP = None


class PrepFailure(Exception):
    """prep_vulcan.py refused something; the message is prep's own."""


def prep() -> Any:
    """Import scripts/prep_vulcan.py once and return the module."""
    global _PREP
    if _PREP is None:
        path = repo_root() / "scripts" / "prep_vulcan.py"
        spec = importlib.util.spec_from_file_location("prep_vulcan", path)
        mod = importlib.util.module_from_spec(spec)
        sys.modules.setdefault("prep_vulcan", mod)
        spec.loader.exec_module(mod)
        _PREP = mod
    return _PREP


def _call(fn, *args):
    try:
        return fn(*args)
    except prep().PrepError as e:
        raise PrepFailure(str(e)) from None


def load_config(path: str | os.PathLike) -> dict:
    """prep's load_config on a file: the parsed, checked config dict ('c' in prep).

    Raises:
        PrepFailure: with prep's message if it refuses the config.
    """
    return _call(prep().load_config, str(path))


@dataclass
class Survey:
    """The inputs of one config as prep reads them, plus the rotated tensors the previews need.

    Attributes:
        c: prep's config dict.
        sites: (id, east_km, north_km, elev_km) rows of paths.coords_file, in file order.
        edis: {site id (EDI DATAID): prep.parse_edi result}.
        origin: (east_km, north_km) the coordinates are centred on (bbox centre unless sites.origin is set).
        angles: {site id: rotation angle in degrees} from data.rotation (0 without it).
        zrot: {site id: complex (nf, 4) Z rotated into the mesh frame, EDI units, order xx xy yx yy}.
        vrot: {site id: real (nf, 4) rotated variances}.
    """

    c: dict
    sites: list
    edis: dict
    origin: tuple
    angles: dict
    zrot: dict = field(default_factory=dict)
    vrot: dict = field(default_factory=dict)

    @property
    def ids(self) -> list[str]:
        """Site ids in sorted order."""
        return sorted(self.edis)


def load_survey(c: dict) -> Survey:
    """Read the site table and every EDI of a loaded config, and rotate the tensors as prep does.

    Raises:
        PrepFailure: if prep refuses the site table, an EDI or the rotation angles.
    """
    P = prep()
    sites = _call(P.read_site_table, c["coords_file"])
    try:
        files = sorted(f for f in os.listdir(c["edi_dir"]) if f.endswith(".edi"))
    except OSError as e:
        raise PrepFailure("cannot list paths.edi_dir %s: %s" % (c["edi_dir"], e)) from None
    edis = {}
    for f in files:
        e = _call(P.parse_edi, os.path.join(c["edi_dir"], f))
        edis[e["dataid"] or os.path.splitext(f)[0]] = e
    if c["origin"] is None:
        ee, nn = [s[1] for s in sites], [s[2] for s in sites]
        origin = (min(ee) + (max(ee) - min(ee)) / 2, min(nn) + (max(nn) - min(nn)) / 2)
    else:
        origin = tuple(c["origin"])
    angles = _call(P.rotation_angles, c, sorted(edis))
    sv = Survey(c=c, sites=sites, edis=edis, origin=origin, angles=angles)
    for sid, e in edis.items():
        z4 = np.column_stack([e["z"][k] for k in P.ZC])
        v4 = np.column_stack([e["var"][k] for k in P.ZC])
        sv.zrot[sid], sv.vrot[sid] = P.rotate_Z(z4, v4, angles[sid])
    return sv


def band_table(sv: Survey) -> list[tuple[float, int]]:
    """Every distinct unmasked EDI band with the number of sites where it is unmasked, highest first."""
    count: dict[float, int] = {}
    for e in sv.edis.values():
        for f in set(e["freq"][e["ok"]].tolist()):
            count[f] = count.get(f, 0) + 1
    return sorted(count.items(), reverse=True)


def candidates(sv: Survey, require_all_sites: bool) -> list[float]:
    """The candidate bands as check C05 builds them: unmasked at every site (or at any, if not required)."""
    n = len(sv.edis)
    return [f for f, k in band_table(sv) if k == n or not require_all_sites]


def select(sv: Survey, fmax: float, fmin: float, per_decade: float, explicit: list | None,
           require_all_sites: bool) -> list[float]:
    """prep's select_bands over the C05 candidates: the selected bands, highest first.

    Raises:
        PrepFailure: if no candidate lies between fmin and fmax or an explicit band is not a candidate.
    """
    return _call(prep().select_bands, candidates(sv, require_all_sites), fmax, fmin, per_decade, explicit)[0]


def floor_counts(sv: Survey, chosen: list[float], floors: list[float]) -> tuple[list[int], int]:
    """Count where the error floor sets the SE, as check C09 does, without writing anything.

    For every site and every selected band present and unmasked in that site's EDI (the lines prep writes,
    C07): floor_i * sqrt(|Z'xy| |Z'yx|) > sqrt(VAR'_i), with Z' and VAR' rotated by data.rotation.

    Returns:
        ([floored count of Zxx, Zxy, Zyx, Zyy], number of site-band pairs).
    """
    tol = prep().TOL_FREQ_REL
    ef = np.asarray(floors, dtype=float)
    counts, total = np.zeros(4, dtype=int), 0
    for sid, e in sv.edis.items():
        fe = e["freq"][e["ok"]]
        idx = []
        for f in chosen:
            if np.any(np.abs(fe - f) <= tol * f):
                j = int(np.argmin(np.abs(e["freq"] - f)))
                if e["ok"][j]:
                    idx.append(j)
        if not idx:
            continue
        z, v = sv.zrot[sid][idx], sv.vrot[sid][idx]
        gm = np.sqrt(np.abs(z[:, 1]) * np.abs(z[:, 2]))
        counts += np.sum(ef[None, :] * gm[:, None] > np.sqrt(v), axis=0)
        total += len(idx)
    return [int(k) for k in counts], total


def rotation_line(sv: Survey) -> str:
    """prep's one-line description of the rotation it applies (README, prep.log)."""
    return prep().rotation_text(sv.c, sv.angles)


def design_warnings(sv: Survey) -> list[str]:
    """prep's design warnings for this config (the ones a full prep run prints before its checks)."""
    return list(prep().design_warnings(sv.c, sv.sites, sv.origin))
