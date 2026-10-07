"""Where each step of the mesh chain comes from on this machine, what the machine has, and how a step is run.

The chain (hpc/phoenix_plan/mesh_chain.sh, femtic_mesh.chain) has four tool steps:
  designer  makeTetraMesh -stp 1..4       C++ only for now (no port; the Gmsh route is study P3)
  tetgen    tetgen                        C++: the chain's own build (Phoenix $VF/bin), or the conda-forge executable
  sizing    makeMtr output.i              C++, or the Python port femtic_mesh.makemtr
  convert   TetGen2Femtic output.N        C++, or the Python port femtic_mesh.tetgen2femtic
(repartition, Python only, is reported but is not a chain step.)
A C++ tool is searched in the bin folder (argument, else $BIN, else $FEMTIC_BIN), then on PATH; tetgen also in the
conda prefixes (sys.prefix, $CONDA_PREFIX; Library/bin on Windows, bin elsewhere), where conda-meta names the package.
prefer='binary' takes a C++ tool when one is found, else the port; prefer='python' takes the port when there is one.
The conda-forge tetgen is not byte-identical to the chain's build (round 0 of chain_proof already differs:
docs/dev/mesh_port_progress.md s4); the Phoenix half-space gate is the acceptance test for any local mesh (D11).

machine() reports cores and RAM (psutil if installed, else the OS: GlobalMemoryStatusEx, /proc/meminfo, sysconf).
estimate() turns the measured reference builds (WSL, gcc tools) into a local-or-Phoenix advice.
run_step() runs one command with its output in a log file and returns exit code, wall time and peak RSS.
"""
import ctypes
import glob
import importlib.util
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field

STEPS = (("designer", "makeTetraMesh"), ("tetgen", "tetgen"), ("sizing", "makeMtr"), ("convert", "TetGen2Femtic"))
PORTS = {"sizing": "femtic_mesh.makemtr", "convert": "femtic_mesh.tetgen2femtic",
         "repartition": "femtic_mesh.repartition"}
SRC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))        # the folder holding femtic_mesh/
PHOENIX = ("Phoenix: make a mesh run on the PC (bash scripts/make_run.sh RunNN --job mesh --files <inputs folder> "
           "--purpose \"...\"), upload it and submit it with run.sh (hpc/phoenix_plan/RUNBOOK.md F3)")
DESIGNER_MISSING = "designer missing: use Phoenix (Run with --job mesh) or wait for the Gmsh route"

# Measured builds (WSL2 Ubuntu 24.04, gcc tools, tetgen libigl e05aca7): the steps of each timings.tsv summed without
# fix_output1; peak_mb is the largest step, always a tetgen round (KB / 1024). The Python ports at v2 size, on this PC:
# TetGen2Femtic port 577-582 MB, 15.2-15.9 s (docs/dev/mesh_port_progress.md s4); makeMtr port: section P2 there.
REFERENCES = {
    "chain_proof": {"tets": 27_501, "wall_s": 1.2, "peak_mb": 16, "src": "mesh/chain_proof/logs/timings.tsv"},
    "chain_proof_meshgen": {"tets": 418_186, "wall_s": 48.7, "peak_mb": 177,
                            "src": "mesh/chain_proof_meshgen/logs/timings.tsv"},
    "v1": {"tets": 1_534_902, "wall_s": 248.7, "peak_mb": 584, "src": "mesh/vulcan_v1/mesh_logs/timings.tsv"},
    "v2": {"tets": 2_446_095, "wall_s": 348.5, "peak_mb": 956, "src": "mesh/vulcan_v2/mesh_logs/timings.tsv"},
    "v3": {"tets": 3_068_130, "wall_s": 987.0, "peak_mb": 1211, "src": "mesh/vulcan_v3/mesh_logs/timings.tsv"},
}
PORT_BASE_MB, PORT_V2_MB = 28, 582   # measured: python + numpy alone; the TetGen2Femtic port on v2


def port_peak_mb(tets):
    """Peak RSS of the heavier Python port: linear between the bare interpreter with numpy (PORT_BASE_MB) and the
    TetGen2Femtic port on v2 (PORT_V2_MB, measured). An estimate between the two measured points."""
    return round(PORT_BASE_MB + (PORT_V2_MB - PORT_BASE_MB) * tets / REFERENCES["v2"]["tets"])


@dataclass
class Tool:
    step: str
    kind: str                         # 'binary' | 'conda-forge' | 'python' | 'override' | 'missing'
    argv: list = field(default_factory=list)   # command prefix; the step's arguments follow
    display: str = ""                 # the command name written to timings.tsv
    where: str = ""                   # executable path or module file
    note: str = ""

    @property
    def ok(self):
        return self.kind != "missing"


def _conda_prefixes(env):
    out = []
    for p in (sys.prefix, env.get("CONDA_PREFIX")):
        if p and os.path.isdir(os.path.join(p, "conda-meta")) and os.path.abspath(p) not in out:
            out.append(os.path.abspath(p))
    return out


def _conda_pkg(exe, prefixes):
    """'tetgen-1.6.0-hac47afa_2' if exe lies in a conda prefix (a known one, or the env two or three folders up:
    env/bin/tetgen, env/Library/bin/tetgen.exe) whose conda-meta lists tetgen, else ''."""
    a = os.path.abspath(exe)
    for root in prefixes + [os.path.dirname(os.path.dirname(a)), os.path.dirname(os.path.dirname(os.path.dirname(a)))]:
        if os.path.normcase(a).startswith(os.path.normcase(root) + os.sep):
            m = sorted(glob.glob(os.path.join(root, "conda-meta", "tetgen-*.json")))
            if m:
                return os.path.basename(m[-1])[:-5]
    return ""


def bin_dir_of(bin_dir=None, env=None):
    env = os.environ if env is None else env
    return bin_dir or env.get("BIN") or env.get("FEMTIC_BIN") or ""


def find_binaries(name, bin_dir=None, env=None, given=None):
    """Every C++ candidate for `name`: [(path, origin)], origin 'given', 'bin', 'PATH' or 'conda'."""
    env = os.environ if env is None else env
    seen, out = set(), []

    def add(p, origin):
        if p and os.path.normcase(os.path.abspath(p)) not in seen:
            seen.add(os.path.normcase(os.path.abspath(p)))
            out.append((os.path.abspath(p), origin))
    if given:
        if not (os.path.isfile(given) and os.access(given, os.X_OK)):
            raise ValueError(f"{name} {given}: not an executable file")
        add(given, "given")
    b = bin_dir_of(bin_dir, env)
    if b:
        add(shutil.which(name, path=b), "bin")
    add(shutil.which(name, path=env.get("PATH", "")), "PATH")
    if name == "tetgen":
        for p in _conda_prefixes(env):
            for sub in ("Library/bin", "bin"):
                add(shutil.which(name, path=os.path.join(p, sub)), "conda")
    return out


def port_tool(step):
    mod = PORTS[step]
    spec = importlib.util.find_spec(mod)
    if spec is None:
        return Tool(step, "missing", note=f"{mod} not importable")
    return Tool(step, "python", [sys.executable, "-m", mod], f"python -m {mod}", spec.origin, "Python port")


def locate(bin_dir=None, prefer="binary", env=None, overrides=None, tetgen=None):
    """(chosen, found): chosen[step] is the Tool the chain uses; found[step] lists every candidate. tetgen names an
    executable to use first; overrides maps a step to a full command prefix (a test's fake or mutant tool)."""
    if prefer not in ("binary", "python"):
        raise ValueError("prefer must be 'binary' or 'python'")
    env = os.environ if env is None else env
    prefixes = _conda_prefixes(env)
    found = {}
    for step, name in STEPS:
        cands = []
        for path, origin in find_binaries(name, bin_dir, env, tetgen if name == "tetgen" else None):
            pkg = _conda_pkg(path, prefixes) if name == "tetgen" else ""
            note = f"{pkg}; not byte-identical to the chain's tetgen build" if pkg else f"C++ ({origin})"
            cands.append(Tool(step, "conda-forge" if pkg else "binary", [path], name, path, note))
        if step in PORTS:
            t = port_tool(step)
            if t.ok:
                cands.append(t)
        found[step] = cands
    found["repartition"] = [port_tool("repartition")]
    chosen = {}
    for step, name in STEPS:
        c = found[step]
        if overrides and step in overrides:
            argv = list(overrides[step])
            chosen[step] = Tool(step, "override", argv, name, " ".join(argv), "given by the caller")
        elif not c:
            chosen[step] = Tool(step, "missing", note=DESIGNER_MISSING if step == "designer" else (
                f"no {name} in the bin folder, on PATH or in a conda env (conda install -c conda-forge tetgen=1.6.0)"))
        elif prefer == "python" and any(t.kind == "python" for t in c):
            chosen[step] = next(t for t in c if t.kind == "python")
        else:
            chosen[step] = c[0]
    return chosen, found


def port_env(env=None):
    """The environment for a step: PYTHONPATH starts with the folder that holds femtic_mesh (no install needed)."""
    e = dict(os.environ if env is None else env)
    e["PYTHONPATH"] = SRC + (os.pathsep + e["PYTHONPATH"] if e.get("PYTHONPATH") else "")
    return e


def machine():
    """{'cores', 'ram_total_mb', 'ram_avail_mb', 'source'}; a value the OS does not give is None."""
    out = {"cores": os.cpu_count(), "ram_total_mb": None, "ram_avail_mb": None, "source": "os"}
    try:
        import psutil
        vm = psutil.virtual_memory()
        out.update(ram_total_mb=vm.total // 2**20, ram_avail_mb=vm.available // 2**20, source="psutil")
        return out
    except Exception:
        pass
    try:
        if os.name == "nt":
            class MEMSTAT(ctypes.Structure):
                _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong),
                            ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
                            ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                            ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong),
                            ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]
            m = MEMSTAT()
            m.dwLength = ctypes.sizeof(MEMSTAT)
            if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(m)):
                out.update(ram_total_mb=m.ullTotalPhys // 2**20, ram_avail_mb=m.ullAvailPhys // 2**20)
        elif os.path.exists("/proc/meminfo"):
            kv = {}
            with open("/proc/meminfo") as fh:
                for ln in fh:
                    k, v = ln.split(":", 1)
                    kv[k] = int(v.split()[0])
            out.update(ram_total_mb=kv.get("MemTotal", 0) // 1024 or None,
                       ram_avail_mb=kv["MemAvailable"] // 1024 if "MemAvailable" in kv else None)
        else:
            out["ram_total_mb"] = os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE") // 2**20
    except Exception:
        pass
    return out


def estimate(size="v2", mach=None):
    """Advice for a build of the given reference size: wall time and peak memory as measured, the RAM it needs
    (twice the larger of the tetgen and Python-port peaks), and 'local' or 'phoenix'."""
    ref = REFERENCES[size]
    mach = machine() if mach is None else mach
    peak = max(ref["peak_mb"], port_peak_mb(ref["tets"]))
    need = 2 * peak
    avail = mach.get("ram_avail_mb")
    verdict = "unknown" if avail is None else ("local" if avail >= need else "phoenix")
    return {"size": size, "tets": ref["tets"], "wall_s": ref["wall_s"], "peak_mb": peak, "need_mb": need,
            "avail_mb": avail, "verdict": verdict,
            "basis": f"{ref['src']} (WSL, gcc tools, one thread); the conda-forge tetgen at this size is unmeasured"}


def _win_peak_kb(proc):
    class PMC(ctypes.Structure):
        _fields_ = [("cb", ctypes.c_ulong), ("PageFaultCount", ctypes.c_ulong)] + [
            (n, ctypes.c_size_t) for n in ("PeakWorkingSetSize", "WorkingSetSize", "QuotaPeakPagedPoolUsage",
                                           "QuotaPagedPoolUsage", "QuotaPeakNonPagedPoolUsage",
                                           "QuotaNonPagedPoolUsage", "PagefileUsage", "PeakPagefileUsage")]
    c = PMC()
    c.cb = ctypes.sizeof(PMC)
    k32 = ctypes.windll.kernel32
    k32.K32GetProcessMemoryInfo.argtypes = [ctypes.c_void_p, ctypes.POINTER(PMC), ctypes.c_ulong]
    if k32.K32GetProcessMemoryInfo(ctypes.c_void_p(int(proc._handle)), ctypes.byref(c), c.cb):
        return c.PeakWorkingSetSize // 1024
    return None


def run_step(argv, cwd, log_path, env=None):
    """Run argv in cwd, stdout and stderr to log_path. Returns (exit code, wall seconds, peak RSS in KB or None):
    os.wait4's ru_maxrss on POSIX, the process's PeakWorkingSetSize on Windows (read before its handle closes)."""
    t0 = time.perf_counter()
    with open(log_path, "wb") as log:
        try:
            proc = subprocess.Popen(argv, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, env=env)
        except OSError as exc:
            log.write(f"cannot start {argv[0]}: {exc}\n".encode())
            return 127, time.perf_counter() - t0, None
        try:
            if os.name == "nt":
                rc = proc.wait()
                kb = _win_peak_kb(proc)
            else:
                _, status, ru = os.wait4(proc.pid, 0)
                rc = proc.returncode = os.waitstatus_to_exitcode(status)
                kb = ru.ru_maxrss // (1024 if sys.platform == "darwin" else 1)
        except BaseException:
            proc.kill()
            proc.wait()
            raise
    return rc, time.perf_counter() - t0, kb


def tools_lines(tools, from_poly=None):
    """The lines of intermediates/logs/tools.txt: each step's backend (with the md5 of a C++ executable, a record as
    mesh_chain.sh keeps one, not a check), then Python, numpy and the machine."""
    import hashlib
    import numpy
    out = []
    for s, name in STEPS:
        t = tools[s]
        if s == "designer" and from_poly:
            out.append(f"designer  skipped: output.poly from {os.path.abspath(from_poly)}")
            continue
        md5 = ""
        if t.kind in ("binary", "conda-forge") and os.path.isfile(t.where):
            with open(t.where, "rb") as fh:
                md5 = "  md5 " + hashlib.md5(fh.read()).hexdigest()
        out.append(f"{s:<9} {name:<14} {t.kind:<12} {t.where}{md5}  ({t.note})")
    m = machine()
    out.append(f"python {sys.version.split()[0]} ({sys.executable}), numpy {numpy.__version__}, {sys.platform}, "
               f"{m['cores']} cores, RAM {m['ram_total_mb']} MB ({m['ram_avail_mb']} MB free)")
    return out
