"""femtic_mesh.tetgen2femtic: the faithful TetGen2Femtic port.

No C++ TetGen2Femtic output exists for any tetgen file on this PC (rounds 1-5 need makeMtr; see
data/chain_proof_round0/README.md). So the port is checked two ways: (1) against the C++ products of
chain_proof, from tetgen-format files rebuilt out of the C++ mesh.dat; (2) on real tetgen output (round 0)
against independent geometric checks. The byte golden for real tetgen files is G0 on Phoenix.

  python tests/mesh/test_tetgen2femtic.py [test_name ...]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C  # noqa: E402
import numpy as np  # noqa: E402
from femtic_mesh import cells  # noqa: E402
from femtic_mesh import repartition as RP  # noqa: E402
from femtic_mesh import tetgen2femtic as T2F  # noqa: E402
from femtic_mesh.io import femtic as F  # noqa: E402
from femtic_mesh.io import tetgen as T  # noqa: E402


def _rebuild_tetgen_files(mesh, prefix, seed=11):
    """output.6.{node,ele,neigh,face} carrying exactly what TetGen2Femtic needs to recreate this mesh.dat.
    Face order: the 7 lists' entries interleaved at random (each list keeps its order); corners rotated or
    reflected at random. Returns the number of Earth-surface faces whose lowest-id element is the air one."""
    rng = np.random.default_rng(seed)
    n, m = mesh.n_nodes, mesh.n_elements
    T.write_node(prefix + ".node", T.NodeFile(ids=np.arange(1, n + 1), xyz=mesh.nodes / 1000.0, attrs=np.zeros((n, 0))))
    air = RP.air_from_surface(mesh)
    T.write_ele(prefix + ".ele", T.EleFile(ids=np.arange(1, m + 1), tets=mesh.tets.astype(np.int64) + 1,
                                           attrs=np.where(air, 10.0, 20.0)[:, None]))
    T.write_neigh(prefix + ".neigh", T.NeighFile(ids=np.arange(1, m + 1),
                                                 neigh=np.where(mesh.neigh >= 0, mesh.neigh + 1, -1).astype(np.int64)))
    labels = np.concatenate([np.full(len(f), k) for k, f in enumerate(mesh.faces)])
    rng.shuffle(labels)
    nxt = [0] * 7
    tri = np.empty((labels.size, 3), dtype=np.int64)
    for i, k in enumerate(labels.tolist()):
        e, f = mesh.faces[k][nxt[k]]
        nxt[k] += 1
        t = mesh.tets[e, T2F._FACE_NODES[f]] + 1
        t = np.roll(t, rng.integers(3))
        tri[i] = t[::-1] if rng.integers(2) else t
    T.write_face(prefix + ".face", T.FaceFile(ids=np.arange(1, labels.size + 1), tri=tri,
                                              markers=np.full(labels.size, -1)))
    s = mesh.faces[6]
    across = mesh.neigh[s[:, 0], s[:, 1]]
    return int((across < s[:, 0]).sum())


def _port_matches(prefix, out, attr, golden_dir):
    T2F.convert(prefix, out, attr, log=None)
    for name, gold in [("mesh.dat", "mesh.dat"), ("resistivity_block_iter0.dat", "resistivity_block_iter0.dat"),
                       ("output.6.femtic.vtk", "output.6.femtic.vtk")]:
        ok, at = C.same_bytes(os.path.join(out, name), os.path.join(golden_dir, gold))
        assert ok, f"port's {name} differs from the C++ {gold} at byte {at}"
    return True


def test_port_reproduces_chain_proof():
    """This test fails if the port, fed output.6.{node,ele,neigh,face} rebuilt from the C++ chain_proof mesh.dat
    (nodes as m/1000 at %.17g, neighbours, attributes 10/20 from the flood fill, the 7 face lists' triangles in
    shuffled order with shuffled corners), does not write mesh.dat, resistivity_block_iter0.dat and
    output.6.femtic.vtk byte-identical to TetGen2Femtic's.

    Negative controls: a mutant port numbering local faces wrongly (face k opposite node k+1), and a perturbed
    input with one earth element under the surface relabelled air, must each make the comparison fail."""
    golden = os.path.dirname(C.need("chain_proof", "mesh.dat"))
    attr = C.repo_file("mesh", "chain_proof", "inputs", "resistivity_attr.dat")
    mesh = F.read_mesh_dat(os.path.join(golden, "mesh.dat"))
    with C.tmpdir() as d:
        prefix = os.path.join(d, "output.6")
        nswap = _rebuild_tetgen_files(mesh, prefix)
        keep = T2F._FACE_NODES
        T2F._FACE_NODES = np.roll(keep, 1, axis=0)
        try:
            C.expect_fail("mutant port: local face k opposite node k+1", _port_matches, prefix,
                          os.path.join(d, "m"), attr, golden)
        finally:
            T2F._FACE_NODES = keep
        el = T.read_ele(prefix + ".ele")
        e = int(mesh.faces[6][0, 0])
        el.attrs[e, 0] = 10.0
        T.write_ele(prefix + ".x.ele", el)
        os.replace(prefix + ".ele", prefix + ".ele.ok")
        os.replace(prefix + ".x.ele", prefix + ".ele")
        C.expect_fail(f"element {e} relabelled air", _port_matches, prefix, os.path.join(d, "p"), attr, golden)
        os.replace(prefix + ".ele.ok", prefix + ".ele")
        _port_matches(prefix, os.path.join(d, "out"), attr, golden)
        print(f"    mesh.dat, block file and VTK byte-identical to the C++; {nswap} of {len(mesh.faces[6])} "
              "Earth-surface faces took the air-element branch (MeshData.cpp:1137-1154)")


_PORT_RUN = """
import sys, time
sys.path.insert(0, sys.argv[4])
from femtic_mesh import tetgen2femtic as T2F
t = time.perf_counter()
T2F.convert(sys.argv[1], sys.argv[2], sys.argv[3], log=None)
wall = time.perf_counter() - t
try:
    import psutil
    mi = psutil.Process().memory_info()
    peak = getattr(mi, "peak_wset", mi.rss) / 2**20
except ImportError:
    peak = -1
print(f"{wall:.2f} {peak:.1f}")
"""


def test_port_reproduces_v2():
    """This test fails if the port, fed output.6.* rebuilt (as above) from the C++ vulcan_v2 mesh.dat
    (2,446,095 tets, 9 ellipsoids, 120 two-circle sites), does not write mesh.dat, resistivity_block_iter0.dat
    and the 329 MB output.6.femtic.vtk byte-identical to TetGen2Femtic's, or (study N5) if the port alone
    takes more than 2 x the C++ wall time (mesh_logs/t2f.time, 11.79 s) or more than 1 GB peak RSS.

    Negative control: the same run with one earth element under the surface relabelled air must differ."""
    golden = os.path.dirname(C.need("vulcan_v2", "inversion", "mesh.dat"))
    gvtk = C.need("vulcan_v2", "vtk", "output.6.femtic.vtk")
    attr = C.repo_file("mesh", "vulcan_v2", "files", "resistivity_attr.dat")
    ref = open(C.repo_file("mesh", "vulcan_v2", "mesh_logs", "t2f.time")).read().split()
    c_wall = float(ref[0])
    mesh = F.read_mesh_dat(os.path.join(golden, "mesh.dat"))
    with C.tmpdir() as d:
        prefix = os.path.join(d, "output.6")
        nswap = _rebuild_tetgen_files(mesh, prefix)
        e = int(mesh.faces[6][0, 0])
        del mesh
        el = T.read_ele(prefix + ".ele")
        el.attrs[e, 0] = 10.0
        os.makedirs(os.path.join(d, "bad"))
        T.write_ele(os.path.join(d, "bad", "output.6.ele"), el)
        del el
        for x in ("node", "face", "neigh"):
            C.link_or_copy(prefix + "." + x, os.path.join(d, "bad", "output.6." + x))
        T2F.convert(os.path.join(d, "bad", "output.6"), os.path.join(d, "bad", "out"), attr, vtk=False, log=None)
        C.expect_fail(f"element {e} relabelled air", lambda: C.same_bytes(
            os.path.join(d, "bad", "out", "mesh.dat"), os.path.join(golden, "mesh.dat"))[0])
        import subprocess
        out = os.path.join(d, "out")
        r = subprocess.run([sys.executable, "-c", _PORT_RUN, prefix, out, attr, C.repo_file("src")],
                           capture_output=True, text=True, check=True)
        wall, peak = (float(v) for v in r.stdout.split()[-2:])
        for name, gold in [("mesh.dat", os.path.join(golden, "mesh.dat")),
                           ("resistivity_block_iter0.dat", os.path.join(golden, "resistivity_block_iter0.dat")),
                           ("output.6.femtic.vtk", gvtk)]:
            ok, at = C.same_bytes(os.path.join(out, name), gold)
            assert ok, f"port's {name} differs from the C++ at byte {at}"
        print(f"    v2: mesh.dat, block file and VTK byte-identical to the C++; {nswap:,} Earth-surface faces took "
              f"the air-element branch; port {wall:.1f} s and {peak:.0f} MB peak RSS vs C++ {c_wall} s and "
              f"{int(ref[3]) / 1024:.0f} MB")
        assert wall <= 2 * c_wall, f"port took {wall:.1f} s, more than 2 x {c_wall} s"
        assert 0 < peak <= 1024, f"port peak RSS {peak} MB"


def _independent_checks(prefix, out, domain_km):
    """Checks of the port's products for prefix, using only tetgen's files and plain geometry."""
    el, nb = T.read_ele(prefix + ".ele"), T.read_neigh(prefix + ".neigh")
    mesh = F.read_mesh_dat(os.path.join(out, "mesh.dat"))
    blk = F.read_resistivity_blocks(os.path.join(out, "resistivity_block_iter0.dat"))
    P = mesh.nodes[mesh.tets]
    vol = np.abs(np.einsum("ij,ij->i", P[:, 1] - P[:, 0], np.cross(P[:, 2] - P[:, 0], P[:, 3] - P[:, 0]))) / 6.0
    box = np.prod((domain_km[:, 1] - domain_km[:, 0]) * 1000.0)
    assert (vol > 0).all() and abs(vol.sum() - box) / box < 1e-6, f"volumes sum to {vol.sum():.6e}, box {box:.6e}"
    e, k = np.nonzero(nb.neigh < 0)
    hull = set(zip(e.tolist(), k.tolist()))
    listed = [tuple(x) for t in range(6) for x in mesh.faces[t].tolist()]
    assert len(listed) == len(set(listed)) and set(listed) == hull, "outer lists are not exactly the hull faces"
    opp = np.array([[1, 2, 3], [0, 2, 3], [0, 1, 3], [0, 1, 2]])   # face k = the 3 corners other than k
    for t in range(6):
        ax, plane = t // 2, domain_km[t // 2, t % 2] * 1000.0
        f = mesh.faces[t]
        xyz = mesh.nodes[mesh.tets[f[:, 0][:, None], opp[f[:, 1]]]]
        assert np.abs(xyz[:, :, ax] - plane).max() < 1e-6, f"list {t} holds a face off its plane"
    attr = el.attrs[:, 0]
    ee, kk = np.nonzero(nb.neigh > 0)
    across = nb.neigh[ee, kk] - 1
    sel = (attr[ee] == 20) & (attr[across] == 10)
    surf = set(zip(ee[sel].tolist(), kk[sel].tolist()))
    got = [tuple(x) for x in mesh.faces[6].tolist()]
    assert len(got) == len(set(got)) and set(got) == surf, "Earth-surface list is not the earth side of air/earth faces"
    assert blk.elem2blk.size == mesh.n_elements and ((blk.elem2blk == 0) == (attr == 10)).all()
    return mesh, blk, len(hull), len(surf)


def test_port_on_real_tetgen_round0():
    """This test fails if the port's products for the conda-forge tetgen round-0 mesh (fixture) break any
    independent check: element volumes (from the port's mesh.dat) not summing to the 600 km box within 1e-6
    or a zero volume; the six outer lists not holding exactly the hull faces of .neigh, each on its plane; the
    Earth-surface list not holding exactly the earth side of every air/earth adjacency in .neigh/.ele; cell 0
    not exactly the air; counts not equal to tetgen's log; the port's cells differing from cells.partition run
    on the .node coordinates with flood-fill regions; or any element whose cell differs in a re-partition of
    the port's own mesh.dat (10-digit coordinates) that does not trace to a near-tie of that rounding
    (repartition.explain_difference).

    Criterion history: the first version required the mesh.dat re-partition to be identical. It failed with 2
    of 7,938 elements (6062, 7196): their z centroids differ by 3e-11 m in .node precision and are equal after
    mesh.dat's rounding, so the count-median cut put them on opposite sides. The finding is real (the D3
    instrument works from mesh.dat, which cannot always reproduce TetGen2Femtic) and is kept as a traced,
    reported near-tie; the check was narrowed, not dropped.

    Negative controls: the mutant port (face k opposite node k+1) must fail the geometric checks, and an
    alternative run with a different split rule must not pass as near-ties."""
    attr = C.repo_file("mesh", "chain_proof", "inputs", "resistivity_attr.dat")
    dom = np.loadtxt(C.repo_file("mesh", "chain_proof", "inputs", "analysis_domain.dat"))
    with C.tmpdir() as d:
        prefix = C.unpack_fixture(d)
        keep = T2F._FACE_NODES
        T2F._FACE_NODES = np.roll(keep, 1, axis=0)
        try:
            T2F.convert(prefix, os.path.join(d, "m"), attr, log=None)
        finally:
            T2F._FACE_NODES = keep
        C.expect_fail("mutant port: face k opposite node k+1", _independent_checks, prefix, os.path.join(d, "m"), dom)
        out = os.path.join(d, "out")
        res = T2F.convert(prefix, out, attr, log=None)
        mesh, blk, nh, ns = _independent_checks(prefix, out, dom)
        assert (res["nodes"], res["elements"], res["tetgen_faces"]) == (1616, 7938, 2714), res
        a = F.read_resistivity_attr(attr)
        field = cells.BlockLengthField(a)
        row = np.where(RP.air_from_surface(mesh), 0, 1)
        c_ref = cells.centroids(T.read_node(prefix + ".node").xyz * 1.0e3, mesh.tets)
        c_alt = cells.centroids(mesh.nodes, mesh.tets)
        e_ref, _ = cells.partition(c_ref, row, a.regions, field)
        assert np.array_equal(e_ref, blk.elem2blk), "port's cells differ from cells.partition on .node coordinates"
        bad = RP.explain_difference(c_ref, c_alt, row, a.regions, field, rule_alt=cells.CellRule(split="midpoint"))
        C.expect_fail("alternative run with the midpoint split", lambda: bad["all_near_ties"])
        tie = RP.explain_difference(c_ref, c_alt, row, a.regions, field)
        assert tie["all_near_ties"], tie
        print(f"    mesh.dat re-partition: {tie['elements_different']} elements in another cell, all traced to "
              f"near-ties: {tie['divergences']}")
        with open(os.path.join(out, "output.1.femtic.vtk"), "rb") as fh:
            head = fh.read(4096)
        assert b"POINTS 1616 double" in head
        print(f"    1616 nodes, 7938 tets; {nh} hull faces, {ns} Earth-surface faces; {blk.n_cells} cells")


def test_cli_exit_codes():
    """This test fails if `python -m femtic_mesh.tetgen2femtic` returns 0 for a missing .face file, for the
    unported -sediment switch, or for a .node whose ids start at 2, or returns non-zero for the valid fixture."""
    attr = C.repo_file("mesh", "chain_proof", "inputs", "resistivity_attr.dat")
    with C.tmpdir() as d:
        prefix = C.unpack_fixture(d)
        out = os.path.join(d, "o")
        assert T2F.main([prefix, out, "--attr", attr, "-sediment"]) == 1
        nd = T.read_node(prefix + ".node")
        nd.ids = nd.ids + 1
        os.makedirs(os.path.join(d, "b"))
        T.write_node(os.path.join(d, "b", "output.1.node"), nd)
        for e in ("ele", "face", "neigh"):
            C.link_or_copy(prefix + "." + e, os.path.join(d, "b", "output.1." + e))
        assert T2F.main([os.path.join(d, "b", "output.1"), out, "--attr", attr]) == 1
        os.rename(prefix + ".face", prefix + ".face.x")
        assert T2F.main([prefix, out, "--attr", attr]) == 1
        os.rename(prefix + ".face.x", prefix + ".face")
        assert T2F.main([prefix, out, "--attr", attr]) == 0
        print("    exit 1 for -sediment, node ids from 2 and a missing .face; exit 0 for the fixture")


def test_port_on_g0_run():
    """This test fails if the port, run on the real tetgen files that a Phoenix reference chain kept
    (FEMTIC_G0_RUN = a fetched copy of runs/Run04 (chain_proof) or runs/Run05 (v2): intermediates/output.N.* and
    intermediates/resistivity_attr.dat, N = the last round), does not write mesh.dat, resistivity_block_iter0.dat
    and output.N.femtic.vtk byte-identical to the C++ TetGen2Femtic products in that run folder (B2 / TD2).
    SKIP until a G0 run has been fetched.

    Negative control: the port fed the same files with one element's region attribute flipped must write a
    different block file. (A first version compared mesh.dat here and did not fail: an attribute change away
    from the PLC facets cannot enter mesh.dat, because only faces listed in .face can.)"""
    run = os.environ.get("FEMTIC_G0_RUN")
    if not run:
        raise C.Skip("set FEMTIC_G0_RUN to a fetched Phoenix reference run folder (runs/Run04 or runs/Run05)")
    wd = os.path.join(run, "intermediates")
    rounds = [int(f.split(".")[1]) for f in os.listdir(wd) if f.startswith("output.") and f.endswith(".ele")]
    if not rounds:
        raise C.Skip(f"no output.N.ele in {wd}")
    n = max(rounds)
    prefix, attr = os.path.join(wd, f"output.{n}"), os.path.join(wd, "resistivity_attr.dat")
    with C.tmpdir() as d:
        el = T.read_ele(prefix + ".ele")
        el.attrs[0, 0] = 20.0 if el.attrs[0, 0] == 10.0 else 10.0
        os.makedirs(os.path.join(d, "bad"))
        T.write_ele(os.path.join(d, "bad", f"output.{n}.ele"), el)
        for x in ("node", "face", "neigh"):
            C.link_or_copy(f"{prefix}.{x}", os.path.join(d, "bad", f"output.{n}.{x}"))
        T2F.convert(os.path.join(d, "bad", f"output.{n}"), os.path.join(d, "bad", "out"), attr, vtk=False, log=None)
        # mesh.dat may not change (only faces listed in .face can enter it); the block file must
        C.expect_fail("element 1's attribute flipped", lambda: C.same_bytes(
            os.path.join(d, "bad", "out", "resistivity_block_iter0.dat"),
            os.path.join(run, "resistivity_block_iter0.dat"))[0])
        out = os.path.join(d, "out")
        T2F.convert(prefix, out, attr, log=None)
        for name in ("mesh.dat", "resistivity_block_iter0.dat", f"output.{n}.femtic.vtk"):
            ok, at = C.same_bytes(os.path.join(out, name), os.path.join(run, name))
            assert ok, f"port's {name} differs from the Phoenix C++ product at byte {at}"
        print(f"    {run}: mesh.dat, block file and VTK byte-identical to Phoenix's TetGen2Femtic (B2/TD2)")


if __name__ == "__main__":
    sys.exit(1 if C.run(globals(), sys.argv[1:]) else 0)
