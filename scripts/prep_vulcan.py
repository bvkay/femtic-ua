#!/usr/bin/env python3
"""prep_vulcan.py -- config-driven FEMTIC data and mesh-input preparation for the Vulcan MT survey.

    python scripts/prep_vulcan.py config/vulcan_mesh_v1.yml [--out DIR] [--force]
    python scripts/prep_vulcan.py config/vulcan_mesh_v1.yml --check-only DIR

Reads the EDIs through femticPy DataGen.read_MTdata and the site coordinates from the trusted site table,
centres the sites, selects frequencies by the rule in the config, and writes

    DIR/inversion/observe.dat      impedance data for FEMTIC (femticPy DataGen.write_observe)
    DIR/inversion/control.dat      FEMTIC inversion control (femticPy DataGen.write_inversion_control)
    DIR/inversion/station_map.csv  FEMTIC station number -> site id, EDI file and coordinates
    DIR/inversion/README.md        frequencies, stations, data counts, error floors, sign convention
    DIR/files/                     mesh-chain inputs (femticPy MeshGen): analysis_domain.dat, control.dat,
                                   makeMtr.param, obs_site.dat, observing_site.dat, resistivity_attr.dat,
                                   coast_line.dat, topography.dat, bathymetry.dat; plus region_seeds.dat
    DIR/README.md                  everything above plus the tables actually written and the self-checks
    DIR/config_used.yml, DIR/prep.log

femticPy is the vendored, patched copy named by paths.femticpy_src (external/femticPy; see its
UPSTREAM.txt and patches/series). No notebook is involved. Runs with Python >= 3.9, numpy, pandas < 3,
matplotlib and PyYAML: the WSL conda env 'femticpy' or a Windows Python that has them.

Everything is written to DIR.staging first. The self-checks then re-read the written files and compare
them with an independent parse of the EDIs and the site table. Only if every check passes is DIR.staging
renamed to DIR; any failure aborts with exit status 1, names the check and leaves DIR.staging for
inspection. --check-only re-runs the checks on an existing DIR without writing anything.
"""
import argparse
import contextlib
import datetime as _dt
import hashlib
import io
import math
import os
import platform
import re
import shutil
import sys
import warnings

import numpy as np
import yaml

C_OHM = 10000.0 / (4.0 * math.pi)   # 1 ohm = 10000/(4 pi) mV/km/nT; FEMTIC wants ohm (V/A)
TOL_POS_KM = 0.001                  # 1 m
TOL_FREQ_REL = 1.0e-6
TOL_TABLE_REL = 1.0e-9
ZC = ["XX", "XY", "YX", "YY"]
MASK_LEVEL = 1.0e10                 # femticPy drops Z rows with any value >= 1e10 (EDI EMPTY = 1e32)


class PrepError(Exception):
    pass


def fail(msg):
    raise PrepError(msg)


LOG = []


def log(msg=""):
    print(msg)
    LOG.append(msg)


# =============================================================================================== config
def cget(cfg, dotted, types=None):
    cur = cfg
    for key in dotted.split("."):
        if not isinstance(cur, dict) or key not in cur:
            fail("config: missing key '%s'" % dotted)
        cur = cur[key]
    if types is not None and not isinstance(cur, types):
        fail("config: '%s' has type %s, expected %s" % (dotted, type(cur).__name__, types))
    return cur


def num_rows(cfg, dotted, ncol):
    rows = cget(cfg, dotted, list)
    if not rows:
        fail("config: '%s' is empty" % dotted)
    out = []
    for i, r in enumerate(rows):
        if not isinstance(r, list) or len(r) != ncol:
            fail("config: '%s' row %d must have %d numbers, got %r" % (dotted, i + 1, ncol, r))
        try:
            out.append([float(v) for v in r])
        except (TypeError, ValueError):
            fail("config: '%s' row %d is not numeric: %r" % (dotted, i + 1, r))
    return out


def check_nested_ellipsoids(name, rows, five_col):
    """makeTetraMesh / makeMtr / TetGen2Femtic rules: radii grow, lengths do not shrink, every semi-axis
    of row i is >= that of row i-1, every oblateness in [0, 1)."""
    for i, r in enumerate(rows):
        obl = r[2:5] if five_col else r[2:4]
        if r[0] <= 0 or r[1] <= 0:
            fail("config: %s row %d: radius and length must be > 0" % (name, i + 1))
        if any(o < 0 or o >= 1 for o in obl):
            fail("config: %s row %d: every oblateness must be in [0, 1), got %s" % (name, i + 1, obl))
        if i == 0:
            continue
        p = rows[i - 1]
        if r[0] <= p[0]:
            fail("config: %s row %d: radius %.6g must exceed the previous %.6g" % (name, i + 1, r[0], p[0]))
        if r[1] < p[1]:
            fail("config: %s row %d: length %.6g is smaller than the previous %.6g" % (name, i + 1, r[1], p[1]))
        cols = range(2, 5) if five_col else range(2, 4)
        for c in cols:
            if r[0] * (1 - r[c]) < p[0] * (1 - p[c]) - 1e-12:
                fail("config: %s row %d: semi-axis r(1-o) of column %d (%.6g km) is smaller than row %d's "
                     "(%.6g km): the ellipsoids must nest" % (name, i + 1, c + 1, r[0] * (1 - r[c]), i,
                                                              p[0] * (1 - p[c])))


def check_increasing_radii(name, rows):
    for i, r in enumerate(rows):
        if r[0] <= 0 or r[1] <= 0:
            fail("config: %s row %d: radius and length must be > 0" % (name, i + 1))
        if i and r[0] <= rows[i - 1][0]:
            fail("config: %s row %d: radii must increase" % (name, i + 1))


def load_config(path):
    with open(path, encoding="utf-8") as fh:
        cfg = yaml.safe_load(fh)
    if not isinstance(cfg, dict) or cfg.get("schema") != "prep_vulcan/1":
        fail("config %s: expected 'schema: prep_vulcan/1'" % path)
    c = {"raw": cfg, "config_path": os.path.abspath(path)}
    root = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(path)), str(cget(cfg, "paths.root"))))
    c["root"] = root
    for k in ("edi_dir", "coords_file", "femticpy_src", "run_dir"):
        c[k] = os.path.normpath(os.path.join(root, str(cget(cfg, "paths." + k))))
    c["name"] = str(cget(cfg, "name"))
    c["expected_count"] = int(cget(cfg, "sites.expected_count"))
    origin = cget(cfg, "sites.origin")
    if origin == "bbox_centre":
        c["origin"] = None
    elif isinstance(origin, list) and len(origin) == 2:
        c["origin"] = [float(origin[0]), float(origin[1])]     # [east_km, north_km]
    else:
        fail("config: sites.origin must be 'bbox_centre' or [east_km, north_km]")
    c["utm"] = "UTM zone %s%s %s" % (cget(cfg, "sites.utm_zone"), cget(cfg, "sites.hemisphere"),
                                     cget(cfg, "sites.datum"))
    # data
    c["invert_Z"] = bool(cget(cfg, "data.invert_Z"))
    c["invert_VTF"] = bool(cget(cfg, "data.invert_VTF"))
    if not c["invert_Z"]:
        fail("config: data.invert_Z must be true (this script prepares impedance data)")
    if c["invert_VTF"]:
        fail("config: data.invert_VTF is true but the Vulcan EDIs hold no tipper; set it to false")
    ef = cget(cfg, "data.error_floor_Z", list)
    if len(ef) != 4 or any((not isinstance(v, (int, float))) or v < 0 for v in ef):
        fail("config: data.error_floor_Z must be 4 non-negative numbers [Zxx, Zxy, Zyx, Zyy]")
    c["error_floor_Z"] = [float(v) for v in ef]
    c["error_floor_VTF"] = float(cget(cfg, "data.error_floor_VTF"))
    # frequencies
    c["require_all_sites"] = bool(cget(cfg, "frequencies.require_all_sites"))
    c["fmax"] = float(cget(cfg, "frequencies.fmax_hz"))
    c["fmin"] = float(cget(cfg, "frequencies.fmin_hz"))
    c["per_decade"] = float(cget(cfg, "frequencies.per_decade"))
    if not (0 < c["fmin"] < c["fmax"]) or c["per_decade"] <= 0:
        fail("config: need 0 < fmin_hz < fmax_hz and per_decade > 0")
    ex = cget(cfg, "frequencies.explicit_hz")
    c["explicit_hz"] = None if ex is None else [float(v) for v in ex]
    # mesh
    dom = cget(cfg, "mesh.analysis_domain_km", dict)
    c["domain"] = []
    for ax in ("x", "y", "z"):
        lo, hi = [float(v) for v in dom[ax]]
        if not lo < 0 < hi:
            fail("config: mesh.analysis_domain_km.%s = [%g, %g] must straddle 0 (TetGen2Femtic classifies "
                 "the outer faces by coordinate sign)" % (ax, lo, hi))
        c["domain"].append([lo, hi])
    c["center"] = [float(v) for v in cget(cfg, "mesh.center_km", list)]
    if len(c["center"]) != 3:
        fail("config: mesh.center_km needs 3 values")
    c["rotation"] = float(cget(cfg, "mesh.rotation_deg"))
    c["topo_mode"] = str(cget(cfg, "mesh.topography.mode"))
    if c["topo_mode"] not in ("flat", "dem"):
        fail("config: mesh.topography.mode must be 'flat' or 'dem'")
    dem = cget(cfg, "mesh.topography.dem_file")
    c["dem_file"] = None if dem is None else os.path.normpath(os.path.join(root, str(dem)))
    if c["topo_mode"] == "dem" and (c["dem_file"] is None or not os.path.isfile(c["dem_file"])):
        fail("config: topography mode 'dem' needs an existing mesh.topography.dem_file")
    ctl = cget(cfg, "mesh.control", dict)
    c["ctl_threads"] = int(ctl["num_threads"])
    c["ctl_surf_mesh"] = bool(ctl["surf_mesh"])
    c["ctl_iter_max"] = None if ctl.get("iter_max") is None else [int(v) for v in ctl["iter_max"]]
    c["ctl_ellipsoids"] = num_rows(cfg, "mesh.control.ellipsoids", 5)
    ip = ctl["interpolate"]
    c["ctl_interp"] = [float(ip["search_radius_km"]), int(ip["max_points"]), float(ip["eps_km"])]
    c["ctl_alt"] = [float(ctl["altitude"]["min_km"]), float(ctl["altitude"]["max_km"])]
    sd = ctl.get("sea_depth")
    c["ctl_sea"] = None if sd is None else [float(sd["min_km"]), float(sd["max_km"])]
    c["observing_circles"] = num_rows(cfg, "mesh.observing_sites.circles", 2)
    c["obs_spheres"] = num_rows(cfg, "mesh.obs_sites.spheres", 3)
    c["mtr_ellipsoids"] = num_rows(cfg, "mesh.mtr.ellipsoids", 5)
    ra = cget(cfg, "mesh.resistivity_attr", dict)
    c["rho_start"] = float(cget(cfg, "mesh.starting_resistivity_ohmm"))
    air, earth = ra["air"], ra["earth"]
    c["regions"] = [[int(air["attribute"]), float(air["resistivity_ohmm"]), int(air["ndiv"]), int(air["fixed"])],
                    [int(earth["attribute"]), c["rho_start"], int(earth["ndiv"]), int(earth["fixed"])]]
    if c["regions"][0][2] >= 0:
        fail("config: the air region needs ndiv < 0 (TetGen2Femtic treats ndiv < 0 as air/sea)")
    if c["regions"][1][2] < 0:
        fail("config: the earth region needs ndiv >= 0 (ndiv < 0 would turn its faces into 'Earth surface')")
    if c["regions"][0][0] == c["regions"][1][0]:
        fail("config: air and earth attributes must differ")
    if c["rho_start"] <= 0:
        fail("config: mesh.starting_resistivity_ohmm must be > 0")
    c["attr_ellipsoids"] = num_rows(cfg, "mesh.resistivity_attr.ellipsoids", 4)
    c["attr_sites"] = num_rows(cfg, "mesh.resistivity_attr_sites.circles", 2)
    c["seeds"] = num_rows(cfg, "mesh.region_seeds", 5)
    check_nested_ellipsoids("mesh.control.ellipsoids", c["ctl_ellipsoids"], True)
    check_nested_ellipsoids("mesh.mtr.ellipsoids", c["mtr_ellipsoids"], True)
    check_nested_ellipsoids("mesh.resistivity_attr.ellipsoids", c["attr_ellipsoids"], False)
    check_increasing_radii("mesh.observing_sites.circles", c["observing_circles"])
    check_increasing_radii("mesh.obs_sites.spheres", c["obs_spheres"])
    check_increasing_radii("mesh.resistivity_attr_sites.circles", c["attr_sites"])
    for i, s in enumerate(c["obs_spheres"]):
        if not 0 <= s[2] < 1:
            fail("config: mesh.obs_sites.spheres row %d: vertical oblateness must be in [0, 1)" % (i + 1))
    seed_attrs = sorted(int(s[3]) for s in c["seeds"])
    if seed_attrs != sorted(r[0] for r in c["regions"]):
        fail("config: region_seeds attributes %s must be exactly the region attributes %s (one seed per "
             "closed region)" % (seed_attrs, sorted(r[0] for r in c["regions"])))
    for s in c["seeds"]:
        for k in range(3):
            if not c["domain"][k][0] < s[k] < c["domain"][k][1]:
                fail("config: region seed %s lies outside the analysis domain" % s)
    # inversion
    inv = cget(cfg, "inversion", dict)
    try:
        c["inv"] = {"NUM_THREADS": int(inv["NUM_THREADS"]), "INV_METHOD": int(inv["INV_METHOD"]),
                    "TRADE_OFF_PARAM": [float(v) for v in inv["TRADE_OFF_PARAM"]],
                    "ITERATION": int(inv["ITERATION"]), "CONVERGE": float(inv["CONVERGE"]),
                    "ALPHA_WEIGHT": [float(v) for v in inv["ALPHA_WEIGHT"]],
                    "DISTORTION": int(inv["DISTORTION"]), "BOTTOM_RESISTIVITY": float(inv["BOTTOM_RESISTIVITY"]),
                    "OWNER_ELEMENT": None if inv["OWNER_ELEMENT"] is None else int(inv["OWNER_ELEMENT"])}
    except KeyError as e:
        fail("config: inversion.%s is missing" % e.args[0])
    iv = c["inv"]
    if iv["INV_METHOD"] not in (0, 1):
        fail("config: inversion.INV_METHOD must be 0 (model space) or 1 (data space)")
    need = {0: 1, 1: 2, 2: 3, 3: 2}.get(iv["DISTORTION"])
    if need is None:
        fail("config: inversion.DISTORTION must be 0, 1, 2 or 3")
    if len(iv["TRADE_OFF_PARAM"]) != need:
        fail("config: DISTORTION %d needs %d TRADE_OFF_PARAM value(s), got %d" %
             (iv["DISTORTION"], need, len(iv["TRADE_OFF_PARAM"])))
    if len(iv["ALPHA_WEIGHT"]) != 3:
        fail("config: inversion.ALPHA_WEIGHT needs 3 values")
    if iv["OWNER_ELEMENT"] not in (None, 0, 1, -1):
        fail("config: inversion.OWNER_ELEMENT must be null, 0, 1 or -1")
    if iv["ITERATION"] < 1 or iv["NUM_THREADS"] < 1 or iv["CONVERGE"] <= 0:
        fail("config: inversion ITERATION and NUM_THREADS must be >= 1, CONVERGE > 0")
    return c


# ============================================================================================ inputs
def read_site_table(path):
    """id east_km north_km elev_km per line; '#' starts a comment. Returns a list of (id, e, n, elev)."""
    rows = []
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            s = line.split("#", 1)[0].strip()
            if not s:
                continue
            p = s.split()
            if len(p) != 4:
                fail("%s:%d: expected 'id east_km north_km elev_km', got %d fields" % (path, n, len(p)))
            try:
                vals = [float(v) for v in p[1:]]
            except ValueError:
                fail("%s:%d: non-numeric coordinate in %r" % (path, n, s))
            if not all(math.isfinite(v) for v in vals):
                fail("%s:%d: non-finite coordinate" % (path, n))
            rows.append((p[0], vals[0], vals[1], vals[2]))
    ids = [r[0] for r in rows]
    dup = sorted({i for i in ids if ids.count(i) > 1})
    if dup:
        fail("%s: duplicate site ids %s" % (path, dup))
    # km sanity: UTM eastings are 100-900 km, northings 0-10000 km
    for r in rows:
        if not (100 < r[1] < 900 and 0 < r[2] < 10000 and -1 < r[3] < 9):
            fail("%s: site %s (%g, %g, %g) is not in km (east, north, elevation)" % ((path,) + r))
    return rows


def load_coordinates_into_datagen(dg, rows):
    """femticPy DataGen.read_MTdata_coordinates (femticPy.py:207-223) adapted to the trusted table: same
    columns and the same result (ids as pandas 'string', rows sorted by id, z = -elevation, mt_coords a deep
    copy), but the table is read and validated by read_site_table instead of a bare read_csv."""
    import pandas as pd
    coords = pd.DataFrame({"id": pd.array([r[0] for r in rows], dtype="string"),
                           "east": np.array([r[1] for r in rows], dtype="float64"),
                           "north": np.array([r[2] for r in rows], dtype="float64"),
                           "z": np.array([r[3] for r in rows], dtype="float64")})
    coords = coords.sort_values("id").reset_index(drop=True)
    dg.mt_coords_utm = coords
    dg.mt_coords_utm["z"] = -dg.mt_coords_utm["z"]
    dg.mt_coords = dg.mt_coords_utm.copy(deep=True)


def parse_edi(path):
    """Independent minimal EDI reader (not MTtools): DATAID, NFREQ, FREQ, Z blocks, tipper presence."""
    blocks, cur, dataid, nfreq, tipper = {}, None, None, None, False
    want = {"FREQ"} | {"Z%s%s" % (c, s) for c in ZC for s in ("R", "I", ".VAR")}
    info = {"RHOXY", "RHOXY.ERR", "RHOYX", "RHOYX.ERR"}          # optional; only for the README statistics
    want_all = want | info
    with open(path, encoding="ascii", errors="replace") as fh:
        for line in fh:
            s = line.strip()
            if s.startswith(">"):
                name = s[1:].split()[0].upper() if len(s) > 1 else ""
                if name.startswith("TXR") or name.startswith("TYR"):
                    tipper = True
                cur = name if name in want_all else None
                if cur:
                    blocks[cur] = []
                continue
            m = re.search(r'DATAID\s*=\s*"([^"]*)"', s)
            if m and dataid is None:
                dataid = m.group(1)
            m = re.match(r"NFREQ\s*=\s*(\d+)", s)
            if m and nfreq is None:
                nfreq = int(m.group(1))
            if cur:
                blocks[cur] += [float(v) for v in s.split()]
    missing = sorted(want - set(blocks))
    if missing:
        fail("%s: missing EDI blocks %s" % (path, missing))
    lens = {k: len(v) for k, v in blocks.items()}
    if len(set(lens.values())) != 1 or (nfreq is not None and lens["FREQ"] != nfreq):
        fail("%s: EDI block lengths disagree: %s (NFREQ %s)" % (path, lens, nfreq))
    f = np.array(blocks["FREQ"])
    z = {c: np.array(blocks["Z%sR" % c]) + 1j * np.array(blocks["Z%sI" % c]) for c in ZC}
    var = {c: np.array(blocks["Z%s.VAR" % c]) for c in ZC}
    stack = np.vstack([np.real(z[c]) for c in ZC] + [np.imag(z[c]) for c in ZC] + [var[c] for c in ZC])
    ok = ~np.any(stack >= MASK_LEVEL, axis=0)
    rho_err = {c: (np.array(blocks["RHO%s" % c]), np.array(blocks["RHO%s.ERR" % c]))
               for c in ("XY", "YX") if "RHO%s" % c in blocks and "RHO%s.ERR" % c in blocks}
    return {"dataid": dataid, "freq": f, "z": z, "var": var, "ok": ok, "tipper": tipper,
            "file": os.path.basename(path), "rho_err": rho_err}


def edi_statistics(edis, chosen):
    """README facts measured on the EDIs (not pass/fail): the EDI-convention phase of Zxy and Zyx at the
    selected bands, and how Geotools' RHO.ERR relates to sqrt(VAR)."""
    pxy, pyx, ratio, n_empty, empty_sel = [], [], [], 0, []
    for e in edis.values():
        for f in chosen:
            j = np.where(np.abs(e["freq"] - f) <= TOL_FREQ_REL * f)[0]
            if len(j) and e["ok"][j[0]]:
                pxy.append(math.degrees(np.angle(e["z"]["XY"][j[0]])))
                pyx.append(math.degrees(np.angle(e["z"]["YX"][j[0]])))
                if any(v[0][j[0]] >= MASK_LEVEL or v[1][j[0]] >= MASK_LEVEL for v in e["rho_err"].values()):
                    empty_sel.append("%s %.5g Hz" % (e["dataid"], f))
        for c, (rho, err) in e["rho_err"].items():
            zz, sd = np.abs(e["z"][c]), np.sqrt(e["var"][c])
            live = e["ok"] & (rho < MASK_LEVEL) & (err < MASK_LEVEL)   # Geotools writes RHO EMPTY where Z is kept
            n_empty += int(np.sum(e["ok"] & ~live))
            with np.errstate(divide="ignore", invalid="ignore"):
                r = err / (2 * rho * sd / zz)
            ratio += [v for v in r[live] if np.isfinite(v)]
    q = lambda a, p: float(np.percentile(a, p)) if len(a) else float("nan")
    return {"edi_phase_xy": q(pxy, 50), "edi_phase_yx": q(pyx, 50), "rhoerr_ratio": (q(ratio, 1), q(ratio, 50),
            q(ratio, 99)), "rhoerr_n": len(ratio), "rho_empty_n": n_empty, "rho_empty_selected": empty_sel}


def select_bands(candidates, fmax, fmin, per_decade, explicit=None):
    """candidates: iterable of band frequencies (Hz). Returns (chosen, table) with chosen in descending order;
    table rows are (target_hz, chosen_hz or None, |dlog10|)."""
    cands = sorted({float(f) for f in candidates if fmin * (1 - 1e-9) <= f <= fmax * (1 + 1e-9)}, reverse=True)
    if not cands:
        fail("no candidate band between fmin %g and fmax %g Hz" % (fmin, fmax))
    lc = np.log10(cands)
    if explicit:
        chosen = []
        for e in explicit:
            d = np.abs(lc - math.log10(e))
            i = int(np.argmin(d))
            if d[i] > 1e-6:
                fail("frequencies.explicit_hz: %g Hz is not a candidate band (nearest %g Hz)" % (e, cands[i]))
            if cands[i] not in chosen:
                chosen.append(cands[i])
        chosen.sort(reverse=True)
        return chosen, [(e, c, 0.0) for e, c in zip(explicit, chosen)]
    step = 1.0 / per_decade
    chosen, table, k = [], [], 0
    lmax, lmin = math.log10(fmax), math.log10(fmin)
    while lmax - k * step >= lmin - 1e-9:
        lt = lmax - k * step
        d = np.abs(lc - lt)
        i = int(np.argmin(d))            # ties go to the first, i.e. the higher, frequency
        if d[i] <= 0.5 * step + 1e-12:
            table.append((10 ** lt, cands[i], float(d[i])))
            if cands[i] not in chosen:
                chosen.append(cands[i])
        else:
            table.append((10 ** lt, None, float(d[i])))
        k += 1
    chosen.sort(reverse=True)
    return chosen, table


# ======================================================================================= file parsers
def tokens_of(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read().split()


class Tok:
    def __init__(self, path):
        self.t, self.i, self.path = tokens_of(path), 0, path

    def next(self, conv=float):
        if self.i >= len(self.t):
            fail("%s: unexpected end of file" % self.path)
        v = self.t[self.i]
        self.i += 1
        try:
            return conv(v)
        except ValueError:
            fail("%s: token %d %r is not %s" % (self.path, self.i, v, conv.__name__))

    def rows(self, n, ncol):
        return [[self.next() for _ in range(ncol)] for _ in range(n)]

    def done(self):
        return self.i >= len(self.t)


def parse_observe(path, owner_minus1):
    """observe.dat per the FEMTIC manual (manual.txt:1033-1072, 1113-1130). Station line:
    ID H_ID [owner] X Y (owner only with OWNER_ELEMENT -1). MT rows: f + 8 values + 8 SEs; VTF rows: f + 4 + 4."""
    with open(path, encoding="utf-8") as fh:
        lines = [ln.split() for ln in fh.read().splitlines()]
    out, i = {}, 0

    def need(cond, msg):
        if not cond:
            fail("%s line %d: %s" % (path, i + 1, msg))

    while True:
        need(i < len(lines), "missing END")
        tok = lines[i]
        if tok == ["END"]:
            break
        need(len(tok) == 2 and tok[0] in ("MT", "VTF"), "expected 'MT n', 'VTF n' or 'END', got %r" % tok)
        typ, n = tok[0], int(tok[1])
        need(typ not in out, "second %s block" % typ)
        i += 1
        nval = 17 if typ == "MT" else 9
        stations = []
        for _ in range(n):
            hdr = lines[i]
            need(len(hdr) == (5 if owner_minus1 else 4), "station line %r has %d fields" % (hdr, len(hdr)))
            st = {"id": int(hdr[0]), "hid": int(hdr[1]), "owner": int(hdr[2]) if owner_minus1 else None,
                  "x": float(hdr[-2]), "y": float(hdr[-1]), "xs": hdr[-2], "ys": hdr[-1]}
            i += 1
            need(len(lines[i]) == 1, "expected the number of frequencies")
            nf = int(lines[i][0])
            i += 1
            rows = []
            for _ in range(nf):
                need(len(lines[i]) == nval, "expected %d numbers, got %d" % (nval, len(lines[i])))
                rows.append([float(v) for v in lines[i]])
                i += 1
            st["rows"] = np.array(rows).reshape(nf, nval)
            stations.append(st)
        out[typ] = stations
    need(all(len(t) == 0 for t in lines[i + 1:]), "text after END")
    return out


def parse_keyword_file(path, keywords):
    """line-oriented FEMTIC/makeTetraMesh control.dat: keyword alone on a line, values on the following
    lines. Returns {keyword: [tokens]}; a repeated keyword fails."""
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    out, cur = {}, None
    for n, ln in enumerate(lines, 1):
        s = ln.strip()
        if s in keywords:
            if s in out:
                fail("%s:%d: keyword %s repeated" % (path, n, s))
            out[s], cur = [], s
            if s == "END":
                break
        elif s:
            if cur is None:
                fail("%s:%d: value %r before any keyword" % (path, n, s))
            out[cur] += s.split()
    if "END" not in out:
        fail("%s: no END" % path)
    return out


def parse_mesh_files(fdir):
    P = {}
    t = Tok(os.path.join(fdir, "analysis_domain.dat"))
    P["domain"] = t.rows(3, 2)
    if not t.done():
        fail("analysis_domain.dat: extra numbers")
    kw = parse_keyword_file(os.path.join(fdir, "control.dat"),
                            {"CENTER", "ROTATION", "NUM_THREADS", "SURF_MESH", "ELLIPSOIDS", "ITER_MAX",
                             "INTERPOLATE", "ALTITUDE", "SEA_DEPTH", "END"})
    ctl = {"center": [float(v) for v in kw["CENTER"]], "rotation": [float(v) for v in kw["ROTATION"]],
           "num_threads": [int(v) for v in kw.get("NUM_THREADS", [])], "surf_mesh": "SURF_MESH" in kw,
           "iter_max": [int(v) for v in kw["ITER_MAX"]] if "ITER_MAX" in kw else None}
    e = kw["ELLIPSOIDS"]
    ne = int(e[0])
    if len(e) != 1 + 5 * ne:
        fail("control.dat: ELLIPSOIDS declares %d rows but holds %d numbers" % (ne, len(e) - 1))
    ctl["ellipsoids"] = [[float(v) for v in e[1 + 5 * k:6 + 5 * k]] for k in range(ne)]
    ip = kw["INTERPOLATE"]
    if len(ip) != 3 or not re.fullmatch(r"[0-9]+", ip[1]):
        fail("control.dat: INTERPOLATE must be radius, an INTEGER point count and epsilon, got %s" % ip)
    ctl["interpolate"] = [float(ip[0]), int(ip[1]), float(ip[2])]
    ctl["altitude"] = kw["ALTITUDE"]
    ctl["sea_depth"] = kw.get("SEA_DEPTH")
    P["control"] = ctl
    t = Tok(os.path.join(fdir, "makeMtr.param"))
    P["mtr"] = {"center": [t.next() for _ in range(3)], "rotation": t.next()}
    P["mtr"]["ellipsoids"] = t.rows(t.next(int), 5)
    P["mtr"]["n_sea"] = t.next(int) if not t.done() else 0
    t = Tok(os.path.join(fdir, "obs_site.dat"))
    sites = []
    for _ in range(t.next(int)):
        xyz = [t.next() for _ in range(3)]
        sites.append((xyz, t.rows(t.next(int), 3)))
    P["obs_site"] = {"sites": sites, "n_lines": t.next(int) if not t.done() else 0}
    t = Tok(os.path.join(fdir, "observing_site.dat"))
    sites = []
    for _ in range(t.next(int)):
        xy = [t.next(), t.next()]
        sites.append((xy, t.rows(t.next(int), 2)))
    P["observing_site"] = {"sites": sites, "n_lines": t.next(int) if not t.done() else 0}
    t = Tok(os.path.join(fdir, "resistivity_attr.dat"))
    ra = {"regions": [[t.next(int), t.next(), t.next(int), t.next(int)] for _ in range(t.next(int))]}
    ra["center"] = [t.next() for _ in range(3)]
    ra["rotation"] = t.next()
    ra["ellipsoids"] = t.rows(t.next(int), 4)
    sites = []
    for _ in range(t.next(int)):
        xyz = [t.next() for _ in range(3)]
        sites.append((xyz, t.rows(t.next(int), 2)))
    ra["sites"] = sites
    if not t.done():
        fail("resistivity_attr.dat: extra numbers after the site list")
    P["resistivity_attr"] = ra
    t = Tok(os.path.join(fdir, "coast_line.dat"))
    nb = t.next(int)
    pts = []
    while not t.done():
        pts.append([t.next(), t.next(), t.next(int), t.next(int)])
    P["coast"] = {"n": nb, "points": pts}
    topo = np.loadtxt(os.path.join(fdir, "topography.dat"), ndmin=2)
    P["topo"] = topo
    seeds = []
    with open(os.path.join(fdir, "region_seeds.dat"), encoding="utf-8") as fh:
        for ln in fh:
            s = ln.split("#", 1)[0].split()
            if s:
                seeds.append([float(v) for v in s])
    P["seeds"] = seeds
    return P


# ============================================================================================ checks
class Checks:
    def __init__(self):
        self.res = []

    def add(self, cid, name, criterion, ok, detail):
        self.res.append({"id": cid, "name": name, "criterion": criterion, "ok": bool(ok), "detail": detail})
        log("  [%s] %-4s %s: %s" % ("PASS" if ok else "FAIL", cid, name, detail))

    def failed(self):
        return [r for r in self.res if not r["ok"]]


def rel_close(a, b, tol):
    return abs(a - b) <= tol * max(abs(a), abs(b), 1e-300)


def e4_bound(v, w):
    """largest |written - exact| that '%.4e' rounding can produce (plus 1e-9 relative slack)"""
    m = max(abs(v), abs(w))
    if m == 0:
        return 0.0
    return 0.5e-4 * 10 ** math.floor(math.log10(m)) * (1 + 1e-9) + 1e-9 * m


def match_sites(points, site_xy, what):
    """points: list of (x, y). Returns (bijection ok, max distance km, mapping list or message)."""
    ids = list(site_xy)
    arr = np.array([site_xy[k] for k in ids])
    used, mapping, dmax = set(), [], 0.0
    for p in points:
        d = np.hypot(arr[:, 0] - p[0], arr[:, 1] - p[1])
        hits = np.where(d <= TOL_POS_KM)[0]
        if len(hits) != 1:
            return False, float(d.min()), "%s point (%.5f, %.5f) is within 1 m of %d sites" % (what, p[0], p[1], len(hits))
        k = ids[hits[0]]
        if k in used:
            return False, float(d.min()), "%s: site %s matched twice" % (what, k)
        used.add(k)
        mapping.append(k)
        dmax = max(dmax, float(d[hits[0]]))
    if len(used) != len(ids):
        return False, dmax, "%s: %d of %d sites matched" % (what, len(used), len(ids))
    return True, dmax, mapping


def run_checks(c, run_dir, sites, edis, origin, femticpy_anchor=None, femticpy_chosen=None):
    """Re-reads every written file and compares it with the config, the site table and an independent
    parse of the EDIs. Returns (Checks, stats) where stats holds what the README reports."""
    ck = Checks()
    stats = {}
    inv_dir, fdir = os.path.join(run_dir, "inversion"), os.path.join(run_dir, "files")
    n_exp = c["expected_count"]
    oe = c["inv"]["OWNER_ELEMENT"]
    e0, n0 = origin
    site_xy = {s[0]: (s[2] - n0, s[1] - e0) for s in sites}           # FEMTIC x = north, y = east
    mesh_z = {s[0]: (0.0 if c["topo_mode"] == "flat" else -s[3]) for s in sites}
    log("self-checks on %s" % run_dir)

    # C01 LF only
    crs = []
    for dp, _, fns in os.walk(run_dir):
        for fn in fns:
            with open(os.path.join(dp, fn), "rb") as fh:
                if b"\r" in fh.read():
                    crs.append(os.path.relpath(os.path.join(dp, fn), run_dir))
    ck.add("C01", "LF line endings", "fails if any file in the run directory contains a CR byte",
           not crs, "no CR in any file" if not crs else "CR in %s" % crs)

    # C02 site ids
    ids_tab = sorted(s[0] for s in sites)
    ids_edi = sorted(e["dataid"] for e in edis.values())
    ids_fn = sorted(os.path.splitext(k)[0] for k in edis)
    ok = (len(ids_tab) == n_exp and ids_tab == ids_edi == ids_fn and len(set(ids_tab)) == n_exp)
    ck.add("C02", "site ids", "fails unless the site table, the EDI DATAIDs and the EDI file names are the "
           "same %d distinct ids" % n_exp, ok,
           "%d table ids, %d DATAIDs, %d files; identical sets: %s" %
           (len(ids_tab), len(ids_edi), len(ids_fn), ids_tab == ids_edi == ids_fn))
    by_id = {e["dataid"]: e for e in edis.values()}

    # C03 origin
    if c["origin"] is None:
        ee = [s[1] for s in sites]
        nn = [s[2] for s in sites]
        indep = (min(ee) + (max(ee) - min(ee)) / 2, min(nn) + (max(nn) - min(nn)) / 2)
        ok = abs(indep[0] - e0) < 1e-9 and abs(indep[1] - n0) < 1e-9
        if femticpy_anchor is not None:
            ok = ok and abs(femticpy_anchor[1] - e0) < 1e-9 and abs(femticpy_anchor[0] - n0) < 1e-9
        ck.add("C03", "origin", "fails if the origin differs by more than 1e-9 km from the site bounding-box "
               "centre recomputed here (and from femticPy's DataGen.anchor when available)", ok,
               "origin E %.5f N %.5f km; bbox centre E %.5f N %.5f km" % (e0, n0, indep[0], indep[1]))

    # C04 observe.dat structure and station mapping
    obs = parse_observe(os.path.join(inv_dir, "observe.dat"), oe == -1)
    mt = obs.get("MT", [])
    smap = {}
    with open(os.path.join(inv_dir, "station_map.csv"), encoding="utf-8") as fh:
        hdr = fh.readline().strip().split(",")
        for ln in fh:
            r = dict(zip(hdr, ln.strip().split(",")))
            smap[int(r["femtic_station_id"])] = r
    ok_ids = [s["id"] for s in mt] == list(range(1, n_exp + 1))
    good, dmax, mapping = match_sites([(s["x"], s["y"]) for s in mt], site_xy, "observe.dat MT")
    ok_map = good and all(smap.get(s["id"], {}).get("site_id") == m for s, m in zip(mt, mapping))
    msg = mapping if not good else "max offset %.2f m" % (dmax * 1000)
    extra = ""
    ok_vtf = True
    if oe == -1:
        vtf = obs.get("VTF", [])
        ok_vtf = (len(vtf) == len(mt) and
                  all(s["hid"] == s["id"] + 1000 and s["owner"] == 0 for s in mt) and
                  all(v["id"] == m["hid"] and v["hid"] == v["id"] and v["owner"] == 1 and len(v["rows"]) == 0
                      and v["xs"] == m["xs"] and v["ys"] == m["ys"] for v, m in zip(vtf, mt)))
        extra = "; %d dummy VTF H-stations (owner 1, 0 frequencies, same x y, ids = MT H-station ids): %s" % (
            len(vtf), ok_vtf)
    else:
        ok_vtf = "VTF" not in obs and all(s["hid"] == s["id"] for s in mt)
    ck.add("C04", "stations", "fails unless observe.dat's MT block holds stations 1..%d, each within 1 m of "
           "exactly one site of the centred site table (a bijection), agreeing with station_map.csv"
           "%s" % (n_exp, "; with OWNER_ELEMENT -1 every MT station must name a dummy VTF station "
                   "(owner 1, 0 frequencies) at the same x y" if oe == -1 else ""),
           ok_ids and ok_map and ok_vtf,
           "%d MT stations, ids 1..N: %s, one-to-one with the site table and station_map.csv: %s (%s)%s" %
           (len(mt), ok_ids, ok_map, msg, extra))

    # C05 frequency selection reproduced from the independent EDI parse
    common = None
    for e in edis.values():
        fs = set(e["freq"][e["ok"]].tolist())
        common = fs if common is None else (common & fs if c["require_all_sites"] else common | fs)
    chosen, _ = select_bands(common, c["fmax"], c["fmin"], c["per_decade"], c["explicit_hz"])
    ok = True
    det = "%d bands selected from %d candidates" % (len(chosen), len(common))
    if femticpy_chosen is not None:
        ok = len(chosen) == len(femticpy_chosen) and all(rel_close(a, b, TOL_FREQ_REL)
                                                         for a, b in zip(chosen, femticpy_chosen))
        det += "; femticPy path chose the same list: %s" % ok
    ck.add("C05", "frequency selection", "fails if the bands selected from femticPy's frequency table differ "
           "from those selected by the same rule from an independent parse of the EDIs", ok, det)

    # C06-C09 per-station data
    fbad, cbad, zbad, sbad, nlines, nexp_lines = [], [], [], [], 0, 0
    zmax, smax, fmax_rel = 0.0, 0.0, 0.0
    ef = c["error_floor_Z"]
    phs_xy, phs_yx = [], []
    floored = np.zeros(4)
    total = 0
    for s in mt:
        sid = smap.get(s["id"], {}).get("site_id")
        e = by_id.get(sid)
        if e is None:
            cbad.append(s["id"])
            continue
        rows = s["rows"]
        nlines += len(rows)
        fe = e["freq"][e["ok"]]
        exp_f = [f for f in chosen if np.any(np.abs(fe - f) <= TOL_FREQ_REL * f)]
        nexp_lines += len(exp_f)
        if len(rows) != len(exp_f):
            cbad.append((sid, len(rows), len(exp_f)))
            continue
        for r, fx in zip(rows, exp_f):
            f = r[0]
            j = int(np.argmin(np.abs(e["freq"] - f)))
            rel = abs(e["freq"][j] - f) / e["freq"][j]
            fmax_rel = max(fmax_rel, rel)
            if rel > TOL_FREQ_REL or not rel_close(fx, e["freq"][j], TOL_FREQ_REL) or not e["ok"][j]:
                fbad.append("%s %.6g Hz" % (sid, f))
                continue
            zo = {cc: complex(r[1 + 2 * k], r[2 + 2 * k]) for k, cc in enumerate(ZC)}
            se = {cc: (r[9 + 2 * k], r[10 + 2 * k]) for k, cc in enumerate(ZC)}
            gm = math.sqrt(abs(e["z"]["XY"][j]) * abs(e["z"]["YX"][j]))
            total += 1
            for k, cc in enumerate(ZC):
                zexp = np.conj(e["z"][cc][j]) / C_OHM
                for w, v in ((zo[cc].real, zexp.real), (zo[cc].imag, zexp.imag)):
                    d = abs(w - v)
                    zmax = max(zmax, d / max(abs(v), 1e-300))
                    if d > e4_bound(v, w):
                        zbad.append("%s %.6g Hz Z%s %.5g vs %.5g" % (sid, f, cc, w, v))
                sd = math.sqrt(e["var"][cc][j])
                sexp = max(sd, ef[k] * gm) / C_OHM
                if ef[k] * gm > sd:
                    floored[k] += 1
                for w in se[cc]:
                    d = abs(w - sexp)
                    smax = max(smax, d / sexp)
                    if d > e4_bound(sexp, w):
                        sbad.append("%s %.6g Hz Z%s SE %.5g vs %.5g" % (sid, f, cc, w, sexp))
                if se[cc][0] != se[cc][1]:
                    sbad.append("%s %.6g Hz Z%s Re/Im SE differ" % (sid, f, cc))
            phs_xy.append(math.degrees(math.atan2(zo["XY"].imag, zo["XY"].real)))
            phs_yx.append(math.degrees(math.atan2(zo["YX"].imag, zo["YX"].real)) % 360.0)
    ck.add("C06", "frequencies", "fails if any observe.dat frequency differs by more than 1e-6 relative from "
           "the same band in that site's EDI, or is not one of the selected bands", not fbad,
           "max relative difference %.2e over %d data lines%s" % (fmax_rel, nlines,
                                                                   "" if not fbad else "; bad: %s" % fbad[:5]))
    ck.add("C07", "data line count", "fails if a station's number of data lines differs from the number of "
           "selected bands present (unmasked) in its EDI, or the total differs from their sum over sites",
           not cbad and nlines == nexp_lines,
           "%d data lines = sum over %d sites of selected bands present (%d)%s" %
           (nlines, len(mt), nexp_lines, "" if not cbad else "; bad stations: %s" % cbad[:5]))
    ck.add("C08", "impedance values", "fails if any Re/Im Z in observe.dat differs from conj(Z_EDI)/(10000/(4 pi)) "
           "(EDI mV/km/nT -> ohm, imaginary part negated) by more than the '%.4e' rounding bound",
           not zbad, "%d values, max relative difference %.1e%s" % (total * 8, zmax,
                                                                     "" if not zbad else "; bad: %s" % zbad[:3]))
    ck.add("C09", "error floors", "fails if any SE differs from max(sqrt(VAR_i), floor_i sqrt(|Zxy| |Zyx|)) / "
           "(10000/(4 pi)) beyond the '%.4e' rounding bound, or the Re and Im SE of a component differ",
           not sbad, "%d SE pairs, max relative difference %.1e; floor active in %s of Zxx/Zxy/Zyx/Zyy%s" %
           (total * 4, smax, "/".join("%.0f%%" % (100 * v / max(total, 1)) for v in floored),
            "" if not sbad else "; bad: %s" % sbad[:3]))
    mxy, myx = (float(np.median(phs_xy)), float(np.median(phs_yx))) if phs_xy else (float("nan"),) * 2
    stats["floored"] = "/".join("%.0f %%" % (100 * v / max(total, 1)) for v in floored)
    stats["phase"] = (mxy, myx)
    ck.add("C10", "time convention", "fails unless the median phase of Zxy in observe.dat is in (-90, 0) deg and "
           "that of Zyx in (90, 180) deg, as FEMTIC's exp(-i omega t) convention gives for a 1-D-like earth "
           "(manual.txt:1015; INV_MT_01 Zxy phase -45 deg)", -90 < mxy < 0 and 90 < myx < 180,
           "median phase Zxy %.1f deg, Zyx %.1f deg" % (mxy, myx))

    # C11 mesh-site coordinates
    P = parse_mesh_files(fdir)
    det, ok = [], True
    for what, pts, zs in (
            ("obs_site.dat", [p[0][:2] for p in P["obs_site"]["sites"]], [p[0][2] for p in P["obs_site"]["sites"]]),
            ("observing_site.dat", [p[0] for p in P["observing_site"]["sites"]], None),
            ("resistivity_attr.dat", [p[0][:2] for p in P["resistivity_attr"]["sites"]],
             [p[0][2] for p in P["resistivity_attr"]["sites"]])):
        good, dmax, mapping = match_sites(pts, site_xy, what)
        zok = True
        if good and zs is not None:
            zerr = max(abs(z - mesh_z[m]) for z, m in zip(zs, mapping))
            zok = zerr <= TOL_POS_KM
        ok = ok and good and zok
        det.append("%s %s" % (what, ("%d sites, max %.2f m" % (len(pts), dmax * 1000)) if good else mapping)
                   + ("" if zok else ", z off by %.1f m" % (zerr * 1000)))
    ck.add("C11", "mesh-site coordinates", "fails unless the sites in obs_site.dat, observing_site.dat and "
           "resistivity_attr.dat map one-to-one to the centred site table within 1 m in x y, and the z in "
           "obs_site.dat and resistivity_attr.dat is the mesh-surface z (%s) within 1 m" %
           ("0 km, flat" if c["topo_mode"] == "flat" else "-elev_km"), ok, "; ".join(det))

    # C12 mesh tables round trip
    bad = []

    def cmp(label, got, exp):
        g, x = np.ravel(np.asarray(got, dtype=float)), np.ravel(np.asarray(exp, dtype=float))
        if g.shape != x.shape or not all(rel_close(a, b, TOL_TABLE_REL) for a, b in zip(g, x)):
            bad.append(label)

    cmp("analysis_domain", P["domain"], c["domain"])
    ctl = P["control"]
    cmp("control CENTER", ctl["center"], c["center"])
    cmp("control ROTATION", ctl["rotation"], [c["rotation"]])
    cmp("control NUM_THREADS", ctl["num_threads"], [c["ctl_threads"]])
    if ctl["surf_mesh"] != c["ctl_surf_mesh"]:
        bad.append("control SURF_MESH")
    if (ctl["iter_max"] is None) != (c["ctl_iter_max"] is None) or (
            ctl["iter_max"] is not None and ctl["iter_max"] != c["ctl_iter_max"]):
        bad.append("control ITER_MAX")
    cmp("control ELLIPSOIDS", ctl["ellipsoids"], c["ctl_ellipsoids"])
    cmp("control INTERPOLATE", ctl["interpolate"], c["ctl_interp"])
    if ctl["altitude"][0] != "topography.dat":
        bad.append("control ALTITUDE file")
    cmp("control ALTITUDE limits", [float(v) for v in ctl["altitude"][1:]], c["ctl_alt"])
    if (ctl["sea_depth"] is None) != (c["ctl_sea"] is None):
        bad.append("control SEA_DEPTH presence")
    elif ctl["sea_depth"] is not None:
        cmp("control SEA_DEPTH limits", [float(v) for v in ctl["sea_depth"][1:]], c["ctl_sea"])
    cmp("makeMtr centre", P["mtr"]["center"], c["center"])
    cmp("makeMtr rotation", [P["mtr"]["rotation"]], [c["rotation"]])
    cmp("makeMtr ellipsoids", P["mtr"]["ellipsoids"], c["mtr_ellipsoids"])
    for k, (_, rows) in enumerate(P["obs_site"]["sites"]):
        cmp("obs_site spheres (site row %d)" % (k + 1), rows, c["obs_spheres"])
    for k, (_, rows) in enumerate(P["observing_site"]["sites"]):
        cmp("observing_site circles (site row %d)" % (k + 1), rows, c["observing_circles"])
    ra = P["resistivity_attr"]
    cmp("resistivity_attr regions", ra["regions"], c["regions"])
    cmp("resistivity_attr centre", ra["center"], c["center"])
    cmp("resistivity_attr rotation", [ra["rotation"]], [c["rotation"]])
    cmp("resistivity_attr ellipsoids", ra["ellipsoids"], c["attr_ellipsoids"])
    for k, (_, rows) in enumerate(ra["sites"]):
        cmp("resistivity_attr site circles (site row %d)" % (k + 1), rows, c["attr_sites"])
    cmp("region_seeds", P["seeds"], c["seeds"])
    if len(P["obs_site"]["sites"]) != n_exp or len(P["observing_site"]["sites"]) != n_exp or len(ra["sites"]) != n_exp:
        bad.append("site counts")
    ck.add("C12", "mesh tables", "fails if any number in analysis_domain.dat, control.dat, makeMtr.param, "
           "obs_site.dat, observing_site.dat, resistivity_attr.dat or region_seeds.dat differs from the config "
           "by more than 1e-9 relative (catches '%4.1f'-style truncation), or a site list is not N long",
           not bad, "all tables equal the config" if not bad else "differ: %s" % bad[:8])

    # C13 geometry
    dom = P["domain"]
    xs = [p[0] for p in site_xy.values()]
    ys = [p[1] for p in site_xy.values()]
    geo = []
    if not all(lo < 0 < hi for lo, hi in dom):
        geo.append("domain does not straddle 0")
    if not (dom[0][0] < min(xs) and max(xs) < dom[0][1] and dom[1][0] < min(ys) and max(ys) < dom[1][1]):
        geo.append("a site lies outside the analysis domain")
    cl = P["coast"]
    pts = cl["points"]
    encl = (cl["n"] == 1 and len(pts) == 4 and [p[2] for p in pts] == [0, 0, 0, 1] and
            all(abs(p[0]) > max(abs(v) for v in dom[0]) and abs(p[1]) > max(abs(v) for v in dom[1]) for p in pts))
    if not encl:
        geo.append("coast_line.dat is not one closed all-land boundary outside the domain")
    tp = P["topo"]
    if tp.shape[1] != 3 or not (tp[:, 0].min() <= dom[0][0] and tp[:, 0].max() >= dom[0][1] and
                                tp[:, 1].min() <= dom[1][0] and tp[:, 1].max() >= dom[1][1]):
        geo.append("topography.dat does not cover the analysis domain")
    if c["topo_mode"] == "flat" and np.any(tp[:, 2] != 0.0):
        geo.append("flat topography.dat has non-zero heights")
    zsurf_min = 0.0 if c["topo_mode"] == "flat" else -float(tp[:, 2].max())
    zsurf_max = 0.0 if c["topo_mode"] == "flat" else -float(tp[:, 2].min())
    air_attr = c["regions"][0][0]
    for s in P["seeds"]:
        if int(s[3]) == air_attr and not s[2] < zsurf_min:
            geo.append("air seed at z %g is not above the surface" % s[2])
        if int(s[3]) != air_attr and not s[2] > zsurf_max:
            geo.append("earth seed at z %g is not below the surface" % s[2])
    ck.add("C13", "geometry", "fails if the domain does not straddle 0, a site lies outside it, the coast line "
           "is not one all-land boundary enclosing it, topography.dat does not cover it (or is not 0 in flat "
           "mode), or a seed is on the wrong side of the surface", not geo,
           "sites x %.3f..%.3f, y %.3f..%.3f km inside the domain; coast, topography and seeds consistent" %
           (min(xs), max(xs), min(ys), max(ys)) if not geo else "; ".join(geo))

    # C14 FEMTIC inversion control.dat
    ikw = parse_keyword_file(os.path.join(inv_dir, "control.dat"),
                             {"NUM_THREADS", "MESH_TYPE", "OUTPUT_PARAM_VTK", "OFILE_TYPE", "DISTORTION",
                              "ALPHA_WEIGHT", "INV_METHOD", "BOTTOM_RESISTIVITY", "BOTTOM_ROUGHNING_FACTOR",
                              "OUTPUT_OPTION", "TRADE_OFF_PARAM", "ITERATION", "RETRIAL", "CONVERGE",
                              "STEP_LENGTH", "OWNER_ELEMENT", "END"})
    iv = c["inv"]
    bad = []

    def ik(key, exp, conv=float):
        got = [conv(v) for v in ikw.get(key, [])]
        if len(got) != len(exp) or not all(rel_close(a, b, TOL_TABLE_REL) for a, b in zip(got, exp)):
            bad.append("%s %s != %s" % (key, got, exp))

    ik("MESH_TYPE", [1], int)
    ik("NUM_THREADS", [iv["NUM_THREADS"]], int)
    ik("INV_METHOD", [iv["INV_METHOD"]], int)
    ik("DISTORTION", [iv["DISTORTION"]], int)
    ik("TRADE_OFF_PARAM", iv["TRADE_OFF_PARAM"])
    ik("ITERATION", [0, iv["ITERATION"]], int)
    ik("CONVERGE", [iv["CONVERGE"]])
    ik("ALPHA_WEIGHT", iv["ALPHA_WEIGHT"])
    ik("BOTTOM_RESISTIVITY", [iv["BOTTOM_RESISTIVITY"]])
    if iv["OWNER_ELEMENT"] is None:
        if "OWNER_ELEMENT" in ikw:
            bad.append("OWNER_ELEMENT written although the config has null")
    else:
        ik("OWNER_ELEMENT", [iv["OWNER_ELEMENT"]], int)
    ck.add("C14", "inversion control.dat", "fails if MESH_TYPE is not 1 or NUM_THREADS, INV_METHOD, DISTORTION, "
           "TRADE_OFF_PARAM, ITERATION (0 N), CONVERGE, ALPHA_WEIGHT, BOTTOM_RESISTIVITY or OWNER_ELEMENT "
           "differ from the config", not bad, "all keywords equal the config" if not bad else "; ".join(bad))
    stats.update(obs=obs, mt=mt, P=P, chosen=chosen, common=common, smap=smap)
    return ck, stats


# ============================================================================================ README
def md_table(header, rows):
    out = ["| " + " | ".join(header) + " |", "|" + "|".join("---" for _ in header) + "|"]
    for r in rows:
        out.append("| " + " | ".join(str(v) for v in r) + " |")
    return "\n".join(out)


def g(v):
    return "%.10g" % v


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        h.update(fh.read())
    return h.hexdigest()


def rel(path, root):
    try:
        r = os.path.relpath(path, root)
    except ValueError:
        return path
    return path if r.startswith("..") else r.replace(os.sep, "/")


def data_sections(c, ctx):
    """markdown shared by README.md and inversion/README.md"""
    L = []
    chosen, table, common = ctx["chosen_femticpy"], ctx["freq_table"], ctx["common"]
    n_sites = len(ctx["mt"])
    L.append("## Frequencies\n")
    if c["explicit_hz"]:
        L.append("Rule: the explicit list `frequencies.explicit_hz` of the config.\n")
    else:
        L.append("Rule (config `frequencies`): candidates are the bands present, unmasked, at %s, between "
                 "fmin = %s Hz and fmax = %s Hz. Targets t_k = fmax x 10^(-k/%s), k = 0, 1, ... while t_k >= "
                 "fmin; each target takes the candidate nearest in log10 f (within half a target step), "
                 "duplicates dropped.\n" % ("every site" if c["require_all_sites"] else "any site",
                                            g(c["fmin"]), g(c["fmax"]), g(c["per_decade"])))
    L.append("%d bands are held by every site (the candidates before the fmin/fmax limits); %d are selected, "
             "%.2f per decade over %.2f decades.\n" %
             (len(common), len(chosen), (len(chosen) - 1) / max(math.log10(chosen[0] / chosen[-1]), 1e-9),
              math.log10(chosen[0] / chosen[-1])))
    rows = []
    for k, f in enumerate(chosen):
        rows.append([k + 1, "%.7g" % f, "%.6e" % f, "%.5g" % (1 / f), ctx["freq_nsites"][f]])
    L.append(md_table(["#", "frequency (Hz)", "as written in observe.dat", "period (s)", "sites"], rows))
    if table:
        L.append("\nTarget-by-target choice (|d log10 f| is the distance from the target to the chosen band):\n")
        L.append(md_table(["target (Hz)", "chosen (Hz)", "|d log10 f|"],
                          [["%.5g" % t, "%.7g" % ch if ch else "none", "%.4f" % d] for t, ch, d in table]))
    L.append("\nAll %d candidate bands held by every site (selected ones in bold):\n" % len(common))
    L.append(", ".join(("**%.5g**" if any(rel_close(f, x, 1e-9) for x in chosen) else "%.5g") % f
                       for f in sorted(common, reverse=True)))
    L.append("")
    nlines = sum(len(s["rows"]) for s in ctx["mt"])
    L.append("## Data\n")
    L.append(md_table(["quantity", "value"], [
        ["MT stations (observe.dat block MT)", n_sites],
        ["frequencies per station", "%d to %d" % (min(len(s["rows"]) for s in ctx["mt"]),
                                                  max(len(s["rows"]) for s in ctx["mt"]))],
        ["data lines (station x frequency)", nlines],
        ["real data values (8 per line: Re, Im of Zxx, Zxy, Zyx, Zyy)", nlines * 8],
        ["dummy VTF H-stations (OWNER_ELEMENT -1; 0 frequencies, no data)", len(ctx["obs"].get("VTF", []))],
        ["tipper data", "none (invert_VTF false; the EDIs hold no tipper)"]]))
    L.append("\n### Units, time convention, station layout\n")
    L.append("- Z is converted from the EDI unit mV/km/nT to ohm (V/A) by dividing by 10000/(4 pi) = %.6f "
             "(femticPy DataGen.convert_units); VAR is divided by the square of that factor." % C_OHM)
    L.append("- The EDIs use exp(+i omega t): at the selected bands the median EDI phase is %.1f deg for Zxy "
             "(first quadrant) and %.1f deg for Zyx (third quadrant). FEMTIC requires exp(-i omega t) "
             "(manual.txt:1015: response functions \"in SI units with e-it time dependence\"; the INV_MT_01 "
             "example has Zxy phase -45 deg). femticPy DataGen.conjugate therefore negates Im(Zxx), Im(Zxy), "
             "Im(Zyx) and Im(Zyy), i.e. observe.dat holds conj(Z_EDI) / (10000/(4 pi)). Check C10 confirms "
             "it on the written file: median phase Zxy %.1f deg, Zyx %.1f deg (Zyx taken in [0, 360))." %
             (ctx["edi_stats"]["edi_phase_xy"], ctx["edi_stats"]["edi_phase_yx"], ctx["phase"][0], ctx["phase"][1]))
    oe = c["inv"]["OWNER_ELEMENT"]
    if oe == -1:
        L.append("- OWNER_ELEMENT -1: each MT station line is `i  1000+i  0  x  y`. E comes from the element "
                 "below the surface (owner type 0) and H from dummy VTF station 1000+i (owner type 1, the element "
                 "above the surface, 0 frequencies) at the same x y (FEMTIC manual, \"How to improve response "
                 "functions at high frequencies\"). inversion/control.dat carries `OWNER_ELEMENT -1`.")
    else:
        L.append("- Station lines are `i  i  x  y` (H and E from the same station; FEMTIC OWNER_ELEMENT %s)." %
                 (0 if oe is None else oe))
    L.append("- x = north, y = east (km) from the origin in the Frame section; FEMTIC ignores station z and "
             "places each station on the mesh surface by (x, y). Coordinates are written to 1 m ('%.3f').")
    L.append("\n### Error floors\n")
    ef = c["error_floor_Z"]
    L.append("femticPy DataGen.apply_error_floor, config `data.error_floor_Z` = [%s] for [Zxx, Zxy, Zyx, Zyy]. "
             "For every site and frequency, with Z in ohm:\n" % ", ".join(g(v) for v in ef))
    L.append("    floor_i = error_floor_Z[i] * sqrt(|Zxy| * |Zyx|)")
    L.append("    SE_i    = max( sqrt(VAR_i), floor_i )\n")
    rr = ctx["edi_stats"]["rhoerr_ratio"]
    L.append("SE_i is written as the standard error of both Re(Z_i) and Im(Z_i). The floor is therefore %s of "
             "the geometric mean of the off-diagonal magnitudes for Zxy and Zyx and %s of it for Zxx and Zyy "
             "(not of sqrt(Zxy^2 + Zyx^2), as the comment in the femticPy notebooks says). VAR_i is the EDI "
             "variance of the complex estimate. In these EDIs Geotools' own RHO.ERR equals "
             "2 rho sqrt(VAR)/|Z| (ratio %.4f / %.4f / %.4f at the 1st / 50th / 99th percentile over %d "
             "off-diagonal values; %d further values have RHO or RHO.ERR EMPTY although Z is present, all "
             "at bands outside the selection unless listed under Design warnings), so sqrt(VAR_i) is the error "
             "Geotools attaches to |Z_i|; femticPy uses it unchanged for each part (a strict complex-Gaussian "
             "reading would give sqrt(VAR_i/2) per part, so the unfloored errors are conservative by up to "
             "sqrt(2))." %
             ("%g %%" % (100 * ef[1]) if ef[1] == ef[2] else "%g %% / %g %%" % (100 * ef[1], 100 * ef[2]),
              "%g %%" % (100 * ef[0]) if ef[0] == ef[3] else "%g %% / %g %%" % (100 * ef[0], 100 * ef[3]),
              rr[0], rr[1], rr[2], ctx["edi_stats"]["rhoerr_n"], ctx["edi_stats"]["rho_empty_n"]))
    L.append("\nFraction of (site, frequency) pairs where the floor replaced the EDI error: %s." % ctx["floored"])
    L.append("")
    return L


def site_section(c, ctx):
    L = ["## Sites\n", "Station number = FEMTIC station ID in observe.dat (also inversion/station_map.csv). "
         "x = north_km - %.5f, y = east_km - %.5f; elevation from the site table (not used by the mesh%s).\n" %
         (ctx["origin"][1], ctx["origin"][0], " in flat mode" if c["topo_mode"] == "flat" else "")]
    rows = []
    for st in ctx["mt"]:
        m = ctx["smap"][st["id"]]
        rows.append([st["id"], m["site_id"], m["edi_file"], m["x_north_km"], m["y_east_km"],
                     "%.1f" % (1000 * float(m["elev_km"])), len(st["rows"])])
    L.append(md_table(["station", "site id", "EDI", "x north (km)", "y east (km)", "elev (m)", "freqs"], rows))
    L.append("")
    return L


def control_listing(path):
    with open(path, encoding="utf-8") as fh:
        return ["```text", fh.read().rstrip("\n"), "```"]


def write_readmes(c, ctx, run_dir, final_dir, ck):
    root = c["root"]
    P = ctx["P"]
    now = ctx["now"]
    iv = c["inv"]
    n_d = sum(len(s["rows"]) for s in ctx["mt"]) * 8
    gb = lambda n: n * n * 8 / 1e9
    # ---------------- inversion/README.md
    L = ["# FEMTIC inversion data: %s" % c["name"], "",
         "Generated by `scripts/prep_vulcan.py` on %s from `%s`. Do not edit: change the config and re-run. "
         "The full record (mesh inputs, provenance, self-checks) is `../README.md`." %
         (now, rel(c["config_path"], root)), "",
         "| file | content |", "|---|---|",
         "| observe.dat | impedance data, %d stations%s |" %
         (len(ctx["mt"]), ", plus %d dummy VTF H-stations" % len(ctx["obs"].get("VTF", [])) if ctx["obs"].get("VTF") else ""),
         "| control.dat | FEMTIC inversion control |",
         "| station_map.csv | station number -> site id, EDI file, coordinates |",
         "| mesh.dat, resistivity_block_iter0.dat | not yet: produced by the mesh chain from ../files |", ""]
    L += data_sections(c, ctx)
    L += ["## control.dat\n"] + control_listing(os.path.join(run_dir, "inversion", "control.dat"))
    L += ["", "INV_METHOD %d. Normal-matrix sizes: data space N_data^2 = %d^2 x 8 B = %.1f GB; model space "
          "N_cells^2 x 8 B = %.1f GB at the 21 000-cell estimate (0.8-14 GB over 10 000-42 000). Re-decide when "
          "resistivity_block_iter0.dat gives N_cells: INV_METHOD 0 if N_cells is clearly below %d." %
          (iv["INV_METHOD"], n_d, gb(n_d), gb(21000), n_d), ""]
    L += site_section(c, ctx)
    with open(os.path.join(run_dir, "inversion", "README.md"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(L) + "\n")

    # ---------------- README.md
    L = ["# FEMTIC run inputs: %s" % c["name"], "",
         "Generated by `scripts/prep_vulcan.py` on %s from `%s` (sha256 %s). Do not edit by hand: change the "
         "config and re-run (`python scripts/prep_vulcan.py %s --force`)." %
         (now, rel(c["config_path"], root), ctx["cfg_sha"][:16], rel(c["config_path"], root)), "",
         "**Status:** data and mesh inputs only. The mesh chain has not been run on them, and nothing has been "
         "forward-tested. Before inverting, pass the half-space test of docs/mesh_tetra_pipeline.md section 9.",
         "", "## Contents", "",
         md_table(["path", "what"], [
             ["inversion/observe.dat", "impedance data (femticPy DataGen.write_observe)"],
             ["inversion/control.dat", "FEMTIC inversion control (DataGen.write_inversion_control)"],
             ["inversion/station_map.csv", "FEMTIC station number -> site id, EDI, coordinates"],
             ["inversion/README.md", "the data part of this file"],
             ["files/", "mesh-chain inputs (femticPy MeshGen), region_seeds.dat for scripts/run_mesh_chain.sh"],
             ["config_used.yml", "copy of the config that produced this directory"],
             ["prep.log", "console output, including femticPy's"]]), "",
         "## Provenance", ""]
    L.append(md_table(["input", "detail"], [
        ["config", "`%s`, sha256 %s" % (rel(c["config_path"], root), ctx["cfg_sha"])],
        ["EDIs", "`%s`, %d files (read by femticPy MTtools.read; checked by an independent parser)" %
         (rel(c["edi_dir"], root), len(ctx["edis"]))],
        ["site table", "`%s`, %d sites, sha256 %s" % (rel(c["coords_file"], root), len(ctx["sites"]), ctx["site_sha"])],
        ["femticPy", "`%s` (%s)" % (rel(c["femticpy_src"], root), ctx["femticpy_desc"])],
        ["python", ctx["pyver"]],
        ["command", "`%s`" % ctx["cmd"]]]))
    L += ["", "## Frame", ""]
    xs = [s[2] - ctx["origin"][1] for s in ctx["sites"]]
    ys = [s[1] - ctx["origin"][0] for s in ctx["sites"]]
    L.append(md_table(["item", "value"], [
        ["coordinates", "%s, km; the site table is the only coordinate source (EDI headers unused)" % c["utm"]],
        ["origin", "E %.5f km, N %.5f km (%s)" % (ctx["origin"][0], ctx["origin"][1],
                                                 "site bounding-box centre" if c["origin"] is None else "config")],
        ["axes", "x = north, y = east, z positive down; mesh ROTATION %s deg" % g(c["rotation"])],
        ["site extent", "x %.3f..%.3f km, y %.3f..%.3f km, max radius %.2f km" %
         (min(xs), max(xs), min(ys), max(ys), max(math.hypot(a, b) for a, b in zip(xs, ys)))],
        ["topography", "flat, z = 0 (sites at z = 0 in the mesh files)" if c["topo_mode"] == "flat"
         else "DEM `%s`; site z = -elevation" % rel(c["dem_file"], root)],
        ["analysis domain", "x %s, y %s, z %s km" % tuple("[%s, %s]" % (g(a), g(b)) for a, b in P["domain"])]]))
    L.append("")
    L += data_sections(c, ctx)
    L += ["## Mesh inputs (files/)", "",
          "Tables as written (parsed back from the files). Run the chain with `bash scripts/run_mesh_chain.sh "
          "<copy of files/ on ext4> 5`; it reads region_seeds.dat.", ""]
    ctl = P["control"]
    L.append("### control.dat (makeTetraMesh: surface triangles)\n")
    L.append("CENTER %s; ROTATION %s; NUM_THREADS %s; SURF_MESH %s; ITER_MAX %s; INTERPOLATE radius %s km, %d points, "
             "eps %s km; ALTITUDE %s [%s, %s] km; SEA_DEPTH %s.\n" %
             (" ".join(g(v) for v in ctl["center"]), g(ctl["rotation"][0]), ctl["num_threads"][0],
              "on" if ctl["surf_mesh"] else "off", " ".join(map(str, ctl["iter_max"])) if ctl["iter_max"] else "default",
              g(ctl["interpolate"][0]), ctl["interpolate"][1], g(ctl["interpolate"][2]), ctl["altitude"][0],
              ctl["altitude"][1], ctl["altitude"][2],
              "not written (land only)" if ctl["sea_depth"] is None else " ".join(ctl["sea_depth"])))
    ecols = ["radius x (km)", "max edge (km)", "obl. horizontal", "obl. below centre (earth)", "obl. above centre (air)"]
    L.append(md_table(["#"] + ecols, [[k + 1] + [g(v) for v in r] for k, r in enumerate(ctl["ellipsoids"])]))
    L.append("\n### makeMtr.param (volume tetrahedra)\n")
    L.append("centre %s; rotation %s; sea attributes %d.\n" % (" ".join(g(v) for v in P["mtr"]["center"]),
                                                              g(P["mtr"]["rotation"]), P["mtr"]["n_sea"]))
    L.append(md_table(["#"] + ecols, [[k + 1] + [g(v) for v in r] for k, r in enumerate(P["mtr"]["ellipsoids"])]))
    L.append("\n### observing_site.dat (surface circles, the same at each of the %d sites)\n" %
             len(P["observing_site"]["sites"]))
    L.append(md_table(["#", "radius (km)", "max edge (km)"],
                      [[k + 1] + [g(v) for v in r] for k, r in enumerate(P["observing_site"]["sites"][0][1])]))
    L.append("\n### obs_site.dat (volume spheres, the same at each of the %d sites; site z %s)\n" %
             (len(P["obs_site"]["sites"]), "0 km" if c["topo_mode"] == "flat" else "-elevation"))
    L.append(md_table(["#", "radius (km)", "max edge (km)", "vertical oblateness"],
                      [[k + 1] + [g(v) for v in r] for k, r in enumerate(P["obs_site"]["sites"][0][1])]))
    ra = P["resistivity_attr"]
    L.append("\n### resistivity_attr.dat (TetGen2Femtic: regions and parameter cells)\n")
    L.append(md_table(["attribute", "resistivity (ohm-m)", "ndiv", "fixed", "role"],
                      [[r[0], g(r[1]), r[2], r[3], "air" if k == 0 else "earth (starting model)"]
                       for k, r in enumerate(ra["regions"])]))
    L.append("\ncentre %s; rotation %s.\n" % (" ".join(g(v) for v in ra["center"]), g(ra["rotation"])))
    L.append(md_table(["#", "radius x (km)", "max cell length (km)", "obl. horizontal", "obl. vertical"],
                      [[k + 1] + [g(v) for v in r] for k, r in enumerate(ra["ellipsoids"])]))
    L.append("\nSite spheres (the same at each of the %d sites):\n" % len(ra["sites"]))
    L.append(md_table(["#", "radius (km)", "max cell length (km)"],
                      [[k + 1] + [g(v) for v in r] for k, r in enumerate(ra["sites"][0][1])]))
    L.append("\n### Other files\n")
    tp = P["topo"]
    L.append(md_table(["file", "content"], [
        ["analysis_domain.dat", "; ".join("%s [%s, %s]" % (ax, g(a), g(b)) for ax, (a, b) in zip("xyz", P["domain"]))],
        ["coast_line.dat", "%d closed all-land boundary: %s" % (P["coast"]["n"], " -> ".join(
            "(%s, %s)" % (g(p[0]), g(p[1])) for p in P["coast"]["points"]))],
        ["topography.dat", "%d points, x %s..%s, y %s..%s km, altitude %s..%s km" %
         (len(tp), g(tp[:, 0].min()), g(tp[:, 0].max()), g(tp[:, 1].min()), g(tp[:, 1].max()),
          g(tp[:, 2].min()), g(tp[:, 2].max()))],
        ["bathymetry.dat", "femticPy dummy (-0.01 km); not read: control.dat has no SEA_DEPTH" if ctl["sea_depth"] is None
         else "sea depths"],
        ["region_seeds.dat", "; ".join("(%s, %s, %s) attr %d maxvol %s" % (g(s[0]), g(s[1]), g(s[2]), int(s[3]), g(s[4]))
                                      for s in P["seeds"])]]))
    L += ["", "## FEMTIC inversion control (inversion/control.dat)", ""]
    L += control_listing(os.path.join(run_dir, "inversion", "control.dat"))
    L += ["", "INV_METHOD %d. Normal-matrix sizes: data space N_data^2 = %d^2 x 8 B = %.1f GB; model space "
          "N_cells^2 x 8 B = %.1f GB at the 21 000-cell estimate (0.8-14 GB over 10 000-42 000). Re-decide when "
          "resistivity_block_iter0.dat gives N_cells: INV_METHOD 0 if N_cells is clearly below %d." %
          (iv["INV_METHOD"], n_d, gb(n_d), gb(21000), n_d), ""]
    if ctx["warnings"]:
        L += ["## Design warnings", ""] + ["- " + w for w in ctx["warnings"]] + [""]
    L += ["## Self-checks", "",
          "Each check re-reads the written files and compares them with the config, the site table and an "
          "independent parse of the EDIs (not femticPy's reader). All must pass or the script aborts. Re-run "
          "them with `python scripts/prep_vulcan.py %s --check-only %s`." %
          (rel(c["config_path"], root), rel(final_dir, root)), ""]
    L.append(md_table(["id", "check", "fails if", "result"],
                      [[r["id"], r["name"], r["criterion"], ("PASS: " if r["ok"] else "FAIL: ") + r["detail"]]
                       for r in ck.res]))
    L += ["", "## Next steps", "",
          "1. Mesh: copy `files/` to ext4 (e.g. /home/tara/femtic_wsl/mesh_runs/%s/) and run "
          "`bash scripts/run_mesh_chain.sh <dir> 5`; copy mesh.dat and resistivity_block_iter0.dat back into "
          "`inversion/`." % c["name"],
          "2. Compare the element and cell counts with docs/mesh_tetra_pipeline.md section 8.4 (about 1.2 M "
          "tetrahedra, 21 000 cells, each +- a factor 2) and settle INV_METHOD (above).",
          "3. Half-space forward test (guide section 9) with 3 and 60 ohm-m starting models, with OWNER_ELEMENT -1 "
          "(this directory) and 0 (set `inversion.OWNER_ELEMENT: 0` in a copy of the config and re-run with "
          "another --out).", ""]
    L += site_section(c, ctx)
    with open(os.path.join(run_dir, "README.md"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(L) + "\n")


# ============================================================================================== main
def import_femticpy(src):
    if not os.path.isfile(os.path.join(src, "femticPy.py")):
        fail("femticPy not found in %s (paths.femticpy_src)" % src)
    sys.dont_write_bytecode = True          # keep __pycache__ out of external/femticPy
    os.environ.setdefault("MPLBACKEND", "Agg")
    sys.path.insert(0, src)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", SyntaxWarning)   # upstream '\s' escapes in regex strings
        import femticPy
    import pandas as pd
    if int(pd.__version__.split(".")[0]) >= 3:
        fail("pandas %s: femticPy needs 1.5 <= pandas < 3" % pd.__version__)
    return femticPy


def femticpy_description(src):
    up = os.path.join(os.path.dirname(src), "UPSTREAM.txt")
    series = os.path.join(os.path.dirname(src), "patches", "series")
    desc = []
    if os.path.isfile(up):
        with open(up, encoding="utf-8") as fh:
            m = re.search(r"commit\s*:\s*([0-9a-f]{40})", fh.read())
        if m:
            desc.append("upstream commit %s" % m.group(1))
    if os.path.isfile(series):
        with open(series, encoding="utf-8") as fh:
            pts = [ln.split()[0] for ln in fh if ln.strip() and not ln.startswith("#")]
        desc.append("patches %s" % ", ".join(p.split("-")[0] for p in pts))
    desc.append("femticPy.py sha256 %s" % sha256(os.path.join(src, "femticPy.py"))[:16])
    return "; ".join(desc)


def build(c, run_dir, ctx):
    femticPy = ctx["femticPy"]
    inv_dir, fdir = os.path.join(run_dir, "inversion"), os.path.join(run_dir, "files")
    os.makedirs(inv_dir)
    os.makedirs(fdir)
    sites = ctx["sites"]

    # ---- data: femticPy DataGen
    dg = femticPy.DataGen(c["name"], inv_dir)
    dg.invert_Z, dg.invert_VTF, dg.invert_PT = c["invert_Z"], c["invert_VTF"], False
    dg.error_floor_Z = list(c["error_floor_Z"])
    dg.error_floor_Tz = c["error_floor_VTF"]
    dg.analysis_domain = [list(v) for v in c["domain"]]
    load_coordinates_into_datagen(dg, sites)
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        dg.read_MTdata(c["edi_dir"])
    ctx["femticpy_out"].append(buf.getvalue())
    log("femticPy read %d EDIs: %d with Z, %d with tipper; %d distinct bands" %
        (dg.nRx, dg.nRx_Z, dg.nRx_VTF, dg.nFreq))
    if dg.nRx_VTF:
        fail("the EDIs unexpectedly hold tipper data; this config inverts Z only")
    ids_z = [str(v) for v in dg.ids_Z]
    ids_tab = sorted(s[0] for s in sites)
    if sorted(ids_z) != ids_tab:
        fail("EDI DATAIDs (%d) and site-table ids (%d) differ: only in EDIs %s; only in table %s" %
             (len(ids_z), len(ids_tab), sorted(set(ids_z) - set(ids_tab))[:10],
              sorted(set(ids_tab) - set(ids_z))[:10]))
    if len(ids_z) != c["expected_count"]:
        fail("%d sites found, but sites.expected_count is %d" % (len(ids_z), c["expected_count"]))
    if c["origin"] is None:
        dg.center_data()
    else:
        e0, n0 = c["origin"]
        dg.mt_coords["east"] -= e0
        dg.mt_coords["north"] -= n0
        dg.anchor = [n0, e0]
    ctx["origin"] = (float(dg.anchor[1]), float(dg.anchor[0]))
    ctx["anchor"] = [float(dg.anchor[0]), float(dg.anchor[1])]
    log("origin (%s): E %.5f km, N %.5f km" % ("bbox centre" if c["origin"] is None else "config",
                                              ctx["origin"][0], ctx["origin"][1]))

    # ---- frequencies
    n = dg.nRx_Z
    sets = [set(df["FREQ"].values.tolist()) for df in dg.data_Z]
    nsites = {float(f): sum(float(f) in s for s in sets) for f in dg.freqs}
    cands = [f for f, k in nsites.items() if (k == n or not c["require_all_sites"])]
    chosen, table = select_bands(cands, c["fmax"], c["fmin"], c["per_decade"], c["explicit_hz"])
    freqs = np.asarray(dg.freqs, dtype=float)
    idx = [int(np.where(freqs == f)[0][0]) for f in chosen]
    ctx.update(chosen_femticpy=chosen, freq_table=table, freq_nsites=nsites)
    log("frequencies: %d candidates, %d selected: %s" % (len(cands), len(chosen), ", ".join("%.5g" % f for f in chosen)))

    # ---- observe.dat and inversion control.dat
    oe = c["inv"]["OWNER_ELEMENT"]
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        dg.write_observe(write=True, freq_bandwidth=[min(chosen), max(chosen)], subsampling=idx, plot=False,
                         owner_element=-1 if oe == -1 else None)
        iv = c["inv"]
        dg.write_inversion_control(INV_METHOD=iv["INV_METHOD"], NUM_THREADS=iv["NUM_THREADS"],
                                   DISTORTION=iv["DISTORTION"], TRADE_OFF_PARAM=iv["TRADE_OFF_PARAM"],
                                   ITERATION=iv["ITERATION"], CONVERGE=iv["CONVERGE"],
                                   ALPHA_WEIGHT=iv["ALPHA_WEIGHT"], BOTTOM_RESISTIVITY=iv["BOTTOM_RESISTIVITY"],
                                   OWNER_ELEMENT=oe)
    ctx["femticpy_out"].append(buf.getvalue())

    # ---- station map (femticPy numbers stations rx+1 in ids_Z order)
    tab = {s[0]: s for s in sites}
    mc = dg.mt_coords
    with open(os.path.join(inv_dir, "station_map.csv"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("femtic_station_id,h_station_id,site_id,edi_file,x_north_km,y_east_km,easting_km,northing_km,"
                 "elev_km,n_freq\n")
        for rx, sid in enumerate(ids_z):
            k = int(np.where(mc["id"].astype(str).values == sid)[0][0])
            s = tab[sid]
            fh.write("%d,%d,%s,%s.edi,%.5f,%.5f,%.4f,%.4f,%.5f,%d\n" %
                     (rx + 1, rx + 1001 if oe == -1 else rx + 1, sid, sid, mc["north"][k], mc["east"][k],
                      s[1], s[2], s[3], len(dg.data_Z[rx])))

    # ---- mesh inputs: femticPy MeshGen
    mt_mesh = dg.mt_coords.copy(deep=True)
    if c["topo_mode"] == "flat":
        mt_mesh["z"] = 0.0                     # mesh-surface z of a flat surface (not -elevation)
    mg = femticPy.MeshGen(c["name"], [list(v) for v in c["domain"]], c["center"][:2], mt_mesh, len(mt_mesh), fdir)
    mg.center = list(c["center"])              # MeshGen's own z = -median(z) has the wrong sign
    mg.rotation = c["rotation"]
    mg.ellipsoids_control = [len(c["ctl_ellipsoids"])] + [list(r) for r in c["ctl_ellipsoids"]]
    mg.ellipsoids_mtr = [len(c["mtr_ellipsoids"])] + [list(r) for r in c["mtr_ellipsoids"]]
    mg.ellipsoids_observing_sites = [len(c["observing_circles"])] + [v for r in c["observing_circles"] for v in r]
    mg.ellipsoids_obs_sites = [len(c["obs_spheres"])] + [list(r) for r in c["obs_spheres"]]
    mg.ellipsoids_resistivity_attr = [len(c["attr_ellipsoids"])] + [list(r) for r in c["attr_ellipsoids"]]
    mg.ellipsoids_resistivity_attr_sites = [len(c["attr_sites"])] + [list(r) for r in c["attr_sites"]]
    mg.interpolate_sr, mg.interpolate_npts, mg.interpolate_minval = c["ctl_interp"]
    mg.altitude_file = "topography.dat"
    mg.altitude_min, mg.altitude_max = c["ctl_alt"]
    if c["ctl_sea"] is None:
        mg.sea_depth_file = None
    else:
        mg.sea_depth_file = "bathymetry.dat"
        mg.sea_depth_min, mg.sea_depth_max = c["ctl_sea"]
    mg.num_threads = c["ctl_threads"]
    mg.surf_mesh = c["ctl_surf_mesh"]
    mg.iter_max = c["ctl_iter_max"]
    mg.regions = [list(r) for r in c["regions"]]
    mg.write_inputs()            # analysis_domain, makeMtr.param, obs_site, observing_site, resistivity_attr, control
    mg.write_dummy_coast_line()  # one closed all-land boundary 1 km outside the domain
    if c["topo_mode"] == "flat":
        mg.write_dummy_topo_file()
    else:
        with open(c["dem_file"], encoding="utf-8") as fi, \
                open(os.path.join(fdir, "topography.dat"), "w", encoding="utf-8", newline="\n") as fo:
            for ln in fi:
                if ln.strip():
                    fo.write(" ".join(ln.split()) + "\n")
    mg.write_dummy_bathy_file()
    with open(os.path.join(fdir, "region_seeds.dat"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("# x_km y_km z_km(down) attribute max_volume_km3 -- one seed per closed region "
                 "(scripts/run_mesh_chain.sh)\n")
        for s in c["seeds"]:
            fh.write("%s %s %s %d %s\n" % (g(s[0]), g(s[1]), g(s[2]), int(s[3]), g(s[4])))
    log("wrote %s and %s" % (", ".join(sorted(os.listdir(inv_dir))), ", ".join(sorted(os.listdir(fdir)))))


def design_warnings(c, sites, origin):
    w = []
    r1 = c["ctl_ellipsoids"][0]
    e0, n0 = origin
    for s in sites:
        x, y = s[2] - n0 - c["center"][0], s[1] - e0 - c["center"][1]
        t = math.radians(c["rotation"])
        u, v = x * math.cos(t) + y * math.sin(t), -x * math.sin(t) + y * math.cos(t)
        if (u / r1[0]) ** 2 + (v / (r1[0] * (1 - r1[2]))) ** 2 > 1:
            w.append("site %s lies outside control.dat ellipsoid 1 (radius %s km): the core size field "
                     "does not cover it" % (s[0], g(r1[0])))
    if c["ctl_ellipsoids"][0][1] > c["mtr_ellipsoids"][0][1]:
        w.append("control.dat core edge %s km > makeMtr.param core edge %s km: the frozen surface is coarser "
                 "than the volume target (guide section 4, rule 3)" % (g(c["ctl_ellipsoids"][0][1]),
                                                                     g(c["mtr_ellipsoids"][0][1])))
    if c["observing_circles"][0][1] > c["obs_spheres"][0][1]:
        w.append("observing_site circle 1 edge exceeds obs_site sphere 1 edge (guide section 4, rule 3)")
    return w


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("config", help="YAML config, e.g. config/vulcan_mesh_v1.yml")
    ap.add_argument("--out", help="output run directory (default: paths.run_dir of the config)")
    ap.add_argument("--force", action="store_true", help="replace an existing output directory")
    ap.add_argument("--check-only", metavar="DIR", help="only re-run the self-checks on an existing DIR")
    a = ap.parse_args(argv)
    try:
        c = load_config(a.config)
        ctx = {"now": _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC"), "femticpy_out": [],
               "cmd": "python " + " ".join([rel(os.path.abspath(sys.argv[0]), c["root"])] + sys.argv[1:])}
        sites = read_site_table(c["coords_file"])
        edi_files = sorted(f for f in os.listdir(c["edi_dir"]) if f.endswith(".edi"))
        edis = {f: parse_edi(os.path.join(c["edi_dir"], f)) for f in edi_files}
        if any(e["tipper"] for e in edis.values()) and not c["invert_VTF"]:
            log("note: some EDIs hold tipper blocks; they are not inverted")
        ctx.update(sites=sites, edis=edis)

        if a.check_only:
            run_dir = os.path.abspath(a.check_only)
            ee, nn = [s[1] for s in sites], [s[2] for s in sites]
            origin = (min(ee) + (max(ee) - min(ee)) / 2, min(nn) + (max(nn) - min(nn)) / 2) \
                if c["origin"] is None else tuple(c["origin"])
            ck = run_checks(c, run_dir, sites, edis, origin)[0]
            bad = ck.failed()
            log("%d checks, %d failed" % (len(ck.res), len(bad)))
            return 1 if bad else 0

        run_dir = os.path.abspath(a.out) if a.out else c["run_dir"]
        stage = run_dir.rstrip("/\\") + ".staging"
        if os.path.exists(run_dir) and os.listdir(run_dir) and not a.force:
            fail("%s exists; use --force to replace it (this deletes everything in it, including any mesh "
                 "products copied there)" % run_dir)
        if os.path.exists(stage):
            shutil.rmtree(stage)
        os.makedirs(stage)
        log("prep_vulcan: config %s -> %s" % (c["config_path"], run_dir))
        ctx["femticPy"] = import_femticpy(c["femticpy_src"])
        import pandas as pd
        ctx["pyver"] = "Python %s on %s; numpy %s, pandas %s" % (platform.python_version(), platform.system(),
                                                                 np.__version__, pd.__version__)
        ctx["femticpy_desc"] = femticpy_description(c["femticpy_src"])
        ctx["cfg_sha"] = sha256(c["config_path"])
        ctx["site_sha"] = sha256(c["coords_file"])
        build(c, stage, ctx)
        shutil.copyfile(c["config_path"], os.path.join(stage, "config_used.yml"))
        ctx["warnings"] = design_warnings(c, sites, ctx["origin"])
        for w in ctx["warnings"]:
            log("design warning: " + w)
        ck, stats = run_checks(c, stage, sites, edis, ctx["origin"], ctx["anchor"], ctx["chosen_femticpy"])
        bad = ck.failed()
        if bad:
            with open(os.path.join(stage, "prep.log"), "w", encoding="utf-8", newline="\n") as fh:
                fh.write("\n".join(LOG) + "\n\n----- femticPy output -----\n" + "".join(ctx["femticpy_out"]))
            fail("%d self-check(s) failed: %s. Inspect %s" % (len(bad), "; ".join(
                "%s %s (%s)" % (r["id"], r["name"], r["detail"]) for r in bad), stage))
        ctx.update(stats)
        ctx["edi_stats"] = edi_statistics(edis, ctx["chosen"])
        if ctx["edi_stats"]["rho_empty_selected"]:
            w = ("%d selected (site, band) pairs have RHO/RHO.ERR EMPTY in the EDI although Z is present (the "
                 "processing may have rejected them): %s" % (len(ctx["edi_stats"]["rho_empty_selected"]),
                                                              ", ".join(ctx["edi_stats"]["rho_empty_selected"][:10])))
            ctx["warnings"].append(w)
            log("design warning: " + w)
        write_readmes(c, ctx, stage, run_dir, ck)
        with open(os.path.join(stage, "prep.log"), "w", encoding="utf-8", newline="\n") as fh:
            fh.write("\n".join(LOG) + "\n\n----- femticPy output -----\n" + "".join(ctx["femticpy_out"]))
        # the READMEs and the log are written after the checks: re-check line endings over the final tree
        crs = []
        for dp, _, fns in os.walk(stage):
            for fn in fns:
                with open(os.path.join(dp, fn), "rb") as fh:
                    if b"\r" in fh.read():
                        crs.append(fn)
        if crs:
            fail("CR bytes in %s (inspect %s)" % (crs, stage))
        if os.path.exists(run_dir):
            shutil.rmtree(run_dir)
        os.replace(stage, run_dir)
        log("OK: %d checks passed; wrote %s" % (len(ck.res), run_dir))
        return 0
    except PrepError as e:
        print("PREP FAILED: %s" % e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
