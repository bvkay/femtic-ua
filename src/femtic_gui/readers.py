# -*- coding: utf-8 -*-
"""readers.py - small readers of the repository's text files for the GUI (no Qt).

runs/INDEX.md (one table line per run, written by scripts/make_run.sh), the option lines of make_run.sh's own
header (the New-run form's tooltips), mesh_logs/mesh_stats.txt (measured mesh counts) and station_map.csv.
record_result() rewrites the job-id and verdict cells of one INDEX.md line and nothing else.

@author ben kay
:license: MIT
"""
from __future__ import annotations

import csv
import os
import re
from pathlib import Path

INDEX_COLUMNS = ("run", "mesh", "purpose", "layout", "jobs", "verdict")
RUN_RE = re.compile(r"^Run(\d{2,})$")


class ReaderError(Exception):
    """A file could not be read or an edit was refused; the message says why."""


def _cells(line: str) -> list[str] | None:
    parts = line.rstrip("\r\n").split("|")
    if len(parts) != 8 or parts[0].strip() or parts[-1].strip():
        return None
    return parts


def read_index(path: str | os.PathLike) -> list[dict]:
    """Read the run lines of runs/INDEX.md.

    Returns:
        One dict per run line (keys INDEX_COLUMNS plus 'line', its 0-based line number), in file order.
        A missing file gives an empty list.
    """
    p = Path(path)
    if not p.is_file():
        return []
    rows = []
    with open(p, encoding="utf-8", newline="") as fh:
        for n, line in enumerate(fh):
            parts = _cells(line)
            if parts is None:
                continue
            vals = [c.strip() for c in parts[1:7]]
            if RUN_RE.match(vals[0]):
                rows.append(dict(zip(INDEX_COLUMNS, vals), line=n))
    return rows


def record_result(path: str | os.PathLike, run: str, jobs: str, verdict: str) -> None:
    """Fill the job id(s) and verdict cells of one run's INDEX.md line; every other byte stays as it is.

    Raises:
        ReaderError: if the run has no line, a value is empty or holds '|' or a line break.
    """
    for what, v in (("job id(s)", jobs), ("verdict", verdict)):
        if not v.strip() or "|" in v or "\n" in v or "\r" in v:
            raise ReaderError("refused: the %s must be one line of text without '|'" % what)
    p = Path(path)
    with open(p, encoding="utf-8", newline="") as fh:
        lines = fh.readlines()
    hits = [n for n, ln in enumerate(lines) if (c := _cells(ln)) is not None and c[1].strip() == run]
    if len(hits) != 1:
        raise ReaderError("refused: %s has %d lines for %s, expected one" % (p, len(hits), run))
    n = hits[0]
    parts = _cells(lines[n])
    eol = lines[n][len(lines[n].rstrip("\r\n")):]
    parts[5], parts[6] = " %s " % jobs.strip(), " %s " % verdict.strip()
    lines[n] = "|".join(parts) + eol
    with open(p, "w", encoding="utf-8", newline="") as fh:
        fh.writelines(lines)


def next_run_name(runs_dir: str | os.PathLike, rows: list[dict]) -> str:
    """The next free run name: one above the highest RunNN among the folders of runs_dir and INDEX.md's lines."""
    nums = [int(m.group(1)) for r in rows if (m := RUN_RE.match(r["run"]))]
    d = Path(runs_dir)
    if d.is_dir():
        nums += [int(m.group(1)) for e in d.iterdir() if (m := RUN_RE.match(e.name))]
    return "Run%02d" % (max(nums, default=0) + 1)


def make_run_options(path: str | os.PathLike) -> dict[str, str]:
    """The option lines of make_run.sh's header ('#   --opt ...' and their continuation lines).

    Returns:
        {'--mesh': '--mesh v2|v3  the shared mesh on Phoenix ...', ...}; for '--iter-step N --iter-max N'
        both options map to the same text.
    """
    opts: dict[str, str] = {}
    cur: list[str] = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if not line.startswith("#"):
                if line.strip():
                    break
                continue
            body = line[1:].rstrip()
            if re.match(r"^\s{3}--", body):
                cur = re.findall(r"--[a-z-]+", re.split(r"\s{2,}", body.strip(), maxsplit=1)[0])
                text = " ".join(body.split())
                for o in dict.fromkeys(cur):
                    opts[o] = text
            elif cur and re.match(r"^\s{10,}\S", body):
                for o in dict.fromkeys(cur):
                    opts[o] += " " + " ".join(body.split())
            else:
                cur = []
    return opts


def mesh_stats_lines(mesh_dir: str | os.PathLike) -> list[str]:
    """Lines 1-2 of <mesh_dir>/mesh_logs/mesh_stats.txt (node, element and cell counts), or [] if absent."""
    p = Path(mesh_dir) / "mesh_logs" / "mesh_stats.txt"
    if not p.is_file():
        return []
    with open(p, encoding="utf-8", errors="replace") as fh:
        return [fh.readline().rstrip("\r\n") for _ in range(2)]


def read_station_map(path: str | os.PathLike) -> list[dict]:
    """Rows of a prep station_map.csv as dicts (femtic_station_id, site_id, x_north_km, y_east_km, ...)."""
    with open(path, encoding="utf-8", newline="") as fh:
        return list(csv.DictReader(fh))


# --------------------------------------------------------------------------------- FEMTIC outputs (Results tab)
RESULT_RE = re.compile(r"^result_(\d+)_iter(\d+)\.csv$")
BLOCK_RE = re.compile(r"^resistivity_block_iter(\d+)\.dat$")
CNV_COLUMNS = ("iter", "retrial", "alpha", "damp", "roughness", "misfit", "rms", "objfunc")
Z_NAMES = ("Zxx", "Zxy", "Zyx", "Zyy")


def scan_results(folder: str | os.PathLike) -> dict:
    """Group a copied-back run folder's FEMTIC outputs; EnSight and unknown files are ignored.

    Returns:
        {'model': {N: block path}, 'fit': {N: [csv paths, by rank]}, 'convergence': [cnv paths, archives in name
        order (logs/run_*/femtic.cnv) then femtic.cnv]}.
    """
    d = Path(folder)
    model: dict[int, Path] = {}
    fit: dict[int, list[tuple[int, Path]]] = {}
    for p in sorted(d.iterdir()) if d.is_dir() else []:
        if (m := BLOCK_RE.match(p.name)):
            model[int(m.group(1))] = p
        elif (m := RESULT_RE.match(p.name)):
            fit.setdefault(int(m.group(2)), []).append((int(m.group(1)), p))
    cnv = sorted(d.glob("logs/run_*/femtic.cnv")) + ([d / "femtic.cnv"] if (d / "femtic.cnv").is_file() else [])
    return {"model": dict(sorted(model.items())),
            "fit": {n: [p for _r, p in sorted(v)] for n, v in sorted(fit.items())}, "convergence": cnv}


def read_result_csv(paths: list) -> dict:
    """Read the MT block of FEMTIC's result_<rank>_iter<N>.csv files (the ranks of one iteration, concatenated).

    Line 1 'MT,', line 2 the header (StaID, Freq[Hz], Re/Im of Zxx..Zyy for _Cal, _Res, _Obs, _SD); the block ends
    at the 'VTF,' line. Z in ohm, exp(-i omega t); _Res = (Obs - Cal) / SD.

    Returns:
        {'sta': (n,) int, 'freq': (n,) Hz, 'cal', 'obs': (n, 4) complex, 'res', 'sd': (n, 8) Re/Im pairs}.

    Raises:
        ReaderError: if a file does not start with the MT block or lacks a column.
    """
    import numpy as np
    parts = []
    for path in paths:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
        if not lines or lines[0].strip() != "MT,":
            raise ReaderError("%s: line 1 is not 'MT,'" % path)
        head = [h.strip() for h in lines[1].split(",")]
        rows = []
        for ln in lines[2:]:
            if ln.strip().startswith("VTF") or not ln.strip():
                break
            rows.append([float(v) for v in ln.split(",") if v.strip()])
        a = np.array(rows, dtype=float).reshape(len(rows), -1)
        try:
            col = {k: head.index(k) for k in ["StaID", "Freq[Hz]"] + ["%s(%s)_%s" % (ri, z, s) for s in
                   ("Cal", "Res", "Obs", "SD") for z in Z_NAMES for ri in ("Re", "Im")]}
        except ValueError as e:
            raise ReaderError("%s: header lacks %s" % (path, e)) from None
        parts.append((a, col))
    out: dict = {}
    for a, col in parts:
        def pairs(s):
            return np.column_stack([a[:, col["%s(%s)_%s" % (ri, z, s)]] for z in Z_NAMES for ri in ("Re", "Im")])
        cur = {"sta": a[:, col["StaID"]].astype(int), "freq": a[:, col["Freq[Hz]"]], "res": pairs("Res"),
               "sd": pairs("SD"), "cal": pairs("Cal")[:, 0::2] + 1j * pairs("Cal")[:, 1::2],
               "obs": pairs("Obs")[:, 0::2] + 1j * pairs("Obs")[:, 1::2]}
        out = cur if not out else {k: np.concatenate([out[k], cur[k]]) for k in cur}
    return out


def site_misfit(fit: dict) -> list[dict]:
    """Per station: RMS = sqrt(mean _Res^2) over its rows' eight residuals, and the worst |_Res| with its band."""
    import numpy as np
    out = []
    for s in sorted(set(fit["sta"].tolist())):
        k = fit["sta"] == s
        r = fit["res"][k]
        i, j = np.unravel_index(int(np.argmax(np.abs(r))), r.shape)
        out.append({"sta": int(s), "rms": float(np.sqrt(np.mean(r ** 2))), "worst": float(abs(r[i, j])),
                    "worst_hz": float(fit["freq"][k][i]),
                    "worst_comp": "%s(%s)" % ("Re" if j % 2 == 0 else "Im", Z_NAMES[j // 2])})
    return out


def read_cnv(paths: list) -> list[tuple]:
    """Merge femtic.cnv files read in the given order, keeping the last row per Iter# (the accepted one).

    FEMTIC truncates femtic.cnv at every start, so a restarted run's history is its archived copies, in name order,
    then the current file. Returns rows (iter, retrial, alpha, damp, roughness, misfit, rms, objfunc), by iteration.
    """
    rows: dict[int, tuple] = {}
    for path in paths:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for ln in fh:
                f = ln.split()
                if len(f) == 8 and f[0].isdigit():
                    rows[int(f[0])] = (int(f[0]), int(f[1])) + tuple(float(v) for v in f[2:])
    return [rows[k] for k in sorted(rows)]


# ---------------------------------------------------------------------------------------- mesh.dat and blocks
def read_mesh(path: str | os.PathLike):
    """mesh.dat through femtic_mesh.io.femtic, the canonical reader (no second parser in the GUI).

    Returns:
        (nodes (N, 3) float64 in m, FEMTIC frame x north, y east, z down; tets (M, 4) int32, 0-based).
    """
    from femtic_mesh.io import femtic as F       # noqa: PLC0415 - the 2D GUI runs without femtic_mesh
    m = F.read_mesh_dat(str(path))
    return m.nodes, m.tets


def read_block(path: str | os.PathLike, n_elements: int | None = None):
    """A resistivity_block_iter<N>.dat through femtic_mesh.io.femtic.

    Returns:
        (elem2blk (M,) parameter cell of each element, rho (K,) ohm-m of each cell).

    Raises:
        ReaderError: if n_elements is given and the block holds another number of elements (both named).
    """
    from femtic_mesh.io import femtic as F       # noqa: PLC0415
    b = F.read_resistivity_blocks(str(path))
    if n_elements is not None and b.elem2blk.size != n_elements:
        raise ReaderError("%s has %d elements but the mesh has %d: not this mesh's model" % (
            Path(path).name, b.elem2blk.size, n_elements))
    return b.elem2blk, b.rho
