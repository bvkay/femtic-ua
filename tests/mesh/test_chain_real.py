"""femtic_mesh.chain with the real tetgen (opt-in): the rounds after makeTetraMesh on chain_proof.

FEMTIC_MESH_TETGEN=<conda-forge tetgen executable> python tests/mesh/test_chain_real.py

tetgen may run on this PC on the 4,705-node chain_proof case only (sub-second per call); the test makes two chains of
six tetgen calls each, so it runs only when FEMTIC_MESH_TETGEN is set, never by default. With the makeMtr and
TetGen2Femtic ports, the chain must give a mesh within 5 % of the WSL build's counts (study S2) that passes
validation/mesh_2026-09-25/check_mesh.py, the independent product checker of 2026-09-25. FEMTIC_MESH_KEEP=<folder>
keeps the run folder.
"""
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C  # noqa: E402
from femtic_mesh.io import tetgen as T  # noqa: E402

WSL = [(1605, 7879), (3279, 18587), (4416, 25714), (4832, 28269), (4654, 27186), (4705, 27501)]   # chain_proof.md


def _real(d, name, tetgen, overrides=None):
    from femtic_mesh import chain
    cp = os.path.dirname(C.main_mesh("chain_proof", "mesh.dat"))
    rd = os.path.join(d, name)
    shutil.copytree(os.path.join(cp, "inputs"), os.path.join(rd, "files"))
    open(os.path.join(rd, "files", "region_seeds.dat"), "w", newline="\n").write(
        "0.0 0.0 -40.0 10 1e9\n0.0 0.0 10.0 20 1e9\n")
    lines = []
    r = chain.run(rd, tetgen=tetgen, prefer="python", from_poly=os.path.join(cp, "logs", "output.poly.before_seed"),
                  overrides=overrides, out=lines.append, err=lines.append)
    assert r["rc"] == 0, r["done"]
    rows = [ln.split("\t") for ln in open(os.path.join(rd, "intermediates", "refinement.tsv")).read().splitlines()[1:]]
    return rd, [(int(a), int(b)) for _, a, b in rows]


def _within(counts, tol=0.05):
    n, t = counts[-1]
    assert abs(n / WSL[-1][0] - 1) <= tol and abs(t / WSL[-1][1] - 1) <= tol, (counts[-1], WSL[-1])
    return True


def test_real_tetgen_chain():
    """This test fails if the driver, from MAIN's chain_proof makeTetraMesh output (logs/output.poly.before_seed),
    inputs and the WSL run's seeds, with the conda-forge tetgen and the makeMtr and TetGen2Femtic ports: does not end
    'MESH CHAIN DONE: OK'; seeds a PLC that parses differently from MAIN's output.poly; writes a makeMtr_i.log that
    differs from the C++'s mesh/chain_proof/logs/makeMtr_i.log in any line but its two count lines, or whose counts
    are not its own round's; gives final node or tet counts more than 5 % from the WSL build's 4,705 / 27,501 (study
    S2); or gives products that fail validation/mesh_2026-09-25/check_mesh.py (--flat-surface-z 0).

    Negative control (first): the chain with a mutant makeMtr that ignores the sites (obs_site.dat read as no sites,
    the 'missing count reads as 0' hazard) must fall outside the 5 % band. Opt-in: FEMTIC_MESH_TETGEN=<exe>."""
    tg = os.environ.get("FEMTIC_MESH_TETGEN")
    if not tg:
        raise C.Skip("FEMTIC_MESH_TETGEN is not set (tetgen runs only when asked, on chain_proof only)")
    with C.tmpdir() as d:
        mut = os.path.join(d, "nosites.py")
        open(mut, "w").write("import sys\nfrom femtic_mesh import makemtr as M\nM._sites = lambda s, X, Y, Z, b: b\n"
                             "sys.exit(M.main())\n")
        _, mc = _real(d, "mutant", tg, {"sizing": [sys.executable, mut]})
        print(f"    mutant (no sites): final {mc[-1][0]} nodes / {mc[-1][1]} tets")
        C.expect_fail("makeMtr without sites", _within, mc)
        rd, counts = _real(d, "real", tg)
        w = os.path.join(rd, "intermediates")
        a, b = T.read_poly(os.path.join(w, "output.poly")), T.read_poly(C.main_mesh("chain_proof", "output.poly"))
        assert (a.xyz == b.xyz).all() and [f.polygons for f in a.facets] == [f.polygons for f in b.facets] \
            and (a.regions == b.regions).all(), "seeded PLC differs from MAIN's output.poly"
        for i in range(1, 6):
            got = open(os.path.join(w, "logs", f"makeMtr_{i}.log")).read().splitlines()
            cpp = open(C.repo_file("mesh", "chain_proof", "logs", f"makeMtr_{i}.log")).read().splitlines()
            diff = [k for k, (x, y) in enumerate(zip(got, cpp)) if x != y]
            nums = [int(got[k].split(":")[1]) for k in diff]
            assert len(got) == len(cpp) and len(diff) <= 2 and all("Total number of" in got[k] for k in diff) \
                and nums == [c for c, x in zip(counts[i - 1], WSL[i - 1]) if c != x], (i, diff, nums)
        print("    round  conda-forge nodes / tets   WSL nodes / tets")
        for i, (c, x) in enumerate(zip(counts, WSL), 1):
            dn, dt = 100 * (c[0] / x[0] - 1), 100 * (c[1] / x[1] - 1)
            print(f"    output.{i}  {c[0]:>6} / {c[1]:>6}  ({dn:+.1f} % / {dt:+.1f} %)   {x[0]:>6} / {x[1]:>6}")
        _within(counts)
        ck = os.path.join(d, "check")
        os.makedirs(ck)
        for f in ("mesh.dat", "resistivity_block_iter0.dat"):
            shutil.copyfile(os.path.join(rd, f), os.path.join(ck, f))
        shutil.copyfile(os.path.join(rd, "files", "analysis_domain.dat"), os.path.join(ck, "analysis_domain.dat"))
        r = subprocess.run([sys.executable, C.repo_file("validation", "mesh_2026-09-25", "check_mesh.py"), ck,
                            "--flat-surface-z", "0"], capture_output=True, text=True)
        assert r.returncode == 0 and re.search(r"(\d+)/\1 checks passed", r.stdout), r.stdout[-800:]
        print(f"    check_mesh.py: {r.stdout.strip().splitlines()[-1]}")
        print("    " + open(os.path.join(rd, "mesh_summary.txt")).read().replace("\n", "\n    ").rstrip())
        for row in open(os.path.join(w, "timings.tsv")).read().splitlines():
            print("    " + row)
        if os.environ.get("FEMTIC_MESH_KEEP"):
            shutil.copytree(rd, os.environ["FEMTIC_MESH_KEEP"], dirs_exist_ok=True)


if __name__ == "__main__":
    sys.exit(1 if C.run(globals(), sys.argv[1:]) else 0)
