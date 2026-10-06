"""FEMTIC files: mesh.dat, resistivity_block_iter0.dat, resistivity_attr.dat and TetGen2Femtic's legacy VTK.

The writers reproduce TetGen2Femtic @ceb8bfb (MeshData.cpp) byte for byte:
  mesh.dat (writeMeshData, 1583-1633):
      "TETRA" / "%10d" nodes / nodes "%10d%20.9e%20.9e%20.9e" (m) / "%10d" elements /
      elements "%10d" x 9 (index, 4 neighbours (-1 = none), 4 nodes; 0-based) /
      7 face lists, each "%10d" count then "%10d%10d" (element, local face): -X +X -Y +Y -Z +Z, Earth surface.
  resistivity_block_iter0.dat (writeResisitivityData, 1815-1888, isotropic branch):
      "%10d%10d" (elements, cells) / "%10d%10d" (element, cell) per element /
      "%10d%15.6e%15.6e%15.6e%15.6e%10d" (cell, rho, 1e-20, 1e+20, 1.0, fix) per cell.
  <root>.femtic.vtk (writeMeshDataToVTK, 1636-1812, isotropic branch).
A file that another program wrote in a different layout is read correctly but written back in this layout.
"""
from dataclasses import dataclass, field

import numpy as np

from . import _fmt

# printf formats of TetGen2Femtic (module constants so the tests can build mutant writers from them)
NODE_COORD_FMT = "%20.9e"
INT_WIDTH = 10
BLOCK_CELL_FMT = "%10d%15.6e%15.6e%15.6e%15.6e%10d\n"

BOUNDARY_NAMES = ("YZMinus", "YZPlus", "ZXMinus", "ZXPlus", "XYMinus", "XYPlus", "EARTH_SURFACE")
EARTH_SURFACE = 6


@dataclass
class MeshDat:
    """Contents of mesh.dat. Indices 0-based; neigh[e, k] is the element across the face opposite node k."""
    nodes: np.ndarray            # (N, 3) float64, metres
    neigh: np.ndarray            # (M, 4) int32, -1 = none
    tets: np.ndarray             # (M, 4) int32
    faces: list = field(default_factory=list)   # 7 arrays (k, 2) int32: (element, local face)

    @property
    def n_nodes(self):
        return int(self.nodes.shape[0])

    @property
    def n_elements(self):
        return int(self.tets.shape[0])

    def counts(self):
        return {"nodes": self.n_nodes, "elements": self.n_elements,
                "outer_faces": [int(len(f)) for f in self.faces[:6]],
                "earth_surface_faces": int(len(self.faces[EARTH_SURFACE]))}


@dataclass
class ResistivityBlocks:
    """Contents of resistivity_block_iter0.dat (isotropic layout)."""
    elem2blk: np.ndarray         # (M,) int32
    rho: np.ndarray              # (K,) float64, ohm-m
    lower: np.ndarray            # (K,) float64
    upper: np.ndarray            # (K,) float64
    weight: np.ndarray           # (K,) float64
    fix: np.ndarray              # (K,) int32

    @property
    def n_cells(self):
        return int(self.rho.size)


def _check_index_column(col, n, what):
    if not np.array_equal(col, np.arange(n)):
        bad = int(np.flatnonzero(col != np.arange(n))[0])
        raise ValueError(f"{what}: index column must run 0..{n - 1}; row {bad} holds {int(col[bad])}")


def read_mesh_dat(path):
    """Read a TETRA mesh.dat. Raises ValueError on any layout problem (counts, index columns, extra lines)."""
    with open(path, "rb") as fh:
        raw = fh.read()
    nl = _fmt.line_ends(raw)
    s, e = _fmt.line_span(nl, 0)
    if raw[s:e].strip() != b"TETRA":
        raise ValueError(f"{path}: first line is {raw[s:e][:20]!r}, expected TETRA")
    nn = _fmt.read_int_line(raw, nl, 1, 1, path)[0]
    t = _fmt.read_table(raw, nl, 2, nn, 4, np.float64, f"{path} nodes")
    _check_index_column(t[:, 0], nn, f"{path} nodes")
    nodes = np.ascontiguousarray(t[:, 1:4])
    del t
    i = 2 + nn
    ne = _fmt.read_int_line(raw, nl, i, 1, path)[0]
    t = _fmt.read_table(raw, nl, i + 1, ne, 9, np.int64, f"{path} elements")
    _check_index_column(t[:, 0], ne, f"{path} elements")
    neigh = t[:, 1:5].astype(np.int32)
    tets = t[:, 5:9].astype(np.int32)
    del t
    i += 1 + ne
    faces = []
    for k in range(7):
        nf = _fmt.read_int_line(raw, nl, i, 1, f"{path} face list {k}")[0]
        f = _fmt.read_table(raw, nl, i + 1, nf, 2, np.int64, f"{path} face list {k}").astype(np.int32)
        faces.append(f)
        i += 1 + nf
    rest = raw[_fmt.line_span(nl, i)[0]:] if i < nl.size else b""
    if rest.strip():
        raise ValueError(f"{path}: {len(rest)} unexpected bytes after the 7 face lists")
    if neigh.size and (neigh.min() < -1 or neigh.max() >= ne):
        raise ValueError(f"{path}: neighbour index out of range")
    if tets.size and (tets.min() < 0 or tets.max() >= nn):
        raise ValueError(f"{path}: node index out of range")
    for k, f in enumerate(faces):
        if f.size and (f[:, 0].min() < 0 or f[:, 0].max() >= ne or f[:, 1].min() < 0 or f[:, 1].max() > 3):
            raise ValueError(f"{path}: face list {k} ({BOUNDARY_NAMES[k]}) has an out-of-range entry")
    return MeshDat(nodes=nodes, neigh=neigh, tets=tets, faces=faces)


def write_mesh_dat(path, mesh):
    """Write mesh.dat exactly as TetGen2Femtic's writeMeshData does."""
    nn, ne = mesh.n_nodes, mesh.n_elements
    if len(mesh.faces) != 7:
        raise ValueError("mesh.faces must hold 7 face lists")
    with open(path, "wb") as fh:
        fh.write(b"TETRA\n")
        fh.write(b"%10d\n" % nn)
        for a in range(0, nn, _fmt.CHUNK_ROWS):
            b = min(nn, a + _fmt.CHUNK_ROWS)
            idx = _fmt.int_fields(np.arange(a, b), INT_WIDTH)
            xyz = mesh.nodes[a:b]
            cols = [_fmt.float_fields(xyz[:, j], NODE_COORD_FMT, 20) for j in range(3)]
            if idx is None or any(c is None for c in cols):
                row = "%" + str(INT_WIDTH) + "d" + NODE_COORD_FMT * 3 + "\n"
                fh.write("".join(row % (a + r, *v) for r, v in enumerate(xyz.tolist())).encode("ascii"))
            else:
                _fmt.write_rows(fh, [idx] + cols)
        fh.write(b"%10d\n" % ne)
        for a in range(0, ne, _fmt.CHUNK_ROWS):
            b = min(ne, a + _fmt.CHUNK_ROWS)
            tab = np.hstack([np.arange(a, b)[:, None], mesh.neigh[a:b], mesh.tets[a:b]])
            _fmt.write_int_table(fh, tab, INT_WIDTH)
        for f in mesh.faces:
            fh.write(b"%10d\n" % len(f))
            if len(f):
                _fmt.write_int_table(fh, np.asarray(f).reshape(-1, 2), INT_WIDTH)


def read_resistivity_blocks(path):
    """Read resistivity_block_iter0.dat (isotropic layout: 6 columns per cell line)."""
    with open(path, "rb") as fh:
        raw = fh.read()
    nl = _fmt.line_ends(raw)
    ne, nc = _fmt.read_int_line(raw, nl, 0, 2, path)
    t = _fmt.read_table(raw, nl, 1, ne, 2, np.int64, f"{path} elements")
    _check_index_column(t[:, 0], ne, f"{path} elements")
    elem2blk = t[:, 1].astype(np.int32)
    c = _fmt.read_table(raw, nl, 1 + ne, nc, 6, np.float64, f"{path} cells")
    _check_index_column(c[:, 0], nc, f"{path} cells")
    if not np.array_equal(c[:, 5], np.round(c[:, 5])):
        raise ValueError(f"{path}: the fix column must hold integers")
    i = 1 + ne + nc
    rest = raw[_fmt.line_span(nl, i)[0]:] if i < nl.size else b""
    if rest.strip():
        raise ValueError(f"{path}: unexpected bytes after {nc} cell lines (anisotropic layout is not supported)")
    if elem2blk.size and (elem2blk.min() < 0 or elem2blk.max() >= nc):
        raise ValueError(f"{path}: element cell index out of range")
    return ResistivityBlocks(elem2blk=elem2blk, rho=c[:, 1].copy(), lower=c[:, 2].copy(), upper=c[:, 3].copy(),
                             weight=c[:, 4].copy(), fix=c[:, 5].astype(np.int32))


def write_resistivity_blocks(path, blocks):
    """Write resistivity_block_iter0.dat exactly as TetGen2Femtic's writeResisitivityData (isotropic) does."""
    ne, nc = int(blocks.elem2blk.size), blocks.n_cells
    with open(path, "wb") as fh:
        fh.write(b"%10d%10d\n" % (ne, nc))
        _fmt.write_int_table(fh, np.stack([np.arange(ne), blocks.elem2blk], axis=1), 10)
        fh.write("".join(BLOCK_CELL_FMT % (k, r, lo, hi, w, int(f)) for k, (r, lo, hi, w, f)
                         in enumerate(zip(blocks.rho.tolist(), blocks.lower.tolist(), blocks.upper.tolist(),
                                          blocks.weight.tolist(), blocks.fix.tolist()))).encode("ascii"))


def write_t2f_vtk(path, mesh, blocks):
    """Write TetGen2Femtic's <root>.femtic.vtk (isotropic branch) byte for byte."""
    nn, ne = mesh.n_nodes, mesh.n_elements
    blk = np.asarray(blocks.elem2blk)
    per_blk = np.bincount(blk, minlength=blocks.n_cells)
    rho_f = _fmt.float_fields(blocks.rho, "%20.9e", 20)
    fix_f = _fmt.int_fields((np.asarray(blocks.fix) != 0).astype(np.int64), 20)
    with open(path, "wb") as fh:
        fh.write(b"# vtk DataFile Version 2.0\nMeshData\nASCII\nDATASET UNSTRUCTURED_GRID\n")
        fh.write(b"POINTS %d double\n" % nn)
        for a in range(0, nn, _fmt.CHUNK_ROWS):
            xyz = mesh.nodes[a:a + _fmt.CHUNK_ROWS]
            _fmt.write_rows(fh, [_fmt.float_fields(xyz[:, j], "%20.9e", 20) for j in range(3)])
        fh.write(b"CELLS %d %d\n" % (ne, ne * 5))
        for a in range(0, ne, _fmt.CHUNK_ROWS):
            t = mesh.tets[a:a + _fmt.CHUNK_ROWS]
            _fmt.write_rows(fh, [_fmt.int_fields(np.full(len(t), 4), 5), _fmt.int_fields(t, 10)])
        fh.write(b"CELL_TYPES %d\n" % ne)
        fh.write(b"   10\n" * ne)
        fh.write(b"CELL_DATA %d\n" % ne)
        fh.write(b"SCALARS BlockSerial int\nLOOKUP_TABLE default\n")
        _fmt.write_int_table(fh, blk, 10)
        fh.write(b"SCALARS ElemPerBlock int\nLOOKUP_TABLE default\n")
        _fmt.write_int_table(fh, per_blk[blk], 10)
        fh.write(b"SCALARS ElemSerial int\nLOOKUP_TABLE default\n")
        fh.write(("\n".join(map(str, range(ne))) + "\n").encode("ascii") if ne else b"")
        fh.write(b"SCALARS Resistivity[Ohm-m] double\nLOOKUP_TABLE default\n")
        for a in range(0, ne, _fmt.CHUNK_ROWS):
            _fmt.write_rows(fh, [rho_f[blk[a:a + _fmt.CHUNK_ROWS]]])
        fh.write(b"SCALARS Fixed int\nLOOKUP_TABLE default\n")
        for a in range(0, ne, _fmt.CHUNK_ROWS):
            _fmt.write_rows(fh, [fix_f[blk[a:a + _fmt.CHUNK_ROWS]]])
        fh.write(b"POINT_DATA %d\n" % nn)
        fh.write(b"SCALARS NodeSerial int\nLOOKUP_TABLE default\n")
        fh.write(("\n".join(map(str, range(nn))) + "\n").encode("ascii") if nn else b"")


# ---------------------------------------------------------------------------------------- resistivity_attr.dat
@dataclass
class ResistivityAttr:
    """resistivity_attr.dat as TetGen2Femtic reads it (readResisitivity, MeshData.cpp:465-708), values as written
    (km). regions[0] is the air. Spheres: rows (radius, B, oblateness_h, oblateness_v). Sites: (x, y, z) and
    the circle radii and lengths, all km."""
    regions: list                 # dicts: attr, rho, ndiv, fix (fix = 1 if the file's flag > 0)
    center_km: tuple
    rotation_deg: float
    spheres_km: np.ndarray        # (ns, 4)
    sites_xyz_km: np.ndarray      # (nsite, 3)
    site_radii_km: list           # per site, 1-D array
    site_lengths_km: list

    @property
    def air_or_sea_attrs(self):
        return {r["attr"] for r in self.regions if r["ndiv"] < 0}


class _Tokens:
    def __init__(self, text, path):
        self.t = text.split()
        self.i = 0
        self.path = path

    def _next(self, what):
        if self.i >= len(self.t):
            raise ValueError(f"{self.path}: file ends before {what}")
        self.i += 1
        return self.t[self.i - 1]

    def int(self, what):
        s = self._next(what)
        try:
            return int(s)
        except ValueError:
            raise ValueError(f"{self.path}: {what} must be an integer, got {s!r}") from None

    def float(self, what):
        s = self._next(what)
        try:
            return float(s)
        except ValueError:
            raise ValueError(f"{self.path}: {what} must be a number, got {s!r}") from None


def read_resistivity_attr(path, anisotropic=False):
    """Parse resistivity_attr.dat in the order and with the checks of TetGen2Femtic's readResisitivity.

    Each C++ exit(1) becomes a ValueError carrying the same message. The anisotropic layout (-aniso) and the
    _ADDITIONAL_FIXED_AREA build are not supported."""
    if anisotropic:
        raise NotImplementedError("anisotropic resistivity_attr.dat (-aniso) is not ported")
    with open(path, "r", encoding="ascii", errors="strict") as fh:
        tk = _Tokens(fh.read(), path)
    nres = tk.int("the number of resistivities")
    if nres < 1:
        raise ValueError("Number of different resisitivities must be greater than or equal to one !!")
    regions = []
    for i in range(nres):
        attr = tk.int(f"attribute of row {i}")
        rho = tk.float(f"resistivity of row {i}")
        ndiv = tk.int(f"ndiv of row {i}")
        ibuf = tk.int(f"fix flag of row {i}")
        if i == 0 and ndiv >= 0:
            raise ValueError("Number of division must be negative for the first resistivity data ( the air layer ) !!")
        regions.append({"attr": attr, "rho": rho, "ndiv": ndiv, "fix": 1 if ibuf > 0 else 0})
    center = (tk.float("centre x"), tk.float("centre y"), tk.float("centre z"))
    rot = tk.float("rotation angle")
    ns = tk.int("the number of spheres")
    sph = np.array([[tk.float(f"sphere {i} value {j}") for j in range(4)] for i in range(max(ns, 0))],
                   dtype=np.float64).reshape(-1, 4)
    r_m, b_m = sph[:, 0] * 1.0e3, sph[:, 1] * 1.0e3
    for i in range(1, ns):
        if r_m[i] < r_m[i - 1]:
            raise ValueError(f"Radius of the region {i} is smaller than that of the previous region.")
        if b_m[i] < b_m[i - 1]:
            raise ValueError(f"Edge length of the region {i} is smaller than that of the previous region.")
        if sph[i, 2] < 0 or sph[i, 2] > 1:
            raise ValueError("Oblateness of horizontal ellipsoid must be smaller than 1 and larger than 0.")
        if sph[i, 3] < 0 or sph[i, 3] > 1:
            raise ValueError("Oblateness must be smaller than 1 and larger than 0.")
        if r_m[i] * (1.0 - sph[i, 2]) < r_m[i - 1] * (1.0 - sph[i - 1, 2]):
            raise ValueError(f"Length of shorter axis of horizontal ellipsoid {i} is less than that of the "
                             "previous ellipsoid.")
        if r_m[i] * (1.0 - sph[i, 3]) < r_m[i - 1] * (1.0 - sph[i - 1, 3]):
            raise ValueError(f"Depth of sphere {i} is shallower than that of the previous sphere in the earth.")
    nsite = tk.int("the number of observed sites")
    xyz, radii, lengths = [], [], []
    for s in range(max(nsite, 0)):
        xyz.append((tk.float(f"site {s} x"), tk.float(f"site {s} y"), tk.float(f"site {s} z")))
        nc = tk.int(f"site {s} circle count")
        rr, ll = [], []
        for i in range(max(nc, 0)):
            r, ln = tk.float(f"site {s} radius {i}"), tk.float(f"site {s} length {i}")
            if i > 0 and r * 1.0e3 < rr[-1] * 1.0e3:
                raise ValueError(f" Error : Radius must be specified in ascending order !! : {r * 1.0e3}")
            if i > 0 and ln * 1.0e3 < ll[-1] * 1.0e3:
                raise ValueError(f" Error : Edge length must increase with radius !! : {ln * 1.0e3}")
            rr.append(r)
            ll.append(ln)
        radii.append(np.array(rr, dtype=np.float64))
        lengths.append(np.array(ll, dtype=np.float64))
    return ResistivityAttr(regions=regions, center_km=center, rotation_deg=rot, spheres_km=sph,
                           sites_xyz_km=np.array(xyz, dtype=np.float64).reshape(-1, 3),
                           site_radii_km=radii, site_lengths_km=lengths)


def blocks_from_partition(elem2blk, blk_region, attr):
    """ResistivityBlocks from a partition: blk_region[k] is the resistivity_attr row of cell k. Bounds 1e-20 and
    1e+20 and weight 1.0 are TetGen2Femtic's hard-coded values (MeshData.cpp:1878-1882)."""
    blk_region = np.asarray(blk_region)
    rho = np.array([attr.regions[r]["rho"] for r in blk_region.tolist()], dtype=np.float64)
    fix = np.array([attr.regions[r]["fix"] for r in blk_region.tolist()], dtype=np.int32)
    k = blk_region.size
    return ResistivityBlocks(elem2blk=np.asarray(elem2blk, dtype=np.int32), rho=rho, lower=np.full(k, 1.0e-20),
                             upper=np.full(k, 1.0e20), weight=np.ones(k), fix=fix)
