#!/usr/bin/env python3
"""inject_and_check.py -- show that each prep_vulcan.py self-check, its --force guard and its DISTORTION guard
can FAIL, and that each passes on the clean case (CLAUDE.md Invariant 10: a test that cannot fail is not a test).

    python validation/prep_checks_2026-09-28/inject_and_check.py WORKDIR [--prep PATH] [--skip-mutants]

WORKDIR must be absent or empty. Everything is written below it: a fixture of 6 real Vulcan EDIs, the v2
config cut down to those sites, and one run directory per test. The repository is only read (the EDIs, the
site table, config/vulcan_mesh_v2.yml, mesh/vulcan_v2 as a layout sample, the vendored femticPy).
--prep picks the script under test (default: scripts/prep_vulcan.py of this repository). Pointed at an
older copy it shows which tests that version fails; give --skip-mutants then, because the mutants are
built from the current script's text.

Every test prints "This test fails if ..." before it runs. Each injection must change the very file it
targets (checked by sha256), so a no-op injection cannot pass as a negative control. Light: every prep run
is single-threaded Python on 6 sites. No FEMTIC, no mesh tools. Exit status 0 only if every test meets its
expectation.

Sections: A clean runs (and C03 with an explicit origin); B the five named injections (C04, C06, C08, C09);
C negative controls; D one injection for every other check; N C06/C08/C09 N/A when nothing was compared;
E full-run faults for C03 and C05, which are N/A under --check-only; F the --force guard; J links on the
path (junction or symlink aliases); K the staging marker after a late abort; L refusals of delete_plan,
called directly with its directory walk replaced by a sentinel; G DISTORTION; H the J6_BxRepaced rename;
I dead config keys; M mutants: copies of the script under test with one guard disabled by an exact text
replacement, on which the named F, J, K, L or N test must FAIL. M is what shows each guard test can fail.
"""
import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys

import yaml

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
SITES = ["A1", "J5", "J6_BxRepaced", "J7", "Vul24-19", "Vul25_004"]
CHECKS = ["C%02d" % k for k in range(1, 15)]
N_CHECKS = 18          # check lines prep prints: C01-C18 (C15-C17 came with data.rotation, C18 with the frame guard)
sys.dont_write_bytecode = True     # section I imports the script under test in-process: no __pycache__ next to it
PRODUCTS = ("inversion/observe.dat", "inversion/control.dat", "inversion/station_map.csv")   # + files/*
OBS = "inversion/observe.dat"
RESULTS = []
ARGS = None


def say(msg=""):
    print(msg, flush=True)


def sha(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def is_link(p):
    isj = getattr(os.path, "isjunction", None)
    return os.path.islink(p) or bool(isj and isj(p))


def tree(d, pre=""):
    """{relative path: sha256} of every file below d; a link is recorded as 'LINK -> target', never entered"""
    out = {}
    for e in sorted(os.scandir(d), key=lambda e: e.name):
        r = pre + e.name
        if is_link(e.path):
            out[r] = "LINK -> %s" % os.path.realpath(e.path)
        elif e.is_dir(follow_symlinks=False):
            out.update(tree(e.path, r + "/"))
        else:
            out[r] = sha(e.path)
    return out


def run(args, env=None):
    # -B: the FAULT and DP wrappers import the script under test, which would leave a __pycache__ next to it
    p = subprocess.run([sys.executable, "-B"] + args, capture_output=True, text=True, cwd=REPO, env=env)
    return p.returncode, p.stdout.replace("\r\n", "\n"), p.stderr.replace("\r\n", "\n")


def prep(*args):
    return run([ARGS.prep] + list(args))


def statuses(text):
    return dict((c, s) for s, c in re.findall(r"\[(PASS|FAIL|N/A)\]\s+(C\d\d)\b", text))


def line_of(text, cid):
    m = re.search(r"\[(?:PASS|FAIL|N/A)\]\s+%s\b.*" % cid, text)
    return m.group(0)[:260] if m else "(no %s line)" % cid


def test(group, name, criterion, fn):
    """fn() -> (ok, observed). The failure criterion is printed before the test runs."""
    say("\n[%s] %s\n  This test fails if %s" % (group, name, criterion))
    try:
        ok, obs = fn()
    except Exception as e:                                   # a crash is a failed test, never a pass
        ok, obs = False, "harness exception: %r" % (e,)
    say("  -> %s: %s" % ("PASS" if ok else "FAIL", obs))
    RESULTS.append((group, name, bool(ok), obs))
    return ok


def info(group, name, text):
    say("\n[%s] %s (observation, not a test)\n  %s" % (group, name, text))
    RESULTS.append((group, name, None, text))


# =========================================================================================== fixture
def make_fixture(name, edit_cfg=None, rename=None, dataid=None):
    """WORK/name: edi/ (6 real EDIs, optionally renamed or with a changed DATAID), site_coords.txt (their
    rows of Vulcan/site_coords_femticpy.txt) and config/fixture.yml (config/vulcan_mesh_v2.yml with the paths
    and sites.expected_count changed, then edit_cfg)."""
    rename, dataid = rename or {}, dataid or {}
    fx = os.path.join(ARGS.work, name)
    os.makedirs(os.path.join(fx, "edi"))
    os.makedirs(os.path.join(fx, "config"))
    for s in SITES:
        with open(os.path.join(REPO, "Vulcan", "Processed_Data", s + ".edi"), "rb") as fh:
            b = fh.read()
        new = rename.get(s, s)
        if new != s:                                           # DATAID, LOC, REFLOC, SECTID all hold the id
            b = b.replace(b'"%s"' % s.encode(), b'"%s"' % new.encode())
        if s in dataid:
            b = re.sub(rb'DATAID\s*=\s*"[^"]*"', b'DATAID="%s"' % dataid[s].encode(), b, count=1)
        with open(os.path.join(fx, "edi", new + ".edi"), "wb") as fh:
            fh.write(b)
    rows = {}
    with open(os.path.join(REPO, "Vulcan", "site_coords_femticpy.txt"), encoding="utf-8") as fh:
        for ln in fh:
            p = ln.split("#", 1)[0].split()
            if p:
                rows[p[0]] = p
    with open(os.path.join(fx, "site_coords.txt"), "w", encoding="utf-8", newline="\n") as fh:
        for s in SITES:
            fh.write("%s %s %s %s\n" % (rename.get(s, s), rows[s][1], rows[s][2], rows[s][3]))
    with open(os.path.join(REPO, "config", "vulcan_mesh_v2.yml"), encoding="utf-8") as fh:
        cfg = yaml.safe_load(fh)
    cfg["name"] = "vulcan_fixture"
    cfg["paths"] = {"root": "..", "edi_dir": "edi", "coords_file": "site_coords.txt",
                    "femticpy_src": os.path.join(REPO, "external", "femticPy", "src"), "run_dir": "out/run"}
    cfg["sites"]["expected_count"] = len(SITES)
    if edit_cfg:
        edit_cfg(cfg)
    cp = os.path.join(fx, "config", "fixture.yml")
    with open(cp, "w", encoding="utf-8", newline="\n") as fh:
        yaml.safe_dump(cfg, fh, sort_keys=False)
    return fx, cp


def fresh(slug, src=None):
    """a copy of the clean run directory (or of src) at WORK/runs/slug"""
    d = os.path.join(ARGS.work, "runs", slug)
    shutil.copytree(src or CLEAN, d)
    return d


# ====================================================================================== file editing
def read_lines(p):
    with open(p, encoding="utf-8", newline="") as fh:
        return fh.read().split("\n")


def write_lines(p, L):
    with open(p, "w", encoding="utf-8", newline="") as fh:
        fh.write("\n".join(L))


def set_token(line, i, fn):
    """replace the i-th whitespace-separated token of line by fn(token), leaving every other byte alone"""
    parts = re.split(r"(\s+)", line)
    toks = [k for k, v in enumerate(parts) if v and not v.isspace()]
    parts[toks[i]] = fn(parts[toks[i]])
    return "".join(parts)


def observe_index(L):
    """{station id: (header line index, [data line indices])} for the MT and the VTF block"""
    out, i = {"MT": {}, "VTF": {}}, 0
    while i < len(L):
        t = L[i].split()
        if len(t) == 2 and t[0] in ("MT", "VTF"):
            blk, n, i = t[0], int(t[1]), i + 1
            for _ in range(n):
                nf = int(L[i + 1].split()[0])
                out[blk][int(L[i].split()[0])] = (i, list(range(i + 2, i + 2 + nf)))
                i += 2 + nf
            continue
        i += 1
    return out["MT"], out["VTF"]


def edit_observe(d, fn):
    p = os.path.join(d, "inversion", "observe.dat")
    L = read_lines(p)
    mt, vtf = observe_index(L)
    fn(L, mt, vtf)
    write_lines(p, L)


def edit_file(d, rel, fn):
    p = os.path.join(d, *rel.split("/"))
    L = read_lines(p)
    fn(L)
    write_lines(p, L)


# observe.dat data line: 0 f | 1-8 Re/Im Zxx Zxy Zyx Zyy | 9-16 Re/Im SE of the same (prep_vulcan.run_checks)
def neg(v):
    return v[1:] if v.startswith("-") else "-" + v


def inj_flip_im_zxy(d):
    def f(L, mt, vtf):
        r = mt[1][1][0]
        L[r] = set_token(L[r], 4, neg)
    edit_observe(d, f)


def inj_scale_se(d):                                  # both Re and Im SE of Zxy, so the Re/Im-equality test
    def f(L, mt, vtf):                                # in C09 is not what trips; the value comparison is
        r = mt[1][1][0]
        for k in (11, 12):
            L[r] = set_token(L[r], k, lambda v: "%.4e" % (float(v) * 1.01))
    edit_observe(d, f)


def inj_move_station(dist_km):
    def inj(d):                                       # the MT station AND its dummy VTF H-station, so C04
        def f(L, mt, vtf):                            # trips on the 1 m position test, not on the x y string
            for blk, sid in ((mt, 1), (vtf, 1001)):   # equality of the VTF station
                h = blk[sid][0]
                L[h] = set_token(L[h], -2, lambda v: "%.4f" % (float(v) + dist_km))
        edit_observe(d, f)
    inj.tfile = OBS
    return inj


def inj_freq(row, fn):
    def inj(d):
        def f(L, mt, vtf):
            r = mt[1][1][row]
            L[r] = set_token(L[r], 0, lambda v: "%.10e" % fn(float(v)))
        edit_observe(d, f)
    inj.tfile = OBS
    return inj


def inj_swap_map(whole):
    def inj(d):
        def f(L):
            if whole:
                L[1], L[2] = L[2], L[1]
            else:
                a, b = L[1].split(","), L[2].split(",")
                a[2], b[2] = b[2], a[2]
                L[1], L[2] = ",".join(a), ",".join(b)
        edit_file(d, "inversion/station_map.csv", f)
    inj.tfile = "inversion/station_map.csv"
    return inj


def inj_cr(d):
    p = os.path.join(d, "inversion", "control.dat")
    with open(p, "rb") as fh:
        b = fh.read()
    with open(p, "wb") as fh:
        fh.write(b.replace(b"\n", b"\r\n", 1))


def inj_drop_line(d):
    def f(L, mt, vtf):
        h, rows = mt[1]
        L[h + 1] = set_token(L[h + 1], 0, lambda v: str(int(v) - 1))
        del L[rows[-1]]
    edit_observe(d, f)


def inj_drop_line_all(d):
    """the last data line of EVERY MT station (and each count), so every station fails C07"""
    def f(L, mt, vtf):
        drop = []
        for h, rows in mt.values():
            L[h + 1] = set_token(L[h + 1], 0, lambda v: str(int(v) - 1))
            drop.append(rows[-1])
        for r in sorted(drop, reverse=True):
            del L[r]
    edit_observe(d, f)


def inj_conjugate_all(d):
    def f(L, mt, vtf):
        for h, rows in mt.values():
            for r in rows:
                for k in (2, 4, 6, 8):
                    L[r] = set_token(L[r], k, neg)
    edit_observe(d, f)


def inj_obs_site(d):
    edit_file(d, "files/obs_site.dat", lambda L: L.__setitem__(1, set_token(L[1], 0, lambda v: "%.4f" %
                                                                            (float(v) + 0.002))))


def inj_mtr(d):
    edit_file(d, "files/makeMtr.param", lambda L: L.__setitem__(3, set_token(L[3], 1, lambda v: "0.21")))


def inj_topo(d):
    edit_file(d, "files/topography.dat", lambda L: L.__setitem__(0, set_token(L[0], 2, lambda v: "0.001")))


def inj_tradeoff(d):
    def f(L):
        i = L.index("TRADE_OFF_PARAM")
        L[i + 1] = set_token(L[i + 1], 0, lambda v: "1")
    edit_file(d, "inversion/control.dat", f)


for _f, _t in ((inj_flip_im_zxy, OBS), (inj_scale_se, OBS), (inj_cr, "inversion/control.dat"),
               (inj_drop_line, OBS), (inj_drop_line_all, OBS), (inj_conjugate_all, OBS),
               (inj_obs_site, "files/obs_site.dat"), (inj_mtr, "files/makeMtr.param"),
               (inj_topo, "files/topography.dat"), (inj_tradeoff, "inversion/control.dat")):
    _f.tfile = _t                                              # the file injection() requires to change


def injection(group, name, target, fn, cfg=None, expect=True):
    """check-only on a fresh copy of the clean run after fn(copy). expect=True: target must FAIL.
    expect=False (negative control): every check must PASS or be N/A."""
    slug = re.sub(r"[^A-Za-z0-9]+", "_", "%s_%s" % (group, name)).strip("_")[:60]

    tf = fn.tfile                                              # the file this injection must change

    def body():
        d = fresh(slug)
        before = tree(d)
        fn(d)
        changed = sorted(k for k, v in tree(d).items() if before.get(k) != v)
        hit = tf in changed
        rc, out, err = prep(cfg or CFG, "--check-only", d)
        st = statuses(out)
        fails = [c for c in CHECKS if st.get(c) == "FAIL"]
        obs = "%s changed: %s (changed: %s); exit %d; FAIL %s; %d check lines" % (tf, hit, changed or "NOTHING", rc,
                                                                                  fails or "none", len(st))
        if expect:
            ok = hit and rc == 1 and st.get(target) == "FAIL"
        else:
            ok = hit and rc == 0 and not fails and len(st) == N_CHECKS
        return ok, obs + "; %s" % line_of(out, target)

    crit = ("the injection leaves %s unchanged, or prep --check-only does not exit 1 with %s FAIL" % (tf, target)
            if expect else "the injection leaves %s unchanged, or prep --check-only exits non-zero, reports "
            "any FAIL or does not report exactly %d checks (the check's tolerance should absorb this change: %s)" %
            (tf, N_CHECKS, target))
    test(group, name, crit, body)


# ========================================================================================== sections
FAULT = r'''
import importlib.util, sys
prep, mode = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("prep_under_test", prep)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
if mode == "C03":
    orig_imp = m.import_femticpy
    def imp(src):
        fp = orig_imp(src)
        orig_cd = fp.DataGen.center_data
        def cd(self):
            orig_cd(self)                                         # femticPy centres on the bbox centre;
            self.mt_coords["north"] -= 0.002                      # the fault: an origin 2 m further north,
            self.anchor = [self.anchor[0] + 0.002, self.anchor[1]]   # applied consistently to every site
        fp.DataGen.center_data = cd
        return fp
    m.import_femticpy = imp
elif mode == "C05":
    orig_sb, calls = m.select_bands, []
    def sb(*a, **k):
        chosen, table = orig_sb(*a, **k)
        calls.append(1)
        return (chosen[:-1] if len(calls) == 1 else chosen), table   # the femticPy path loses its lowest band
    m.select_bands = sb
elif mode in ("CR", "ADD"):
    import os
    orig_wr = m.write_readmes
    def wr(c, ctx, stage, final, ck):
        orig_wr(c, ctx, stage, final, ck)
        if mode == "CR":                          # a CR written after the self-checks: only the late CR
            with open(os.path.join(stage, "README.md"), "ab") as fh:        # scan can see it
                fh.write(b"late CR\r\n")
        else:                                     # someone copies a mesh into the run directory while prep
            with open(os.path.join(final, "inversion", "mesh.dat"), "w") as fh:      # is running
                fh.write("added during the run\n")
    m.write_readmes = wr
sys.exit(m.main(sys.argv[3:]))
'''


def section_e():
    for cid, what in (("C03", "femticPy centres the sites on a point 2 m north of the bbox centre (consistently, "
                               "so C04 and C11 cannot see it)"),
                      ("C05", "the femticPy path drops its lowest selected band")):
        def body(cid=cid):
            out_dir = os.path.join(ARGS.work, "runs", "E_full_" + cid)
            rc, out, err = run(["-c", FAULT, ARGS.prep, cid, CFG, "--out", out_dir])
            st = statuses(out)
            fails = [c for c in CHECKS if st.get(c) == "FAIL"]
            ok = rc == 1 and st.get(cid) == "FAIL" and not os.path.exists(out_dir)
            return ok, "exit %d; FAIL %s; output dir created: %s; %s" % (rc, fails, os.path.exists(out_dir),
                                                                        line_of(out, cid))
        test("E", "full run, %s: %s" % (cid, what), "prep exits 0, %s is not FAIL, or the output directory is "
             "created" % cid, body)


def manifest_ok(d):
    """(ok, text): d/prep_manifest.sha256 lists every other file of d, each with its sha256"""
    p = os.path.join(d, "prep_manifest.sha256")
    if not os.path.isfile(p):
        return False, "no prep_manifest.sha256"
    listed = {}
    with open(p, encoding="utf-8") as fh:
        for ln in fh:
            if ln.startswith("#") and not listed:     # header comments (script sha256, data.rotation) come first
                continue
            h, r = ln.rstrip("\n").split("  ", 1)
            listed[r] = h
    t = tree(d)
    t.pop("prep_manifest.sha256")
    bad = sorted(r for r in set(t) | set(listed) if t.get(r) != listed.get(r))
    return not bad, "%d files listed, %d mismatches %s" % (len(listed), len(bad), bad[:5])


def add_foreign(d):
    files = {"inversion/mesh.dat": "dummy mesh\n", "inversion/resistivity_block_iter0.dat": "dummy block\n",
             "halfspace/acc_3/b1/femtic_0.log": "dummy log\n", "mesh_logs/products.md5": "0 mesh.dat\n"}
    for r, txt in files.items():
        p = os.path.join(d, *r.split("/"))
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(txt)
    return files


def make_link(target, link):
    try:
        os.symlink(target, link, target_is_directory=True)
        return "symlink"
    except (OSError, NotImplementedError):
        import _winapi                                        # Windows without symlink privilege: a junction
        _winapi.CreateJunction(target, link)
        return "junction"


# ================================================================ registered tests (re-run on mutants in M)
TESTS, ORDER = {}, []


def reg(tid, group, title, criterion):
    """register a test by id, so section M can run the very same test against a mutant of the script"""
    def deco(fn):
        TESTS[tid] = (group, "%s %s" % (tid, title), criterion, fn)
        ORDER.append(tid)
        return fn
    return deco


def run_group(group):
    for tid in ORDER:
        g, title, crit, fn = TESTS[tid]
        if g == group:
            test(g, title, crit, fn)


def G(*parts):
    """a path below WORK/guard (created on demand, so a mutant run gets its own tree)"""
    p = os.path.join(ARGS.work, "guard")
    os.makedirs(p, exist_ok=True)
    return os.path.join(p, *parts)


@reg("F1", "F", "--force on an unchanged prep directory replaces it", "prep exits non-zero, or the replaced "
     "directory lacks a prep_manifest.sha256 that lists every file in it with a matching sha256")
def f1():
    d = fresh("F1_clean_force")
    rc, out, err = prep(CFG, "--out", d, "--force")
    ok_m, t = manifest_ok(d)
    return rc == 0 and ok_m, "exit %d; %s; %s" % (rc, t, (err.strip() or out.strip().splitlines()[-1])[:200])


@reg("F2", "F", "--force refuses a directory holding mesh products and half-space runs", "prep exits 0, any "
     "file of the directory is deleted or changed, or the listing does not name inversion/mesh.dat, "
     "inversion/resistivity_block_iter0.dat, halfspace/ and mesh_logs/")
def f2():
    d = fresh("F2_foreign")
    add_foreign(d)
    before = tree(d)
    rc, out, err = prep(CFG, "--out", d, "--force")
    same = tree(d) == before
    named = all(s in out for s in ("inversion/mesh.dat", "inversion/resistivity_block_iter0.dat", "halfspace/",
                                   "mesh_logs/"))
    return (rc == 1 and same and named, "exit %d; directory unchanged: %s; refusal names the 4 foreign entries: "
            "%s; %s" % (rc, same, named, err.strip()[:220]))


@reg("F3", "F", "--force refuses when a prep product was edited since", "prep exits 0, the directory changes, "
     "or the edited observe.dat is not listed as CHANGED")
def f3():
    d = fresh("F3_changed")
    inj_flip_im_zxy(d)                                         # a hand edit of a prep product
    before = tree(d)
    rc, out, err = prep(CFG, "--out", d, "--force")
    same = tree(d) == before
    listed = "CHANGED inversion/observe.dat" in out
    return rc == 1 and same and listed, "exit %d; directory unchanged: %s; 'CHANGED inversion/observe.dat' " \
        "listed: %s" % (rc, same, listed)


@reg("F4", "F", "--force --force-delete-foreign deletes the foreign files", "prep exits non-zero, a foreign "
     "file survives, or the new manifest does not verify")
def f4():
    d = fresh("F4_foreign_ok")
    foreign = add_foreign(d)
    rc, out, err = prep(CFG, "--out", d, "--force", "--force-delete-foreign")
    left = [r for r in foreign if os.path.exists(os.path.join(d, *r.split("/")))]
    ok_m, t = manifest_ok(d)
    return rc == 0 and not left and ok_m, "exit %d; foreign files left %s; %s; %s" % (rc, left, t,
                                                                                    err.strip()[:200])


def link_inside(flags):
    def body():
        tag = "F5_link_" + str(len(flags))
        d = fresh(tag)
        outside = G(tag + "_outside")
        os.makedirs(outside)
        with open(os.path.join(outside, "keep.txt"), "w", encoding="utf-8", newline="\n") as fh:
            fh.write("outside the run directory\n")
        kind = make_link(outside, os.path.join(d, "inversion", "linked"))
        before, before_d = tree(outside), tree(d)
        rc, out, err = prep(CFG, "--out", d, *flags)
        link_there = os.path.lexists(os.path.join(d, "inversion", "linked"))
        same_out = tree(outside) == before
        same_d = os.path.isdir(d) and tree(d) == before_d
        refused = "refusing to delete" in err
        return (rc == 1 and refused and link_there and same_out and same_d,
                "%s; exit %d; refused: %s; link kept: %s; target untouched: %s; run dir intact: %s; %s" %
                (kind, rc, refused, link_there, same_out, same_d, err.strip()[:160]))
    return body


for _tid, _flags in (("F5a", ["--force"]), ("F5b", ["--force", "--force-delete-foreign"])):
    reg(_tid, "F", "a link inside the run directory, %s" % " ".join(_flags), "prep exits other than 1 without "
        "'refusing to delete', or the link, its target's files or the run directory's files are touched")(
        link_inside(_flags))


def fixture_root(tag, flags):
    def body():
        fx, cp = make_fixture("fixture_" + tag)
        before = tree(fx)
        rc, out, err = prep(cp, "--out", fx, *flags)
        same = os.path.isdir(fx) and tree(fx) == before
        refused = "refusing to delete" in err
        return rc == 1 and refused and same, "exit %d; refused: %s; fixture (config, EDIs) unchanged: %s; %s" % (
            rc, refused, same, err.strip()[:200])
    return body


for _tid, _flags in (("F6a", ["--force"]), ("F6b", ["--force", "--force-delete-foreign"])):
    reg(_tid, "F", "--out = the fixture root (holds the config and the EDIs), %s" % " ".join(_flags),
        "prep exits other than 1 without 'refusing to delete', or any fixture file is deleted or changed")(
        fixture_root(_tid, _flags))


@reg("F7", "F", "an existing RUN.staging without prep's marker is not deleted", "prep exits 0 or deletes the "
     "unmarked staging directory's notes.txt")
def f7():
    out_dir = G("F7", "run")
    os.makedirs(out_dir + ".staging")
    note = os.path.join(out_dir + ".staging", "notes.txt")
    with open(note, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("not prep's\n")
    rc, out, err = prep(CFG, "--out", out_dir)
    kept = os.path.isfile(note)
    return rc == 1 and kept, "exit %d; notes.txt kept: %s; %s" % (rc, kept, err.strip()[:200])


@reg("F8", "F", "a stale RUN.staging with prep's marker is replaced", "prep exits non-zero, the stale staging "
     "directory survives, or the run directory is not written")
def f8():
    out_dir = G("F8", "run")
    os.makedirs(out_dir + ".staging")
    for fn in (".prep_vulcan_staging", "prep.log"):
        with open(os.path.join(out_dir + ".staging", fn), "w", encoding="utf-8", newline="\n") as fh:
            fh.write("left by a failed run\n")
    rc, out, err = prep(CFG, "--out", out_dir)
    gone = not os.path.exists(out_dir + ".staging")
    return rc == 0 and gone and os.path.isdir(out_dir), "exit %d; stale staging removed: %s; %s" % (
        rc, gone, err.strip()[:160])


@reg("F9", "F", "no --force on an existing directory", "prep exits 0 or changes the directory")
def f9():
    d = fresh("F9_noforce")
    before = tree(d)
    rc, out, err = prep(CFG, "--out", d)
    same = tree(d) == before
    return rc == 1 and same, "exit %d; unchanged: %s; %s" % (rc, same, err.strip()[:200])


@reg("F10", "F", "--force on a copy of the committed mesh/vulcan_v2 (no manifest, halfspace/, mesh_logs/)",
     "prep exits 0, the copy changes, or the listing does not name halfspace/, mesh_logs/ and the missing "
     "manifest")
def f10():
    d = os.path.join(ARGS.work, "runs", "F10_legacy_v2")
    shutil.copytree(os.path.join(REPO, "mesh", "vulcan_v2"), d)
    before = tree(d)
    rc, out, err = prep(CFG, "--out", d, "--force")
    same = tree(d) == before
    named = all(s in out for s in ("halfspace/", "mesh_logs/", "no prep_manifest.sha256"))
    return rc == 1 and same and named, "exit %d; unchanged: %s; lists halfspace/, mesh_logs/ and 'no " \
        "prep_manifest.sha256': %s; %d files in the copy" % (rc, same, named, len(before))


@reg("F11", "F", "--force-delete-foreign without --force", "prep exits 0 or writes the output")
def f11():
    d = G("F11_run")
    rc, out, err = prep(CFG, "--out", d, "--force-delete-foreign")
    return rc == 1 and not os.path.exists(d), "exit %d; output written: %s; %s" % (rc, os.path.exists(d),
                                                                                  err.strip()[:160])


def reinventory_abort(slug):
    """--force on a fresh copy of the clean run while a mesh.dat is dropped into it mid-run (FAULT 'ADD').
    Returns (rc, err, d, before, what went wrong or '')"""
    d = fresh(slug)
    before = tree(d)
    rc, out, err = run(["-c", FAULT, ARGS.prep, "ADD", CFG, "--out", d, "--force"])
    added = os.path.join(d, "inversion", "mesh.dat")
    after = tree(d)
    after.pop("inversion/mesh.dat", None)
    bad = []
    if rc != 1 or "changed during the run" not in err:
        bad.append("exit %d without 'changed during the run'" % rc)
    if not os.path.isfile(added):
        bad.append("the added mesh.dat is gone")
    if after != before:
        bad.append("original files changed")
    return rc, err, d, before, "; ".join(bad)


@reg("F12", "F", "the re-inventory: a mesh.dat copied into the run directory during a --force run stops it",
     "prep exits 0, or the added mesh.dat or any original file of the directory is deleted or changed")
def f12():
    rc, err, d, before, bad = reinventory_abort("F12_reinventory")
    return not bad, "exit %d; %s; %s" % (rc, bad or "aborted, mesh.dat and the originals kept", err.strip()[:200])


@reg("F13", "F", "a git repository nested in the run directory", "prep exits other than 1 without 'contains a "
     "git repository', or any file of the directory is deleted or changed")
def f13():
    d = fresh("F13_nested_git")
    os.makedirs(os.path.join(d, "halfspace", ".git"))
    with open(os.path.join(d, "halfspace", ".git", "HEAD"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("ref: refs/heads/main\n")
    before = tree(d)
    rc, out, err = prep(CFG, "--out", d, "--force", "--force-delete-foreign")
    same = os.path.isdir(d) and tree(d) == before
    msg = "contains a git repository" in err
    return rc == 1 and msg and same, "exit %d; message: %s; unchanged: %s; %s" % (rc, msg, same,
                                                                                 err.strip()[:160])


# ------------------------------------------------------------------------- J: links on the path (aliases)
def aliased(tag):
    """WORK/<tag>_real/fixture (a full fixture) and WORK/<tag>_alias -> WORK/<tag>_real (symlink, or a junction
    as mklink /J makes it where symlinks need a privilege). Returns (real, alias, fixture, config, kind)."""
    fx, cp = make_fixture(tag + "_real/fixture")
    real, alias = os.path.dirname(fx), os.path.join(ARGS.work, tag + "_alias")
    kind = make_link(real, alias)
    return real, alias, fx, cp, kind


@reg("J1", "J", "--out reaches the fixture root through a linked parent (alias/fixture), config by its real "
     "path, --force --force-delete-foreign", "prep exits other than 1 without 'refusing to delete', or any "
     "file below the real directory is deleted, changed or added")
def j1():
    real, alias, fx, cp, kind = aliased("J1")
    before = tree(real)
    rc, out, err = prep(cp, "--out", os.path.join(alias, "fixture"), "--force", "--force-delete-foreign")
    same = tree(real) == before
    refused = "refusing to delete" in err
    return rc == 1 and refused and same, "%s; exit %d; refused: %s; real tree unchanged: %s; %s" % (
        kind, rc, refused, same, err.strip()[:220])


@reg("J2", "J", "the config is given through a linked parent (alias/fixture/config/fixture.yml), --out is the "
     "real fixture root, --force --force-delete-foreign", "prep exits other than 1 without 'refusing to delete', "
     "or any file below the real directory is deleted, changed or added")
def j2():
    real, alias, fx, cp, kind = aliased("J2")
    before = tree(real)
    cp_alias = os.path.join(alias, "fixture", "config", "fixture.yml")
    rc, out, err = prep(cp_alias, "--out", fx, "--force", "--force-delete-foreign")
    same = tree(real) == before
    refused = "refusing to delete" in err
    return rc == 1 and refused and same, "%s; exit %d; refused: %s; real tree unchanged: %s; %s" % (
        kind, rc, refused, same, err.strip()[:220])


@reg("J3", "J", "--out reaches an ordinary run directory with foreign files through a linked parent, "
     "--force --force-delete-foreign", "prep exits other than 1 without 'refusing to delete', or any file of "
     "the real run directory is deleted, changed or added")
def j3():
    real, alias = os.path.join(ARGS.work, "J3_real"), os.path.join(ARGS.work, "J3_alias")
    d = os.path.join(real, "run")
    shutil.copytree(CLEAN, d)
    add_foreign(d)
    kind = make_link(real, alias)
    before = tree(real)
    rc, out, err = prep(CFG, "--out", os.path.join(alias, "run"), "--force", "--force-delete-foreign")
    same = tree(real) == before
    refused = "refusing to delete" in err
    return rc == 1 and refused and same, "%s; exit %d; refused: %s; real run dir unchanged: %s; %s" % (
        kind, rc, refused, same, err.strip()[:220])


# ------------------------------------------------------------------ K: the staging marker after a late abort
def rerun_after_abort(out_dir, force):
    """the next, unpatched run on the same --out: (ok, text)"""
    stage = out_dir + ".staging"
    marked = os.path.isfile(os.path.join(stage, ".prep_vulcan_staging"))
    rc, out, err = prep(CFG, "--out", out_dir, *(["--force"] if force else []))
    false_msg = "not created by this version" in (out + err)
    removed = "left by an earlier run" in out
    ok_m, t = manifest_ok(out_dir)
    gone = not os.path.exists(stage)
    ok = marked and rc == 0 and not false_msg and removed and gone and ok_m
    return ok, "staging kept its marker after the abort: %s; rerun exit %d; 'not created by this version': %s; " \
        "'left by an earlier run': %s; staging gone: %s; %s; %s" % (marked, rc, false_msg, removed, gone, t,
                                                                  err.strip()[:160])


@reg("K1", "K", "a run stopped by the late CR scan, then the same command again", "the first run does not exit "
     "1 with 'CR bytes', its RUN.staging lacks prep's marker afterwards, or the rerun exits non-zero, says 'not "
     "created by this version', leaves RUN.staging, or writes a run directory whose manifest does not verify")
def k1():
    out_dir = G("K1", "run")
    rc, out, err = run(["-c", FAULT, ARGS.prep, "CR", CFG, "--out", out_dir])
    if rc != 1 or "CR bytes" not in err:
        return False, "first run: exit %d without 'CR bytes': %s" % (rc, err.strip()[:200])
    return rerun_after_abort(out_dir, False)


@reg("K2", "K", "a --force run stopped by the re-inventory; the added mesh.dat is moved out, then the same "
     "command again", "the first run does not stop at the re-inventory, its RUN.staging lacks prep's marker "
     "afterwards, or the rerun exits non-zero, says 'not created by this version', leaves RUN.staging, or "
     "writes a run directory whose manifest does not verify")
def k2():
    rc, err, d, before, bad = reinventory_abort("K2_reinventory")
    if bad:
        return False, "first run: %s; %s" % (bad, err.strip()[:200])
    os.remove(os.path.join(d, "inversion", "mesh.dat"))
    return rerun_after_abort(d, True)


# ------------------------------------------- L: delete_plan refusals, called directly (it never deletes)
DP = r'''
import importlib.util, sys
prep, top, cfg = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("prep_under_test", prep)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
class Reached(Exception):
    pass
def sentinel(t):                          # the directory walk: reaching it means no refusal came first
    raise Reached(t)
m.inventory = sentinel
c = m.load_config(cfg)
try:
    m.delete_plan(top, c)
    print("RESULT returned a plan without refusing")
except m.PrepError as e:
    print("RESULT refused: %s" % e)
except Reached as e:
    print("RESULT reached the walk of %s without refusing" % e)
'''


def plan_refusal(top, expect, env=None):
    rc, out, err = run(["-c", DP, ARGS.prep, top, CFG], env=env)
    res = next((ln for ln in out.splitlines() if ln.startswith("RESULT")), "no RESULT line: %s" % err.strip()[:200])
    return res.startswith("RESULT refused") and expect in res, "top %s: %s" % (top, res[:260])


@reg("L1", "L", "delete_plan on a link (symlink or junction) as the directory itself", "delete_plan does not "
     "refuse with 'is a link' before walking the directory")
def l1():
    real, link = G("L1_real"), G("L1_link")
    os.makedirs(real)
    kind = make_link(real, link)
    ok, t = plan_refusal(link, "is a link")
    return ok, "%s; %s" % (kind, t)


@reg("L2", "L", "delete_plan on a directory inside a .git directory", "delete_plan does not refuse with 'inside "
     "a .git directory' before walking it")
def l2():
    top = G("L2_repo", ".git", "objects")
    os.makedirs(top)
    return plan_refusal(top, "inside a .git directory")


@reg("L3", "L", "delete_plan on the filesystem root of the scratch directory", "delete_plan does not refuse "
     "with 'filesystem root' before walking it")
def l3():
    return plan_refusal(os.path.splitdrive(ARGS.work)[0] + os.sep, "filesystem root")


@reg("L4", "L", "delete_plan on a directory that holds the home directory (HOME and USERPROFILE pointed into "
     "the scratch tree)", "delete_plan does not refuse with 'the home directory' before walking it")
def l4():
    home = G("L4_parent", "home")
    os.makedirs(home)
    env = dict(os.environ, HOME=home, USERPROFILE=home)
    return plan_refusal(os.path.dirname(home), "the home directory", env=env)


@reg("L5", "L", "delete_plan on the directory that holds the script under test", "delete_plan does not refuse "
     "with 'this script' before walking it")
def l5():
    return plan_refusal(os.path.dirname(os.path.abspath(ARGS.prep)), "this script")


# ------------------------------------------------------ N: C06, C08 and C09 when nothing could be compared
@reg("N1", "N", "every MT station loses its last data line (and its count), so every station fails C07",
     "observe.dat is unchanged, prep --check-only does not exit 1 with C07 FAIL, or any of C06, C08 and C09 is "
     "anything but N/A (they compared nothing, so a PASS would be vacuous)")
def n1():
    d = fresh("N1_all_fail_c07")
    before = tree(d)
    inj_drop_line_all(d)
    hit = tree(d).get(OBS) != before.get(OBS)
    rc, out, err = prep(CFG, "--check-only", d)
    st = statuses(out)
    ok = hit and rc == 1 and st.get("C07") == "FAIL" and all(st.get(c) == "N/A" for c in ("C06", "C08", "C09"))
    return ok, "observe.dat changed: %s; exit %d; %s; %s | %s" % (
        hit, rc, " ".join("%s=%s" % (c, st.get(c)) for c in ("C06", "C07", "C08", "C09")),
        line_of(out, "C06")[:140], line_of(out, "C08")[:140])


# -------------------------------------------------------------- M: mutants of the script under test
PROT = ("        if inside(p, top):\n", "        if False:\n", 1)
NOFORCE = ("                if not a.force:\n", "                if False:\n", 1)
REINV = ('            new = sorted(plan1["entries"] - (plan0["entries"] if plan0 else set()))\n',
         '            plan1 = dict(plan1, entries=set(), foreign=[], foreign_dirs=[])\n'
         '            new = sorted(plan1["entries"] - (plan0["entries"] if plan0 else set()))\n', 1)
ROOT = ("    if os.path.dirname(top) == top:\n", "    if False:\n", 1)
ABSP = ("os.path.normcase(os.path.realpath(path)), os.path.normcase(os.path.realpath(anc))",
        "os.path.normcase(os.path.abspath(path)), os.path.normcase(os.path.abspath(anc))", 1)
TOPONLY = ("    links_up = link_components(top)\n", "    links_up = [top] if is_link(top) else []\n", 1)
MUTANTS = [   # (id, what is disabled, exact replacements, tests that must FAIL, tests shown still to PASS)
    ("M1", "links inside the directory no longer refused", [("    if links:\n", "    if False:\n", 1)],
     ["F5a", "F5b"], []),
    ("M2", "the protected-path check removed (repository, config, inputs, script, home)", [PROT],
     ["F6a", "F6b", "L4", "L5"], []),
    ("M3", "foreign files refused even with --force-delete-foreign",
     [("                    if not a.force_delete_foreign:\n", "                    if True:\n", 1)], ["F4"], []),
    ("M4", "--force-delete-foreign accepted without --force",
     [("        if a.force_delete_foreign and not a.force:\n", "        if False:\n", 1)], ["F11"], []),
    ("M5", "the up-front refusal of an existing directory without --force removed", [NOFORCE], [], ["F9"]),
    ("M7", "the re-inventory just before the delete made blind", [REINV], ["F12"], []),
    ("M5+M7", "both refusals of a run without --force removed", [NOFORCE, REINV], ["F9"], []),
    ("M6", "the staging marker ignored",
     [("    marked = owned_by_marker and os.path.isfile(os.path.join(top, STAGE_MARK))\n",
       "    marked = False\n", 1)], ["F8", "K1", "K2"], []),
    ("M8", "the staging marker dropped before the CR scan and the re-inventory (the round-1 order)",
     [("        os.remove(os.path.join(stage, STAGE_MARK))\n        try:\n", "        try:\n", 1),
      ("        write_readmes(c, ctx, stage, run_dir, ck)\n",
       "        write_readmes(c, ctx, stage, run_dir, ck)\n        os.remove(os.path.join(stage, STAGE_MARK))\n", 1)],
     ["K1", "K2"], []),
    ("M9", "inside() compares abspath instead of realpath", [ABSP], ["J2"], ["J1"]),
    ("M10", "only the directory itself is tested for a link, not its parents", [TOPONLY], ["J3"], ["J1"]),
    ("M11", "M9 + M10, i.e. the round-1 guard logic", [ABSP, TOPONLY], ["J1", "J2", "J3"], []),
    ("M12", "the '.git on the path' refusal removed",
     [('    if ".git" in re.split(', '    if False and ".git" in re.split(', 1)], ["L2"], []),
    ("M13", "the filesystem-root refusal removed (the protected-path check still refuses the root, with another "
     "message)", [ROOT], ["L3"], []),
    ("M13+M2", "the filesystem-root refusal and the protected-path check removed", [ROOT, PROT], ["L3"], []),
    ("M14", "a nested .git no longer refused", [("    if gits:\n", "    if False:\n", 1)], ["F13"], []),
    ("M15", "C06, C08 and C09 PASS on zero comparisons (the round-1 behaviour)",
     [("(not fbad) if ncmp else None", "not fbad", 1), ("(not zbad) if total else None", "not zbad", 1),
      ("(not sbad) if total else None", "not sbad", 1)], ["N1"], []),
    ("M16", "no link test on the path at all", [("    links_up = link_components(top)\n", "    links_up = []\n", 1)],
     ["L1"], []),
]


def on_mutant(tid, path, work):
    """run registered test tid with ARGS.prep = path and a fresh ARGS.work; (ok, observed)"""
    saved = ARGS.prep, ARGS.work
    ARGS.prep, ARGS.work = path, work
    try:
        os.makedirs(work)
        return TESTS[tid][3]()
    except Exception as e:                                   # a crash is a failed test, never a pass
        return False, "harness exception: %r" % (e,)
    finally:
        ARGS.prep, ARGS.work = saved


def section_m():
    mdir = os.path.join(ARGS.work, "mutants")
    os.makedirs(mdir)
    with open(ARGS.prep, encoding="utf-8", newline="") as fh:
        src = fh.read()
    for mid, what, reps, must_fail, still_pass in MUTANTS:
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
        for tid in must_fail:
            def body(tid=tid, mid=mid, path=path, built=built, missing=missing):
                if not built:
                    return False, "mutant not built: %s" % missing
                ok, obs = on_mutant(tid, path, os.path.join(ARGS.work, "mut", "%s_%s" % (mid, tid)))
                return not ok, "%s on %s: %s: %s" % (tid, mid, "PASS" if ok else "FAIL", obs)
            test("M", "%s (%s): %s must FAIL" % (mid, what, tid), "the mutant cannot be built from the script "
                 "under test, or %s still PASSes on it (so %s would not notice this guard missing)" % (tid, tid),
                 body)
        for tid in still_pass:
            ok, obs = on_mutant(tid, path, os.path.join(ARGS.work, "mut", "%s_%s" % (mid, tid))) if built else \
                (False, "mutant not built: %s" % missing)
            info("M", "%s alone: %s on it" % (mid, tid), "%s: %s (a second guard still holds: defence in depth, "
                 "so this mutant alone cannot show %s failing)" % ("PASS" if ok else "FAIL", obs, tid))



def section_g():
    def edit(cfg):
        cfg["inversion"]["DISTORTION"] = 1
        cfg["inversion"]["TRADE_OFF_PARAM"] = [3.0, 1.0]
    fx, cp = make_fixture("fixture_distortion1", edit_cfg=edit)

    def body():
        out_dir = os.path.join(fx, "out", "run")
        rc, out, err = prep(cp, "--out", out_dir)
        msg = "DISTORTION 1 is not supported" in err
        return rc == 1 and msg and not os.path.exists(out_dir), "exit %d; message: %s; output written: %s; %s" % (
            rc, msg, os.path.exists(out_dir), err.strip()[:200])
    test("G", "G1 DISTORTION 1 (with its two TRADE_OFF_PARAM values) is rejected by load_config",
         "prep exits 0, writes an output directory, or does not say 'DISTORTION 1 is not supported'", body)


def products(d):
    t = tree(d)
    return {k: v for k, v in t.items() if k in PRODUCTS or k.startswith("files/")}


def section_h():
    fx, cp = make_fixture("fixture_j6_renamed", rename={"J6_BxRepaced": "J6_BxReplaced"})

    def body():
        out_dir = os.path.join(fx, "out", "run")
        rc, out, err = prep(cp, "--out", out_dir)
        if rc != 0:
            return False, "prep failed on the renamed fixture: %s" % err.strip()[:200]
        a, b = products(CLEAN), products(out_dir)
        diff = sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))
        L0 = read_lines(os.path.join(CLEAN, "inversion", "station_map.csv"))
        L1 = read_lines(os.path.join(out_dir, "inversion", "station_map.csv"))
        rows = [k for k in range(max(len(L0), len(L1))) if (L0[k:k + 1] or [""])[0] != (L1[k:k + 1] or [""])[0]]
        ok = diff == ["inversion/station_map.csv"] and len(rows) == 1 and "J6_BxReplaced" in L1[rows[0]]
        return ok, "products that differ: %s; station_map rows that differ: %s -> %r" % (
            diff, rows, [L1[k] for k in rows])
    test("H", "H1 renaming J6_BxRepaced -> J6_BxReplaced (EDI file, DATAID/LOC/REFLOC/SECTID, site table)",
         "observe.dat, inversion/control.dat or any files/* differ from the clean run, or station_map.csv "
         "differs in any row but J6's", body)

    def body2():
        names = sorted(os.path.splitext(f)[0] for f in os.listdir(os.path.join(REPO, "Vulcan", "Processed_Data"))
                       if f.endswith(".edi"))
        ren = sorted("J6_BxReplaced" if n == "J6_BxRepaced" else n for n in names)
        i0, i1 = names.index("J6_BxRepaced"), ren.index("J6_BxReplaced")
        return len(names) == 120 and i0 == i1, "%d EDIs; station number %d before, %d after (%s < J6 < %s)" % (
            len(names), i0 + 1, i1 + 1, names[i0 - 1], names[i0 + 1])
    test("H", "H2 the rename keeps J6's FEMTIC station number among all 120 EDIs (femticPy numbers stations in "
         "np.sort order of the EDI file names; site rows are sorted by id)",
         "J6's index in the sorted list of the 120 EDI names changes", body2)


def section_i():
    import importlib.util
    spec = importlib.util.spec_from_file_location("prep_for_keys", ARGS.prep)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    read = set()

    class T(dict):
        def __init__(self, d, pre):
            super().__init__({k: (T(v, pre + (k,)) if isinstance(v, dict) else v) for k, v in d.items()})
            self.pre = pre

        def __getitem__(self, k):
            read.add(".".join(self.pre + (k,)))
            return super().__getitem__(k)

        def get(self, k, default=None):
            read.add(".".join(self.pre + (k,)))
            return super().get(k, default)

    real = m.yaml.safe_load
    m.yaml.safe_load = lambda fh: T(real(fh), ())
    m.load_config(os.path.join(REPO, "config", "vulcan_mesh_v2.yml"))
    m.yaml.safe_load = real
    with open(os.path.join(REPO, "config", "vulcan_mesh_v2.yml"), encoding="utf-8") as fh:
        cfg = yaml.safe_load(fh)

    def leaves(d, pre=()):
        for k, v in d.items():
            if isinstance(v, dict):
                yield from leaves(v, pre + (k,))
            else:
                yield ".".join(pre + (k,))
    unread = [k for k in leaves(cfg) if k not in read]
    info("I", "I0 keys of config/vulcan_mesh_v2.yml that load_config never reads", unread or "none")

    def setkey(dotted, val):
        def edit(c):
            cur = c
            ks = dotted.split(".")
            for k in ks[:-1]:
                cur = cur[k]
            cur[ks[-1]] = val
        return edit

    for dotted, val, live in (("data.error_floor_Z", [0.2, 0.06, 0.06, 0.2], True),
                              ("inversion.NUM_THREADS", 4, True),
                              ("data.error_floor_VTF", 0.5, False),
                              ("sites.utm_zone", 54, False),
                              ("sites.hemisphere", "N", False),
                              ("sites.datum", "GDA94", False),
                              ("mesh.topography.dem_file", "no_such_dem.txt", False)):
        def body(dotted=dotted, val=val, live=live):
            tag = "I_" + dotted.replace(".", "_")
            fx, cp = make_fixture("fixture_" + tag, edit_cfg=setkey(dotted, val))
            out_dir = os.path.join(fx, "out", "run")
            rc, out, err = prep(cp, "--out", out_dir)
            if rc != 0:
                return False, "prep failed: %s" % err.strip()[:200]
            a, b = products(CLEAN), products(out_dir)
            diff = sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))
            return (bool(diff) == live), "products that differ from the clean run: %s" % (diff or "none")
        if live:
            test("I", "%s -> %r changes the products (positive control of the comparison)" % (dotted, val),
                 "no product file (observe.dat, control.dat, station_map.csv, files/*) differs", body)
        else:
            test("I", "%s -> %r leaves every product unchanged (dead key)" % (dotted, val),
                 "any product file (observe.dat, control.dat, station_map.csv, files/*) differs", body)


def main():
    global ARGS, CLEAN, CFG
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("work", help="scratch directory, absent or empty")
    ap.add_argument("--prep", default=os.path.join(REPO, "scripts", "prep_vulcan.py"))
    ap.add_argument("--skip-mutants", action="store_true", help="skip section M (for an older --prep)")
    ARGS = ap.parse_args()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(newline="\n")                 # LF logs on Windows too
    ARGS.work, ARGS.prep = os.path.abspath(ARGS.work), os.path.abspath(ARGS.prep)
    if os.path.exists(ARGS.work) and os.listdir(ARGS.work):
        sys.exit("%s is not empty" % ARGS.work)
    os.makedirs(ARGS.work, exist_ok=True)
    say("prep under test: %s (sha256 %s)" % (ARGS.prep, sha(ARGS.prep)[:16]))
    say("repository: %s; python %s (%s) on %s" % (REPO, sys.version.split()[0], sys.executable, sys.platform))
    say("fixture sites: %s" % ", ".join(SITES))
    fx, CFG = make_fixture("fixture")
    CLEAN = os.path.join(fx, "out", "clean")

    # ---- A clean
    def a1():
        rc, out, err = prep(CFG, "--out", CLEAN)
        st = statuses(out)
        ok = rc == 0 and [st.get(c) for c in CHECKS] == ["PASS"] * 14
        return ok, "exit %d; %s; %s" % (rc, " ".join("%s=%s" % (c, st.get(c)) for c in CHECKS),
                                       (out.strip().splitlines() or [""])[-1][:200])
    if not test("A", "A1 clean full run of the fixture", "prep exits non-zero or any of C01-C14 is not PASS "
                "(in a full run C03 and C05 compare against femticPy, so all 14 apply)", a1):
        say("clean run failed: nothing else can be tested")
        return summary()

    def a2():
        rc, out, err = prep(CFG, "--check-only", fresh("A2_clean_check_only"))
        st = statuses(out)
        exp = ["N/A" if c in ("C03", "C05") else "PASS" for c in CHECKS]
        ok = rc == 0 and [st.get(c) for c in CHECKS] == exp
        return ok, "exit %d; %s; %s" % (rc, " ".join("%s=%s" % (c, st.get(c)) for c in CHECKS),
                                       (out.strip().splitlines() or [""])[-1][:120])
    test("A", "A2 clean --check-only", "prep exits non-zero, C03 or C05 is anything but N/A (under --check-only "
         "they have no femticPy result to compare, so PASS would be vacuous), or any other check is not PASS", a2)

    def a3():
        fx3, cp3 = make_fixture("fixture_origin", edit_cfg=lambda c: c["sites"].__setitem__("origin",
                                                                                            [697.0, 6699.5]))
        rc, out, err = prep(cp3, "--out", os.path.join(fx3, "out", "run"))
        st = statuses(out)
        exp = ["N/A" if c == "C03" else "PASS" for c in CHECKS]
        return rc == 0 and [st.get(c) for c in CHECKS] == exp, "exit %d; %d check lines; %s; %s" % (
            rc, len(st), " ".join("%s=%s" % (c, st.get(c)) for c in CHECKS), line_of(out, "C03"))
    test("A", "A3 full run with an explicit sites.origin [697.0, 6699.5] km", "prep exits non-zero, C03 is not "
         "reported (it used to be skipped silently, giving 13 checks) or is anything but N/A, or any other check "
         "is not PASS", a3)

    # ---- B the five named injections
    injection("B", "B1 flip the sign of Im(Zxy), station 1, 100 Hz", "C08", inj_flip_im_zxy)
    injection("B", "B2 scale the Re and Im SE of Zxy by 1.01, station 1, 100 Hz", "C09", inj_scale_se)
    injection("B", "B3 move station 1 (and its dummy VTF H-station) 2 m north", "C04", inj_move_station(0.002))
    injection("B", "B4 frequency x (1 + 2e-6), station 1, 100 Hz", "C06", inj_freq(0, lambda f: f * (1 + 2e-6)))
    injection("B", "B5 swap the site_id fields of station_map.csv rows 1 and 2", "C04", inj_swap_map(False))
    injection("B", "B6 frequency + 1e-5 Hz at the lowest band (8e-3 relative), station 1", "C06",
              inj_freq(-1, lambda f: f + 1e-5))

    # ---- C negative controls
    injection("C", "C1 swap whole rows 1 and 2 of station_map.csv", "C04", inj_swap_map(True), expect=False)
    injection("C", "C2 frequency + 1e-5 Hz at 100 Hz (1e-7 relative), station 1", "C06",
              inj_freq(0, lambda f: f + 1e-5), expect=False)
    injection("C", "C3 frequency x (1 + 5e-7), station 1, 100 Hz", "C06", inj_freq(0, lambda f: f * (1 + 5e-7)),
              expect=False)
    injection("C", "C4 move station 1 (and its VTF H-station) 0.2 m north", "C04", inj_move_station(0.0002),
              expect=False)

    # ---- D the other checks
    injection("D", "D1 one CRLF in inversion/control.dat", "C01", inj_cr)
    def d2():
        fx2, cfg2 = make_fixture("fixture_dataid", dataid={"A1": "A1x"})
        changed = sha(os.path.join(fx2, "edi", "A1.edi")) != sha(os.path.join(fx, "edi", "A1.edi"))
        rc, out, err = prep(cfg2, "--check-only", fresh("D2_dataid"))
        st = statuses(out)
        fails = [c for c in CHECKS if st.get(c) == "FAIL"]
        return changed and rc == 1 and st.get("C02") == "FAIL", "EDI changed: %s; exit %d; FAIL %s; %s" % (
            changed, rc, fails, line_of(out, "C02"))
    test("D", "D2 DATAID of A1.edi changed to A1x (an input fault: a fixture copy of the EDIs)", "the EDI is "
         "unchanged, or prep --check-only does not exit 1 with C02 FAIL", d2)
    injection("D", "D3 drop the last data line of station 1 (and its count)", "C07", inj_drop_line)
    injection("D", "D4 conjugate every impedance (exp(+i omega t) left in)", "C10", inj_conjugate_all)
    injection("D", "D5 move site 1 of files/obs_site.dat 2 m", "C11", inj_obs_site)
    injection("D", "D6 makeMtr.param core edge 0.2 -> 0.21 km", "C12", inj_mtr)
    injection("D", "D7 one topography.dat height 0 -> 0.001 km (flat mode)", "C13", inj_topo)
    injection("D", "D8 inversion/control.dat TRADE_OFF_PARAM 3 -> 1", "C14", inj_tradeoff)

    run_group("N")
    section_e()
    for g in ("F", "J", "K", "L"):
        run_group(g)
    section_g()
    section_h()
    section_i()
    if ARGS.skip_mutants:
        say("\n[M] skipped (--skip-mutants)")
    else:
        section_m()
    return summary()


def summary():
    say("\n==== summary ====")
    say("| group | test | result | observed |")
    say("|---|---|---|---|")
    for g, n, ok, obs in RESULTS:
        say("| %s | %s | %s | %s |" % (g, n, "info" if ok is None else ("PASS" if ok else "FAIL"),
                                       str(obs).replace("|", "/")[:300]))
    tests = [r for r in RESULTS if r[2] is not None]
    bad = [r for r in tests if not r[2]]
    say("\n%d tests: %d PASS, %d FAIL" % (len(tests), len(tests) - len(bad), len(bad)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
