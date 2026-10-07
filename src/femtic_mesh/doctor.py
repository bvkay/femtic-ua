"""Can this machine build a FEMTIC mesh itself, or should the build go to Phoenix?

  python -m femtic_mesh.doctor [--bin DIR] [--tetgen EXE] [--prefer binary|python]

prints, for each step of the chain (femtic_mesh.backends.STEPS), the tool found: a C++ binary, the conda-forge
tetgen, a Python port, or MISSING, with every other candidate; then the machine (cores, RAM) and the measured cost of
a v2- and a v3-size build with a local-or-Phoenix advice (backends.estimate). Exit 0 only when a complete chain is
available (designer, tetgen, sizing, convert); exit 2 otherwise, naming what is missing, the Phoenix alternative
(hpc/phoenix_plan/RUNBOOK.md F3) and, when only the designer is missing, the local route from an existing output.poly.
The GUI's 'Build mesh: Local | Phoenix' choice reads the same facts through report().
dry_run() is the chain's --dry-run (python -m femtic_mesh.chain RUN_DIR --dry-run): the plan, nothing written.
"""
import argparse
import sys

from . import backends


def tool_lines(tools, from_poly=None, found=None):
    """One line per step (chosen tool; '*' marks it among the other candidates when found is given)."""
    out = [f"  {'step':<9} {'tool':<14} {'backend':<12} where"]
    for s, name in backends.STEPS:
        t = tools[s]
        if s == "designer" and from_poly:
            out.append(f"  {s:<9} {name:<14} {'skipped':<12} output.poly from {from_poly}")
            continue
        kind = "MISSING" if not t.ok else t.kind
        out.append(f"  {s:<9} {name:<14} {kind:<12} {t.where if t.ok else t.note}")
        if t.ok and t.note:
            out.append(f"  {'':<9} {'':<14} {'':<12} ({t.note})")
        for o in (found or {}).get(s, []):
            if o.where != t.where:
                out.append(f"  {'':<9} {'':<14} {'also ' + o.kind:<12} {o.where}")
    if found:
        r = found["repartition"][0]
        out.append(f"  {'(repartition, not a chain step)':<38} {r.kind:<12} {r.where or r.note}")
    return out


def estimate_lines(mach):
    out = [f"  machine: {mach['cores']} cores, RAM {mach['ram_total_mb']} MB ({mach['ram_avail_mb']} MB free; "
           f"read by {mach['source']})"]
    for size in ("v2", "v3"):
        e = backends.estimate(size, mach)
        out.append(f"  a {size}-size build ({e['tets']:,} tets): about {e['wall_s']:.0f} s and {e['peak_mb']} MB "
                   f"peak as measured; needs {e['need_mb']} MB free -> {e['verdict']}")
    out.append(f"  (basis: {backends.estimate('v2', mach)['basis']})")
    return out


def report(bin_dir=None, tetgen=None, prefer="binary", out=print):
    """Print the table, the machine, the estimate and the verdict. Returns (exit code, missing step names)."""
    tools, found = backends.locate(bin_dir, prefer, tetgen=tetgen)
    import numpy
    out(f"femtic_mesh doctor: can this machine build a mesh? (python {sys.version.split()[0]}, numpy "
        f"{numpy.__version__}, {sys.platform}; bin folder: {backends.bin_dir_of(bin_dir) or 'none'})")
    for ln in tool_lines(tools, found=found):
        out(ln)
    for ln in estimate_lines(backends.machine()):
        out(ln)
    missing = [s for s, _ in backends.STEPS if not tools[s].ok]
    if not missing:
        out("VERDICT: COMPLETE (exit 0): python -m femtic_mesh.chain RUN_DIR builds a mesh on this machine; the "
            "half-space gate on Phoenix is still its acceptance test (D11)")
        return 0, missing
    names = ", ".join(f"{s} ({dict(backends.STEPS)[s]})" for s in missing)
    out(f"VERDICT: INCOMPLETE (exit 2): missing {names}.")
    for s in missing:
        out(f"  {s}: {tools[s].note}")
    out(f"  {backends.PHOENIX}.")
    if missing == ["designer"]:
        out("  Local now, after the designer: python -m femtic_mesh.chain RUN_DIR --from-poly <makeTetraMesh's "
            "unseeded output.poly> runs every later step here.")
    return 2, missing


def dry_run(run_dir, files="files", rounds=5, bin_dir=None, tetgen=None, prefer="binary", from_poly=None, t2f_args="",
            overrides=None, out=print):
    """The chain's plan (tools, steps, estimate); writes nothing. Returns 0 if the run would start, else 1."""
    from .chain import Chain
    tools, _ = backends.locate(bin_dir, prefer, overrides=overrides, tetgen=tetgen)
    c = Chain(run_dir, files, rounds, tools, from_poly, t2f_args, out)
    out(f"femtic_mesh.chain plan (dry run: nothing is written): run folder {c.rd}, inputs {files}/, {rounds} rounds")
    for ln in tool_lines(tools, from_poly):
        out(ln)
    why = c.refusal()
    for name, cmd in ([] if why else c.plan()):
        out(f"  step {name:<12} {cmd}")
    for ln in estimate_lines(backends.machine()):
        out(ln)
    out(f"PLAN: REFUSED: {why}" if why else f"PLAN: would run {len(c.plan())} steps")
    return 1 if why else 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="python -m femtic_mesh.doctor", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bin", default=None, help="folder of the C++ tools (default $BIN, then $FEMTIC_BIN)")
    ap.add_argument("--tetgen", default=None, help="a tetgen executable to consider first")
    ap.add_argument("--prefer", choices=("binary", "python"), default="binary")
    a = ap.parse_args(argv)
    try:
        return report(a.bin, a.tetgen, a.prefer)[0]
    except ValueError as exc:
        print(f"doctor: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
