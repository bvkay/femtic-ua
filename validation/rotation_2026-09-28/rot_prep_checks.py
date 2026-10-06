#!/usr/bin/env python3
"""rot_prep_checks.py -- tests of the data.rotation feature of scripts/prep_vulcan.py (work item C5), each shown
FAILING on a broken case before it is shown PASSING (CLAUDE.md Invariant 10).

    python validation/rotation_2026-09-28/rot_prep_checks.py WORKDIR [--prep PATH] [--skip-mutants]
                                                             [--old-prep PATH] [--only R10a,R11a,...]

WORKDIR must be absent or empty; every output goes below it. The repository is only read: the 120 Vulcan
EDIs, the site table, config/vulcan_mesh_v2_rot.yml and config/vulcan_mesh_v2.yml, mesh/vulcan_v2 and
mesh/vulcan_v3 (compared against, never written) and alpha_per_site.csv. --prep picks the script under test
(default scripts/prep_vulcan.py); the mutants of section M are built from its text by exact replacement
(occurrence count asserted; a missing anchor = 'NOT BUILT' = FAIL). Light: single-threaded Python, prep
takes about 3 s per full run on 120 sites. No FEMTIC, no mesh tool.

Sections: R real-data runs (regression at angle 0, the 7.42 deg run, invariants, cross-checks, per-site
'auto', config refusals, mesh reuse, schema; R9b/R9c only with --old-prep, a prep_vulcan.py from before
data.rotation; R10 the EDI frame guard C18 on scratch copies of the EDIs; R11 the angle column of 'auto' per
frame_in; R12 the generated records of a mesh-reuse run); M mutants of the script under test, on which the
named test must FAIL. --only runs the listed R tests alone.
"""
import argparse
import hashlib
import importlib.util
import os
import re
import subprocess
import sys

import numpy as np
import yaml

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
V2 = os.path.join(REPO, "mesh", "vulcan_v2")
OBS = "inversion/observe.dat"
SMAP = "inversion/station_map.csv"
ALL = ["C%02d" % k for k in range(1, 19)]
RESULTS, TESTS = [], {}
ARGS = None


def say(msg=""):
    print(msg, flush=True)


def sha(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def run(args):
    p = subprocess.run([sys.executable, "-B"] + args, capture_output=True, text=True, cwd=REPO)   # -B: no __pycache__
    return p.returncode, p.stdout.replace("\r\n", "\n"), p.stderr.replace("\r\n", "\n")


def statuses(text):
    return dict((c, s) for s, c in re.findall(r"\[(PASS|FAIL|N/A)\]\s+(C\d\d)\b", text))


def line_of(text, cid, n=230):
    m = re.search(r"\[(?:PASS|FAIL|N/A)\]\s+%s\b.*" % cid, text)
    return m.group(0)[:n] if m else "(no %s line)" % cid


def load(prep):
    """the script under test as a module (for rotate_Z, parse_edi); bytecode is never written"""
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("prep_under_test_%d" % len(sys.modules), prep)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def register(tid, name, criterion, fn):
    """fn(prep, work) -> (ok, observed); criterion completes 'This test fails if ...'"""
    TESTS[tid] = (name, criterion, fn)


def test(tid, prep=None, work=None, label=None):
    name, crit, fn = TESTS[tid]
    say("\n[%s] %s\n  This test fails if %s" % (label or tid, name, crit))
    try:
        ok, obs = fn(prep or ARGS.prep, work or os.path.join(ARGS.work, tid))
    except Exception as e:                                   # a crash is a failed test, never a pass
        ok, obs = False, "harness exception: %r" % (e,)
    say("  -> %s: %s" % ("PASS" if ok else "FAIL", obs))
    RESULTS.append((label or tid, name, bool(ok), obs))
    return ok, obs


def info(label, text):
    say("\n[%s] (observation, not a test)\n  %s" % (label, text))
    RESULTS.append((label, "observation", None, text))


def config(work, name, edit):
    """work/cfg/name.yml: config/vulcan_mesh_v2_rot.yml with paths.root made absolute, then edit(cfg)"""
    with open(os.path.join(REPO, "config", "vulcan_mesh_v2_rot.yml"), encoding="utf-8") as fh:
        cfg = yaml.safe_load(fh)
    cfg["paths"]["root"] = REPO
    edit(cfg)
    d = os.path.join(work, "cfg")
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, name + ".yml")
    with open(p, "w", encoding="utf-8", newline="\n") as fh:
        yaml.safe_dump(cfg, fh, sort_keys=False)
    return p


def rot(angle, frame="magnetic", **kw):
    def edit(cfg):
        cfg["data"]["rotation"] = dict({"frame_in": frame, "rotate_to": "grid", "angle_deg": angle,
                                        "provenance": "rot_prep_checks.py"}, **kw)
    return edit


def full(prep, cfg, out):
    rc, o, e = run([prep, cfg, "--out", out])
    return rc, o + e, statuses(o + e)


def read_smap(path):
    with open(path, encoding="utf-8") as fh:
        rows = [ln.rstrip("\n").split(",") for ln in fh]
    return rows[0], rows[1:]


def smap_without_rot(path):
    """station_map.csv with its rot_deg column removed, as text, plus that column's values"""
    hdr, rows = read_smap(path)
    if "rot_deg" not in hdr:
        return "\n".join(",".join(r) for r in [hdr] + rows), None
    k = hdr.index("rot_deg")
    drop = lambda r: r[:k] + r[k + 1:]
    return "\n".join(",".join(drop(r)) for r in [hdr] + rows), [r[k] for r in rows]


def same_as_v2(out, names):
    return [n for n in names if sha(os.path.join(out, *n.split("/"))) != sha(os.path.join(V2, *n.split("/")))]


def files_names():
    return ["files/" + n for n in sorted(os.listdir(os.path.join(V2, "files")))]


# ============================================================================================ R tests
LAST = {}


def t_r1(prep, work):
    out = os.path.join(work, "run")
    rc, text, st = full(prep, config(work, "angle0", rot(0.0, frame="grid")), out)
    if rc != 0:
        return False, "exit %d: %s" % (rc, text.strip()[-300:])
    diff = same_as_v2(out, [OBS, "inversion/control.dat"] + files_names())
    s_new, col = smap_without_rot(os.path.join(out, SMAP))
    s_old = smap_without_rot(os.path.join(V2, SMAP))[0]
    ok = not diff and s_new == s_old and col is not None and set(col) == {"0"}
    return ok, ("exit 0; differ from mesh/vulcan_v2: %s; observe.dat sha256 %s (v2 %s); station_map.csv = v2's "
                "plus a rot_deg column %s: %s" % (diff or "none", sha(os.path.join(out, OBS))[:16],
                                                  sha(os.path.join(V2, OBS))[:16], sorted(set(col or [])),
                                                  s_new == s_old))


register("R1", "regression: data.rotation with angle 0 (frame_in grid) reproduces mesh/vulcan_v2 byte for byte",
         "prep exits non-zero, or observe.dat, inversion/control.dat or any files/* differs from mesh/vulcan_v2 by "
         "sha256, or station_map.csv differs from v2's in anything but an added rot_deg column of zeros", t_r1)


def manifest_ok(out):
    with open(os.path.join(out, "prep_manifest.sha256"), encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    head = [ln for ln in lines if ln.startswith("#")]
    listed = {ln.split("  ", 1)[1]: ln.split("  ", 1)[0] for ln in lines if not ln.startswith("#")}
    found = []
    for dp, _, fns in os.walk(out):
        found += [os.path.relpath(os.path.join(dp, f), out).replace(os.sep, "/") for f in fns]
    found.remove("prep_manifest.sha256")
    bad = sorted(r for r in set(found) | set(listed) if r not in listed or r not in found or
                 sha(os.path.join(out, *r.split("/"))) != listed[r])
    return head, len(listed), bad


def t_r2(prep, work):
    out = os.path.join(work, "run")
    LAST["742"] = out
    rc, text, st = full(prep, config(work, "rot742", lambda c: None), out)
    LAST["st"] = st
    notpass = ["%s=%s" % (c, st.get(c)) for c in ALL if st.get(c) != "PASS"]
    if rc != 0 or notpass:
        return False, "exit %d; not PASS: %s; %s" % (rc, notpass, " | ".join(line_of(text, c.split("=")[0], 200)
                                                                             for c in notpass[:3]))
    s_new, col = smap_without_rot(os.path.join(out, SMAP))
    head, n, bad = manifest_ok(out)
    hok = sum(h.startswith("# data.rotation: magnetic -> grid, alpha 7.42 deg (explicit)") for h in head) == 1
    same = same_as_v2(out, ["inversion/control.dat"] + files_names())
    changed = sha(os.path.join(out, OBS)) != sha(os.path.join(V2, OBS))
    ok = (s_new == smap_without_rot(os.path.join(V2, SMAP))[0] and col is not None and set(col) == {"7.42"}
          and hok and not bad and not same and changed)
    return ok, ("exit 0, %d PASS; %s | %s; station_map = v2's plus rot_deg %s: %s; manifest header %r, %d files, "
                "mismatches %s; control.dat and files/* as v2: %s; observe.dat differs from v2's: %s" %
                (len(ALL), line_of(text, "C08", 90), line_of(text, "C17", 120), sorted(set(col or [])),
                 s_new == smap_without_rot(os.path.join(V2, SMAP))[0], head, n, bad, not same, changed))


register("R2", "full prep of config/vulcan_mesh_v2_rot.yml (7.42 deg): checks, records and unchanged mesh inputs",
         "prep exits non-zero, any of C01-C18 is not PASS, station_map.csv is not v2's plus a rot_deg column of "
         "7.42, prep_manifest.sha256 lacks the one '# data.rotation: magnetic -> grid, alpha 7.42 deg (explicit)' "
         "header line or does not list every other file with its sha256, inversion/control.dat or a files/* differs "
         "from mesh/vulcan_v2, or observe.dat does NOT differ from v2's", t_r2)


def edi_tensors(pv):
    d = os.path.join(REPO, "Vulcan", "Processed_Data")
    for f in sorted(os.listdir(d)):
        if f.endswith(".edi"):
            e = pv.parse_edi(os.path.join(d, f))
            yield (e["dataid"], np.column_stack([e["z"][c] for c in pv.ZC])[e["ok"]],
                   np.column_stack([e["var"][c] for c in pv.ZC])[e["ok"]])


def invariants(z):
    return (z[:, 0] * z[:, 3] - z[:, 1] * z[:, 2], z[:, 0] + z[:, 3], z[:, 1] - z[:, 2],
            np.sqrt((np.abs(z) ** 2).sum(1)))


def t_r3(prep, work):
    pv = load(prep)
    w, n, ns = [0.0] * 5, 0, 0
    for _, z, v in edi_tensors(pv):
        zr = pv.rotate_Z(z, v, 7.42)[0]
        (d0, t0, a0, f0), (d1, t1, a1, f1) = invariants(z), invariants(zr)
        for k, x in enumerate((np.abs(np.abs(d1) - np.abs(d0)) / np.abs(d0), np.abs(d1 - d0) / f0 ** 2,
                               np.abs(t1 - t0) / f0, np.abs(a1 - a0) / f0, np.abs(f1 - f0) / f0)):
            w[k] = max(w[k], float(x.max()))
        n, ns = n + len(z), ns + 1
    ok = max(w) <= 1e-10
    return ok, ("%d tensors of %d EDIs (every unmasked band), rotate_Z at 7.42 deg: max relative change of |det Z| "
                "%.1e, of det Z %.1e (/|Z|^2), of Zxx+Zyy %.1e, of Zxy-Zyx %.1e, of |Z|_F %.1e (/|Z|_F)" %
                (n, ns, w[0], w[1], w[2], w[3], w[4]))


register("R3", "rotational invariants at full precision (all 120 EDIs, every unmasked band)",
         "for any tensor, rotate_Z at 7.42 deg changes |det Z| by more than 1e-10 relative, det Z by more than "
         "1e-10 |Z|_F^2, Zxx+Zyy or Zxy-Zyx by more than 1e-10 |Z|_F, or |Z|_F by more than 1e-10 relative", t_r3)


def obs_tensors(pv, path):
    mt = pv.parse_observe(path, True)["MT"]
    z = np.vstack([s["rows"][:, 1:9:2] + 1j * s["rows"][:, 2:9:2] for s in mt])
    se = np.vstack([s["rows"][:, 9::2] for s in mt])
    return z, se


def t_r4(prep, work):
    """written files: invariants within the '%.4e' rounding, and how much each component moved"""
    pv = load(prep)
    z0, s0 = obs_tensors(pv, os.path.join(V2, OBS))
    z1, s1 = obs_tensors(pv, os.path.join(LAST["742"], OBS))
    (d0, t0, a0, f0), (d1, t1, a1, f1) = invariants(z0), invariants(z1)
    w = [float(x.max()) for x in (np.abs(np.abs(d1) - np.abs(d0)) / f0 ** 2, np.abs(t1 - t0) / f0,
                                  np.abs(a1 - a0) / f0, np.abs(f1 - f0) / f0)]
    wdet = float((np.abs(np.abs(d1) - np.abs(d0)) / np.abs(d0)).max())
    mv = np.abs(z1 - z0) / np.abs(z0)
    mf = np.abs(z1 - z0) / f0[:, None]
    ms = np.abs(s1 - s0) / s0
    LAST["moved"] = ("per component xx/xy/yx/yy over %d data lines: median |dZ|/|Z| %s, max %s; max |dZ|/|Z|_F %s; "
                     "SE median |dSE|/SE %s, max %s" % (len(z0), "/".join("%.3g" % v for v in np.median(mv, 0)),
                                                      "/".join("%.3g" % v for v in mv.max(0)),
                                                      "/".join("%.3g" % v for v in mf.max(0)),
                                                      "/".join("%.2g" % v for v in np.median(ms, 0)),
                                                      "/".join("%.2g" % v for v in ms.max(0))))
    ok = max(w) <= 3e-4 and float(mf.max()) > 1e-2
    return ok, ("written observe.dat, 7.42 deg vs mesh/vulcan_v2 (both '%%.4e'): max change of |det Z| %.1e "
                "|Z|_F^2 (%.1e of |det Z|, information), of Zxx+Zyy %.1e, of Zxy-Zyx %.1e, of |Z|_F %.1e (/|Z|_F); "
                "largest component change %.3f |Z|_F" % (w[0], wdet, w[1], w[2], w[3], float(mf.max())))


register("R4", "rotational invariants on the written files (R2's observe.dat against mesh/vulcan_v2's)",
         "|det Z| of any written tensor differs between the two files by more than 3e-4 |Z|_F^2, or Zxx+Zyy, "
         "Zxy-Zyx or |Z|_F by more than 3e-4 |Z|_F (the '%.4e' rounding of both files allows at most about "
         "2e-4), or no component "
         "moved by more than 1e-2 |Z|_F (the rotation would then be invisible here)", t_r4)


def t_check_only(cfgname, target, expect_fail):
    def body(prep, work):
        if cfgname == "v2":
            cfg = os.path.join(REPO, "config", "vulcan_mesh_v2.yml")
        else:
            cfg = config(work, "rot742", lambda c: None)
        tgt = V2 if target == "v2" else LAST["742"]
        before = tree_hash(tgt)
        rc, o, e = run([prep, cfg, "--check-only", tgt])
        st = statuses(o + e)
        same = tree_hash(tgt) == before
        if expect_fail:
            ok = rc == 1 and st.get("C08") == "FAIL" and same
        else:
            ok = rc == 0 and same and [st.get(c) for c in ALL] == [
                "N/A" if c in ("C03", "C05") else "PASS" for c in ALL]
        return ok, "exit %d; %s; C08 %s; C09 %s; tree unchanged: %s" % (
            rc, " ".join("%s=%s" % (c, st.get(c)) for c in ALL), line_of(o + e, "C08", 160)[6:],
            st.get("C09"), same)
    return body


def tree_hash(d):
    h = hashlib.sha256()
    for dp, dns, fns in sorted(os.walk(d)):
        dns.sort()
        for f in sorted(fns):
            p = os.path.join(dp, f)
            h.update(os.path.relpath(p, d).encode() + sha(p).encode())
    return h.hexdigest()[:16]


register("R5a", "--check-only of R2's output with its own config", "it exits non-zero, a check other than "
         "C03/C05 (N/A under --check-only) is not PASS, or the directory changes", t_check_only("rot", "742", False))
register("R5b", "--check-only of R2's (rotated) output with config/vulcan_mesh_v2.yml (no data.rotation)",
         "C08 does NOT FAIL (it would then accept rotated data as unrotated), prep exits other than 1, or the "
         "directory changes", t_check_only("v2", "742", True))
register("R5c", "--check-only of mesh/vulcan_v2 (unrotated) with config/vulcan_mesh_v2_rot.yml",
         "C08 does NOT FAIL, prep exits other than 1, or mesh/vulcan_v2 changes", t_check_only("rot", "v2", True))


ALPHA_CSV = os.path.join(REPO, "validation", "rotation_2026-09-28", "alpha_per_site.csv")


def t_r6(prep, work):
    out = os.path.join(work, "run")
    rc, text, st = full(prep, config(work, "auto", rot("auto", angle_file=ALPHA_CSV, angle_column="alpha_deg")), out)
    notpass = ["%s=%s" % (c, st.get(c)) for c in ALL if st.get(c) != "PASS"]
    if rc != 0 or notpass:
        return False, "exit %d; not PASS: %s; %s" % (rc, notpass, text.strip()[-300:])
    with open(ALPHA_CSV, encoding="utf-8") as fh:
        hdr = fh.readline().strip().split(",")
        tab = {r[0]: float(r[hdr.index("alpha_deg")]) for r in (ln.strip().split(",") for ln in fh)}
    h, rows = read_smap(os.path.join(out, SMAP))
    got = {r[h.index("site_id")]: float(r[h.index("rot_deg")]) for r in rows}
    err = max(abs(got[k] - tab[k]) for k in got)
    pv = load(prep)
    z7 = obs_tensors(pv, os.path.join(LAST["742"], OBS))[0]
    za = obs_tensors(pv, os.path.join(out, OBS))[0]
    LAST["auto"] = "auto vs 7.42: max |dZ| %.2e |Z|_F over %d data lines" % (
        float((np.abs(za - z7) / invariants(z7)[3][:, None]).max()), len(z7))
    ok = len(got) == 120 and set(got) == set(tab) and err <= 1e-9
    return ok, "exit 0, %d PASS (%s); station_map rot_deg = alpha_per_site.csv for %d sites, max diff %.1e; %s" % (
        len(ALL), line_of(text, "C08", 80), len(got), err, LAST["auto"])


register("R6", "data.rotation angle_deg 'auto': per-site alpha from alpha_per_site.csv", "prep exits non-zero, any "
         "check is not PASS, or station_map.csv's rot_deg differs from the CSV's alpha_deg by more than 1e-9 for "
         "any of the 120 sites", t_r6)


def refusal(edit, msg):
    def body(prep, work):
        out = os.path.join(work, "run")
        rc, o, e = run([prep, config(work, "bad", edit), "--out", out])
        ok = rc == 1 and msg in e and not os.path.exists(out) and not os.path.exists(out + ".staging")
        return ok, "exit %d; message %r present: %s; output written: %s; %s" % (
            rc, msg, msg in e, os.path.exists(out), (e.strip().splitlines() or [""])[-1][:220])
    return body


def no_angle(cfg):
    rot(None)(cfg)
    del cfg["data"]["rotation"]["angle_deg"]


def missing_site_csv(work):
    def edit(cfg):
        p = os.path.join(work, "alpha_no_J6.csv")
        with open(ALPHA_CSV, encoding="utf-8") as fi, open(p, "w", encoding="utf-8", newline="\n") as fo:
            fo.writelines(ln for ln in fi if not ln.startswith("J6_"))
        rot("auto", angle_file=p)(cfg)
    return edit


register("R7a", "refusal: frame_in magnetic without angle_deg", "prep exits other than 1, writes an output or "
         "staging directory, or does not say 'refusing to guess'", refusal(no_angle, "refusing to guess"))
register("R7b", "refusal: frame_in grid with angle_deg 7.42", "prep exits other than 1, writes output, or does not "
         "say 'angle_deg must be 0'", refusal(rot(7.42, frame="grid"), "angle_deg must be 0"))
register("R7c", "refusal: a misspelt key (angle_degs)", "prep exits other than 1, writes output, or does not say "
         "'unknown key'", refusal(lambda cfg: (rot(7.42)(cfg), cfg["data"]["rotation"].update(angle_degs=1)),
                                  "unknown key"))
register("R7d", "refusal: angle_deg 'auto' without angle_file", "prep exits other than 1, writes output, or does "
         "not say 'needs angle_file'", refusal(rot("auto"), "needs angle_file"))


def t_r7e(prep, work):
    os.makedirs(work, exist_ok=True)
    return refusal(missing_site_csv(work), "has no angle for 1 site(s)")(prep, work)


register("R7e", "refusal: angle_deg 'auto' with a CSV that lacks one site (J6_BxRepaced)", "prep exits other than "
         "1, writes output, or does not say 'has no angle for 1 site(s)'", t_r7e)


def t_r8(prep, work):
    out = os.path.join(work, "run")
    rc, text, st = full(prep, config(work, "reuse_v3", lambda c: c["mesh"].update(reuse_from="mesh/vulcan_v3")), out)
    ok = rc == 1 and st.get("C17") == "FAIL" and not os.path.exists(out)
    return ok, "exit %d; %s; output written: %s" % (rc, line_of(text, "C17", 200), os.path.exists(out))


register("R8", "mesh.reuse_from pointing at a mesh built from other inputs (mesh/vulcan_v3)", "prep exits other "
         "than 1, C17 is not FAIL, or the output directory is created", t_r8)
register("R9a", "refusal: data.rotation under 'schema: prep_vulcan/1'", "prep exits other than 1, writes output, "
         "or does not say \"need 'schema: prep_vulcan/2'\"",
         refusal(lambda cfg: cfg.update(schema="prep_vulcan/1"), "need 'schema: prep_vulcan/2'"))


def t_r9b(prep, work):
    out = os.path.join(work, "run")
    rc, o, e = run([ARGS.old_prep, os.path.join(REPO, "config", "vulcan_mesh_v2_rot.yml"), "--out", out])
    ok = rc == 1 and "schema" in e and not os.path.exists(out)
    return ok, "%s (sha256 %s): exit %d; output written: %s; %s" % (
        os.path.basename(ARGS.old_prep), sha(ARGS.old_prep)[:16], rc, os.path.exists(out),
        (e.strip().splitlines() or [""])[-1][:160])


def t_r9c(prep, work):
    out = os.path.join(work, "run")
    cfg = config(work, "schema1", lambda c: c.update(schema="prep_vulcan/1"))
    rc, o, e = run([ARGS.old_prep, cfg, "--out", out])
    same = rc == 0 and sha(os.path.join(out, OBS)) == sha(os.path.join(V2, OBS))
    return same, "old script, the v2_rot config with schema prep_vulcan/1: exit %d; observe.dat identical to the " \
        "UNrotated mesh/vulcan_v2: %s; %s" % (rc, same, line_of(o + e, "C08", 120))


register("R9c", "the hazard R9b guards against: the older script given the rotation config under prep_vulcan/1",
         "the old script refuses it or writes rotated data (then the schema bump would be unnecessary); this is the "
         "failing case of R9b's criterion", t_r9c)
register("R9b", "an older prep_vulcan.py (--old-prep, which ignores data.rotation) refuses "
         "config/vulcan_mesh_v2_rot.yml", "the old script exits 0 or writes an output directory (it would then "
         "write UNrotated data from a config that asks for rotation)", t_r9b)


# ======================================================= R10-R12: frame guard, angle column, generated records
EDI_DIR = os.path.join(REPO, "Vulcan", "Processed_Data")


def g6(v):
    return "%.6g" % v


def edi_copy(work, site, edit):
    """work/edi: a scratch copy of the 120 Vulcan EDIs with site's file changed by edit(bytes) -> bytes (the
    change is asserted, so a no-op edit cannot pass as a fault)"""
    d = os.path.join(work, "edi")
    os.makedirs(d)
    changed = False
    for f in sorted(os.listdir(EDI_DIR)):
        if not f.endswith(".edi"):
            continue
        with open(os.path.join(EDI_DIR, f), "rb") as fh:
            b = fh.read()
        if f == site + ".edi":
            nb = edit(b)
            changed = nb != b
            b = nb
        with open(os.path.join(d, f), "wb") as fh:
            fh.write(b)
    if not changed:
        raise RuntimeError("the edit left %s.edi unchanged" % site)
    return d


def set_zrot(v):
    """every value of the >ZROT block set to v (the tensor then claims to be rotated by v already)"""
    def edit(b):
        def blk(m):
            return m.group(1) + re.sub(rb"[-+0-9.Ee]+", ("%.6E" % v).encode(), m.group(2))
        return re.sub(rb"(>ZROT[^\n]*\n)([^>]*)", blk, b, count=1)
    return edit


def set_decl(v):
    return lambda b: re.sub(rb"(DECLINATION\s*:\s*)[-+0-9.]+", lambda m: m.group(1) + (b"%.4f" % v), b, count=1)


def set_hx_azm(v):
    return lambda b: re.sub(rb"(>HMEAS [^\n]*CHTYPE=HX [^\n]*AZM=)[-+0-9.]+", lambda m: m.group(1) + (b"%g" % v), b,
                            count=1)


def frame_case(edi_edit, rot_edit, expect_fail, needle):
    def body(prep, work):
        d = edi_copy(work, "E5", edi_edit)
        out = os.path.join(work, "run")

        def edit(cfg):
            if rot_edit:
                rot_edit(cfg)
            cfg["paths"]["edi_dir"] = d
        rc, text, st = full(prep, config(work, "frame", edit), out)
        line = line_of(text, "C18", 330)
        if expect_fail:
            ok = rc == 1 and st.get("C18") == "FAIL" and "E5" in line and needle in line and not os.path.exists(out)
        else:
            ok = rc == 0 and [st.get(c) for c in ALL] == ["PASS"] * len(ALL)
        return ok, "exit %d; C18 %s; output written: %s; %s" % (rc, st.get("C18"), os.path.exists(out), line)
    return body


register("R10a", "frame guard: E5's ZROT set to 7.42 at every band in a scratch copy of the 120 EDIs (the tensor "
         "claims to be rotated already), run with config/vulcan_mesh_v2_rot.yml", "prep exits other than 1, C18 is "
         "not FAIL, C18 does not name E5 and 'ZROT 7.42', or the output directory is created (prep would rotate E5 "
         "a second time)", frame_case(set_zrot(7.42), None, True, "ZROT 7.42"))
register("R10b", "frame guard: E5's DECLINATION set to 6.4 under frame_in magnetic", "prep exits other than 1, C18 "
         "is not FAIL, C18 does not name E5 and 'DECLINATION 6.4', or the output directory is created",
         frame_case(set_decl(6.4), None, True, "DECLINATION 6.4"))
register("R10c", "frame guard: E5's first HMEAS HX AZM set to 7.42", "prep exits other than 1, C18 is not FAIL, C18 "
         "does not name E5 and 'AZM 7.42', or the output directory is created",
         frame_case(set_hx_azm(7.42), None, True, "AZM 7.42"))
register("R10d", "frame guard, documented exception: DECLINATION 6.4 at E5 under frame_in true (angle 1.02)",
         "prep exits non-zero or any of C01-C18 is not PASS (under frame_in true DECLINATION is information only)",
         frame_case(set_decl(6.4), rot(1.02, frame="true"), False, ""))
register("R10e", "frame guard: E5's ZROT 7.42 under frame_in true (angle 1.02): the ZROT rule holds in every frame",
         "prep exits other than 1, C18 is not FAIL, C18 does not name E5 and 'ZROT 7.42', or the output directory "
         "is created", frame_case(set_zrot(7.42), rot(1.02, frame="true"), True, "ZROT 7.42"))


def true_csv(work):
    """work/alpha_true.csv: alpha_per_site.csv plus a column alpha_true_deg = -conv_pyproj_deg (the azimuth of
    true north clockwise from grid north)"""
    os.makedirs(work, exist_ok=True)
    p = os.path.join(work, "alpha_true.csv")
    with open(ALPHA_CSV, encoding="utf-8") as fi, open(p, "w", encoding="utf-8", newline="\n") as fo:
        hdr = fi.readline().rstrip("\n").split(",")
        fo.write(",".join(hdr + ["alpha_true_deg"]) + "\n")
        k = hdr.index("conv_pyproj_deg")
        for ln in fi:
            r = ln.rstrip("\n").split(",")
            fo.write(",".join(r + ["%.5f" % -float(r[k])]) + "\n")
    return p


def t_r11d(prep, work):
    csv = true_csv(work)
    out = os.path.join(work, "run")
    rc, text, st = full(prep, config(work, "true_auto", rot("auto", frame="true", angle_file=csv)), out)
    notpass = ["%s=%s" % (c, st.get(c)) for c in ALL if st.get(c) != "PASS"]
    if rc != 0 or notpass:
        return False, "exit %d; not PASS: %s; %s" % (rc, notpass, text.strip()[-300:])
    with open(csv, encoding="utf-8") as fh:
        hdr = fh.readline().strip().split(",")
        tab = {r[0]: float(r[hdr.index("alpha_true_deg")]) for r in (ln.strip().split(",") for ln in fh)}
    h, rows = read_smap(os.path.join(out, SMAP))
    got = {r[h.index("site_id")]: float(r[h.index("rot_deg")]) for r in rows}
    err = max(abs(got[k] - tab[k]) for k in got)
    lo, hi = min(got.values()), max(got.values())
    ok = len(got) == 120 and set(got) == set(tab) and err <= 1e-9 and 0.9 < lo <= hi < 1.1
    return ok, "exit 0, %d PASS; station_map rot_deg %s..%s deg = the CSV's alpha_true_deg for %d sites, max diff " \
        "%.1e" % (len(ALL), g6(lo), g6(hi), len(got), err)


register("R11a", "angle column: frame_in true with angle_deg 'auto' and no angle_column, on alpha_per_site.csv "
         "(which has no true-north column)", "prep exits other than 1, writes an output or staging directory, or "
         "does not name the column 'alpha_true_deg' (it would then use the magnetic alpha_deg, about 7.42 instead "
         "of about 1.02 deg)", refusal(rot("auto", frame="true", angle_file=ALPHA_CSV), "alpha_true_deg"))
register("R11b", "angle column: frame_in true with angle_column alpha_deg (the magnetic angle)", "prep exits other "
         "than 1, writes output, or does not say 'does not match frame_in true'",
         refusal(rot("auto", frame="true", angle_file=ALPHA_CSV, angle_column="alpha_deg"),
                 "does not match frame_in true"))
register("R11c", "angle column: frame_in magnetic with angle_column conv_pyproj_deg", "prep exits other than 1, "
         "writes output, or does not say 'does not match frame_in magnetic'",
         refusal(rot("auto", angle_file=ALPHA_CSV, angle_column="conv_pyproj_deg"), "does not match frame_in magnetic"))
register("R11d", "angle column, accepted case: frame_in true, 'auto', a CSV with alpha_true_deg = -conv_pyproj_deg",
         "prep exits non-zero, any of C01-C18 is not PASS, station_map.csv's rot_deg differs from the CSV's "
         "alpha_true_deg by more than 1e-9 for any of the 120 sites, or any rot_deg is outside (0.9, 1.1) deg", t_r11d)


def t_r12(prep, work):
    out = os.path.join(work, "run")
    rc, text, st = full(prep, config(work, "rot742", lambda c: None), out)
    if rc != 0:
        return False, "exit %d: %s" % (rc, text.strip()[-300:])

    def rd(p):
        with open(os.path.join(out, *p.split("/")), encoding="utf-8") as fh:
            return fh.read()
    inv, top, man = rd("inversion/README.md"), rd("README.md"), rd("prep_manifest.sha256")
    s = sha(prep)
    head = [ln for ln in man.splitlines() if ln.startswith("#")]
    res = {"inversion/README.md without 'not yet'": "not yet" not in inv,
           "inversion/README.md says it reuses mesh/vulcan_v2": "reuses the existing mesh of `mesh/vulcan_v2`" in inv,
           "inversion/README.md names the script sha256": s in inv,
           "README.md provenance row 'script' has it": re.search(r"^\| script \| `[^`]+`, sha256 %s " % s, top,
                                                                re.M) is not None,
           "manifest header '# written by ... sha256' has it": any(re.fullmatch(r"# written by \S+ sha256 %s" % s, h)
                                                                   for h in head)}
    return all(res.values()), "script under test sha256 %s; %s; manifest header %s" % (
        s[:16], "; ".join("%s: %s" % kv for kv in res.items()), head)


register("R12", "generated records of a mesh-reuse run (config/vulcan_mesh_v2_rot.yml): no 'not yet produced' mesh "
         "row, and the sha256 of the script under test in both READMEs and the manifest header",
         "inversion/README.md contains 'not yet' or does not say it reuses the existing mesh of mesh/vulcan_v2, "
         "either README lacks the sha256 of the script under test (README.md in its provenance row 'script'), or "
         "prep_manifest.sha256 has no header line '# written by <path> sha256 <that sha256>'", t_r12)


# ============================================================================================ mutants
APPLY = ("            zr, vr = rotate_Z(z4, v4, ang[sid])\n",)
SIGN = ("    M = np.kron(rot_matrix(-alpha_deg), rot_matrix(-alpha_deg))\n",)
NOAPPLY = ('    if c["rot"] is not None:\n        for rx, sid in enumerate(ids_z):\n',
           '    if False:\n        for rx, sid in enumerate(ids_z):\n', 1)
CHKROT = ("[e[\"var\"][cc][j] for cc in ZC], ang[sid])\n", "[e[\"var\"][cc][j] for cc in ZC], 0.0)\n", 1)
RECORD = ("        if not okr:\n            zbad.append(", "        if False:\n            zbad.append(", 1)
MUTANTS = [   # (id, what is broken, exact replacements, {test: checks that must be FAIL in its prep output},
              #  [tests shown still to PASS on it: another guard holds, recorded as an observation])
    ("MZ", "the rotation at angle 0 is not exact (alpha + 1e-3 deg)",
     [(APPLY[0], "            zr, vr = rotate_Z(z4, v4, ang[sid] + 1e-3)\n", 1)], {"R1": []}),
    ("MR1", "wrong sign: R(+alpha) instead of R(-alpha)",
     [(SIGN[0], "    M = np.kron(rot_matrix(alpha_deg), rot_matrix(alpha_deg))\n", 1)], {"R2": ["C08", "C15"]}),
    ("MR2", "the rotation applied twice",
     [(APPLY[0], "            zr, vr = rotate_Z(*rotate_Z(z4, v4, ang[sid]), ang[sid])\n", 1)], {"R2": ["C08"]}),
    ("MR3", "VAR not rotated (rotate_Z returns the input variances)",
     [("    return np.asarray(Z4, dtype=complex) @ M.T, np.asarray(var4, dtype=float) @ (M * M).T\n",
       "    return np.asarray(Z4, dtype=complex) @ M.T, np.asarray(var4, dtype=float)\n", 1)], {"R2": ["C09", "C15"]}),
    ("MR3b", "VAR not rotated (build writes the unrotated variances back)",
     [("zr[:, i].real, zr[:, i].imag, vr[:, i]\n", "zr[:, i].real, zr[:, i].imag, v4[:, i]\n", 1)], {"R2": ["C09"]}),
    ("MR4", "R Z R instead of R Z R^T (not a similarity transform)",
     [(SIGN[0], "    M = np.kron(rot_matrix(-alpha_deg), rot_matrix(-alpha_deg).T)\n", 1)],
     {"R2": ["C08", "C15", "C16"], "R3": []}),
    ("MR5", "the refusal of frame_in magnetic without an angle removed",
     [('            if fin != "grid":\n                fail("config: data.rotation.frame_in is %s but angle_deg',
       '            if False:\n                fail("config: data.rotation.frame_in is %s but angle_deg', 1)],
     {"R7a": []}),
    ("MR6", "the rotation not applied in build", [NOAPPLY], {"R2": ["C08"]}),
    ("MR9", "station_map.csv rot_deg written as 0",
     [('",%s" % g(ang[sid]) if rotated else ""', '",%s" % g(0.0) if rotated else ""', 1)], {"R2": ["C08"]}),
    ("MR10", "the manifest header dropped (both lines: script sha256 and data.rotation)",
     [('        write_manifest(stage, ("written by %s sha256 %s" % (ctx["script_rel"], ctx["script_sha"]),) +\n'
       '                       (() if c["rot"] is None else (rotation_text(c, ctx["rot_deg"]),)))\n',
       "        write_manifest(stage)\n", 1)], {"R2": [], "R12": []}),
    ("MR11", "C17 always passes", [("crit17, not diff and used and not bad_in and okp,", "crit17, True,", 1)],
     {"R8": []}),
    ("MR14", "'auto' ignores the CSV (7.42 for every site)",
     [("    return {i: tab[i] for i in ids}\n", "    return {i: 7.42 for i in ids}\n", 1)], {"R6": []}),
    ("MR15", "C08/C09 compare against the UNrotated EDI tensor", [CHKROT], {"R5a": []}, ["R5c"]),
    ("MR15+MR16", "C08/C09 compare against the unrotated tensor and C08 ignores station_map.csv rot_deg",
     [CHKROT, RECORD], {"R5c": []}),
    ("MR6+MR15", "rotation neither applied nor checked (the feature silently off)", [NOAPPLY, CHKROT],
     {"R2": [], "R4": []}),
    ("MR17", "the 'auto' angle file is checked only inside build (after the staging directory exists)",
     [('        ang0 = rotation_angles(c, sorted(e["dataid"] for e in edis.values()))\n',
       '        ang0 = {e["dataid"]: 0.0 for e in edis.values()}\n', 1)], {"R7e": []}),
    ("MR18", "frame_in grid with a non-zero angle accepted",
     [('            if fin == "grid" and ang != 0:\n', '            if False:\n', 1)], {"R7b": []}),
    ("MR19", "unknown data.rotation keys accepted", [("        if unknown:\n", "        if False:\n", 1)], {"R7c": []}),
    ("MR20", "'auto' without angle_file not refused up front", [("            if not af:\n", "            if False:\n", 1)],
     {"R7d": []}),
    ("MR21", "data.rotation accepted under schema prep_vulcan/1",
     [('    if (c["rot"] is not None or c["reuse_from"] is not None) and cfg["schema"] != "prep_vulcan/2":\n',
       '    if False:\n', 1)], {"R9a": []}),
    # 2026-09-28 follow-ups: frame guard C18, the angle column of 'auto', the generated records
    ("MR22", "C18 always passes", [('           "frame", ok, det)\n', '           "frame", True, det)\n', 1)],
     {"R10a": [], "R10b": [], "R10c": [], "R10e": []}),
    ("MR25", "C18 ignores ZROT", [('        nz = [v for v in fr["zrot"] if not abs(v) <= TOL_FRAME_DEG]\n',
                                   '        nz = []\n', 1)], {"R10a": [], "R10e": []}),
    ("MR26", "C18 ignores DECLINATION", [('    if frame_in != "true":\n', '    if False:\n', 1)], {"R10b": []}),
    ("MR27", "C18 ignores AZM", [('            if not abs((a - want + 180.0) % 360.0 - 180.0) <= TOL_FRAME_DEG:\n',
                                  '            if False:\n', 1)], {"R10c": []}),
    ("MR30", "C18 requires DECLINATION 0 under frame_in true too (the documented exception removed)",
     [('    if frame_in != "true":\n', '    if True:\n', 1)], {"R10d": []}),
    ("MR23", "'auto' takes alpha_deg whatever frame_in is (the behaviour before the fix)",
     [("            want = ROT_ANGLE_COLUMN[fin]\n", '            want = "alpha_deg"\n', 1)],
     {"R11a": [], "R11b": [], "R11d": []}),
    ("MR24", "angle_column not compared with frame_in", [("            if col != want:\n", "            if False:\n", 1)],
     {"R11b": [], "R11c": []}, ["R11a"]),
    ("MR28", "inversion/README.md says 'not yet' for the mesh whatever mesh.reuse_from is",
     [('from ../files |" if not ru else\n', 'from ../files |" if True else\n', 1)], {"R12": []}),
    ("MR31", "the recorded script sha256 is not the script's",
     [('        ctx["script_sha"] = sha256(os.path.abspath(__file__))', '        ctx["script_sha"] = "0" * 64', 1)],
     {"R12": []}),
]


def section_m():
    with open(ARGS.prep, encoding="utf-8", newline="") as fh:
        src = fh.read()
    mdir = os.path.join(ARGS.work, "mutants")
    os.makedirs(mdir)
    main_out = LAST.get("742")
    for mid, what, reps, must, *still in MUTANTS:
        text, missing = src, []
        for old, new, cnt in reps:
            n = text.count(old)
            if n != cnt:
                missing.append("%r occurs %d times, expected %d" % (old.strip()[:60], n, cnt))
            text = text.replace(old, new)
        path = os.path.join(mdir, "prep_vulcan_%s.py" % mid.replace("+", "_"))
        with open(path, "w", encoding="utf-8", newline="") as fh:
            fh.write(text)
        built = not missing and text != src
        say("\n[M] mutant %s: %s; %s" % (mid, what, "built, sha256 %s" % sha(path)[:16] if built else
                                          "NOT BUILT: %s" % missing))
        LAST["742"], LAST["st"] = main_out, {}
        for tid in (still[0] if still else []):
            ok_t, obs_t = (TESTS[tid][2](path, os.path.join(ARGS.work, "mut", "%s_%s" % (mid.replace("+", "_"), tid)))
                           if built else (False, "mutant not built: %s" % missing))
            info("M %s/%s" % (mid, tid), "%s on %s alone: %s: %s (a second guard still holds, so this mutant alone "
                 "cannot show %s failing)" % (tid, mid, "PASS" if ok_t else "FAIL", obs_t[:300], tid))
        for tid, checks in must.items():
            name, crit, fn = TESTS[tid]
            label = "M %s/%s" % (mid, tid)
            say("\n[%s] %s must FAIL on mutant %s%s\n  This test fails if the mutant cannot be built, or %s still "
                "PASSes on it%s" % (label, tid, mid, "" if not checks else " with %s FAIL" % "+".join(checks), tid,
                                    "" if not checks else ", or any of %s is not FAIL in its prep output" %
                                    "/".join(checks)))
            if not built:
                ok, obs = False, "mutant not built: %s" % missing
            else:
                LAST["st"] = {}
                try:
                    ok_t, obs_t = fn(path, os.path.join(ARGS.work, "mut", "%s_%s" % (mid.replace("+", "_"), tid)))
                except Exception as e:
                    ok_t, obs_t = False, "harness exception: %r" % (e,)
                st = LAST.get("st", {}) if tid == "R2" else {}
                miss = [c for c in checks if st.get(c) != "FAIL"]
                ok = (not ok_t) and not miss
                obs = "%s on %s: %s%s: %s" % (tid, mid, "PASS" if ok_t else "FAIL",
                                              "" if not checks else " (%s)" % " ".join(
                                                  "%s=%s" % (c, st.get(c)) for c in ALL if st.get(c) != "PASS"),
                                              obs_t[:400])
            say("  -> %s: %s" % ("PASS" if ok else "FAIL", obs))
            RESULTS.append((label, "%s must FAIL on %s" % (tid, mid), bool(ok), obs))
    LAST["742"] = main_out


def main():
    global ARGS
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("work")
    ap.add_argument("--prep", default=os.path.join(REPO, "scripts", "prep_vulcan.py"))
    ap.add_argument("--skip-mutants", action="store_true")
    ap.add_argument("--old-prep", help="a prep_vulcan.py from before data.rotation (for R9b)")
    ap.add_argument("--only", help="comma-separated section-R test ids to run alone (no observations, no section "
                    "M), e.g. to show new tests FAILING on an older --prep before they PASS on the current one")
    ARGS = ap.parse_args()
    ARGS.work, ARGS.prep = os.path.abspath(ARGS.work), os.path.abspath(ARGS.prep)
    if os.path.exists(ARGS.work) and os.listdir(ARGS.work):
        sys.exit("WORKDIR %s is not empty" % ARGS.work)
    os.makedirs(ARGS.work, exist_ok=True)
    say("rot_prep_checks.py: prep under test %s (sha256 %s); python %s; numpy %s" % (
        ARGS.prep, sha(ARGS.prep)[:16], sys.version.split()[0], np.__version__))
    say("repository %s; config/vulcan_mesh_v2_rot.yml sha256 %s; alpha_per_site.csv sha256 %s" % (
        REPO, sha(os.path.join(REPO, "config", "vulcan_mesh_v2_rot.yml"))[:16], sha(ALPHA_CSV)[:16]))
    if ARGS.only:
        for tid in ARGS.only.split(","):
            test(tid.strip())
        return summary()
    for tid in ("R1", "R2", "R3", "R4", "R5a", "R5b", "R5c", "R6", "R7a", "R7b", "R7c", "R7d", "R7e", "R8", "R9a",
                "R10a", "R10b", "R10c", "R10d", "R10e", "R11a", "R11b", "R11c", "R11d", "R12"):
        test(tid)
    if ARGS.old_prep:
        ARGS.old_prep = os.path.abspath(ARGS.old_prep)
        test("R9b")
        test("R9c")
    info("R4 per-component change (7.42 deg, written files)", LAST.get("moved", "(R4 did not run)"))
    info("R6 per-site against single angle", LAST.get("auto", "(R6 did not run)"))
    if not ARGS.skip_mutants:
        section_m()
    return summary()


def summary():
    say("\n==== summary ====")
    for label, name, ok, obs in RESULTS:
        say("  %-5s %-16s %s" % ("-" if ok is None else ("PASS" if ok else "FAIL"), label, name[:90]))
    n = [r for r in RESULTS if r[2] is not None]
    bad = [r for r in n if not r[2]]
    say("%d tests: %d PASS, %d FAIL; %d observations" % (len(n), len(n) - len(bad), len(bad), len(RESULTS) - len(n)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
