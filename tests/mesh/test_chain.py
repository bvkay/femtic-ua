"""femtic_mesh.chain, .backends and .doctor: the mesh chain driver that runs on a student's own machine.

Oracles: (1) the kit's hpc/phoenix_plan/mesh_chain.sh, run by bash on the same fake tools (fake_tools.py), must make the
same tool calls and write the same mesh_summary.txt, DONE line and intermediates (Git Bash on Windows, never the WSL
launcher; SKIP without bash); (2) each failure case must exit 1 with mesh_chain.sh's message and leave no product;
(3) the dry run, the doctor and the machine report against fixed expectations. The run with the real tetgen is
test_chain_real.py (opt-in).

  python tests/mesh/test_chain.py [test_name ...]
"""
import json
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C  # noqa: E402
import fake_tools  # noqa: E402
from femtic_mesh import backends  # noqa: E402

KIT_SRC = C.repo_file("hpc", "phoenix_plan")
RUNNER = ("import json, sys\nimport femtic_mesh.chain as ch\nsrc = open(ch.__file__, encoding='utf-8').read()\n"
          "for old, new in json.loads(sys.argv[1]):\n    assert src.count(old) == 1, old\n"
          "    src = src.replace(old, new)\n"
          "exec(compile(src, ch.__file__, 'exec'), ch.__dict__)\nsys.exit(ch.main(sys.argv[2:]))\n")


def _bash():
    if os.name == "nt":                                            # bash.exe on PATH is the WSL launcher: never that
        for p in (os.environ.get("FEMTIC_TEST_BASH"), "C:/Program Files/Git/bin/bash.exe"):
            if p and os.path.isfile(p):
                return p
        return None
    return shutil.which("bash")


def _px(p):
    return fake_tools.posix(p) if os.name == "nt" else p


def _setup(d):
    """d/bin (the four fakes and femtic_env.sh), d/kit (mesh_chain.sh, femtic_lib.sh, VERSION), d/files (the 10 inputs
    of a land-only +-300 km box, air 10 above, earth 20 below; seeds at z = -40 and +10 km, as run_sh_test.sh's)."""
    b = fake_tools.install(os.path.join(d, "bin"))
    open(os.path.join(b, "femtic_env.sh"), "w", newline="\n").write(f"export PATH={_px(b)}:$PATH\n")
    os.makedirs(os.path.join(d, "kit"))
    for f in ("mesh_chain.sh", "femtic_lib.sh"):
        shutil.copyfile(os.path.join(KIT_SRC, f), os.path.join(d, "kit", f))
    open(os.path.join(d, "kit", "VERSION"), "w", newline="\n").write("test\n2026-10-07\n")
    f = os.path.join(d, "files")
    os.makedirs(f)
    w = lambda n, s: open(os.path.join(f, n), "w", newline="\n").write(s)  # noqa: E731
    w("control.dat", "ALTITUDE\ntopography.dat\n0\n1e10\nEND\n")
    w("analysis_domain.dat", "-300 300\n-300 300\n-300 300\n")
    for n in ("observing_site.dat", "coast_line.dat", "obs_site.dat", "makeMtr.param", "topography.dat",
              "bathymetry.dat"):
        w(n, "0\n")
    w("resistivity_attr.dat", "2\n10 1e9 -1 1\n20 100 9 0\n")
    w("region_seeds.dat", "# x y z attr maxvol\n0 0 -40 10 1e9\n0 0 10 20 1e9\n")
    return d


def _run_dir(d, name, seeds=None, extra=None):
    rd = os.path.join(d, name)
    shutil.rmtree(rd, ignore_errors=True)
    shutil.copytree(os.path.join(d, "files"), os.path.join(rd, "files"))
    if seeds:
        open(os.path.join(rd, "files", "region_seeds.dat"), "w", newline="\n").write(seeds)
    for n, s in (extra or {}).items():
        open(os.path.join(rd, "files", n), "w", newline="\n").write(s)
    return rd


def _py(d, rd, env=None, edits=(), args=(), bin_name="bin"):
    """The Python driver as a user runs it (optionally a mutant: text edits of chain.py). (exit, stdout, calls)."""
    calls = rd + ".calls"
    e = dict(C.port_env(), FAKE_CALLS=calls, **(env or {}))
    r = subprocess.run([sys.executable, "-c", RUNNER, json.dumps(list(edits)), rd, "--bin", os.path.join(d, bin_name),
                        *args], env=e, capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr, open(calls).read() if os.path.exists(calls) else ""


def _sh(d, rd, env=None):
    """The kit's mesh_chain.sh, as a Slurm job would run it, on the same fakes. (exit, stdout, calls)."""
    calls = rd + ".calls"
    e = dict(os.environ, SLURM_JOB_ID="4242", SLURM_SUBMIT_DIR=_px(rd), KIT=_px(os.path.join(d, "kit")),
             BIN=_px(os.path.join(d, "bin")), VF=_px(d), FAKE_CALLS=calls, MSYS_NO_PATHCONV="1", **(env or {}))
    r = subprocess.run([_bash(), _px(os.path.join(d, "kit", "mesh_chain.sh")), _px(rd)], cwd=rd, env=e,
                       capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr, open(calls).read() if os.path.exists(calls) else ""


def _done(out):
    return [ln for ln in out.splitlines() if ln.startswith("MESH CHAIN DONE:")][-1]


def _tree(rd):
    w = os.path.join(rd, "intermediates")
    return sorted(os.path.relpath(os.path.join(a, f), w).replace("\\", "/") for a, _, fs in os.walk(w) for f in fs)


def _text(rd, name, cols=None):
    p = os.path.join(rd, "intermediates", name)
    if not os.path.exists(p):
        return None
    s = open(p).read().replace(" *", "  ")                         # Git Bash's md5sum marks binary mode with '*'
    if name == "summary.txt":
        s = "\n".join(x for x in s.splitlines() if not x.startswith(("run_dir ", "total wall time")))
    if cols:
        s = "\n".join("\t".join(x.split("\t")[c] for c in cols) for x in s.splitlines())
    return s


def _same_as_sh(a, b):
    """a, b: (exit, out, calls, run folder) of the Python driver and of mesh_chain.sh. Asserts every compared item."""
    (ra, oa, ca, da), (rb, ob, cb, db) = a, b
    assert ra == rb, ("exit", ra, rb)
    assert _done(oa) == _done(ob), ("DONE line", _done(oa), _done(ob))
    assert ca == cb, ("tool calls", ca.splitlines()[-3:], cb.splitlines()[-3:])
    for f in ("mesh_summary.txt", "mesh.dat", "resistivity_block_iter0.dat"):
        pa, pb = os.path.join(da, f), os.path.join(db, f)
        assert os.path.exists(pa) == os.path.exists(pb), ("product present", f)
        assert not os.path.exists(pa) or open(pa).read() == open(pb).read(), ("content", f)
    if os.path.isdir(os.path.join(db, "intermediates")):
        assert _tree(da) == _tree(db), ("intermediates", sorted(set(_tree(da)) ^ set(_tree(db))))
        for f, cols in (("output.poly", None), ("region_seeds.used", None), ("refinement.tsv", None),
                        ("input_md5.txt", None), ("summary.txt", None), ("timings.tsv", (0, 1, 4))):
            assert _text(da, f, cols) == _text(db, f, cols), ("intermediate", f)
    return True


SWAPPED = "0 0 -40 20 1e9\n0 0 10 10 1e9\n"
CASES = [("full chain", {}, None), ("makeMtr writes nothing in round 2", {"FAKE_MTR_SKIP": "2"}, None),
         ("round-1 .mtr one value short", {"FAKE_MTR_SHORT": "1"}, None),
         ("tetgen exits 1 in round 2", {"FAKE_TETGEN_FAIL": "2"}, None), ("seeds swapped", {}, SWAPPED)]


def test_fake_chain_equals_mesh_chain_sh():
    """This test fails if, on the same fake tools and inputs, the Python driver and the kit's mesh_chain.sh differ in
    exit code, DONE line, tool calls (order and switches), mesh_summary.txt, products, the set of intermediates/ files,
    or output.poly, region_seeds.used, refinement.tsv, input_md5.txt, summary.txt (without its run_dir and wall-time
    lines) and timings.tsv's step, rc and command columns; for a full chain and four failing ones (makeMtr writes
    nothing in round 2, a round-1 .mtr one value short, tetgen exits 1 in round 2, swapped seeds).

    Negative controls: a driver whose round switches lack 'a' (-nmpYVrAkq3.0/0) on the full chain, and one that does
    not keep tetgen's output.2.mtr apart (makeMtr's missing file then goes unseen) on the round-2 case, must differ."""
    if not _bash():
        raise C.Skip("no bash (Git Bash on Windows) to run mesh_chain.sh")
    with C.tmpdir() as d:
        _setup(d)
        sh = {}
        for k, (what, env, seeds) in enumerate(CASES):
            rb = _run_dir(d, f"sh{k}", seeds)
            sh[k] = _sh(d, rb, env) + (rb,)
        mutants = {0: ('SW0, SWR = "-nVpYAakq3.0/0", "-nmpYVrAakq3.0/0"',
                       'SW0, SWR = "-nVpYAakq3.0/0", "-nmpYVrAkq3.0/0"'),
                   1: ('                os.replace(mtr, self.w(f"output.{i}.tetgen.mtr"))', '                pass')}
        for k, edit in mutants.items():
            ra = _run_dir(d, f"mut{k}", CASES[k][2])
            C.expect_fail(f"mutant on '{CASES[k][0]}'", _same_as_sh, _py(d, ra, CASES[k][1], [edit]) + (ra,), sh[k])
        for k, (what, env, seeds) in enumerate(CASES):
            ra = _run_dir(d, f"py{k}", seeds)
            _same_as_sh(_py(d, ra, env) + (ra,), sh[k])
            print(f"    {what}: same as mesh_chain.sh: {_done(sh[k][1])[:110]}")


def _failed(d, rd, want, env=None, args=(), bin_name="bin", written=None):
    rc, out, _ = _py(d, rd, env, args=args, bin_name=bin_name)
    assert rc == 1 and want in _done(out), (rc, _done(out))
    if written is not None:                                        # a refusal: the folder exactly as it was
        assert sorted(os.listdir(rd)) == written, sorted(os.listdir(rd))
        return True
    for f in ("mesh.dat", "resistivity_block_iter0.dat"):
        assert not os.path.exists(os.path.join(rd, f)), f"product {f} left in the run folder"
    return True


def test_fake_chain_failures():
    """This test fails if the Python driver does not exit 1 with its DONE line naming the step and reason, or leaves a
    product in the run folder, for: makeTetraMesh exits 1 (step 1) or logs an error (step 3); tetgen exits 1 on
    output.poly; makeMtr exits 1 (round 3); a .mtr one value short (header too); a .mtr whose header is right but one
    row is missing (stricter than mesh_chain.sh); a stray output.1.b.node; or if a refused run (no makeTetraMesh and
    no --from-poly; an earlier build in the folder) writes anything at all.

    Negative control: the same check on the healthy run must fail (it exits 0 and writes the products)."""
    with C.tmpdir() as d:
        _setup(d)
        C.expect_fail("healthy run", _failed, d, _run_dir(d, "ok"), "FAILED")
        cases = [("makeTetraMesh exits 1", {"FAKE_MTM_FAIL": "1"}, "at stp1: makeTetraMesh -stp 1 (see intermediates/"
                  "logs/makeTetraMesh_stp1.log) (stp1 1)"),
                 ("makeTetraMesh logs an error", {"FAKE_MTM_ERROR": "3"},
                  "at stp3: makeTetraMesh -stp 3 logged an error"),
                 ("tetgen exits 1", {"FAKE_TETGEN_FAIL": "0"}, "at tetgen_1: tetgen -nVpYAakq3.0/0 output.poly"),
                 ("makeMtr exits 1", {"FAKE_MTR_FAIL": "3"}, "at makeMtr_3: makeMtr output.3 ("),
                 ("short .mtr", {"FAKE_MTR_SHORT": "1"}, "at makeMtr_1: output.1.mtr lists 11 values, output.1.node "
                  "has 12 nodes (tetgen would refine without sizing)"),
                 ("truncated .mtr", {"FAKE_MTR_TRUNC": "2"},
                  "at makeMtr_2: output.2.mtr: header says 12 rows, file holds 11")]
        for what, env, want in cases:
            _failed(d, _run_dir(d, "f"), want, env)
            print(f"    {what}: exit 1, '...{want[-60:]}'")
        _failed(d, _run_dir(d, "f", extra={"output.1.b.node": "1 3 0 0\n1 0 0 0\n"}),
                "at makeMtr_1: output.1.b.node exists: tetgen -m would read it as a background mesh")
        nodes = os.path.join(d, "nodesigner")
        os.makedirs(nodes)
        for t in os.listdir(os.path.join(d, "bin")):
            if not t.startswith("makeTetraMesh"):
                shutil.copy2(os.path.join(d, "bin", t), nodes)
        _failed(d, _run_dir(d, "f"), "at setup: designer missing: use Phoenix (Run with --job mesh) or wait for the "
                "Gmsh route ()", bin_name="nodesigner", written=["files"])
        rd = _run_dir(d, "f")
        open(os.path.join(rd, "mesh.dat"), "w").write("x")
        _failed(d, rd, "exists: an earlier mesh build is in this run folder", written=["files", "mesh.dat"])
        print("    stray background mesh, missing designer, earlier build: refused or failed as required")
        if backends.find_binaries("tetgen"):
            print("    (missing tetgen not tried: this machine has a tetgen outside the test's bin folder)")
            return
        notg = os.path.join(d, "notetgen")
        os.makedirs(notg)
        for t in os.listdir(os.path.join(d, "bin")):
            if not t.startswith("tetgen"):
                shutil.copy2(os.path.join(d, "bin", t), notg)
        _failed(d, _run_dir(d, "f"), "at setup: tetgen missing (no tetgen in the bin folder, on PATH or in a conda env",
                bin_name="notetgen", written=["files"])
        print("    missing tetgen: refused, nothing written")


def test_dry_run_and_doctor():
    """This test fails if: --dry-run writes anything, or does not print 16 steps and exit 0 with the fake tools, 12
    steps with --from-poly and no makeTetraMesh, or 'PLAN: REFUSED: designer missing: ...' and exit 1 without either;
    the doctor does not exit 0 with all four fake tools, or exit 2 naming the designer and Phoenix (RUNBOOK F3) without
    makeTetraMesh; backends.machine() without psutil reports a RAM total more than 1 % from psutil's (where psutil is
    installed); or estimate() advises 'local' on a machine with less free RAM than twice the v2 peak.

    Negative controls: the doctor check on the incomplete tool set, and the RAM check on a fallback that misreads
    bytes as KB, must fail."""
    from femtic_mesh import doctor
    with C.tmpdir() as d:
        _setup(d)
        rd = _run_dir(d, "dry")
        before = sorted(os.listdir(rd))
        nodes = os.path.join(d, "nodesigner")
        os.makedirs(nodes)
        for t in os.listdir(os.path.join(d, "bin")):
            if not t.startswith("makeTetraMesh"):
                shutil.copy2(os.path.join(d, "bin", t), nodes)
        poly = os.path.join(d, "unseeded.poly")
        open(poly, "w").write("# Part 1\n0 3 0 0\n# Part 2\n0 0\n# Part 3\n0\n# Part 4\n0\n")
        dry = [(["--dry-run"], "bin", 0, "PLAN: would run 16 steps"),
               (["--dry-run", "--from-poly", poly], "nodesigner", 0, "PLAN: would run 12 steps"),
               (["--dry-run"], "nodesigner", 1, "PLAN: REFUSED: designer missing: use Phoenix")]
        for args, bin_name, want_rc, want in dry:
            rc, out, _ = _py(d, rd, args=args, bin_name=bin_name)
            assert rc == want_rc and want in out and sorted(os.listdir(rd)) == before, (rc, out[-300:])
            print(f"    dry run ({bin_name}{', --from-poly' if '--from-poly' in args else ''}): exit {rc}, '{want}'")

        def doctor_ok(bin_dir, rc_want, words):
            lines = []
            rc, missing = doctor.report(bin_dir, out=lines.append)
            assert rc == rc_want and all(w in "\n".join(lines) for w in words), (rc, missing)
            return True
        C.expect_fail("doctor on the incomplete set", doctor_ok, nodes, 0, ["VERDICT: COMPLETE"])
        doctor_ok(os.path.join(d, "bin"), 0, ["VERDICT: COMPLETE"])
        doctor_ok(nodes, 2, ["missing designer (makeTetraMesh)", "Phoenix:", "RUNBOOK.md F3", "--from-poly"])
    m = backends.machine()
    assert m["cores"] and m["ram_total_mb"], m
    if m["source"] == "psutil":
        saved = sys.modules.get("psutil")
        sys.modules["psutil"] = None
        try:
            fb = backends.machine()
            wrong = dict(fb, ram_total_mb=fb["ram_total_mb"] * 1024)
        finally:
            sys.modules["psutil"] = saved
        near = lambda x: abs(x["ram_total_mb"] - m["ram_total_mb"]) <= 0.01 * m["ram_total_mb"]  # noqa: E731
        C.expect_fail("fallback misreading the unit", near, wrong)
        assert fb["source"] == "os" and near(fb), (fb, m)
        print(f"    RAM total: psutil {m['ram_total_mb']} MB, OS fallback {fb['ram_total_mb']} MB")
    need = backends.estimate("v2", {"ram_avail_mb": 0})["need_mb"]
    assert backends.estimate("v2", {"ram_avail_mb": need - 1})["verdict"] == "phoenix"
    assert backends.estimate("v2", {"ram_avail_mb": need})["verdict"] == "local" and need >= 2 * 956


if __name__ == "__main__":
    sys.exit(1 if C.run(globals(), sys.argv[1:]) else 0)
