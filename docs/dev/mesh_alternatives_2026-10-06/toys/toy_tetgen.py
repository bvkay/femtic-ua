"""Toy TetGen front-ends on the same gmsh-made triangle PLC (out/toy.poly, out/toy_plc.npz).
Round 0: -pYAq1.4 (+ n f) ; rounds 1..R: makeMtr-equivalent size at nodes, then refine with -m.
usage: python toy_tetgen.py {exe|meshpy|pyvista} ROUNDS TAG"""
import sys, os, time, json, hashlib, subprocess
import numpy as np

front, R, tag = sys.argv[1], int(sys.argv[2]), sys.argv[3]
NL = "\n"
d = np.load("out/toy_plc.npz")
sites3 = np.c_[d["sites"], d["sites_z"]]


def target(xyz):
    """makeMtr stand-in, same law as the gmsh toy: min(4 m + 0.24 (d-6), 40 + 0.25 r_ell), capped 150."""
    ds = np.min(np.linalg.norm(xyz[:, None, :] - sites3[None], axis=2), axis=1)
    hs = np.clip(4.0 + (150.0 - 4.0) * (ds - 6.0) / (600.0 - 6.0), 4.0, 150.0)
    hg = 40.0 + 0.25 * np.sqrt(xyz[:, 0]**2 + xyz[:, 1]**2 + 4 * xyz[:, 2]**2)
    return np.minimum(hs, hg)


def summary(nodes, tets, attr, t):
    used = np.unique(tets)
    P = nodes[tets]
    vol = np.einsum("ij,ij->i", np.cross(P[:, 1]-P[:, 0], P[:, 2]-P[:, 0]), P[:, 3]-P[:, 0]) / 6
    h = hashlib.md5(np.round(nodes[used], 9).tobytes() + tets.astype(np.int64).tobytes()).hexdigest()
    return dict(front=front, tag=tag, rounds=R, nodes=int(len(used)), tets=int(len(tets)),
                air=int((attr == 10).sum()), earth=int((attr == 20).sum()),
                attrs=sorted(set(np.unique(attr).astype(int).tolist())),
                sum_vol_rel_err=float(abs(np.abs(vol).sum() - 1e9) / 1e9),
                min_abs_vol=float(np.abs(vol).min()), t_s=round(t, 3), md5=h)


t0 = time.perf_counter()
SW0, SWR = "pYAq1.4nQ", "pYrmAq1.4nQ"     # Usui uses -nVpYAakq3.0/0 then -nmpYVrAakq3.0/0

if front == "exe":
    exe = os.path.join(os.path.dirname(sys.executable), "Library", "bin", "tetgen.exe")
    wd = f"out/exe_{tag}"; os.makedirs(wd, exist_ok=True)
    import shutil; shutil.copy("out/toy.poly", f"{wd}/toy.poly")

    def rd(stem):
        n = np.loadtxt(f"{wd}/{stem}.node", skiprows=1, comments="#")
        e = np.loadtxt(f"{wd}/{stem}.ele", skiprows=1, comments="#")
        return n[:, 1:4], e[:, 1:5].astype(np.int64) - 1, e[:, 5]
    subprocess.run([exe, "-" + SW0.replace("Q", "Q"), "toy.poly"], cwd=wd, check=True, capture_output=True)
    for i in range(1, R + 1):
        nodes, tets, attr = rd(f"toy.{i}")
        mtr = target(nodes)
        with open(f"{wd}/toy.{i}.mtr", "w", newline=NL) as f:
            f.write(f"{len(mtr)} 1" + NL + NL.join(repr(float(v)) for v in mtr) + NL)
        subprocess.run([exe, "-" + SWR, f"toy.{i}"], cwd=wd, check=True, capture_output=True)
    nodes, tets, attr = rd(f"toy.{R+1}")

elif front == "meshpy":
    from meshpy.tet import MeshInfo, Options, tetrahedralize
    mi = MeshInfo(); mi.load_poly("out/toy")
    m = tetrahedralize(mi, Options(SW0.replace("Q", "")))
    for i in range(R):
        nodes = np.array(m.points); mtr = target(nodes)
        stem = f"out/meshpy_{tag}_{i}"      # pybind view of pointmtrlist has unit 0, so go via load_mtr
        with open(stem + ".mtr", "w", newline=NL) as f:
            f.write(f"{len(mtr)} 1" + NL + NL.join(repr(float(v)) for v in mtr) + NL)
        m.load_mtr(stem)
        m = tetrahedralize(m, Options(SWR.replace("Q", "")))
    nodes = np.array(m.points); tets = np.array(m.elements, dtype=np.int64); tets -= int(tets.max() == len(nodes))  # .poly was 1-based
    attr = np.array(m.element_attributes).ravel()

elif front == "pyvista":
    import tetgen
    xyz, tri, mark = d["xyz"], d["tri"].astype(np.int32), d["mark"].astype(np.int32)

    def fresh():
        tg = tetgen.TetGen(xyz, tri, mark)
        tg.add_region(10, (0.0, 0.0, 250.0)); tg.add_region(20, (0.0, 0.0, -250.0))
        return tg
    tg = fresh(); tg.tetrahedralize(switches=SW0)
    for i in range(R):
        bn, bt = tg.node.copy(), tg.elem.astype(np.int32).copy()
        bm = target(bn)
        tg = fresh()
        tg._tetgen.load_bgmesh_from_arrays(bn, bt, bm.astype(np.float64))
        tg.tetrahedralize(switches=SW0 + "m")
    nodes, tets, attr = tg.node, tg.elem.astype(np.int64), tg.attributes.ravel()

print(json.dumps(summary(nodes, tets, attr, time.perf_counter() - t0)))
