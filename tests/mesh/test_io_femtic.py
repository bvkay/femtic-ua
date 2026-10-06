"""femtic_mesh.io.femtic: byte-exact mesh.dat / resistivity_block_iter0.dat / VTK writers and the readers.

  python tests/mesh/test_io_femtic.py [test_name ...]
"""
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C  # noqa: E402
import numpy as np  # noqa: E402
from femtic_mesh.io import femtic as F  # noqa: E402


def _roundtrip_mesh(src, dst):
    F.write_mesh_dat(dst, F.read_mesh_dat(src))
    ok, at = C.same_bytes(src, dst)
    assert ok, f"{dst} differs from {src} at byte {at}"
    return True


def _roundtrip_blocks(src, dst):
    F.write_resistivity_blocks(dst, F.read_resistivity_blocks(src))
    ok, at = C.same_bytes(src, dst)
    assert ok, f"{dst} differs from {src} at byte {at}"
    return True


def test_mesh_dat_roundtrip_chain_proof():
    """This test fails if write_mesh_dat(read_mesh_dat(f)) differs by one byte from chain_proof/mesh.dat (cmp).

    Negative controls: a mutant writer printing node coordinates with 8 instead of 9 decimals, and a perturbed
    mesh (two Earth-surface entries swapped), must both make the comparison fail."""
    src = C.need("chain_proof", "mesh.dat")
    with C.tmpdir() as d:
        out = os.path.join(d, "mesh.dat")
        keep = F.NODE_COORD_FMT
        F.NODE_COORD_FMT = "%20.8e"
        try:
            C.expect_fail("mutant writer %20.8e", _roundtrip_mesh, src, out)
        finally:
            F.NODE_COORD_FMT = keep
        m = F.read_mesh_dat(src)
        m.faces[6][[0, 1]] = m.faces[6][[1, 0]]
        F.write_mesh_dat(out, m)
        C.expect_fail("Earth-surface entries 0 and 1 swapped", lambda: C.same_bytes(src, out)[0])
        _roundtrip_mesh(src, out)
        print(f"    chain_proof mesh.dat round trip byte-identical ({os.path.getsize(src):,} bytes)")


def test_block_roundtrip_chain_proof():
    """This test fails if write_resistivity_blocks(read_resistivity_blocks(f)) differs by one byte from
    chain_proof/resistivity_block_iter0.dat (cmp).

    Negative controls: a mutant writer with the fix flag in a 9-wide field, and one element moved to another
    cell, must both make the comparison fail."""
    src = C.need("chain_proof", "resistivity_block_iter0.dat")
    with C.tmpdir() as d:
        out = os.path.join(d, "blk.dat")
        keep = F.BLOCK_CELL_FMT
        F.BLOCK_CELL_FMT = keep.replace("%10d" + chr(10), "%9d" + chr(10))
        try:
            C.expect_fail("mutant writer: fix flag %9d", _roundtrip_blocks, src, out)
        finally:
            F.BLOCK_CELL_FMT = keep
        b = F.read_resistivity_blocks(src)
        b.elem2blk[100] = (b.elem2blk[100] + 1) % b.n_cells
        F.write_resistivity_blocks(out, b)
        C.expect_fail("element 100 moved to another cell", lambda: C.same_bytes(src, out)[0])
        _roundtrip_blocks(src, out)
        print(f"    chain_proof block file round trip byte-identical ({os.path.getsize(src):,} bytes)")


def test_vtk_chain_proof():
    """This test fails if write_t2f_vtk(mesh.dat, block file) differs by one byte from TetGen2Femtic's own
    chain_proof/output.6.femtic.vtk (an output the reader never saw, so this checks the VTK writer's formats).

    Negative control: the same VTK written after moving one element between air and earth must differ."""
    golden = C.need("chain_proof", "output.6.femtic.vtk")
    m = F.read_mesh_dat(C.need("chain_proof", "mesh.dat"))
    b = F.read_resistivity_blocks(C.need("chain_proof", "resistivity_block_iter0.dat"))
    with C.tmpdir() as d:
        out = os.path.join(d, "o.vtk")
        b2 = F.read_resistivity_blocks(C.need("chain_proof", "resistivity_block_iter0.dat"))
        b2.elem2blk[7] = 0 if b2.elem2blk[7] else 1
        F.write_t2f_vtk(out, m, b2)
        C.expect_fail("element 7 moved between air and earth", lambda: C.same_bytes(golden, out)[0])
        F.write_t2f_vtk(out, m, b)
        ok, at = C.same_bytes(golden, out)
        assert ok, f"VTK differs from {golden} at byte {at}"
        print(f"    output.6.femtic.vtk reproduced byte for byte ({os.path.getsize(golden):,} bytes)")


def test_crlf_and_layout_checks():
    """This test fails if a CRLF copy of chain_proof/mesh.dat parses to different arrays than the LF original,
    or if the reader accepts a truncated file, a file with a wrong index column or one with trailing data.

    Negative control: a copy with one neighbour digit changed must parse to different arrays."""
    src = C.need("chain_proof", "mesh.dat")
    ref = F.read_mesh_dat(src)
    raw = open(src, "rb").read()

    def same(m):
        return (np.array_equal(m.nodes, ref.nodes) and np.array_equal(np.signbit(m.nodes), np.signbit(ref.nodes))
                and np.array_equal(m.neigh, ref.neigh) and np.array_equal(m.tets, ref.tets)
                and all(np.array_equal(a, b) for a, b in zip(m.faces, ref.faces)))
    NL = b"\n"
    with C.tmpdir() as d:
        p = os.path.join(d, "m.dat")
        lines = raw.split(NL)
        k = 3 + ref.n_nodes + 5
        bad = lines[k][:-1] + bytes([(lines[k][-1] - 48 + 1) % 10 + 48])
        open(p, "wb").write(NL.join(lines[:k] + [bad] + lines[k + 1:]))
        C.expect_fail("one neighbour digit changed", lambda: same(F.read_mesh_dat(p)))
        open(p, "wb").write(raw.replace(NL, b"\r" + NL))
        assert same(F.read_mesh_dat(p)), "CRLF copy parsed differently"
        print("    CRLF copy parses to the same arrays (sign of zero included)")
        for what, data in [("truncated (last line dropped)", NL.join(lines[:-2]) + NL),
                           ("trailing data", raw + b"         0         1" + NL),
                           ("node index column off by one",
                            raw.replace(NL + b"         0     ", NL + b"         1     ", 1))]:
            open(p, "wb").write(data)
            try:
                F.read_mesh_dat(p)
            except ValueError as exc:
                print(f"    rejected {what}: {str(exc)[:90]}")
                continue
            raise AssertionError(f"reader accepted a file with {what}")


def _parse_stats(txt):
    m1 = re.search(r"nodes (\d+)\s+elements (\d+) \(air (\d+), earth (\d+)\)", txt)
    m2 = re.search(r"parameter cells (\d+) \(incl\. air cell 0\); earth-surface faces (\d+); "
                   r"outer faces \[([\d, ]+)\]", txt)
    return {"nodes": int(m1[1]), "elements": int(m1[2]), "air": int(m1[3]), "earth": int(m1[4]),
            "cells": int(m2[1]), "earth_surface_faces": int(m2[2]), "outer_faces": [int(v) for v in m2[3].split(",")]}


def _counts(mesh, blocks):
    air = int((blocks.elem2blk == 0).sum())
    c = mesh.counts()
    return {"nodes": c["nodes"], "elements": c["elements"], "air": air, "earth": c["elements"] - air,
            "cells": blocks.n_cells, "earth_surface_faces": c["earth_surface_faces"], "outer_faces": c["outer_faces"]}


def test_v2_roundtrip_and_counts():
    """This test fails if the 256 MB vulcan_v2 mesh.dat or its block file does not round-trip byte-identically,
    if read + write takes more than 20 minutes, or if the counts read here differ from mesh_stats.txt (written
    in WSL by scripts/mesh_stats.py, an independent parser): nodes, elements, air/earth, cells, face lists.

    Negative controls: the count comparison against v3's mesh_stats.txt must fail, and a v2 mesh written with
    one node index of element 0 changed must differ from the original."""
    src = C.need("vulcan_v2", "inversion", "mesh.dat")
    bsrc = C.need("vulcan_v2", "inversion", "resistivity_block_iter0.dat")
    t0 = time.perf_counter()
    m = F.read_mesh_dat(src)
    t_read = time.perf_counter() - t0
    b = F.read_resistivity_blocks(bsrc)
    got = _counts(m, b)
    v3 = _parse_stats(open(C.repo_file("mesh", "vulcan_v3", "mesh_logs", "mesh_stats.txt")).read())
    C.expect_fail("counts compared with v3's mesh_stats.txt", lambda: got == v3)
    exp = _parse_stats(open(C.repo_file("mesh", "vulcan_v2", "mesh_logs", "mesh_stats.txt")).read())
    assert got == exp, f"counts {got} != mesh_stats.txt {exp}"
    print(f"    counts equal mesh_stats.txt: {got}")
    with C.tmpdir() as d:
        out = os.path.join(d, "mesh.dat")
        t1 = time.perf_counter()
        F.write_mesh_dat(out, m)
        t_write = time.perf_counter() - t1
        ok, at = C.same_bytes(src, out)
        assert ok, f"v2 mesh.dat round trip differs at byte {at}"
        total = t_read + t_write
        print(f"    v2 mesh.dat ({os.path.getsize(src):,} bytes) round trip byte-identical: read {t_read:.1f} s, "
              f"write {t_write:.1f} s, peak RSS of this process so far {C.peak_rss_mb()} MB")
        assert total < 20 * 60, f"read + write took {total:.0f} s"
        m.tets[0, 0] = (m.tets[0, 0] + 1) % m.n_nodes
        F.write_mesh_dat(out, m)
        C.expect_fail("node index of element 0 changed", lambda: C.same_bytes(src, out)[0])
        _roundtrip_blocks(bsrc, os.path.join(d, "blk.dat"))
        print(f"    v2 block file ({os.path.getsize(bsrc):,} bytes) round trip byte-identical")


if __name__ == "__main__":
    sys.exit(1 if C.run(globals(), sys.argv[1:]) else 0)
