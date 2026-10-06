"""makeTetraMesh step-2 stand-in: 2-D refined triangulation of the earth-surface plane with
Triangle (via meshpy.triangle) and a Python size callback (site circles + far-field law)."""
import time, numpy as np
from meshpy.triangle import MeshInfo, build
H = 500.0; sites = [(-60.0, -40.0), (0.0, 55.0), (80.0, -10.0)]
def h(x, y):
    d = min(((x-a)**2 + (y-b)**2) ** 0.5 for a, b in sites)
    return min(4.0 + (150.0 - 4.0) * max(d - 6.0, 0.0) / 594.0, 40 + 0.25 * (x*x + y*y) ** 0.5, 150.0)
ncall = [0]
def refine(v, area):        # Triangle asks per triangle: split if longest edge > 1.0 * h(centroid)
    ncall[0] += 1
    p = np.array(v); c = p.mean(axis=0)
    e = max(np.hypot(*(p[i] - p[(i+1) % 3])) for i in range(3))
    return bool(e > h(c[0], c[1]))
mi = MeshInfo(); mi.set_points([(-H, -H), (H, -H), (H, H), (-H, H)]); mi.set_facets([(0, 1), (1, 2), (2, 3), (3, 0)])
t0 = time.perf_counter(); m = build(mi, refinement_func=refine, min_angle=25); t = time.perf_counter() - t0
P = np.array(m.points); T = np.array(m.elements)
c = P[T].mean(axis=1); se = []
for a, b in sites:
    k = np.argmin((c[:, 0]-a)**2 + (c[:, 1]-b)**2); q = P[T[k]]
    se.append(round(max(np.hypot(*(q[i]-q[(i+1) % 3])) for i in range(3)), 2))
print(f"triangles {len(T)} points {len(P)} callback_calls {ncall[0]} time {t:.2f}s  site_tri_max_edge_m {se}")
