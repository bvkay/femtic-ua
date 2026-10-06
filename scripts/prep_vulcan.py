#!/usr/bin/env python3
"""prep_vulcan.py -- config-driven FEMTIC data and mesh-input preparation for the Vulcan MT survey.

    python scripts/prep_vulcan.py config/vulcan_mesh_v1.yml [--out DIR] [--force [--force-delete-foreign]]
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
    DIR/prep_manifest.sha256       sha256 of every file above ('sha256sum -c' format)

femticPy is the vendored, patched copy named by paths.femticpy_src (external/femticPy; see its
UPSTREAM.txt and patches/series). No notebook is involved. Runs with Python >= 3.9, numpy, pandas < 3,
matplotlib and PyYAML: the WSL conda env 'femticpy' or a Windows Python that has them.

Everything is written to DIR.staging first. The self-checks then re-read the written files and compare
them with an independent parse of the EDIs and the site table. Only if every check passes is DIR.staging
renamed to DIR; any failure aborts with exit status 1, names the check and leaves DIR.staging for
inspection. --check-only re-runs the checks on an existing DIR without writing anything; there C03 and
C05 report N/A (they compare femticPy's in-memory results, which only a full run has).

An existing, non-empty DIR is never replaced without --force, and --force deletes it only when every file in
it is listed in its prep_manifest.sha256 with an unchanged sha256, i.e. prep wrote it and nobody changed it.
Anything else (mesh.dat and resistivity_block_iter0.dat copied in, half-space runs, mesh logs, edits, or a
directory from before the manifest existed) is listed and the run stops, unless --force-delete-foreign is
given as well. Links (symlinks, junctions) are never followed or deleted: a DIR that holds one, or is reached
through one (any link among the directories on its path), is refused whatever the flags. So is a DIR that
is, or contains, the repository root, an input of the run, a .git directory, the home directory or a
filesystem root; these are compared after resolving links, so an alias cannot hide them. A leftover
DIR.staging is removed only if it holds prep's staging marker, which a run drops only after its last abort
point. The safe re-run is a new directory: --out DIR2.

Frame. A data.rotation block (frame_in magnetic|grid|true, rotate_to grid, angle_deg a number or 'auto' = per
site from a CSV column, provenance) rotates every impedance tensor from the sensor frame into the mesh frame
(x = UTM grid north): Z' = R(-alpha) Z R(-alpha)^T and Var' = (M o M) Var with M = kron(R(-alpha), R(-alpha)),
alpha = azimuth of the sensor x axis clockwise from grid north (rotate_Z below). It is applied to femticPy's
DataGen.data_Z after the id checks and before write_observe, i.e. before the unit conversion, the
conjugation and the error floor, so the floor is computed from the rotated tensor. frame_in magnetic or true
without an angle is refused, and 'auto' reads only the column of frame_in (ROT_ANGLE_COLUMN: alpha_deg for
magnetic, alpha_true_deg for true). The angle(s) go into the READMEs, station_map.csv (column rot_deg) and a
'#' header line of prep_manifest.sha256 (sha256sum -c skips it). Without the block nothing is rotated and the
README warns (validation/rotation_2026-09-28/README.md: the Vulcan EDIs are in the geomagnetic frame).
Check C18 reads ZROT, DECLINATION and the HMEAS/EMEAS azimuths of every EDI and fails if a rotation is
recorded there (edi_frame_problems), since prep would then rotate an already rotated tensor.
The sha256 of this script goes into the README provenance and a '#' header line of prep_manifest.sha256.
mesh.reuse_from names a run directory whose gated mesh these inputs reuse; check C17 then verifies that
files/ is byte-identical to the inputs that mesh was built from (its mesh_logs/input_md5.txt). A config
using either key must say 'schema: prep_vulcan/2', which versions of this script from before 2026-09-28
refuse (they would silently ignore data.rotation).
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


# ============================================================================================ rotation
ROT_FRAMES = ("magnetic", "grid", "true")
ROT_KEYS = {"frame_in", "rotate_to", "angle_deg", "angle_file", "angle_column", "provenance"}
ROT_REF_DEG = 7.42        # the Vulcan magnetic -> grid angle; C15 always tests the sign convention at it
# angle_deg 'auto': the only angle_file column accepted for each frame_in. Both hold the azimuth of the sensor x
# axis clockwise from grid north: alpha_deg = D - gamma (magnetic north), alpha_true_deg = -gamma (true north).
# conv_pyproj_deg of alpha_per_site.csv is gamma itself, i.e. the true-north angle with the WRONG sign.
ROT_ANGLE_COLUMN = {"magnetic": "alpha_deg", "true": "alpha_true_deg"}


def rot_matrix(t_deg):
    """R(t) = [[cos t, sin t], [-sin t, cos t]]: its rows are the new x and y axes in the old (x, y) frame when
    the new x axis lies t degrees clockwise (from x = north towards y = east) of the old one"""
    t = math.radians(t_deg)
    return np.array([[math.cos(t), math.sin(t)], [-math.sin(t), math.cos(t)]])


def rotate_Z(Z4, var4, alpha_deg):
    """Rotate impedance tensors into the frame whose x axis lies alpha_deg ANTI-clockwise of theirs, i.e. from
    a sensor frame whose x axis lies alpha_deg clockwise of the target x axis (Vulcan: magnetic north, 7.42 deg
    clockwise of UTM grid north) into the target frame:
        Z' = R(-alpha) Z R(-alpha)^T,    Var' = (M o M) Var,    M = kron(R(-alpha), R(-alpha)).
    Z4: complex (..., 4) in the order xx, xy, yx, yy; var4: real (..., 4), the variances of the complex
    estimates (EDI ZXX.VAR ...), taken as uncorrelated (the EDIs carry no covariances). R is real, so this
    commutes with the unit conversion and the complex conjugation, but not with the error floor, which must
    be computed from the rotated tensor. Pure: returns new arrays (Z4', var4') and changes nothing."""
    M = np.kron(rot_matrix(-alpha_deg), rot_matrix(-alpha_deg))
    return np.asarray(Z4, dtype=complex) @ M.T, np.asarray(var4, dtype=float) @ (M * M).T


def rotation_angles(c, ids):
    """{site id: alpha_deg} for the sites ids, from data.rotation (0 for every site without the block)"""
    r = c["rot"]
    if r is None or r["angle"] != "auto":
        return {i: (0.0 if r is None else r["angle"]) for i in ids}
    import csv
    with open(r["angle_file"], encoding="utf-8", newline="") as fh:
        rows = list(csv.DictReader(fh))
    if not rows or "site_id" not in rows[0] or r["angle_column"] not in rows[0]:
        fail("data.rotation.angle_file %s needs the columns site_id and %s (frame_in %s takes its per-site angle "
             "only from %s: the azimuth of the %s x axis clockwise from grid north); refusing to use another "
             "column" % (r["angle_file"], r["angle_column"], r["frame_in"], r["angle_column"], r["frame_in"]))
    tab = {}
    for row in rows:
        sid = row["site_id"].strip()
        if sid in tab:
            fail("data.rotation.angle_file: site %s is listed twice" % sid)
        try:
            v = float(row[r["angle_column"]])
        except (TypeError, ValueError):
            fail("data.rotation.angle_file: site %s: %r is not a number" % (sid, row[r["angle_column"]]))
        if not (math.isfinite(v) and abs(v) < 45):
            fail("data.rotation.angle_file: site %s: angle %r must be finite and within +-45 deg" % (sid, v))
        tab[sid] = v
    missing = sorted(set(ids) - set(tab))
    if missing:
        fail("data.rotation.angle_file %s has no angle for %d site(s): %s" % (r["angle_file"], len(missing),
                                                                             missing[:10]))
    return {i: tab[i] for i in ids}


def rotation_text(c, ang):
    """one line naming the rotation actually applied (README, prep.log, manifest header)"""
    r = c["rot"]
    if r is None:
        return "data.rotation not set: impedances written in the EDI frame, unrotated"
    v = sorted(set(ang.values()))
    how = ("%s deg (explicit), all %d stations" % (g(v[0]), len(ang)) if r["angle"] != "auto" else
           "per site from %s column %s: %s..%s deg over %d stations" % (rel(r["angle_file"], c["root"]),
                                                                      r["angle_column"], g(v[0]), g(v[-1]), len(ang)))
    return "data.rotation: %s -> %s, alpha %s; Z' = R(-alpha) Z R(-alpha)^T" % (r["frame_in"], r["rotate_to"], how)


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
    if not isinstance(cfg, dict) or cfg.get("schema") not in ("prep_vulcan/1", "prep_vulcan/2"):
        fail("config %s: expected 'schema: prep_vulcan/1' (or prep_vulcan/2 with data.rotation or "
             "mesh.reuse_from)" % path)
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
    # data.rotation (optional): sensor frame -> mesh frame
    rot = cget(cfg, "data", dict).get("rotation")
    if rot is None:
        c["rot"] = None
    else:
        if not isinstance(rot, dict):
            fail("config: data.rotation must be a mapping (frame_in, rotate_to, angle_deg, provenance)")
        unknown = sorted(set(rot) - ROT_KEYS)
        if unknown:
            fail("config: data.rotation has unknown key(s) %s; allowed: %s" % (unknown, sorted(ROT_KEYS)))
        fin, fto, ang = rot.get("frame_in"), rot.get("rotate_to"), rot.get("angle_deg")
        if fin not in ROT_FRAMES:
            fail("config: data.rotation.frame_in must be one of %s, got %r" % (list(ROT_FRAMES), fin))
        if fto != "grid":
            fail("config: data.rotation.rotate_to must be 'grid' (the mesh x axis is UTM grid north), got %r" % fto)
        if ang is None:
            if fin != "grid":
                fail("config: data.rotation.frame_in is %s but angle_deg is not given: refusing to guess the "
                     "rotation. Give the azimuth of the %s x axis clockwise from grid north (a number, e.g. 7.42 "
                     "for Vulcan: validation/rotation_2026-09-28/README.md) or 'auto' with angle_file" % (fin, fin))
            ang = 0.0
        if ang == "auto":
            if fin == "grid":
                fail("config: data.rotation: frame_in grid needs no angle ('auto' given)")
            af = rot.get("angle_file")
            if not af:
                fail("config: data.rotation.angle_deg 'auto' needs angle_file (CSV with site_id and the angle column)")
            af = os.path.normpath(os.path.join(root, str(af)))
            if not os.path.isfile(af):
                fail("config: data.rotation.angle_file %s does not exist" % af)
            # the column must be the one of frame_in: without this rule 'true' + 'auto' used to take the magnetic
            # alpha_deg (about 7.42 deg instead of about 1.02 deg) without a word
            want = ROT_ANGLE_COLUMN[fin]
            col = want if rot.get("angle_column") is None else str(rot.get("angle_column"))
            if col != want:
                fail("config: data.rotation.angle_column %r does not match frame_in %s, whose per-site angle (the "
                     "azimuth of the %s x axis clockwise from grid north) is read only from column %s. alpha_deg is "
                     "D - gamma (magnetic north); alpha_true_deg is -gamma (true north); conv_pyproj_deg is gamma, "
                     "the true-north angle with the opposite sign" % (col, fin, fin, want))
            c["rot"] = {"angle": "auto", "angle_file": af, "angle_column": col}
        else:
            if isinstance(ang, bool) or not isinstance(ang, (int, float)) or not math.isfinite(ang) or abs(ang) >= 45:
                fail("config: data.rotation.angle_deg must be a number within +-45 deg or 'auto', got %r" % (ang,))
            if fin == "grid" and ang != 0:
                fail("config: data.rotation: frame_in grid is already the mesh frame; angle_deg must be 0, got %r" % ang)
            if rot.get("angle_file") is not None or rot.get("angle_column") is not None:
                fail("config: data.rotation.angle_file and angle_column are used only with angle_deg 'auto'")
            c["rot"] = {"angle": float(ang)}
        prov = rot.get("provenance")
        if fin != "grid" and not (isinstance(prov, str) and prov.strip()):
            fail("config: data.rotation.provenance must say where the angle comes from (frame_in %s)" % fin)
        c["rot"].update(frame_in=fin, rotate_to=fto, provenance=" ".join(str(prov or "").split()))
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
    reuse = cget(cfg, "mesh", dict).get("reuse_from")
    c["reuse_from"] = None if reuse is None else os.path.normpath(os.path.join(root, str(reuse)))
    if c["reuse_from"] is not None and not os.path.isdir(os.path.join(c["reuse_from"], "files")):
        fail("config: mesh.reuse_from %s has no files/ directory" % c["reuse_from"])
    # prep_vulcan.py before 2026-09-28 accepts prep_vulcan/1 and silently ignores data.rotation, so a config that
    # rotates must say prep_vulcan/2: an old script then refuses it instead of writing unrotated data
    if (c["rot"] is not None or c["reuse_from"] is not None) and cfg["schema"] != "prep_vulcan/2":
        fail("config: data.rotation and mesh.reuse_from need 'schema: prep_vulcan/2' (older versions of this "
             "script accept prep_vulcan/1 and would silently ignore them)")
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
    if iv["DISTORTION"] != 0:
        fail("config: inversion.DISTORTION %d is not supported: with DISTORTION != 0 FEMTIC reads "
             "distortion_iter<N>.dat at start, distortion_iter0.dat for ITERATION '0 N', and exits if it is "
             "missing (femtic/src AnalysisControl.cpp:282-286, ObservedData.cpp:489-500), but neither this "
             "script nor femticPy writes that file. Set DISTORTION: 0, or add a distortion_iter0.dat writer "
             "(one line per MT station, count = MT stations of observe.dat) first" % iv["DISTORTION"])
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
    """Independent minimal EDI reader (not MTtools): DATAID, NFREQ, FREQ, Z blocks, tipper presence, and the frame
    fields check C18 tests (the ZROT block, the ROT= option of the Z blocks, DECLINATION, HMEAS/EMEAS lines)."""
    blocks, cur, dataid, nfreq, tipper = {}, None, None, None, False
    want = {"FREQ"} | {"Z%s%s" % (c, s) for c in ZC for s in ("R", "I", ".VAR")}
    info = {"RHOXY", "RHOXY.ERR", "RHOYX", "RHOYX.ERR"}          # optional; only for the README statistics
    want_all = want | info | {"ZROT"}                            # ZROT optional; C18
    zrefs, decl, meas = set(), [], []
    with open(path, encoding="ascii", errors="replace") as fh:
        for line in fh:
            s = line.strip()
            if s.startswith(">"):
                name = s[1:].split()[0].upper() if len(s) > 1 else ""
                if name.startswith("TXR") or name.startswith("TYR"):
                    tipper = True
                if name in want and name != "FREQ":              # '>ZXXR ROT=ZROT //62': the rotation block used
                    m = re.search(r"\bROT=(\S+)", s, re.I)
                    zrefs.add(m.group(1).upper() if m else "")
                if name in ("HMEAS", "EMEAS"):
                    kv = {k.upper(): v for k, v in re.findall(r"(\w+)=(\S+)", s[1:])}
                    meas.append((name, kv.get("CHTYPE", "").upper(), kv))
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
            m = re.match(r"DECL(?:INATION)?\s*[:=]\s*(\S+)", s, re.I)    # INFO 'DECLINATION : 0.0000' or 'DECL='
            if m and not cur:
                try:
                    decl.append(float(m.group(1)))
                except ValueError:
                    decl.append(float("nan"))
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
            "file": os.path.basename(path), "rho_err": rho_err,
            "frame": {"zrot": blocks.get("ZROT"), "zrefs": zrefs, "decl": decl, "meas": meas}}


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
        """ok None = N/A: the check cannot be evaluated in this mode (never counted as a pass)"""
        status = "N/A" if ok is None else ("PASS" if ok else "FAIL")
        self.res.append({"id": cid, "name": name, "criterion": criterion, "ok": None if ok is None else bool(ok),
                         "status": status, "detail": detail})
        log("  [%s] %-4s %s: %s" % (status, cid, name, detail))

    def failed(self):
        return [r for r in self.res if r["ok"] is False]

    def count(self, status):
        return sum(r["status"] == status for r in self.res)

    def summary(self):
        return "%d checks: %d PASS, %d FAIL, %d N/A" % (len(self.res), self.count("PASS"), self.count("FAIL"),
                                                        self.count("N/A"))


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


def rotate_Z_check(z, v, alpha_deg):
    """The self-checks' own rotation, written independently of rotate_Z: the four explicit formulas of
    validation/rotation_2026-09-28/README.md (c = cos alpha, s = sin alpha, alpha = azimuth of the sensor x
    axis clockwise from grid north) and the squares of their coefficients for the variances. z, v: sequences
    (xx, xy, yx, yy) of complex / real scalars or arrays."""
    a = math.radians(alpha_deg)
    c, s = math.cos(a), math.sin(a)
    cc, ss, cs = c * c, s * s, c * s
    xx, xy, yx, yy = z
    zr = (cc * xx - cs * (xy + yx) + ss * yy,
          cs * xx + cc * xy - ss * yx - cs * yy,
          cs * xx - ss * xy + cc * yx - cs * yy,
          ss * xx + cs * (xy + yx) + cc * yy)
    vxx, vxy, vyx, vyy = v
    c4, s4, c2s2 = cc * cc, ss * ss, cc * ss
    vr = (c4 * vxx + c2s2 * (vxy + vyx) + s4 * vyy,
          c2s2 * vxx + c4 * vxy + s4 * vyx + c2s2 * vyy,
          c2s2 * vxx + s4 * vxy + c4 * vyx + c2s2 * vyy,
          s4 * vxx + c2s2 * (vxy + vyx) + c4 * vyy)
    return zr, vr


def rotation_selftest(angles):
    """C15: T1-T3 of validation/rotation_2026-09-28/rot_test.py run on rotate_Z itself, at ROT_REF_DEG and at the
    smallest and largest configured angle. Returns (ok, detail)."""
    zte, ztm = 1.3 - 0.9j, -0.4 + 0.25j
    zmag = np.array([0, zte, ztm, 0], dtype=complex)            # 2-D earth, strike along the sensor x axis
    test = sorted({ROT_REF_DEG, min(angles), max(angles)})

    def truth(a):                                               # built in the grid frame: strike at azimuth +a
        r = math.radians(a)
        s, n = np.array([math.cos(r), math.sin(r)]), np.array([-math.sin(r), math.cos(r)])
        return (zte * np.outer(s, n) + ztm * np.outer(n, s)).ravel()

    t1 = max(float(np.abs(rotate_Z(zmag, np.zeros(4), a)[0] - truth(a)).max()) for a in test)
    wrong = float(np.abs(rotate_Z(zmag, np.zeros(4), -ROT_REF_DEG)[0] - truth(ROT_REF_DEG)).max())
    phis = np.arange(-45.0, 45.0, 0.005)
    co, si = np.cos(np.radians(phis)), np.sin(np.radians(phis))
    t2 = 0.0
    for a in test:        # T2: strike of rotate_Z's output, found by turning a frame phi clockwise from grid north
        zg = rotate_Z(zmag, np.zeros(4), a)[0]                  # diagonal of R(phi) Zg R(phi)^T, written out:
        dxx = co * co * zg[0] + co * si * (zg[1] + zg[2]) + si * si * zg[3]
        dyy = si * si * zg[0] - co * si * (zg[1] + zg[2]) + co * co * zg[3]
        t2 = max(t2, abs(float(phis[int(np.argmin(np.abs(dxx) ** 2 + np.abs(dyy) ** 2))]) - a))
    V = np.array([0.02, 0.5, 0.8, 0.03])                       # T3: variances, deterministic and Monte Carlo
    vr = rotate_Z(np.zeros(4), V, ROT_REF_DEG)[1]
    t3a = float(np.max(np.abs(vr - np.array(rotate_Z_check((0, 0, 0, 0), tuple(V), ROT_REF_DEG)[1])) / vr))
    rng = np.random.default_rng(1)
    dz = (rng.standard_normal((200000, 4)) + 1j * rng.standard_normal((200000, 4))) * np.sqrt(V / 2)
    emp = np.array([np.mean(np.abs(w) ** 2) for w in rotate_Z_check(tuple(dz.T), (0, 0, 0, 0), ROT_REF_DEG)[0]])
    t3b = float(np.max(np.abs(emp / vr - 1)))
    moved = float(np.max(np.abs(vr / V - 1)))
    ok = t1 <= 1e-12 and wrong > 0.1 and t2 <= 0.01 and t3a <= 1e-12 and t3b <= 0.02 and moved > 0.1
    return ok, ("T1 max|rotate_Z(Z_2D) - Z_grid| %.1e at %s deg (the opposite sign gives %.2f); T2 strike "
                "recovered within %.3f deg; T3 variances: %.1e from the explicit formulas, %.1f %% from a "
                "200k-sample Monte Carlo (rotation changes them by up to %.0f %%)" %
                (t1, "/".join(g(a) for a in test), wrong, t2, t3a, 100 * t3b, 100 * moved))


def isotropy_selftest(angles):
    """C16: a 1-D tensor (Zxx = Zyy = 0, Zyx = -Zxy) and equal variances are unchanged by rotate_Z at any angle.
    Returns (ok, detail)."""
    z1, v1 = np.array([0, 1.3 - 0.9j, -(1.3 - 0.9j), 0]), np.full(4, 0.37)
    test = sorted({ROT_REF_DEG, min(angles), max(angles), 30.0, -60.0, 90.0})
    dz = max(float(np.abs(rotate_Z(z1, v1, a)[0] - z1).max()) for a in test) / abs(z1[1])
    dv = max(float(np.abs(rotate_Z(z1, v1, a)[1] - v1).max()) for a in test) / v1[0]
    return dz <= 1e-12 and dv <= 1e-12, ("max relative change %.1e in Z, %.1e in the variances, at %s deg" %
                                         (dz, dv, "/".join(g(a) for a in test)))


FRAME_AXIS = {"HX": 0.0, "EX": 0.0, "HY": 90.0, "EY": 90.0}   # C18; HZ and other channels have no azimuth to test
TOL_FRAME_DEG = 1e-6        # ZROT, DECLINATION and AZM are plain numbers in the EDI (0.000000E+00, 0.0000, 90.0)
TOL_DIPOLE_DEG = 0.5        # direction of an EMEAS dipole X,Y -> X2,Y2 (the EDI gives them to 0.1 m)


def edi_frame_problems(e, frame_in):
    """C18 for one EDI (parse_edi output): what contradicts the frame data.rotation.frame_in names (None = no
    data.rotation). Returns (problems, counts).
    Every frame: the tensor must be the one the sensors measured, i.e. no rotation may be recorded in the file:
    each Z block's ROT= option, if any, names ZROT; the ZROT block, if any, is 0 at every band; every HX and EX
    azimuth is 0 and every HY and EY azimuth 90 deg (the AZM of HMEAS/EMEAS lines where given; an EMEAS without
    AZM by the direction X,Y -> X2,Y2 of its dipole, polarity ignored, when that has a length). prep rotates
    such a tensor by the configured angle as if it were in the sensor frame, so a ZROT of 7.42 would be
    rotated a second time. Which north the sensor x axis pointed to is what frame_in states; the EDI cannot
    record it. DECLINATION: frame_in magnetic or grid, or no data.rotation (whose README states the Vulcan EDIs
    are magnetic with DECLINATION 0 and ZROT 0): present and 0, since a non-zero value can mean a declination
    correction was applied. frame_in true: information only (a true-north layout does not need it)."""
    fr, bad = e["frame"], []
    n = {"zrot": 0, "decl": 0, "azm": 0, "dipole": 0, "no_orient": 0}
    other = sorted(r or "(none)" for r in fr["zrefs"] if r not in ("", "ZROT"))
    if other:
        bad.append("Z blocks name ROT=%s, not ZROT" % "/".join(other))
    if "ZROT" in fr["zrefs"] and fr["zrot"] is None:
        bad.append("Z blocks name ROT=ZROT but there is no >ZROT block")
    if fr["zrot"] is not None:
        n["zrot"] = 1
        nz = [v for v in fr["zrot"] if not abs(v) <= TOL_FRAME_DEG]
        if nz:
            bad.append("ZROT %s at %d of %d bands" % (g(nz[0]), len(nz), len(fr["zrot"])))
    n["decl"] = int(bool(fr["decl"]))
    if frame_in != "true":
        if not fr["decl"]:
            bad.append("no DECLINATION")
        elif any(not abs(v) <= TOL_FRAME_DEG for v in fr["decl"]):
            bad.append("DECLINATION %s" % "/".join(g(v) for v in fr["decl"]))
    for kind, ch, kv in fr["meas"]:
        want = FRAME_AXIS.get(ch)
        if want is None:
            continue
        if "AZM" in kv:
            n["azm"] += 1
            try:
                a = float(kv["AZM"])
            except ValueError:
                a = float("nan")
            if not abs((a - want + 180.0) % 360.0 - 180.0) <= TOL_FRAME_DEG:
                bad.append("%s %s AZM %s (must be %s)" % (kind, ch, kv["AZM"], g(want)))
        elif kind == "EMEAS":
            try:
                dx, dy = float(kv["X2"]) - float(kv["X"]), float(kv["Y2"]) - float(kv["Y"])
            except (KeyError, ValueError):
                dx = dy = 0.0
            if dx == 0 and dy == 0:
                n["no_orient"] += 1
                continue
            n["dipole"] += 1
            a = math.degrees(math.atan2(dy, dx))              # EDI X north, Y east: clockwise from north
            if not abs((a - want + 90.0) % 180.0 - 90.0) <= TOL_DIPOLE_DEG:
                bad.append("EMEAS %s dipole azimuth %.2f deg (must be %s or %s)" % (ch, a, g(want), g(want + 180)))
    return bad, n


def frame_check(c, edis):
    """C18 over every EDI: (ok, detail)"""
    fin = c["rot"]["frame_in"] if c["rot"] is not None else None
    probs, tot = [], {"zrot": 0, "decl": 0, "azm": 0, "dipole": 0, "no_orient": 0}
    for k in sorted(edis):
        b, n = edi_frame_problems(edis[k], fin)
        for key in tot:
            tot[key] += n[key]
        if b:
            probs.append("%s: %s" % (edis[k]["dataid"] or k, "; ".join(b)))
    rule = ("frame_in %s" % fin) if fin else "no data.rotation (EDI frame written as is; README: magnetic)"
    det = ("%d EDIs, rule of %s: %d hold a ZROT block, %d a DECLINATION%s; %d HX/HY/EX/EY azimuths (AZM) and %d "
           "EMEAS dipole directions tested; %d EMEAS without AZM and of zero length (orientation not recorded)" %
           (len(edis), rule, tot["zrot"], tot["decl"], " (not tested: frame_in true)" if fin == "true" else "",
            tot["azm"], tot["dipole"], tot["no_orient"]))
    if probs:
        det = "%d of %d EDIs contradict it: %s; %s" % (len(probs), len(edis), " | ".join(probs[:5]), det)
    return not probs, det


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

    # C03 origin: femticPy's centring (DataGen.center_data) against an independent bbox centre. Only a full
    # run has femticPy's origin; under --check-only the origin passed in is this same bbox formula (a
    # tautology), and with an explicit sites.origin prep subtracts the configured value itself. In both cases
    # the written coordinates are still tested, by C04 and C11, against the site table minus that origin.
    crit03 = ("fails if femticPy's origin (DataGen.center_data) differs by more than 1e-9 km from the site "
              "bounding-box centre recomputed here; N/A under --check-only and with an explicit sites.origin")
    if c["origin"] is not None:
        ck.add("C03", "origin", crit03, None, "N/A: sites.origin is explicit (E %.5f N %.5f km), so no femticPy "
               "centring to compare; C04 and C11 test the written coordinates against it" % (e0, n0))
    elif femticpy_anchor is None:
        ck.add("C03", "origin", crit03, None, "N/A under --check-only: femticPy's origin exists only in a full "
               "run; the bbox centre E %.5f N %.5f km used here is what C04 and C11 test the written "
               "coordinates against" % (e0, n0))
    else:
        ee = [s[1] for s in sites]
        nn = [s[2] for s in sites]
        indep = (min(ee) + (max(ee) - min(ee)) / 2, min(nn) + (max(nn) - min(nn)) / 2)
        ok = (abs(indep[0] - e0) < 1e-9 and abs(indep[1] - n0) < 1e-9 and
              abs(femticpy_anchor[1] - indep[0]) < 1e-9 and abs(femticpy_anchor[0] - indep[1]) < 1e-9)
        ck.add("C03", "origin", crit03, ok, "femticPy origin E %.5f N %.5f km; bbox centre E %.5f N %.5f km" %
               (femticpy_anchor[1], femticpy_anchor[0], indep[0], indep[1]))

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
    det = "%d bands selected from %d candidates" % (len(chosen), len(common))
    if femticpy_chosen is None:
        ok = None
        det = ("N/A under --check-only: femticPy's frequency table exists only in a full run; the independent "
               "selection (%s) is what C06 and C07 test observe.dat against" % det)
    else:
        ok = len(chosen) == len(femticpy_chosen) and all(rel_close(a, b, TOL_FREQ_REL)
                                                         for a, b in zip(chosen, femticpy_chosen))
        det += "; femticPy path chose the same list: %s" % ok
    ck.add("C05", "frequency selection", "fails if the bands selected from femticPy's frequency table differ "
           "from those selected by the same rule from an independent parse of the EDIs; N/A under "
           "--check-only", ok, det)

    # C06-C09 per-station data
    fbad, cbad, zbad, sbad, nlines, nexp_lines, ncmp = [], [], [], [], 0, 0, 0
    zmax, smax, fmax_rel = 0.0, 0.0, 0.0
    ef = c["error_floor_Z"]
    ang = rotation_angles(c, sorted(by_id))           # data.rotation; 0 for every site without the block
    angs = sorted(set(ang.values()))
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
            ncmp += 1
            if rel > TOL_FREQ_REL or not rel_close(fx, e["freq"][j], TOL_FREQ_REL) or not e["ok"][j]:
                fbad.append("%s %.6g Hz" % (sid, f))
                continue
            zo = {cc: complex(r[1 + 2 * k], r[2 + 2 * k]) for k, cc in enumerate(ZC)}
            se = {cc: (r[9 + 2 * k], r[10 + 2 * k]) for k, cc in enumerate(ZC)}
            zrot, vrot = rotate_Z_check([e["z"][cc][j] for cc in ZC], [e["var"][cc][j] for cc in ZC], ang[sid])
            gm = math.sqrt(abs(zrot[1]) * abs(zrot[2]))
            total += 1
            for k, cc in enumerate(ZC):
                zexp = np.conj(zrot[k]) / C_OHM
                for w, v in ((zo[cc].real, zexp.real), (zo[cc].imag, zexp.imag)):
                    d = abs(w - v)
                    zmax = max(zmax, d / max(abs(v), 1e-300))
                    if d > e4_bound(v, w):
                        zbad.append("%s %.6g Hz Z%s %.5g vs %.5g" % (sid, f, cc, w, v))
                sd = math.sqrt(vrot[k])
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
    # the angle recorded in station_map.csv (column rot_deg, written only with data.rotation) must be the one
    # C08 and C09 applied; without the column every angle must be 0
    for s in mt:
        m = smap.get(s["id"], {})
        want, got = ang.get(m.get("site_id"), 0.0), m.get("rot_deg")
        try:
            okr = (want == 0.0) if got is None else abs(float(got) - want) <= 1e-9
        except ValueError:
            okr = False
        if not okr:
            zbad.append("station %d: station_map.csv rot_deg %s, applied %s deg" % (s["id"], got, g(want)))
    rot_det = "alpha %s deg" % (g(angs[0]) if len(angs) == 1 else "%s..%s" % (g(angs[0]), g(angs[-1])))
    # C06, C08 and C09 skip every station that fails C07; if that leaves nothing to compare they are N/A
    skipped = "" if not cbad else "; %d of %d station(s) skipped: they failed C07" % (len(cbad), len(mt))
    nothing = "nothing compared: %d of %d station(s) failed C07" % (len(cbad), len(mt))
    nothing_z = nothing + ("" if not fbad else ", and every other data line failed C06")
    ck.add("C06", "frequencies", "fails if any observe.dat frequency differs by more than 1e-6 relative from "
           "the same band in that site's EDI, or is not one of the selected bands; N/A if no station passed C07",
           (not fbad) if ncmp else None,
           "max relative difference %.2e over %d of %d data lines%s%s" % (
               fmax_rel, ncmp, nlines, skipped, "" if not fbad else "; bad: %s" % fbad[:5])
           if ncmp else nothing)
    ck.add("C07", "data line count", "fails if a station's number of data lines differs from the number of "
           "selected bands present (unmasked) in its EDI, or the total differs from their sum over sites",
           not cbad and nlines == nexp_lines,
           "%d data lines = sum over %d sites of selected bands present (%d)%s" %
           (nlines, len(mt), nexp_lines, "" if not cbad else "; bad stations: %s" % cbad[:5]))
    ck.add("C08", "impedance values", "fails if any Re/Im Z in observe.dat differs from conj(Z_EDI rotated by "
           "data.rotation's alpha)/(10000/(4 pi)) (the rotation written out as its four explicit formulas, "
           "independently of rotate_Z; EDI mV/km/nT -> ohm, imaginary part negated) by more than the '%.4e' "
           "rounding bound, or station_map.csv's rot_deg is not the alpha applied; N/A if no data line passed "
           "C06 and C07", (not zbad) if total else None,
           "%d values, %s, max relative difference %.1e%s%s" % (total * 8, rot_det, zmax, skipped,
                                                                "" if not zbad else "; bad: %s" % zbad[:3])
           if total else nothing_z)
    ck.add("C09", "error floors", "fails if any SE differs from max(sqrt(VAR'_i), floor_i sqrt(|Z'xy| |Z'yx|)) / "
           "(10000/(4 pi)) beyond the '%.4e' rounding bound, or the Re and Im SE of a component differ (VAR' and "
           "Z' rotated by the explicit formulas as in C08); N/A if no data line passed C06 and C07",
           (not sbad) if total else None,
           "%d SE pairs, %s, max relative difference %.1e; floor active in %s of Zxx/Zxy/Zyx/Zyy%s%s" %
           (total * 4, rot_det, smax, "/".join("%.0f%%" % (100 * v / max(total, 1)) for v in floored), skipped,
            "" if not sbad else "; bad: %s" % sbad[:3]) if total else nothing_z)
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

    # C15-C16 rotate_Z on synthetic tensors (every run, whatever the angle: the sign convention is always tested)
    ok, det = rotation_selftest(angs)
    ck.add("C15", "rotation sanity", "fails if rotate_Z, turning a 2-D tensor with strike along the sensor x axis "
           "by alpha, misses the tensor built directly in the grid frame with strike at azimuth +alpha by more than "
           "1e-12 (T1; the opposite sign must miss by more than 0.1), the strike recovered from its output is off "
           "by more than 0.01 deg (T2), or its variances differ from the explicit formulas by more than 1e-12 "
           "relative or from a Monte Carlo by more than 2 %% (T3); at %s deg and the configured angle(s)" %
           g(ROT_REF_DEG), ok, det)
    ok, det = isotropy_selftest(angs)
    ck.add("C16", "isotropic invariance", "fails if rotate_Z changes a 1-D tensor (Zxx = Zyy = 0, Zyx = -Zxy) or "
           "equal variances by more than 1e-12 relative at any of the test angles", ok, det)

    # C17 mesh reuse: these mesh inputs are exactly the ones the reused mesh was built from
    crit17 = ("fails unless every files/* is byte-identical to mesh.reuse_from's files/ (same names), every file in "
              "its mesh_logs/input_md5.txt (what the mesh chain read) has that md5 here, and its "
              "mesh_logs/products.md5 names mesh.dat and resistivity_block_iter0.dat; N/A without mesh.reuse_from")
    ru = c["reuse_from"]
    if ru is None:
        ck.add("C17", "mesh reuse", crit17, None, "N/A: mesh.reuse_from is not set, so these inputs still have to be "
               "meshed")
    else:
        md5 = lambda p: hashlib.md5(open(p, "rb").read()).hexdigest()
        mine, theirs = sorted(os.listdir(fdir)), sorted(os.listdir(os.path.join(ru, "files")))
        diff = sorted(set(mine) ^ set(theirs)) + [n for n in mine if n in theirs and
                                                   sha256(os.path.join(fdir, n)) != sha256(os.path.join(ru, "files", n))]
        rec, prod = os.path.join(ru, "mesh_logs", "input_md5.txt"), os.path.join(ru, "mesh_logs", "products.md5")
        used = [ln.split() for ln in open(rec, encoding="utf-8")] if os.path.isfile(rec) else []
        bad_in = [p[1] for p in used if len(p) != 2 or not os.path.isfile(os.path.join(fdir, p[1]))
                  or md5(os.path.join(fdir, p[1])) != p[0]]
        names = {ln.split()[-1] for ln in open(prod, encoding="utf-8") if ln.split()} if os.path.isfile(prod) else set()
        okp = {"mesh.dat", "resistivity_block_iter0.dat"} <= names
        ck.add("C17", "mesh reuse", crit17, not diff and used and not bad_in and okp,
               "%s: %d of %d files/* identical%s; input_md5.txt %s; products.md5 names mesh.dat and "
               "resistivity_block_iter0.dat: %s" %
               (os.path.relpath(ru, c["root"]).replace(os.sep, "/"), len(mine) - len(diff), len(set(mine) | set(theirs)),
                "" if not diff else " (differ: %s)" % diff[:5],
                ("%d of %d md5 match" % (len(used) - len(bad_in), len(used))) if used else "missing", okp))

    # C18 EDI frame: nothing recorded in the EDIs has rotated the tensors away from the frame frame_in names
    ok, det = frame_check(c, edis)
    ck.add("C18", "EDI frame", "fails if any EDI records a rotation of its tensor (a Z block whose ROT= names "
           "anything but ZROT, a non-zero ZROT, an HX/EX azimuth other than 0 or an HY/EY azimuth other than 90 deg "
           "in HMEAS/EMEAS AZM or an EMEAS dipole's direction) or, unless data.rotation.frame_in is true, a "
           "DECLINATION that is missing or non-zero: prep would rotate such a tensor as if it were in the sensor "
           "frame", ok, det)
    stats.update(obs=obs, mt=mt, P=P, chosen=chosen, common=common, smap=smap, rot_deg=ang)
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
    L.append("\n### Frame rotation (config `data.rotation`)\n")
    r = c["rot"]
    L.append("- " + rotation_text(c, ctx["rot_deg"]) + ".")
    if r is None:
        L.append("- The Vulcan EDIs are in the geomagnetic frame (DECLINATION 0, ZROT 0; decision D2 of "
                 "2026-09-28), whose x axis lies about 7.42 deg clockwise of the mesh x axis (UTM grid north), so "
                 "this observe.dat is NOT in the mesh frame. Add a data.rotation block "
                 "(validation/rotation_2026-09-28/README.md) before inverting it.")
    else:
        L.append("- Sensor frame: %s. Provenance: %s" % (r["frame_in"], r["provenance"] or "(none given)"))
        L.append("- alpha is the azimuth of the sensor x axis clockwise from UTM grid north, the mesh x axis. "
                 "Each EDI tensor, still in mV/km/nT, is rotated into the mesh frame before femticPy converts units, "
                 "conjugates and applies the error floor: Z' = R(-alpha) Z R(-alpha)^T with R(t) = [[cos t, sin t], "
                 "[-sin t, cos t]], and Var' = (M o M) Var with M = kron(R(-alpha), R(-alpha)) (the EDI components "
                 "are taken as uncorrelated). The floor below uses the rotated |Z'xy| and |Z'yx|. Column rot_deg of "
                 "station_map.csv holds each station's alpha. Checks C08 and C09 recompute the rotation from its "
                 "explicit formulas; C15 and C16 test rotate_Z on synthetic tensors "
                 "(validation/rotation_2026-09-28/README.md). C18 confirms that no EDI records a rotation of its own "
                 "(ZROT 0, HX/HY azimuths 0/90%s), so no tensor is rotated twice." %
                 ("" if r["frame_in"] == "true" else ", DECLINATION 0"))
    L.append("\n### Units, time convention, station layout\n")
    L.append("- Z is converted from the EDI unit mV/km/nT to ohm (V/A) by dividing by 10000/(4 pi) = %.6f "
             "(femticPy DataGen.convert_units); VAR is divided by the square of that factor." % C_OHM)
    L.append("- The EDIs use exp(+i omega t): at the selected bands the median EDI phase is %.1f deg for Zxy "
             "(first quadrant) and %.1f deg for Zyx (third quadrant). FEMTIC requires exp(-i omega t) "
             "(manual.txt:1015: response functions \"in SI units with e-it time dependence\"; the INV_MT_01 "
             "example has Zxy phase -45 deg). femticPy DataGen.conjugate therefore negates Im(Zxx), Im(Zxy), "
             "Im(Zyx) and Im(Zyy), i.e. observe.dat holds conj(Z_EDI) / (10000/(4 pi))%s. Check C10 confirms "
             "it on the written file: median phase Zxy %.1f deg, Zyx %.1f deg (Zyx taken in [0, 360))." %
             (ctx["edi_stats"]["edi_phase_xy"], ctx["edi_stats"]["edi_phase_yx"],
              "" if c["rot"] is None else ", with Z_EDI first rotated as above", ctx["phase"][0], ctx["phase"][1]))
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
    ru = rel(c["reuse_from"], root) if c["reuse_from"] else None
    L = ["# FEMTIC inversion data: %s" % c["name"], "",
         "Generated by `%s` (sha256 %s) on %s from `%s`. Do not edit: change the config and re-run. "
         "The full record (mesh inputs, provenance, self-checks) is `../README.md`." %
         (ctx["script_rel"], ctx["script_sha"], now, rel(c["config_path"], root)), "",
         "| file | content |", "|---|---|",
         "| observe.dat | impedance data, %d stations%s |" %
         (len(ctx["mt"]), ", plus %d dummy VTF H-stations" % len(ctx["obs"].get("VTF", [])) if ctx["obs"].get("VTF") else ""),
         "| control.dat | FEMTIC inversion control |",
         "| station_map.csv | station number -> site id, EDI file, coordinates |",
         "| mesh.dat, resistivity_block_iter0.dat | not yet: produced by the mesh chain from ../files |" if not ru else
         "| mesh.dat, resistivity_block_iter0.dat | not in this directory: this run reuses the existing mesh of `%s` "
         "(../files is byte-identical to its inputs, check C17). Copy both files from the main checkout's `%s/inversion/` "
         "(on Phoenix: hpc/phoenix_plan/RUNBOOK.md S4). Do not re-mesh. |" % (ru, ru), ""]
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
         "config and write a new directory (`python scripts/prep_vulcan.py %s --out <new dir>`). `--force` "
         "replaces this directory only while every file in it is listed, unchanged, in prep_manifest.sha256; "
         "once mesh products, half-space runs or edits are in it, it refuses and lists them." %
         (now, rel(c["config_path"], root), ctx["cfg_sha"][:16], rel(c["config_path"], root)), "",
         "**Status:** data and mesh inputs only. The mesh chain has not been run on them, and nothing has been "
         "forward-tested. Before inverting, pass the half-space test of docs/mesh_tetra_pipeline.md section 9."
         if not c["reuse_from"] else
         "**Status:** data inputs for an existing mesh. files/ is byte-identical to the inputs from which `%s` was "
         "meshed (check C17), so that mesh is this run's mesh: mesh.dat and resistivity_block_iter0.dat, md5 in "
         "`%s/mesh_logs/products.md5` (the files are gitignored, in the main checkout's `%s/inversion/`). Do not "
         "re-mesh. The half-space gate tests the mesh, and a uniform half-space is unchanged by a frame rotation, "
         "so the gate result of `%s` applies (validation/mesh_2026-09-25/halfspace_accuracy.md)." %
         ((rel(c["reuse_from"], root),) * 4),
         "", "## Contents", "",
         md_table(["path", "what"], [
             ["inversion/observe.dat", "impedance data (femticPy DataGen.write_observe)"],
             ["inversion/control.dat", "FEMTIC inversion control (DataGen.write_inversion_control)"],
             ["inversion/station_map.csv", "FEMTIC station number -> site id, EDI, coordinates"],
             ["inversion/README.md", "the data part of this file"],
             ["files/", "mesh-chain inputs (femticPy MeshGen), region_seeds.dat for scripts/run_mesh_chain.sh"
              if not c["reuse_from"] else "mesh-chain inputs (femticPy MeshGen), byte-identical to the inputs of the "
              "reused mesh `%s` (check C17); a record, not to be meshed again" % rel(c["reuse_from"], root)],
             ["config_used.yml", "copy of the config that produced this directory"],
             ["prep.log", "console output, including femticPy's"],
             [MANIFEST, "sha256 of every file above (`sha256sum -c %s`); `--force` deletes only these, "
              "unchanged" % MANIFEST]]), "",
         "## Provenance", ""]
    L.append(md_table(["input", "detail"], [
        ["script", "`%s`, sha256 %s (the code that wrote and checked this directory)" % (ctx["script_rel"],
                                                                                          ctx["script_sha"])],
        ["config", "`%s`, sha256 %s" % (rel(c["config_path"], root), ctx["cfg_sha"])],
        ["EDIs", "`%s`, %d files (read by femticPy MTtools.read; checked by an independent parser)" %
         (rel(c["edi_dir"], root), len(ctx["edis"]))],
        ["site table", "`%s`, %d sites, sha256 %s" % (rel(c["coords_file"], root), len(ctx["sites"]), ctx["site_sha"])],
        ["frame rotation", rotation_text(c, ctx["rot_deg"]) + (
            "; angle file sha256 %s" % sha256(c["rot"]["angle_file"]) if c["rot"] and c["rot"]["angle"] == "auto"
            else "")],
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
          "<copy of files/ on ext4> 5`; it reads region_seeds.dat." if not c["reuse_from"] else
          "Tables as written (parsed back from the files). They are byte-identical to `%s/files` (check C17): "
          "do not mesh them again." % rel(c["reuse_from"], root), ""]
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
          "independent parse of the EDIs (not femticPy's reader). Any FAIL aborts the script; N/A marks a check "
          "that cannot be evaluated in this mode and is never counted as a pass. Re-run them with "
          "`python scripts/prep_vulcan.py %s --check-only %s` (C03 and C05 are N/A there)." %
          (rel(c["config_path"], root), rel(final_dir, root)), ""]
    L.append(md_table(["id", "check", "fails if", "result"],
                      [[r["id"], r["name"], r["criterion"], r["status"] + ": " + r["detail"]]
                       for r in ck.res]))
    L += ["", "## Next steps", ""] + ([
          "1. Take the mesh of `%s`: its mesh.dat and resistivity_block_iter0.dat (gitignored, in the main checkout's "
          "`%s/inversion/`; on Phoenix, the shared mesh folder of hpc/phoenix_plan/RUNBOOK.md S4). Do not run the mesh "
          "chain or hpc/phoenix_plan/03_mesh.slurm." % (ru, ru),
          "2. The element and parameter-cell counts are those of `%s/mesh_logs/mesh_stats.txt`; settle INV_METHOD "
          "(above)." % ru,
          "3. The half-space gate result of `%s` applies (validation/mesh_2026-09-25/halfspace_accuracy.md)." % ru,
          "4. Upload and run on Phoenix: hpc/phoenix_plan/RUNBOOK.md.", ""] if ru else [
          "1. Mesh these inputs with the gated chain, `bash scripts/run_mesh_chain.sh <copy of files/> 5` "
          "(docs/mesh_tetra_pipeline.md; it reads files/region_seeds.dat), and keep the md5 of mesh.dat and "
          "resistivity_block_iter0.dat. hpc/phoenix_plan/03_mesh.slurm is a different, ungated chain: do not "
          "use it for these inputs.",
          "2. Compare the element and parameter-cell counts with docs/mesh_tetra_pipeline.md section 8.4 and "
          "settle INV_METHOD (above).",
          "3. Before inverting, pass the half-space accuracy gate of validation/mesh_2026-09-25/"
          "halfspace_accuracy.md: uniform 3 and 100 ohm-m, the OWNER_ELEMENT of inversion/control.dat, and at "
          "most 5 % in rho_a, 1.5 degrees in phase and 2 % in the diagonal ratio at every site and band.",
          "4. Upload and run on Phoenix: hpc/phoenix_plan/RUNBOOK.md.", ""])
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

    # ---- frame rotation (data.rotation): the EDI tensors, still in mV/km/nT and exp(+i omega t), are rotated
    # here, before write_observe -> prep_data converts units, conjugates and applies the error floor
    ang = rotation_angles(c, ids_z)
    ctx["rot_deg"] = ang
    if c["rot"] is not None:
        for rx, sid in enumerate(ids_z):
            df = dg.data_Z[rx].copy()
            z4 = np.column_stack([df["Z%sR" % k].to_numpy(float) + 1j * df["Z%sI" % k].to_numpy(float) for k in ZC])
            v4 = np.column_stack([df["Z%s.VAR" % k].to_numpy(float) for k in ZC])
            zr, vr = rotate_Z(z4, v4, ang[sid])
            for i, k in enumerate(ZC):
                df["Z%sR" % k], df["Z%sI" % k], df["Z%s.VAR" % k] = zr[:, i].real, zr[:, i].imag, vr[:, i]
            dg.data_Z[rx] = df
    log(rotation_text(c, ang))
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
        rotated = c["rot"] is not None          # without data.rotation the file keeps its pre-rotation layout
        fh.write("femtic_station_id,h_station_id,site_id,edi_file,x_north_km,y_east_km,easting_km,northing_km,"
                 "elev_km,n_freq%s\n" % (",rot_deg" if rotated else ""))
        for rx, sid in enumerate(ids_z):
            k = int(np.where(mc["id"].astype(str).values == sid)[0][0])
            s = tab[sid]
            fh.write("%d,%d,%s,%s.edi,%.5f,%.5f,%.4f,%.4f,%.5f,%d%s\n" %
                     (rx + 1, rx + 1001 if oe == -1 else rx + 1, sid, sid, mc["north"][k], mc["east"][k],
                      s[1], s[2], s[3], len(dg.data_Z[rx]), ",%s" % g(ang[sid]) if rotated else ""))

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
    if c["rot"] is None:
        w.append("data.rotation is not set: observe.dat holds the tensors in the EDI frame, unrotated. The Vulcan "
                 "EDIs are in the geomagnetic frame, about 7.42 deg clockwise of the mesh x axis (UTM grid north): "
                 "validation/rotation_2026-09-28/README.md")
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


# ================================================================================= guarded replacement
MANIFEST = "prep_manifest.sha256"      # written last into every run directory; --force trusts only it
STAGE_MARK = ".prep_vulcan_staging"    # marks DIR.staging as prep's own scratch; removed just before the
                                       # rename, after the last abort point, and never listed in the manifest


def is_link(path):
    """symlink, Windows junction or other reparse point: never descended into and never deleted through"""
    if os.path.islink(path):
        return True
    isj = getattr(os.path, "isjunction", None)                                 # Python >= 3.12
    if isj is not None and isj(path):
        return True
    return bool(getattr(os.lstat(path), "st_file_attributes", 0) & 0x400)    # FILE_ATTRIBUTE_REPARSE_POINT


def link_components(path):
    """every component of abspath(path), from the root down to path itself, that is a link. A directory
    reached through a symlinked or junctioned parent is treated like a link itself. A component that exists
    but cannot be examined counts as a link (fail closed)."""
    p, out = os.path.abspath(path), []
    while True:
        if os.path.lexists(p):
            try:
                if is_link(p):
                    out.append(p)
            except OSError:
                out.append(p)
        up = os.path.dirname(p)
        if up == p:
            return out[::-1]
        p = up


def inventory(top):
    """(files, dirs, links) below top as sorted '/'-separated relative paths; no link is followed"""
    files, dirs, links = [], [], []

    def walk(d, pre):
        with os.scandir(d) as it:
            ents = sorted(it, key=lambda e: e.name)
        for e in ents:
            r = pre + e.name
            if is_link(e.path):
                links.append(r)
            elif e.is_dir(follow_symlinks=False):
                dirs.append(r)
                walk(e.path, r + "/")
            else:
                files.append(r)

    walk(top, "")
    return files, dirs, links


def read_manifest(top):
    """{relative path: sha256} from top/prep_manifest.sha256; None if absent or not in sha256sum format"""
    p = os.path.join(top, MANIFEST)
    if not os.path.isfile(p) or is_link(p):
        return None
    out = {}
    with open(p, encoding="utf-8") as fh:
        for ln in fh:
            if ln.startswith("#"):          # header comments (script sha256, data.rotation); sha256sum -c skips them
                continue
            m = re.fullmatch(r"([0-9a-f]{64}) [ *](\S.*)", ln.rstrip("\n"))
            if not m:
                return None
            out[m.group(2)] = m.group(1)
    return out


def mark_staging(stage, run_dir):
    with open(os.path.join(stage, STAGE_MARK), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("prep_vulcan.py staging directory for %s; deleted by the next run\n" % run_dir)


def write_manifest(top, header=()):
    files = [r for r in inventory(top)[0] if r not in (MANIFEST, STAGE_MARK)]
    with open(os.path.join(top, MANIFEST), "w", encoding="utf-8", newline="\n") as fh:
        for h in header:
            fh.write("# %s\n" % " ".join(h.split()))
        for r in files:
            fh.write("%s  %s\n" % (sha256(os.path.join(top, *r.split("/"))), r))
    return len(files)


def inside(path, anc):
    """True if path is anc or lies below it, compared after resolving every link on both sides (realpath),
    so no symlink or junction alias can hide a protected path (case-insensitive where the file system is)"""
    p, a = os.path.normcase(os.path.realpath(path)), os.path.normcase(os.path.realpath(anc))
    try:
        return os.path.commonpath([p, a]) == a
    except ValueError:                                                         # different drives
        return False


def delete_plan(top, c, owned_by_marker=False):
    """What deleting the directory `top` would remove, file by file. PrepError (whatever the flags) if top is
    a link, a filesystem root, the home directory, contains the repository root, an input of the run, this
    script or a .git directory, or holds any link. Otherwise returns the inventory split into 'prep' (listed
    in top's prep_manifest.sha256 with that sha256; with owned_by_marker, every file of a directory that holds
    prep's staging marker) and 'foreign' (everything else, including files changed since prep wrote them).
    top counts as a link if it, or any directory above it, is a symlink or junction; the protected paths are
    compared after resolving links on both sides."""
    top = os.path.abspath(top)
    links_up = link_components(top)
    if links_up:
        fail("refusing to delete %s: %s on that path is a link (symlink or junction); prep never deletes through "
             "links. If you mean the directory it points to, give its real path (%s)" %
             (top, " and ".join(links_up), os.path.realpath(top)))
    if not os.path.isdir(top):
        fail("%s exists and is not a directory" % top)
    if os.path.dirname(top) == top:
        fail("refusing to delete %s: it is a filesystem root" % top)
    if ".git" in re.split(r"[\\/]", top) + re.split(r"[\\/]", os.path.realpath(top)):
        fail("refusing to delete %s: it lies inside a .git directory" % top)
    protected = [("the repository root (paths.root)", c["root"]), ("the config", c["config_path"]),
                 ("the EDI directory", c["edi_dir"]), ("the site table", c["coords_file"]),
                 ("femticPy", c["femticpy_src"]), ("this script", os.path.abspath(__file__)),
                 ("the home directory", os.path.expanduser("~"))]
    if c.get("dem_file"):
        protected.append(("the DEM", c["dem_file"]))
    for what, p in protected:
        if inside(p, top):
            fail("refusing to delete %s: it is or contains %s (%s)" % (top, what, p))
    files, dirs, links = inventory(top)
    if links:
        fail("refusing to delete %s: it contains %d link(s) (symlink or junction), which prep never follows or "
             "deletes: %s. Remove them by hand first" % (top, len(links), ", ".join(links[:10])))
    gits = [r for r in files + dirs if r.split("/")[-1] == ".git"]
    if gits:
        fail("refusing to delete %s: it contains a git repository (%s)" % (top, ", ".join(gits[:5])))
    man = None if owned_by_marker else read_manifest(top)
    marked = owned_by_marker and os.path.isfile(os.path.join(top, STAGE_MARK))
    prep, foreign, changed = [], [], []
    for r in files:
        if marked or (man is not None and r == MANIFEST):
            prep.append(r)
        elif man is not None and r in man:
            if sha256(os.path.join(top, *r.split("/"))) == man[r]:
                prep.append(r)
            else:
                foreign.append(r)
                changed.append(r)
        else:
            foreign.append(r)
    keep = {"/".join(r.split("/")[:k]) for r in prep for k in range(1, r.count("/") + 1)}
    fdirs = [d for d in dirs if d not in keep and not any(f.startswith(d + "/") for f in foreign)
             and not any(d.startswith(x + "/") for x in dirs if x not in keep)]
    size = lambda r: os.path.getsize(os.path.join(top, *r.split("/")))
    return {"top": top, "files": files, "dirs": dirs, "prep": prep, "foreign": foreign, "changed": changed,
            "foreign_dirs": fdirs, "manifest": man is not None, "marked": marked,
            "entries": set(files) | set(dirs), "prep_bytes": sum(size(r) for r in prep),
            "foreign_sizes": {r: size(r) for r in foreign}}


def describe_plan(plan, limit=40):
    """lines naming everything deleting plan['top'] would remove; foreign files grouped by the first
    directory that holds no prep product"""
    mb = lambda b: "%.1f MB" % (b / 1e6) if b >= 1e5 else "%d B" % b
    keep = {"/".join(r.split("/")[:k]) for r in plan["prep"] for k in range(1, r.count("/") + 1)}
    L = ["  %d file(s), %s, written by prep and unchanged since (%s)" %
         (len(plan["prep"]), mb(plan["prep_bytes"]),
          "staging marker" if plan["marked"] else (MANIFEST if plan["manifest"] else "no manifest"))]
    groups = {}
    for r in plan["foreign"]:
        parts = r.split("/")
        k = next((k for k in range(1, len(parts)) if "/".join(parts[:k]) not in keep), len(parts))
        key = "/".join(parts[:k]) + ("/" if k < len(parts) else "")
        n, b = groups.get(key, (0, 0))
        groups[key] = (n + 1, b + plan["foreign_sizes"][r])
    for d in plan["foreign_dirs"]:
        groups.setdefault(d + "/", (0, 0))
    ch = set(plan["changed"])
    for i, (k, (n, b)) in enumerate(sorted(groups.items())):
        if i == limit:
            L.append("  ... and %d more foreign entries" % (len(groups) - limit))
            break
        if k.endswith("/"):
            L.append("  FOREIGN %s  (%d file(s), %s)" % (k, n, mb(b)))
        else:
            L.append("  %s %s  (%s)" % ("CHANGED" if k in ch else "FOREIGN", k, mb(b)))
    if not plan["manifest"] and not plan["marked"] and plan["files"]:
        L.append("  (no %s: a directory written before 2026-09-28 or not by prep, so every file counts as "
                 "foreign)" % MANIFEST)
    return L


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("config", help="YAML config, e.g. config/vulcan_mesh_v1.yml")
    ap.add_argument("--out", help="output run directory (default: paths.run_dir of the config)")
    ap.add_argument("--force", action="store_true",
                    help="replace an existing output directory, only if every file in it is listed unchanged in "
                         "its %s" % MANIFEST)
    ap.add_argument("--force-delete-foreign", action="store_true",
                    help="with --force: also delete files prep did not write or that changed since (listed "
                         "first); links, inputs and the repository are still refused")
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
        # resolve the rotation angle of every site now, so a bad 'auto' angle file stops the run before anything
        # is written (build and the checks resolve it again the same way)
        ang0 = rotation_angles(c, sorted(e["dataid"] for e in edis.values()))

        if a.check_only:
            run_dir = os.path.abspath(a.check_only)
            ee, nn = [s[1] for s in sites], [s[2] for s in sites]
            origin = (min(ee) + (max(ee) - min(ee)) / 2, min(nn) + (max(nn) - min(nn)) / 2) \
                if c["origin"] is None else tuple(c["origin"])
            log(rotation_text(c, ang0))
            ck = run_checks(c, run_dir, sites, edis, origin)[0]
            bad = ck.failed()
            log(ck.summary())
            return 1 if bad else 0

        run_dir = os.path.abspath(a.out) if a.out else c["run_dir"]
        stage = run_dir.rstrip("/\\") + ".staging"
        if a.force_delete_foreign and not a.force:
            fail("--force-delete-foreign only widens --force; give both")
        plan0 = None
        if os.path.lexists(run_dir):
            plan0 = delete_plan(run_dir, c)
            if plan0["entries"]:
                if not a.force:
                    for ln in ["%s exists and is not empty:" % run_dir] + describe_plan(plan0):
                        log(ln)
                    fail("%s exists. Write to a new directory with --out DIR, or use --force to replace it (allowed "
                         "only while every file in it is listed unchanged in its %s)" % (run_dir, MANIFEST))
                for ln in ["--force: once every self-check passes, %s will be deleted and replaced; it holds:" %
                           run_dir] + describe_plan(plan0):
                    log(ln)
                if plan0["foreign"] or plan0["foreign_dirs"]:
                    if not a.force_delete_foreign:
                        fail("nothing deleted: %s holds %d file(s) and %d empty dir(s) that prep did not write or "
                             "that changed since (listed above), e.g. mesh products or half-space runs copied "
                             "there. Move them out, write to a new --out directory, or add --force-delete-foreign "
                             "to delete them too" % (run_dir, len(plan0["foreign"]), len(plan0["foreign_dirs"])))
                    log("--force-delete-foreign: the foreign entries above will be deleted too")
        if os.path.lexists(stage):
            splan = delete_plan(stage, c, owned_by_marker=True)
            if not splan["marked"] and splan["entries"] and not a.force_delete_foreign:
                for ln in ["%s exists without prep's staging marker %s:" % (stage, STAGE_MARK)] + describe_plan(splan):
                    log(ln)
                fail("nothing deleted: %s was not created by this version of prep; move it away (or add --force "
                     "--force-delete-foreign)" % stage)
            log("removing %s (%d file(s)) left by an earlier run" % (stage, len(splan["files"])))
            shutil.rmtree(stage)
        os.makedirs(stage)
        mark_staging(stage, run_dir)
        log("prep_vulcan: config %s -> %s" % (c["config_path"], run_dir))
        ctx["femticPy"] = import_femticpy(c["femticpy_src"])
        import pandas as pd
        ctx["pyver"] = "Python %s on %s; numpy %s, pandas %s" % (platform.python_version(), platform.system(),
                                                                 np.__version__, pd.__version__)
        ctx["femticpy_desc"] = femticpy_description(c["femticpy_src"])
        ctx["script_sha"] = sha256(os.path.abspath(__file__))     # README provenance and the manifest header
        ctx["script_rel"] = rel(os.path.abspath(__file__), c["root"])
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
        log("writing %s: sha256 of every file of the run directory" % MANIFEST)
        with open(os.path.join(stage, "prep.log"), "w", encoding="utf-8", newline="\n") as fh:
            fh.write("\n".join(LOG) + "\n\n----- femticPy output -----\n" + "".join(ctx["femticpy_out"]))
        write_manifest(stage, ("written by %s sha256 %s" % (ctx["script_rel"], ctx["script_sha"]),) +
                       (() if c["rot"] is None else (rotation_text(c, ctx["rot_deg"]),)))
        # the READMEs and the log are written after the checks: re-check line endings over the final tree
        crs = []
        for dp, _, fns in os.walk(stage):
            for fn in fns:
                with open(os.path.join(dp, fn), "rb") as fh:
                    if b"\r" in fh.read():
                        crs.append(fn)
        if crs:
            fail("CR bytes in %s (inspect %s)" % (crs, stage))
        if os.path.lexists(run_dir):
            # re-inventory just before deleting: anything added or changed during the run stops it here
            plan1 = delete_plan(run_dir, c)
            new = sorted(plan1["entries"] - (plan0["entries"] if plan0 else set()))
            if new or (plan1["entries"] and not a.force) or (
                    (plan1["foreign"] or plan1["foreign_dirs"]) and not a.force_delete_foreign):
                fail("nothing deleted: %s changed during the run (%s); the new products are in %s" %
                     (run_dir, ", ".join(new[:10]) or "foreign or changed files", stage))
            shutil.rmtree(run_dir)
        # every abort point is behind us (checks, CR scan, re-inventory): only now is the staging marker
        # dropped, so a run that stopped anywhere above leaves a marked DIR.staging that the next run removes
        os.remove(os.path.join(stage, STAGE_MARK))
        try:
            os.replace(stage, run_dir)
        except OSError as e:
            mark_staging(stage, run_dir)
            fail("could not rename %s to %s (%s); nothing else was changed and the staging directory keeps its "
                 "marker" % (stage, run_dir, e))
        print("OK: %s; wrote %s" % (ck.summary(), run_dir))
        return 0
    except PrepError as e:
        print("PREP FAILED: %s" % e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
