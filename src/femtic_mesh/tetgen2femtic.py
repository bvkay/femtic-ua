"""Faithful Python port of TetGen2Femtic (github.com/yoshiya-usui/TetGen2Femtic @ceb8bfb; Copyright (c) 2021
Yoshiya Usui, MIT licence: see LICENSE_TetGen2Femtic.txt in this package).

  python -m femtic_mesh.tetgen2femtic PREFIX OUT_DIR [-rotate] [-div_all] [-thread N] [--attr FILE] [--no-vtk]

reads PREFIX.node .ele .neigh .face (tetgen -n output, region attribute per element) and resistivity_attr.dat,
and writes OUT_DIR/mesh.dat, OUT_DIR/resistivity_block_iter0.dat and OUT_DIR/<basename PREFIX>.femtic.vtk.
The C++ reads resistivity_attr.dat from the current directory and writes mesh.dat and the block file there;
the port does the same unless --attr is given, but writes all products into OUT_DIR.

Ported: readNodeData (incl. -rotate), readElemData, readNeighElements, readFaceData, readResisitivity
(isotropic), calcBoundaryFaces, writeMeshData, makeResistivityBlock (incl. -div_all; cells.py),
writeResisitivityData and writeMeshDataToVTK (isotropic). -thread is a no-op, as in the C++.
Not ported (NotImplementedError): -sediment, -aniso, the bound_attr.dat route (compiled out with #if 0) and
the _ADDITIONAL_FIXED_AREA build. Every C++ exit(1) is a ValueError or RuntimeError with the same message.
"""
import argparse
import os
import sys
import time

import numpy as np

from . import cells
from .io import femtic as femtic_io
from .io import tetgen as tetgen_io

# local face k of a tetrahedron is the face opposite node k: FEMTIC numbers it 6 - (sum of the 3 local nodes)
_FACE_NODES = np.array([[1, 2, 3], [0, 2, 3], [0, 1, 3], [0, 1, 2]])
_BITS = 21


def _keys(tri):
    t = np.sort(np.asarray(tri, dtype=np.int64), axis=-1)
    return (t[..., 0] << (2 * _BITS)) | (t[..., 1] << _BITS) | t[..., 2]


def boundary_faces(nodes_m, tets1, neigh1, elem_air, face_tri):
    """TetGen2Femtic calcBoundaryFaces: the 7 face lists (0-based element, local face), in .face order.

    tets1, neigh1, face_tri are tetgen's 1-based ids (neighbour -1 = none); elem_air marks elements whose
    region has ndiv < 0 (air or sea)."""
    if nodes_m.shape[0] >= 1 << _BITS:
        raise NotImplementedError(f"more than {(1 << _BITS) - 1} nodes")
    ek = np.empty((tets1.shape[0], 4), dtype=np.int64)   # key of the face opposite node k
    for k in range(4):
        ek[:, k] = _keys(tets1[:, _FACE_NODES[k]])
    flat = ek.ravel()
    order = np.argsort(flat, kind="stable")       # equal keys keep (element, face) order: lowest element first
    sk = flat[order]
    del ek, flat
    qk = _keys(face_tri)
    pos = np.searchsorted(sk, qk)
    ok = pos < sk.size
    ok[ok] = sk[pos[ok]] == qk[ok]
    if not ok.all():
        a, b, c = face_tri[np.flatnonzero(~ok)[0]].tolist()
        raise ValueError(f"Element face having node {a} {b} {c} cannot be found !!")
    first = order[pos]
    E, K = first // 4, first % 4                  # calcElementFace: first element (lowest id) holding the face
    nb = neigh1[E, K] - 1                         # elemIDNeighFromZero
    typ = np.full(E.size, -1, dtype=np.int64)
    outE, outK = E.copy(), K.copy()
    inner = nb >= 0
    i = np.flatnonzero(inner)
    ea, na = elem_air[E[i]], elem_air[nb[i]]
    c1 = i[~ea & na]                              # earth element, air/sea neighbour
    typ[c1] = femtic_io.EARTH_SURFACE
    c2 = i[ea & ~na]                              # air/sea element, earth neighbour: use the neighbour's face
    if c2.size:
        n2 = nb[c2]
        hit = neigh1[n2] == (E[c2] + 1)[:, None]
        if not hit.any(axis=1).all():
            raise ValueError("Face ID of neighboor element cannot be found.")
        outE[c2], outK[c2] = n2, np.argmax(hit, axis=1)
        typ[c2] = femtic_io.EARTH_SURFACE
    j = np.flatnonzero(~inner)                    # calcBoundTypeFromCoordinate
    if j.size:
        p = nodes_m[face_tri[j] - 1]              # (n, 3 nodes, 3 coords)
        eps = 1.0e-9
        same = [(np.abs(p[:, 0, d] - p[:, 1, d]) < eps) & (np.abs(p[:, 0, d] - p[:, 2, d]) < eps) for d in range(3)]
        t = np.full(j.size, -1, dtype=np.int64)
        for d in (2, 1, 0):                       # X first wins, so assign in reverse order
            t[same[d]] = np.where(p[same[d], 0, d] > 0, 2 * d + 1, 2 * d)
        if (t < 0).any():
            raise ValueError(f"Face {int(j[np.flatnonzero(t < 0)[0]])} is not on the boundary plane !!")
        typ[j] = t
    faces = []
    for b in range(7):
        s = typ == b
        faces.append(np.stack([outE[s], outK[s]], axis=1).astype(np.int32))
    return faces


def _seq_check(ids, what, msg):
    bad = np.flatnonzero(ids != np.arange(1, ids.size + 1))
    if bad.size:
        raise ValueError(f"{what}: {msg} (row {int(bad[0]) + 1} holds {int(ids[bad[0]])})")


def convert(prefix, out_dir=".", attr_path="resistivity_attr.dat", rotate=False, div_all=False, sediment=False,
            aniso=False, vtk=True, log=print):
    """Run the port. Returns a dict of counts and output paths."""
    if sediment:
        raise NotImplementedError("-sediment is not ported")
    if aniso:
        raise NotImplementedError("-aniso is not ported")
    t0 = time.perf_counter()
    nd = tetgen_io.read_node(prefix + ".node")
    _seq_check(nd.ids, prefix + ".node", "Node ID must be sequence number from 1 !!")
    if nd.attrs.shape[1] > 1:
        raise ValueError(f"{prefix}.node: {nd.attrs.shape[1]} attributes per node; TetGen2Femtic reads only one")
    xyz = nd.xyz.copy()
    if rotate:
        xyz = np.stack([nd.xyz[:, 1], -nd.xyz[:, 0], nd.xyz[:, 2]], axis=1)
    nodes_m = xyz * 1.0e3
    el = tetgen_io.read_ele(prefix + ".ele")
    _seq_check(el.ids, prefix + ".ele", "Element ID must be sequence number from 1!!")
    if el.attrs.shape[1] != 1:
        raise ValueError("You must specify region attribute to elements.")
    if not np.array_equal(el.attrs[:, 0], np.round(el.attrs[:, 0])):
        raise ValueError(f"{prefix}.ele: region attributes must be integers")
    elem_attr = el.attrs[:, 0].astype(np.int64)
    tets1 = el.tets
    if tets1.size and (tets1.min() < 1 or tets1.max() > nodes_m.shape[0]):
        raise ValueError(f"{prefix}.ele: node id out of range")
    nb = tetgen_io.read_neigh(prefix + ".neigh")
    if nb.ids.size != el.ids.size:
        raise ValueError(f"Total element number written in .neigh file ({nb.ids.size} ) is different from the one "
                         f"written in .ele file ( {el.ids.size} ) !!")
    _seq_check(nb.ids, prefix + ".neigh", "Element ID must be sequence number from 1!!")
    fc = tetgen_io.read_face(prefix + ".face")
    if fc.markers is None:
        raise ValueError("Boundary marker of face must be one.")
    attr = femtic_io.read_resistivity_attr(attr_path)
    row_of = {}
    for r, reg in enumerate(attr.regions):
        row_of.setdefault(reg["attr"], r)           # std::map::insert keeps the first row of a repeated attribute
    rows = np.array([row_of.get(int(a), -1) for a in np.unique(elem_attr)])
    if (rows < 0).any():
        miss = np.unique(elem_attr)[rows < 0][0]
        raise ValueError(f"Error : Region attiribute << {int(miss)} of element cannot be found !!")
    uniq = np.unique(elem_attr)
    elem_row = rows[np.searchsorted(uniq, elem_attr)]
    elem_air = np.isin(elem_attr, sorted(attr.air_or_sea_attrs))
    faces = boundary_faces(nodes_m, tets1, nb.neigh, elem_air, fc.tri)
    n_tg_faces = int(fc.tri.shape[0])
    mesh = femtic_io.MeshDat(nodes=nodes_m, neigh=np.where(nb.neigh > 0, nb.neigh - 1, -1).astype(np.int32),
                             tets=(tets1 - 1).astype(np.int32), faces=faces)
    del nd, el, nb, fc, tets1, elem_attr
    os.makedirs(out_dir, exist_ok=True)
    out = {"mesh.dat": os.path.join(out_dir, "mesh.dat"),
           "block": os.path.join(out_dir, "resistivity_block_iter0.dat")}
    femtic_io.write_mesh_dat(out["mesh.dat"], mesh)
    C = cells.centroids(nodes_m, mesh.tets)
    field = cells.BlockLengthField(attr) if len(attr.spheres_km) > 0 else None
    e2b, blk_row = cells.partition(C, elem_row, attr.regions, field, cells.USUI, div_all=div_all)
    blocks = femtic_io.blocks_from_partition(e2b, blk_row, attr)
    femtic_io.write_resistivity_blocks(out["block"], blocks)
    if vtk:
        out["vtk"] = os.path.join(out_dir, os.path.basename(prefix) + ".femtic.vtk")
        femtic_io.write_t2f_vtk(out["vtk"], mesh, blocks)
    res = {"nodes": mesh.n_nodes, "elements": mesh.n_elements, "tetgen_faces": n_tg_faces,
           "cells_incl_air": int(blocks.n_cells), "outer_faces": [len(f) for f in faces[:6]],
           "earth_surface_faces": len(faces[6]), "seconds": round(time.perf_counter() - t0, 2), "outputs": out}
    if log:
        log(f"nodes {res['nodes']}  elements {res['elements']}  tetgen faces {res['tetgen_faces']}  "
            f"cells {res['cells_incl_air']}  outer faces {res['outer_faces']}  "
            f"earth-surface faces {res['earth_surface_faces']}  ({res['seconds']} s)")
    return res


def main(argv=None):
    ap = argparse.ArgumentParser(prog="python -m femtic_mesh.tetgen2femtic", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("prefix", help="tetgen output prefix, e.g. output.6")
    ap.add_argument("out_dir", help="directory for mesh.dat, resistivity_block_iter0.dat and the VTK")
    ap.add_argument("--attr", default="resistivity_attr.dat",
                    help="resistivity_attr.dat (default: in the current directory, as the C++)")
    ap.add_argument("-rotate", action="store_true", help="rotate the model 90 degrees about z (x' = y, y' = -x)")
    ap.add_argument("-div_all", action="store_true", help="every earth element its own parameter cell")
    ap.add_argument("-thread", type=int, default=1, help="accepted and ignored, as in the C++")
    ap.add_argument("-sediment", action="store_true", help="not ported: raises NotImplementedError")
    ap.add_argument("-aniso", action="store_true", help="not ported: raises NotImplementedError")
    ap.add_argument("--no-vtk", action="store_true", help="skip the VTK")
    a = ap.parse_args(argv)
    try:
        convert(a.prefix, a.out_dir, a.attr, rotate=a.rotate, div_all=a.div_all, sediment=a.sediment,
                aniso=a.aniso, vtk=not a.no_vtk)
    except (ValueError, RuntimeError, NotImplementedError, OSError) as exc:
        print(f"TetGen2Femtic port FAILED: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
