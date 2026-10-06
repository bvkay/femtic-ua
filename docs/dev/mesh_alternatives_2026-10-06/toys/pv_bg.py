import sys, numpy as np, tetgen
d = np.load("out/toy_plc.npz"); xyz, tri, mark = d["xyz"], d["tri"].astype(np.int32), d["mark"].astype(np.int32)
sw0, sw1, usemark = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
def fresh():
    tg = tetgen.TetGen(xyz, tri, mark) if usemark else tetgen.TetGen(xyz, tri)
    tg.add_region(10, (0.0, 0.0, 250.0)); tg.add_region(20, (0.0, 0.0, -250.0)); return tg
tg = fresh(); tg.tetrahedralize(switches=sw0)
bn = np.ascontiguousarray(tg.node, dtype=np.float64); bt = np.ascontiguousarray(tg.elem, dtype=np.int32)
print("bg", bn.shape, bt.shape, bt.min(), bt.max(), flush=True)
bm = np.full(len(bn), 30.0)
tg2 = fresh(); tg2._tetgen.load_bgmesh_from_arrays(bn, bt, bm)
print("loaded", flush=True)
tg2.tetrahedralize(switches=sw1)
print("ok", tg2.elem.shape, flush=True)
