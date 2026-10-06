import time, numpy as np, discretize
from discretize import TreeMesh, SimplexMesh
# --- SimplexMesh as post-processor of an existing tet mesh (exe toy output)
def rd(stem):
    n = np.loadtxt(stem + ".node", skiprows=1, comments="#"); e = np.loadtxt(stem + ".ele", skiprows=1, comments="#")
    return n[:, 1:4], e[:, 1:5].astype(np.int64) - 1, e[:, 5]
nodes, tets, attr = rd("out/exe_e3a/toy.4")
t0 = time.perf_counter(); sm = SimplexMesh(nodes, tets); t1 = time.perf_counter()
print(f"SimplexMesh: {sm.n_cells} cells, {sm.n_faces} faces, {sm.n_edges} edges, build {t1-t0:.3f}s")
print("  vol sum rel err", abs(sm.cell_volumes.sum() - 1e9) / 1e9, " neighbors shape", sm.neighbors.shape,
      " boundary face count", int((sm.neighbors == -1).sum()))
q = np.array([[0.0, 55.0, -1.0], [0.0, 0.0, 100.0]])
print("  point2index", sm.point2index(q), " interp matrix", sm.get_interpolation_matrix(q, "cell_centers").shape)
print("  has edge curl", sm.edge_curl.shape, " face areas", sm.face_areas.shape)
# --- TreeMesh (octree) generation for the same toy: 4 m at sites, 1024 m cube
h = [[(4.0, 256)]] * 3
tm = TreeMesh(h, origin=[-512.0, -512.0, -512.0], diagonal_balance=True)
sites = np.array([[-60.0, -40.0, 0.0], [0.0, 55.0, 0.0], [80.0, -10.0, 0.0]])
t0 = time.perf_counter()
tm.refine_points(sites, level=-1, padding_cells_by_level=[2, 2, 2, 2, 2, 2, 2, 2], finalize=False)
xs = np.linspace(-512, 512, 65); X, Y = np.meshgrid(xs, xs); topo = np.c_[X.ravel(), Y.ravel(), np.zeros(X.size)]
tm.refine_surface(topo, level=4, finalize=False)   # 64 m cells along the earth surface
tm.finalize(); t1 = time.perf_counter()
print(f"TreeMesh: {tm.n_cells} cells, levels {sorted(set(tm.cell_levels_by_index(np.arange(tm.n_cells))))}, "
      f"min h {tm.h_gridded.min():.1f} m, build {t1-t0:.3f}s, n_hanging_nodes {tm.n_hanging_nodes}, total_nodes {tm.n_total_nodes}")
