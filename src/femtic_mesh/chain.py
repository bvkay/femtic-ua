"""The FEMTIC tetrahedral mesh chain on this machine: the steps, switches, checks and intermediates of
hpc/phoenix_plan/mesh_chain.sh, each tool step done by the backend femtic_mesh.backends chose (a C++ binary, the
conda-forge tetgen, or a Python port).

  python -m femtic_mesh.chain RUN_DIR [--files files] [--rounds 5] [--bin DIR] [--tetgen EXE] [--prefer binary|python]
                              [--from-poly OUTPUT_POLY] [--t2f-args "-thread 8"] [--dry-run]

  makeTetraMesh -stp 1..4 -> region seeds into output.poly -> tetgen -nVpYAakq3.0/0 output.poly
  -> ROUNDS x (makeMtr output.i ; tetgen -nmpYVrAakq3.0/0 output.i) -> TetGen2Femtic output.(ROUNDS+1)

RUN_DIR/FILES holds the 10 inputs of mesh/vulcan_v2/files (as scripts/make_run.sh --job mesh writes them). Written in
RUN_DIR: mesh.dat, resistivity_block_iter0.dat, output.N.femtic.vtk (moved up once every check passed); intermediates/
(the inputs as used, region_seeds.used, every output.* and .mtr, logs/<step>.log and .timev, logs/tools.txt,
timings.tsv, refinement.tsv, input_md5.txt, summary.txt); mesh_summary.txt with mesh_chain.sh's two lines, 'MESH COUNTS:
...' and 'MESH CHAIN DONE: OK|FAILED ...'. --from-poly takes makeTetraMesh's unseeded output.poly in place of steps 1-4;
without it and without makeTetraMesh the run is refused (designer missing: use Phoenix (Run with --job mesh) or wait for
the Gmsh route). Exit: 0 done; 1 refused (nothing written) or failed; 130 interrupted; 143 SIGTERM. --dry-run prints the
plan and the resource estimate, writes nothing, and exits 0 if the run would start, else 1. Left out: Slurm, login-node
and job_outcomes.tsv logic (kit-only), and FIX_OUTPUT1 (a no-op with correct seeds; the attribute-set check catches
the stray regions it hid). Stricter than mesh_chain.sh: a .mtr whose rows differ from its header and a stray
output.i.b.node/.ele (tetgen -m would read it as a background mesh) fail. GUI API: run(..., progress=callback(step)).
"""
import argparse
import os
import re
import shutil
import signal
import sys
import threading
import time
import traceback

from . import backends, checks
from .io import tetgen as tetgen_io

MESH_INPUTS = ("analysis_domain.dat bathymetry.dat coast_line.dat control.dat makeMtr.param obs_site.dat "
               "observing_site.dat region_seeds.dat resistivity_attr.dat topography.dat").split()
SW0, SWR = "-nVpYAakq3.0/0", "-nmpYVrAakq3.0/0"          # run_mesh_chain.sh:158, :183; mesh_chain.sh
EARLIER = ("mesh.dat", "resistivity_block_iter0.dat", "intermediates", "mesh_summary.txt")
NAMES = dict(backends.STEPS)


class _Die(Exception):
    """A refusal or a failed check: exit 1 with this message."""


class Chain:
    def __init__(self, run_dir, files="files", rounds=5, tools=None, from_poly=None, t2f_args="", out=print, err=None,
                 progress=None):
        self.rd, self.files, self.rounds = os.path.abspath(run_dir), files, rounds
        self.tools, self.from_poly, self.t2f_args = tools, from_poly, t2f_args or ""
        self.out, self.err, self.progress = out, err or (lambda s: print(s, file=sys.stderr)), progress
        self.wd = os.path.join(self.rd, "intermediates")
        self.steps, self.stepname, self.started, self.counts, self.env = [], "setup", False, None, backends.port_env()

    def die(self, msg):
        raise _Die(msg)

    def w(self, name):
        return os.path.join(self.wd, name)

    def step(self, name, tool, *args):
        """Run one tool step in intermediates/ (mesh_chain.sh step()): log, timings row, the 'name rc' DONE item."""
        self.stepname = name
        if self.progress:
            self.progress(name)
        rc, wall, kb = backends.run_step(tool.argv + list(args), self.wd, self.w(f"logs/{name}.log"), self.env)
        cmd, rss = " ".join([tool.display] + list(args)), ("n/a" if kb is None else str(kb))
        with open(self.w(f"logs/{name}.timev"), "w", newline="\n") as fh:
            fh.write(f'\tCommand being timed: "{" ".join(tool.argv + list(args))}"\n\tElapsed (wall clock) time '
                     f'(s): {wall:.2f}\n\tMaximum resident set size (kbytes): {rss}\n\tExit status: {rc}\n')
        with open(self.w("timings.tsv"), "a", newline="\n") as fh:
            fh.write(f"{name}\t{rc}\t{wall:.2f}\t{rss}\t{cmd}\n")
        self.steps.append(f"{name} {rc}")
        self.out(f"[{time.strftime('%H:%M:%S')}] {name} rc={rc}  {wall:.2f} s  maxrss {rss} KB")
        return rc

    def refusal(self):
        """The reason this run would be refused before anything is written, or None (mesh_chain.sh's preamble)."""
        need = ([] if self.from_poly else ["designer"]) + ["tetgen", "sizing", "convert"]
        for s in need:
            t = self.tools[s]
            if not t.ok:
                return t.note if s == "designer" else f"{NAMES[s]} missing ({t.note}); {backends.PHOENIX}"
        if self.from_poly and not os.path.isfile(self.from_poly):
            return f"--from-poly {self.from_poly}: no such file"
        if not isinstance(self.rounds, int) or self.rounds < 0:
            return f"NROUNDS={self.rounds} (a whole number; 5 as in run_mesh_chain.sh)"
        if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*", self.files):
            return f"FILES={self.files} (a folder name inside the run folder, e.g. files)"
        if not os.path.isdir(self.rd):
            return f"cannot cd to the run folder {self.rd}"
        fd = os.path.join(self.rd, self.files)
        if not os.path.isdir(fd):
            return f"no inputs folder {fd} (scripts/make_run.sh --job mesh --files <dir> makes it)"
        miss = [f for f in MESH_INPUTS if not (os.path.isfile(os.path.join(fd, f))
                                               and os.path.getsize(os.path.join(fd, f)))]
        if miss:
            return f"{fd} lacks {' '.join(miss)} (a mesh run needs all 10: {' '.join(MESH_INPUTS)})"
        for f in EARLIER:
            p = os.path.join(self.rd, f)
            if os.path.exists(p) or os.path.islink(p):
                return (f"{p} exists: an earlier mesh build is in this run folder (move it away first; the chain "
                        "never overwrites one)")
        return None

    def plan(self):
        """[(step name, command)] the run would execute."""
        t, n = self.tools, self.rounds + 1
        p = [] if self.from_poly else [(f"stp{s}", f"{t['designer'].display} -stp {s}") for s in (1, 2, 3, 4)]
        p.append(("tetgen_1", f"{t['tetgen'].display} {SW0} output.poly"))
        for i in range(1, n):
            p += [(f"makeMtr_{i}", f"{t['sizing'].display} output.{i}"),
                  (f"tetgen_r{i}", f"{t['tetgen'].display} {SWR} output.{i}")]
        return p + [("t2f", " ".join([t["convert"].display] + self._t2f_args(n)))]

    def _t2f_args(self, n):
        extra = ([".", "--attr", "resistivity_attr.dat"] if self.tools["convert"].kind == "python" else [])
        return [f"output.{n}"] + extra + self.t2f_args.split()

    def go(self):
        why = self.refusal()
        if why:
            self.die(why)
        fd = os.path.join(self.rd, self.files)
        try:
            os.mkdir(self.wd)
            os.mkdir(self.w("logs"))
        except OSError:
            self.die(f"cannot make {self.wd}")
        self.started, self.summary = True, os.path.join(self.rd, "mesh_summary.txt")
        open(self.summary, "w").close()
        with open(self.w("logs/tools.txt"), "w", newline="\n") as fh:
            fh.write("".join(ln + "\n" for ln in backends.tools_lines(self.tools, self.from_poly)))
            fh.write(f"settings: FILES={self.files} NROUNDS={self.rounds} T2F_ARGS='{self.t2f_args}'\n")
        with open(self.w("timings.tsv"), "w", newline="\n") as fh:
            fh.write("step\trc\twall_s\tmaxrss_kb\tcommand\n")
        try:                                                       # ---- preflight (run_mesh_chain.sh's), on a copy
            dom, seed, res, air, used = checks.preflight(fd, self.wd, self.out)
        except checks.CheckFailed as exc:
            self.die(str(exc))
        self._mesh(dom, seed, res, air, len(used), used)
        return 0

    def _mesh(self, dom, seed, res, air, nseeds, used):
        T, n = self.tools, self.rounds + 1
        if self.from_poly:                                         # ---- STEP 1-4 makeTetraMesh, or its output.poly
            shutil.copyfile(self.from_poly, self.w("output.poly"))
        for s in ([] if self.from_poly else (1, 2, 3, 4)):
            rc = self.step(f"stp{s}", T["designer"], "-stp", str(s))
            if os.path.isfile(self.w("makeTetraMesh.log")):
                shutil.copyfile(self.w("makeTetraMesh.log"), self.w(f"logs/makeTetraMesh_stp{s}.log"))
            if rc:
                self.die(f"makeTetraMesh -stp {s} (see intermediates/logs/makeTetraMesh_stp{s}.log)")
            log = self.w("makeTetraMesh.log")
            if os.path.isfile(log) and "error" in open(log, errors="replace").read().lower():
                self.die(f"makeTetraMesh -stp {s} logged an error")
        if not os.path.isfile(self.w("output.poly")):
            self.die("makeTetraMesh -stp 4 produced no output.poly")
        with open(self.w("output.poly"), "rb") as fh:                # ---- region seeds into output.poly
            pl = fh.read().decode("ascii", "replace").split("\n")
        if pl and pl[-1] == "":
            pl.pop()
        if len(pl) < 2 or pl[-2] != "# Part 4" or pl[-1].replace(" ", "") != "0":
            self.die("unexpected output.poly tail (expected '# Part 4' then '0')")
        shutil.copyfile(self.w("output.poly"), self.w("logs/output.poly.unseeded"))
        pl[-1] = str(nseeds)
        with open(self.w("output.poly"), "w", newline="\n") as fh:
            fh.write("".join(s + "\n" for s in pl) + "".join(f"{k} {u}\n" for k, u in enumerate(used, 1)))
        if self.step("tetgen_1", T["tetgen"], SW0, "output.poly"):  # ---- STEP 5 tetgen
            self.die(f"tetgen {SW0} output.poly")
        if not os.path.isfile(self.w("output.1.ele")):
            self.die("tetgen produced no output.1.ele")
        for s in open(self.w("logs/tetgen_1.log"), errors="replace").read().splitlines():
            if re.search(r"Found [0-9]+ (subdomains|domain)", s):
                self.out("tetgen: " + s.lstrip())
        self._attrs("output.1", seed, air, dom, first=True)
        with open(self.w("refinement.tsv"), "w", newline="\n") as fh:   # ---- STEP 6 makeMtr + tetgen rounds
            fh.write("mesh\tnodes\telements\n" + self._ref_row(1))
        for i in range(1, n):
            mtr, j = self.w(f"output.{i}.mtr"), i + 1
            if os.path.exists(mtr):                                # keep tetgen's interpolated .mtr apart
                os.replace(mtr, self.w(f"output.{i}.tetgen.mtr"))
            if self.step(f"makeMtr_{i}", T["sizing"], f"output.{i}"):
                self.die(f"makeMtr output.{i}")
            if not (os.path.isfile(mtr) and os.path.getsize(mtr)):
                self.die(f"makeMtr produced no output.{i}.mtr")
            mn, nn = checks.first_field(mtr), checks.first_field(self.w(f"output.{i}.node"))
            if mn != nn:
                self.die(f"output.{i}.mtr lists {mn} values, output.{i}.node has {nn} nodes (tetgen would refine "
                         "without sizing)")
            try:
                tetgen_io.read_mtr(mtr)
            except ValueError as exc:
                self.die(f"{os.path.basename(str(exc).split(': ', 1)[0])}: {str(exc).split(': ', 1)[-1]}")
            for e in ("node", "ele"):
                if os.path.exists(self.w(f"output.{i}.b.{e}")):
                    self.die(f"output.{i}.b.{e} exists: tetgen -m would read it as a background mesh")
            if self.step(f"tetgen_r{i}", T["tetgen"], SWR, f"output.{i}"):
                self.die(f"tetgen {SWR} output.{i}")
            if not os.path.isfile(self.w(f"output.{j}.ele")):
                self.die(f"tetgen refinement {i} produced no output.{j}.ele")
            with open(self.w("refinement.tsv"), "a", newline="\n") as fh:
                fh.write(self._ref_row(j))
        self._attrs(f"output.{n}", seed, air, dom, first=False)
        if self.step("t2f", T["convert"], *self._t2f_args(n)):     # ---- STEP 7 TetGen2Femtic
            self.die(f"TetGen2Femtic output.{n} (see intermediates/logs/t2f.log)")
        if re.search(r"error|cannot", open(self.w("logs/t2f.log"), errors="replace").read(), re.I):
            self.die("TetGen2Femtic logged an error (see intermediates/logs/t2f.log)")
        prods = ["mesh.dat", "resistivity_block_iter0.dat", f"output.{n}.femtic.vtk"]
        for f in prods:
            if not (os.path.isfile(self.w(f)) and os.path.getsize(self.w(f))):
                self.die(f"missing product {f}")
        self._products(dom, seed, res, air, n, prods)

    def _ref_row(self, k):
        return (f"output.{k}\t{checks.first_field(self.w(f'output.{k}.node'))}\t"
                f"{checks.first_field(self.w(f'output.{k}.ele'))}\n")

    def _attrs(self, root, seed, air, dom, first):
        got = checks.attr_set(self.w(root + ".ele"))
        if first:
            self.out(f"{root}.ele region attributes:\n" + "\n".join(checks.attr_hist(self.w(root + ".ele"))))
        if got != seed:
            self.die(f"tetgen region attributes {{{got}}} != seeded {{{seed}}}: an unseeded closed region got max+1.. "
                     "(add a seed for it)" if first else f"{root}.ele region attributes {{{got}}} != seeded {{{seed}}}")
        msg, ok = checks.air_on_top(self.w(root), dom[2][0], dom[2][1], air)
        self.out(msg.replace(self.w(root), root))
        if not ok:
            self.die(f"air attribute {air} is not the region at the top of the domain (or is at the bottom): check the "
                     "region seeds" if first else
                     f"air attribute {air} is not the region at the top of the domain in {root}")

    def _products(self, dom, seed, res, air, n, prods):
        ne_ele, nn_ele = checks.first_field(self.w(f"output.{n}.ele")), checks.first_field(self.w(f"output.{n}.node"))
        nn_mesh = checks.first_field(self.w("mesh.dat"), 2)
        ne_mesh = checks.first_field(self.w("mesh.dat"), int(checks._awkval(nn_mesh)) + 3)
        blk = self.w("resistivity_block_iter0.dat")
        ne_blk, ncell = checks.first_field(blk), checks._second(blk)
        if not (ne_ele == ne_mesh == ne_blk):
            self.die(f"element counts disagree: ele {ne_ele}, mesh.dat {ne_mesh}, block {ne_blk}")
        if nn_ele != nn_mesh:
            self.die(f"node counts disagree: node {nn_ele}, mesh.dat {nn_mesh}")
        vt, vb, vr, vz, ok = checks.volume_check(self.w(f"output.{n}"), dom)
        if not ok:
            self.die(f"element volumes sum to {vt} km^3 vs analysis box {vb} km^3 (rel {vr}, {vz} zero-volume "
                     "elements)")
        self.stepname = "products"
        for f in prods:
            try:
                os.replace(self.w(f), os.path.join(self.rd, f))
            except OSError:
                self.die(f"cannot move {f} to {self.rd}")
        try:
            self.counts = checks.mesh_counts(self.rd)
        except (ValueError, OSError) as exc:
            self.err(str(exc))
            self.die(f"cannot count the products in {self.rd} (mesh_counts above)")
        self.out(f"MESH COUNTS: {self.counts}")
        with open(self.summary, "a", newline="\n") as fh:
            fh.write(f"MESH COUNTS: {self.counts}\n")
        seeds = "".join(u + ";" for u in open(self.w("region_seeds.used")).read().splitlines())
        s = (f"run_dir            : {self.rd} (inputs {self.files}/, work intermediates/)\n"
             f"refinement rounds  : {self.rounds}  (final mesh output.{n})\nregion seeds       : {seeds}\n"
             f"region attributes  : {{{seed}}} in output.1.ele and output.{n}.ele (resistivity_attr.dat: {{{res}}}, "
             f"air {air})\n"
             f"nodes / elements   : {nn_mesh} / {ne_mesh}\nparameter cells    : {ncell} (cell 0 = air)\n"
             f"volume check       : sum |V| = {vt} km^3, box = {vb} km^3, rel err {vr}\n"
             f"total wall time    : {int(time.time() - self.t0)} s\ncounts             : {self.counts}\n")
        with open(self.w("summary.txt"), "w", newline="\n") as fh:
            fh.write(s)
        self.out(s.rstrip("\n"))
        for name in ("refinement", "timings"):
            self.out(f"{name}:\n" + "\n".join("  " + r for r in open(self.w(f"{name}.tsv")).read().splitlines()))


class _Term(Exception):
    """SIGTERM (Slurm's --time limit, scancel)."""


def run(run_dir, files="files", rounds=5, bin_dir=None, tetgen=None, prefer="binary", from_poly=None, t2f_args="",
        overrides=None, out=print, err=None, progress=None):
    """Run the chain; returns {'rc', 'done' (the DONE line), 'counts' (or None), 'run_dir'}."""
    tools, _ = backends.locate(bin_dir, prefer, overrides=overrides, tetgen=tetgen)
    c = Chain(run_dir, files, rounds, tools, from_poly, t2f_args, out, err, progress)
    c.t0 = time.time()
    old = None
    if hasattr(signal, "SIGTERM") and threading.current_thread() is threading.main_thread():
        def _term(*_):
            raise _Term()
        old = signal.signal(signal.SIGTERM, _term)
    msg, rc = "", 0
    try:
        rc = c.go()
    except _Die as d:
        msg, rc = str(d), 1
    except KeyboardInterrupt:
        msg, rc = "stopped by SIGINT", 130
    except _Term:
        msg, rc = "stopped by SIGTERM (the --time limit, or scancel)", 143
    except Exception as exc:                                       # a bug or an I/O error: still a DONE line
        c.err(traceback.format_exc())
        msg, rc = f"unexpected {type(exc).__name__}: {exc}", 1
    finally:
        if old is not None:
            signal.signal(signal.SIGTERM, old)
    if msg and rc == 1:
        c.err(f"MESH CHAIN FAILED: {msg}")
        if c.started:
            with open(c.w("summary.txt"), "a", newline="\n") as fh:
                fh.write(f"MESH CHAIN FAILED: {msg}\n")
    items = ", ".join(c.steps)
    done = (f"MESH CHAIN DONE: OK, exit 0 ({items})" if rc == 0 else
            f"MESH CHAIN DONE: FAILED, exit {rc} at {c.stepname}: {msg or 'see the log above'} ({items})")
    out(done)
    if c.started:
        with open(c.summary, "a", newline="\n") as fh:
            fh.write(done + "\n")
    return {"rc": rc, "done": done, "counts": c.counts, "run_dir": c.rd}


def main(argv=None):
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(newline="\n", line_buffering=True)
    ap = argparse.ArgumentParser(prog="python -m femtic_mesh.chain", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir", help="the run folder (holds FILES/; gets intermediates/ and the products)")
    ap.add_argument("--files", default=os.environ.get("FILES", "files"), help="inputs folder name (default files)")
    ap.add_argument("--rounds", type=int, default=int(os.environ.get("NROUNDS", "5")), help="refinement rounds (5)")
    ap.add_argument("--bin", default=None, help="folder of the C++ tools (default $BIN, then $FEMTIC_BIN)")
    ap.add_argument("--tetgen", default=None, help="this tetgen executable first")
    ap.add_argument("--prefer", choices=("binary", "python"), default="binary", help="C++ tool or port (binary)")
    ap.add_argument("--from-poly", default=None, help="makeTetraMesh's unseeded output.poly, in place of steps 1-4")
    ap.add_argument("--t2f-args", default=os.environ.get("T2F_ARGS", ""), help="extra TetGen2Femtic arguments")
    ap.add_argument("--dry-run", action="store_true", help="print the plan and the estimate; write nothing")
    a = ap.parse_args(argv)
    kw = {k: getattr(a, k) for k in ("files", "rounds", "tetgen", "prefer", "from_poly", "t2f_args")}
    try:
        if a.dry_run:
            from .doctor import dry_run
            return dry_run(a.run_dir, bin_dir=a.bin, **kw)
        return run(a.run_dir, bin_dir=a.bin, **kw)["rc"]
    except ValueError as exc:                                      # e.g. --tetgen is not an executable
        print(f"MESH CHAIN DONE: FAILED, exit 1 at setup: {exc} ()")
        return 1


if __name__ == "__main__":
    sys.exit(main())
