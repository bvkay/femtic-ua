import numpy as np, tetgen
d = np.load("out/toy_plc.npz"); xyz, tri, mark = d["xyz"], d["tri"].astype(np.int32), d["mark"].astype(np.int32)
tg = tetgen.TetGen(xyz, tri, mark); tg.add_region(10, (0.0, 0.0, 250.0)); tg.add_region(20, (0.0, 0.0, -250.0))
tg.tetrahedralize(switches="pYAq1.4nQ", bgmeshfilename="out/exe_e3a/toy.1")
print("ok", tg.elem.shape, flush=True)
