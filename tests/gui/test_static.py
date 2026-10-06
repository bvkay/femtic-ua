# -*- coding: utf-8 -*-
"""test_static.py - static rules of the source: no network code (T6) and VTK isolated in viewer3d.

An AST scan of every .py under src/femtic_gui, so it sees imports inside functions too.

    python tests/gui/test_static.py

@author ben kay
:license: MIT
"""
from __future__ import annotations

import ast
import shutil
from pathlib import Path

import _common as C

PKG = C.REPO / "src" / "femtic_gui"
NETWORK = ("socket", "ssl", "http", "urllib.request", "urllib3", "requests", "pooch", "paramiko", "ftplib",
           "smtplib", "asyncio", "PySide6.QtNetwork", "PySide6.QtWebEngine")
VTK = ("vtk", "pyvista", "pyvistaqt")


def imports(path: Path) -> list[tuple[str, bool]]:
    """(module, at module level) for every import in a file; 'from a import b' also gives 'a.b'."""
    tree = ast.parse(path.read_text(encoding="utf-8"))
    top = {id(n) for n in tree.body}
    out = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            out += [(a.name, id(node) in top) for a in node.names]
        elif isinstance(node, ast.ImportFrom):
            base = ("." * node.level) + (node.module or "")
            out.append((base, id(node) in top))
            out += [("%s.%s" % (base, a.name) if node.module else base + a.name, id(node) in top)
                    for a in node.names]
    return out


def _matches(mod: str, names: tuple) -> bool:
    return any(mod == n or mod.startswith(n + ".") or (n.endswith("WebEngine") and mod.startswith(n))
               for n in names)


def scan_network(pkg: Path) -> tuple[bool, str]:
    bad = ["%s: %s" % (p.relative_to(pkg).as_posix(), m) for p in sorted(pkg.rglob("*.py"))
           for m, _top in imports(p) if _matches(m, NETWORK)]
    return not bad, "network imports: %s" % (bad or "none")


def scan_vtk(pkg: Path) -> tuple[bool, str]:
    bad = []
    for p in sorted(pkg.rglob("*.py")):
        rel = p.relative_to(pkg).as_posix()
        for m, top in imports(p):
            if _matches(m, VTK) and (rel != "viewer3d.py" or top):
                bad.append("%s imports %s%s" % (rel, m, " at module level" if top else ""))
            if m.endswith("viewer3d") and top:
                bad.append("%s imports viewer3d at module level" % rel)
    return not bad, "VTK/viewer3d imports outside viewer3d's functions: %s" % (bad or "none")


def _mutant(tmp: Path, file: str, line: str) -> Path:
    dst = tmp / "femtic_gui"
    shutil.copytree(PKG, dst, ignore=shutil.ignore_patterns("__pycache__"))
    f = dst / file
    f.write_text(f.read_text(encoding="utf-8") + "\n" + line + "\n", encoding="utf-8")
    return dst


def test_no_network_imports():
    """This test fails if any .py under src/femtic_gui imports socket, ssl, http, urllib.request, urllib3, requests,
    pooch, paramiko, ftplib, smtplib, asyncio, PySide6.QtNetwork or PySide6.QtWebEngine* (T6). Failing case: a
    temporary copy of the package with one 'import urllib.request' added."""
    with C.temp_dir("static") as d:
        C.fails_first(scan_network, _mutant(Path(d), "readers.py", "import urllib.request"))
    C.passes(scan_network, PKG)


def test_vtk_only_inside_viewer3d_functions():
    """This test fails if any module but viewer3d imports vtk, pyvista or pyvistaqt, if viewer3d imports them at
    module level, or if any module imports viewer3d at module level (the smoke test then must not see VTK).
    Failing case: a copy whose tabs/mesh.py imports viewer3d at module level."""
    with C.temp_dir("static") as d:
        C.fails_first(scan_vtk, _mutant(Path(d), "tabs/mesh.py", "from .. import viewer3d"))
    C.passes(scan_vtk, PKG)


if __name__ == "__main__":
    C.main(globals())
