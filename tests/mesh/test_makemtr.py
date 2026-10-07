"""femtic_mesh.makemtr: the makeMtr port (makeMtr @df8e207).

No .mtr survives from any C++ run (mesh/chain_proof kept only the makeMtr logs; G0 on Phoenix keeps them) and makeMtr
may not run on this PC. So the port is checked against: (1) the C++'s own logs, line for line (chain_proof round 1,
vulcan_v2 round 1); (2) values derived by hand from the C++ formulas at chosen points; (3) an independent formula
(the centre-to-ellipsoid ray length |v| / sqrt(q), sites by "the smallest sphere holding the node") on real node sets
and on points packed around Vulcan's five-sphere sites; (4) the C++ error messages; (5) the study's N5 limits at v2
size. The byte golden (study B4 / TD5) is G0's output.1-5 with their .mtr.

  python tests/mesh/test_makemtr.py [test_name ...]
"""
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C  # noqa: E402
import numpy as np  # noqa: E402
from femtic_mesh import makemtr as M  # noqa: E402
from femtic_mesh.io import femtic as F  # noqa: E402
from femtic_mesh.io import tetgen as T  # noqa: E402

CP_IN = C.repo_file("mesh", "chain_proof", "inputs")
V2_IN = C.repo_file("mesh", "vulcan_v2", "files")
QUIET = lambda s: None  # noqa: E731
MUT_VAL1 = ("val1 = np.sqrt(3.0 * (rr * rr))", "val1 = rr")                      # the quirk 'fixed'
MUT_BASE = ("out[tr] = (ln - l0) / (l1 - l0) * (L[k] - L[k - 1]) + L[k - 1]",
            "out[tr] = (ln - l0) / (l1 - l0) * (L[k] - L[k - 1]) + L[k]")         # wrong base shell


def _inputs(folder):
    return (M.read_params(os.path.join(folder, "makeMtr.param"), QUIET),
            M.read_sites(os.path.join(folder, "obs_site.dat"), QUIET)[0])


def _port(cwd, root="output.1"):
    r = subprocess.run([sys.executable, "-m", "femtic_mesh.makemtr", root], cwd=cwd, env=C.port_env(),
                       capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr


def _case(d, inputs, nodes=None, fixture=False):
    for f in ("makeMtr.param", "obs_site.dat"):
        shutil.copyfile(os.path.join(inputs, f), os.path.join(d, f))
    if fixture:
        C.unpack_fixture(d)
    elif nodes is not None:
        n = len(nodes)
        T.write_node(os.path.join(d, "output.1.node"), T.NodeFile(np.arange(1, n + 1), np.asarray(nodes, float),
                                                                  np.zeros((n, 0))))
        T.write_ele(os.path.join(d, "output.1.ele"), T.EleFile(np.array([1]), np.array([[1, 2, 3, 4]]),
                                                               np.array([[20.0]])))


def _log_diff(port_log, cpp_log):
    a, b = port_log.splitlines(), open(cpp_log).read().splitlines()
    if len(a) != len(b):
        return [("length", len(a), len(b))]
    return [(i, x, y) for i, (x, y) in enumerate(zip(a, b)) if x != y]


def _only_counts(diff, want_port, want_cpp):
    """True if the only differing lines are 'Total number of nodes / elements' with these values."""
    keys = ("Total number of nodes : ", "Total number of elements : ")
    if len(diff) != 2 or any(len(t) != 3 or not t[1].startswith(keys[k]) or not t[2].startswith(keys[k])
                             for k, t in enumerate(diff)):
        return False
    return [int(t[1].split(":")[1]) for t in diff] == want_port and [int(t[2].split(":")[1]) for t in diff] == want_cpp


def test_log_matches_cpp_chain_proof():
    """This test fails if the port's stdout on chain_proof round 1 (the conda-forge round-0 fixture, the chain_proof
    makeMtr.param and obs_site.dat) differs from the C++ log mesh/chain_proof/logs/makeMtr_1.log in any line other
    than the two count lines, or if those lines do not hold each build's own tetgen counts (port 1,616 nodes / 7,938
    elements as tetgen_round0.log; C++ 1,605 / 7,879 as mesh/chain_proof/logs/tetgen_stp5.log).

    Negative control: obs_site.dat with one site radius changed (1.000 -> 1.001) must fail the comparison."""
    cpp = C.repo_file("mesh", "chain_proof", "logs", "makeMtr_1.log")
    with C.tmpdir() as d:
        _case(d, CP_IN, fixture=True)
        src = open(os.path.join(d, "obs_site.dat")).read()
        open(os.path.join(d, "obs_site.dat"), "w").write(src.replace("1.000 0.500 0.300", "1.001 0.500 0.300", 1))
        rc, out, _ = _port(d)
        C.expect_fail("one site radius 1.001", lambda: rc == 0 and _only_counts(_log_diff(out, cpp), [1616, 7938],
                                                                                 [1605, 7879]))
        open(os.path.join(d, "obs_site.dat"), "w").write(src)
        rc, out, err = _port(d)
        assert rc == 0, err
        diff = _log_diff(out, cpp)
        assert _only_counts(diff, [1616, 7938], [1605, 7879]), diff[:4]
        print(f"    {len(out.splitlines())} log lines equal the C++'s except the 2 count lines "
              "(1616/7938 vs 1605/7879)")


def test_log_matches_cpp_v2():
    """This test fails if the port's stdout on vulcan_v2's makeMtr.param (9 ellipsoids) and obs_site.dat (120 sites,
    5 spheres each, no line count) differs from the C++ log mesh/vulcan_v2/mesh_logs/makeMtr_1.log in any line other
    than the two count lines (a 4-node mesh stands in for output.1).

    Negative control: makeMtr.param with one earth oblateness changed (0.73 -> 0.74) must fail the comparison."""
    cpp = C.main_mesh("vulcan_v2", "mesh_logs", "makeMtr_1.log")
    with C.tmpdir() as d:
        _case(d, V2_IN, nodes=[[0, 0, 0], [1, 0, 0], [0, 1, 0], [0, 0, 1]])
        src = open(os.path.join(d, "makeMtr.param")).read()
        assert src.count(" 0.73 ") == 1
        open(os.path.join(d, "makeMtr.param"), "w").write(src.replace(" 0.73 ", " 0.74 "))
        rc, out, _ = _port(d)
        C.expect_fail("oblateness 0.74",
                      lambda: rc == 0 and _only_counts(_log_diff(out, cpp), [4, 1], [144681, 801832]))
        open(os.path.join(d, "makeMtr.param"), "w").write(src)
        rc, out, err = _port(d)
        assert rc == 0, err
        diff = _log_diff(out, cpp)
        assert _only_counts(diff, [4, 1], [144681, 801832]), diff[:4]
        print(f"    {len(out.splitlines())} log lines equal the C++'s except the 2 count lines")


HAND = [  # (point km, '%15.6e' by hand from the C++ formulas, why); chain_proof makeMtr.param and obs_site.dat
    ((0.0, 0.0, 0.0), "   2.000000e+00", "inside ellipsoid 0 (r 10, L 2); no site within 1 km"),
    ((10.0, 0.0, 0.0), "   2.000000e+00", "on shell 0: (10/10)^2 = 1 <= 1 counts as inside"),
    ((-7.5, -7.5, 0.69), "   5.000000e-01", "site sphere: (0.69/0.7)^2 = 0.97 <= 1 -> 0.5"),
    ((-6.5, -7.5, 0.0), "   5.000000e-01", "on the site sphere: (1/1)^2 = 1"),
    ((2.5, 2.5, -0.5), "   5.000000e-01", "site sphere, air side: (0.5/0.7)^2 = 0.51"),
    ((-7.5, -7.5, 0.71), "   2.094551e+00", "outside the site (1.03); shell 0-1: 2 + (10.6303387 - 10)/20 x 3"),
    ((20.0, 0.0, 0.0), "   3.500000e+00", "shell 0-1: 2 + (20 - 10)/20 x 3"),
    ((0.0, 0.0, 65.0), "   5.250000e+01", "shell 1-2: 5 + (65 - 30)/70 x 95"),
    ((0.0, 0.0, -200.0), "   1.000000e+02", "shell 2-3 in the air: 100 + 0"),
    ((400.0, 0.0, 0.0), "   1.000000e+02", "outside the last ellipsoid"),
]
HAND_V2 = [  # vulcan_v2: site 0 at (-1.697, -6.622, 0), spheres r 0.012/0.03/0.1/0.3/0.6, L 0.004/0.01/0.04/0.1/0.2
    ((-1.677, -6.622, 0.0), "   5.201155e-03", "spheres 0-1: 0.004 + 0.006 (0.02/0.012 - 1)/(sqrt(3) 2.5 - 1)"),
    ((-1.497, -6.622, 0.0), "   5.429881e-02", "spheres 2-3: 0.04 + 0.06 (0.2/0.1 - 1)/(sqrt(3) 3 - 1)"),
]


def _hand_ok(mod, cases, inputs):
    P = mod.read_params(os.path.join(inputs, "makeMtr.param"), QUIET)
    S, L = mod.read_sites(os.path.join(inputs, "obs_site.dat"), QUIET)
    v, err = mod.size_field(np.array([c[0] for c in cases]), P, S, L)
    got = ["%15.6e" % x for x in v]
    bad = [(c[0], g, c[1]) for c, g in zip(cases, got) if g != c[1]]
    assert err is None and not bad, bad
    return True


def test_hand_derived_values():
    """This test fails if any of 12 points gets a size other than the one derived by hand from the C++ formulas
    (main.cpp:516-554, 694-797; ObservationPoint.cpp:107-138): chain_proof's ellipsoid centre, a shell boundary,
    site spheres (earth and air side, on the sphere), three transition shells and the outside; two points between the
    spheres of a Vulcan five-sphere site, with the sqrt(3) quirk; or if the CLI's .mtr text differs from them.

    Negative controls: mutants with the wrong base shell in the transition (L[k] for L[k-1]) and with the site
    quirk 'fixed' (val1 = r[i+1]/r[i]) must each fail."""
    C.expect_fail("transition based on L[k]", _hand_ok, C.mutant("femtic_mesh.makemtr", [MUT_BASE]), HAND, CP_IN)
    C.expect_fail("val1 without sqrt(3)", _hand_ok, C.mutant("femtic_mesh.makemtr", [MUT_VAL1]), HAND_V2, V2_IN)
    _hand_ok(M, HAND, CP_IN)
    _hand_ok(M, HAND_V2, V2_IN)
    with C.tmpdir() as d:
        _case(d, CP_IN, nodes=[c[0] for c in HAND])
        rc, _, err = _port(d)
        assert rc == 0, err
        lines = open(os.path.join(d, "output.1.mtr")).read().splitlines()
        assert lines == ["%10d%10d" % (len(HAND), 1)] + [c[1] for c in HAND], lines
    print(f"    {len(HAND) + len(HAND_V2)} hand-derived sizes reproduced; the CLI's .mtr carries them")


def _reference(P, sites, xyz):
    """Independent field: ray length to each axis-aligned ellipsoid |v| / sqrt(q); a site's value from the smallest
    sphere holding the node. Returns (values, tie): tie marks nodes within 1e-12 of a sphere or shell surface."""
    X, Y, Z = xyz.T
    c, s = np.cos(-P["rot"]), np.sin(-P["rot"])
    u0, v0, w = X - P["c"][0], Y - P["c"][1], Z - P["c"][2]
    u, v = u0 * c - v0 * s, u0 * s + v0 * c
    a = P["r"]
    cz = np.where((w < 0)[None, :], (a * (1 - P["fa"]))[:, None], (a * (1 - P["fe"]))[:, None])
    with np.errstate(all="ignore"):
        q = (u[None] / a[:, None]) ** 2 + (v[None] / (a * (1 - P["fh"]))[:, None]) ** 2 + (w[None] / cz) ** 2
    n, ins = a.size, q <= 1
    k = np.where(ins.any(0), ins.argmax(0), n)
    rad = np.sqrt(u * u + v * v + w * w)
    e = np.where(k == 0, P["L"][0], P["L"][n - 1])
    t = np.flatnonzero((k > 0) & (k < n))
    kk = k[t]
    l0, l1 = rad[t] / np.sqrt(q[kk - 1, t]), rad[t] / np.sqrt(q[kk, t])
    e[t] = P["L"][kk - 1] + (rad[t] - l0) / (l1 - l0) * (P["L"][kk] - P["L"][kk - 1])
    tie = (np.abs(q - 1) < 1e-12).any(0)
    best = np.full(X.size, 1e20)
    for (sx, sy, sz), r, L, f in sites:
        qs = ((X - sx)[None] / r[:, None]) ** 2 + ((Y - sy)[None] / r[:, None]) ** 2 \
            + ((Z - sz)[None] / (r * (1 - f))[:, None]) ** 2
        tie |= (np.abs(qs - 1) < 1e-12).any(0)
        j = np.where((qs <= 1).any(0), (qs <= 1).argmax(0), -1)
        val = np.where(j == 0, L[0], 1e20)
        m = np.flatnonzero(j > 0)
        i = j[m] - 1
        val[m] = L[i] + (L[i + 1] - L[i]) * (np.sqrt(qs[i, m]) - 1) / (np.sqrt(3.0) * r[i + 1] / r[i] - 1)
        best = np.minimum(best, val)
    return np.minimum(best, e), tie


def _agrees(mod, P, S, xyz, what):
    got, err = mod.size_field(xyz, P, S)
    want, tie = _reference(P, S, xyz)
    g, w = np.array(["%15.6e" % x for x in got]), np.array(["%15.6e" % x for x in want])
    mis = np.flatnonzero(g != w)
    near = np.abs(got[mis] - want[mis]) <= 1e-12 * np.abs(want[mis])
    bad = mis[~near & ~tie[mis]]
    assert err is None and bad.size == 0, \
        f"{what}: {bad.size} unexplained of {xyz.shape[0]}, e.g. {g[bad[:2]]} vs {w[bad[:2]]}"
    return mis.size, int(near.sum())


def test_values_match_independent_formula():
    """This test fails if, on any node set, the port's 7-digit text differs from the independent formula's at a node
    that is neither at a rounding boundary (values within 1e-12 relative) nor on a sphere or shell surface (|q - 1| <
    1e-12). Node sets: chain_proof round 1 (conda-forge, 1,616), the chain_proof final mesh (4,705), 24,000 points
    around Vulcan's 120 five-sphere sites and 20,000 in Vulcan's 9 oblate shells; and the v2 final mesh (401,334).

    Negative controls: the two mutants of test_hand_derived_values must each fail here too (on round 1 and on the
    Vulcan site points)."""
    P, S = _inputs(CP_IN)
    P2, S2 = _inputs(V2_IN)
    with C.tmpdir() as d:
        r1 = T.read_node(C.unpack_fixture(d) + ".node").xyz
    rng = np.random.default_rng(7)
    sxyz = np.array([s[0] for s in S2])
    k = rng.integers(0, len(S2), 24000)
    near = sxyz[k] + rng.normal(0, 0.25, (24000, 3)) * [1, 1, 0.5]
    shells = rng.normal(0, 1, (20000, 3))
    shells *= (rng.uniform(9, 900, 20000) / np.linalg.norm(shells, axis=1))[:, None]
    C.expect_fail("transition based on L[k]", _agrees, C.mutant("femtic_mesh.makemtr", [MUT_BASE]), P, S, r1, "r1")
    C.expect_fail("val1 without sqrt(3)", _agrees, C.mutant("femtic_mesh.makemtr", [MUT_VAL1]), P2, S2, near, "sites")
    sets = [("chain_proof round 1", P, S, r1), ("Vulcan site points", P2, S2, near), ("Vulcan shells", P2, S2, shells)]
    cp = C.main_mesh("chain_proof", "mesh.dat")
    sets.append(("chain_proof final mesh", P, S, F.read_mesh_dat(cp).nodes / 1000.0))
    try:
        v2 = F.read_mesh_dat(C.need("vulcan_v2", "inversion", "mesh.dat")).nodes / 1000.0
        sets.append(("v2 final mesh", P2, S2, v2))
    except C.Skip as s:
        print(f"    (v2 final mesh skipped: {s})")
    for what, p, s, xyz in sets:
        n_mis, n_round = _agrees(M, p, s, xyz, what)
        print(f"    {what}: {xyz.shape[0]} nodes, {n_mis} text differences ({n_round} at a rounding boundary)")


def test_cli_error_paths():
    """This test fails if the port's CLI exits 0, writes a .mtr, or prints a message other than the C++'s for: no
    argument; no makeMtr.param; 0 spheres; a radius smaller than the previous one; a site with 0 spheres; an .ele
    without attributes; an edge length of 0 inside sphere 0 ('Edge length is too short', on stdout, as the C++).

    Negative control: the same check on the healthy case (chain_proof inputs, fixture round 1) must fail, i.e. the
    check sees a run that exits 0 and writes its .mtr."""
    def broken(d, edit):
        if edit == "noarg":
            r = subprocess.run([sys.executable, "-m", "femtic_mesh.makemtr"], cwd=d, env=C.port_env(),
                               capture_output=True, text=True)
            return r.returncode, r.stdout, r.stderr
        edit(d)
        return _port(d)

    def refused(d, msg, stream="err", edit=None):
        rc, out, err = broken(d, edit)
        text = err if stream == "err" else out
        assert rc == 1 and not os.path.exists(os.path.join(d, "output.1.mtr")) and msg in text, (rc, out[-200:], err)
        return True

    def param(txt):
        return lambda d: open(os.path.join(d, "makeMtr.param"), "w").write(txt)
    cases = [
        ("no argument", "You must specify node file name !!", "err", None),
        ("no makeMtr.param", "Cannot open file makeMtr.param", "err",
         lambda d: os.remove(os.path.join(d, "makeMtr.param"))),
        ("0 spheres", "Total number of spheres must be greater than zero.", "err", param("0 0 0\n0\n0\n")),
        ("radius decreasing", "Radius of the region 1 is smaller than that of the previous region.", "err",
         param("0 0 0\n0\n2\n10 2 0 0 0\n5 3 0 0 0\n")),
        ("site with 0 spheres", "Error : Total number of spheres less than 1. : 0", "err",
         lambda d: open(os.path.join(d, "obs_site.dat"), "w").write("1\n0 0 0\n0\n")),
        ("no attributes", "You must specify region attribute to elements.", "err",
         lambda d: open(os.path.join(d, "output.1.ele"), "w").write("1 4 0\n1 1 2 3 4\n")),
        ("edge length 0", "Edge length is too short 0.000000e+00", "out",
         param("0 0 0\n0\n2\n10 0 0 0 0\n30 5 0 0 0\n")),
    ]
    with C.tmpdir() as d0:
        _case(d0, CP_IN, fixture=True)
        C.expect_fail("healthy case", refused, d0, "", "err", lambda d: None)
    for what, msg, stream, edit in cases:
        with C.tmpdir() as d:
            _case(d, CP_IN, fixture=True)
            refused(d, msg, stream, "noarg" if edit is None else edit)
            print(f"    {what}: exit 1, no .mtr, '{msg}'")


def test_v2_size_time_and_memory():
    """This test fails if the port, run as `python -m femtic_mesh.makemtr` on a v2-size mesh (the v2 mesh.dat's 401,334
    nodes and 2,446,095 elements written as output.5.node/.ele, v2's inputs), takes more than 2 x the C++'s round 5
    (mesh/vulcan_v2/mesh_logs/makeMtr_5.time: 1.87 s for 424,462 nodes; study N5) or more than 1 GB peak RSS, or if
    its values differ from the in-process size_field.

    Negative control: a mutant without the per-site bounding-box pruning (every site against every node, the study's
    brute force) must exceed the time limit."""
    from femtic_mesh import backends, repartition
    m = F.read_mesh_dat(C.need("vulcan_v2", "inversion", "mesh.dat"))
    with C.tmpdir() as d:
        _case(d, V2_IN)
        n, e = m.n_nodes, m.n_elements
        T.write_node(os.path.join(d, "output.5.node"),
                     T.NodeFile(np.arange(1, n + 1), m.nodes / 1000.0, np.zeros((n, 0))))
        air = repartition.air_from_surface(m)
        T.write_ele(os.path.join(d, "output.5.ele"), T.EleFile(np.arange(1, e + 1), m.tets.astype(np.int64) + 1,
                                                               np.where(air, 10.0, 20.0)[:, None]))
        limit = 2 * 1.87
        brute = os.path.join(d, "brute.py")
        open(brute, "w").write("import sys\nfrom femtic_mesh import makemtr as M\n"
                               "src = open(M.__file__).read().replace('R, D = r.max() * (1 + 1e-6) + 1e-12, d.max() * "
                               "(1 + 1e-6) + 1e-12', 'R, D = 1e300, 1e300')\nexec(compile(src, M.__file__, 'exec'), "
                               "M.__dict__)\nsys.exit(M.main(['output.5']))\n")

        def within(argv):
            rc, wall, kb = backends.run_step(argv, d, os.path.join(d, "run.log"), C.port_env())
            name = " ".join(os.path.basename(a) for a in argv[1:])
            print(f"    {name}: rc {rc}, {wall:.2f} s, peak {kb / 1024:.0f} MB")
            assert rc == 0 and wall <= limit and kb <= 1024 * 1024, (rc, wall, kb)
            return True
        C.expect_fail("no bounding-box pruning", within, [sys.executable, brute])
        within([sys.executable, "-m", "femtic_mesh.makemtr", "output.5"])
        got = T.read_mtr(os.path.join(d, "output.5.mtr"))[:, 0]
        P, S = _inputs(d)
        want = np.array([float("%.6e" % x) for x in M.size_field(m.nodes / 1000.0, P, S)[0]])
        assert np.array_equal(got, want)


if __name__ == "__main__":
    sys.exit(1 if C.run(globals(), sys.argv[1:]) else 0)
