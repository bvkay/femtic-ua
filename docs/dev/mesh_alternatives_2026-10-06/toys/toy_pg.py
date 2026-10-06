import time, os, sys, numpy as np
t0 = time.perf_counter()
os.environ["PATH"] = os.path.join(os.path.dirname(sys.executable), "Library", "bin") + os.pathsep + os.environ["PATH"]
import pygimli as pg, pygimli.meshtools as mt
ti = time.perf_counter() - t0
earth = mt.createCube(start=[-500, -500, -500], end=[500, 500, 0], marker=20)
air = mt.createCube(start=[-500, -500, 0], end=[500, 500, 500], marker=10)
plc = mt.mergePLC3D([earth, air])
sites = [(-60, -40), (0, 55), (80, -10)]
for x, y in sites:                      # pyGIMLi-style local refinement: extra PLC nodes, no metric
    for dx, dy in ((0, 0), (3, 0), (-3, 0), (0, 3), (0, -3)):
        plc.createNode([x + dx, y + dy, 0.0])
        plc.createNode([x + dx, y + dy, -3.0])
print("regions:", [ (r.marker()) for r in plc.regionMarkers()] if hasattr(plc, "regionMarkers") else "n/a")
t1 = time.perf_counter()
mesh = mt.createMesh(plc, quality=1.4, area=0, verbose=False, tetgen=os.path.join(os.path.dirname(sys.executable), "Library", "bin", "tetgen.exe"))
t2 = time.perf_counter()
print(f"import {ti:.2f}s  mesh {t2-t1:.2f}s  cells {mesh.cellCount()} nodes {mesh.nodeCount()} "
      f"markers {sorted(set(mesh.cellMarkers()))} boundaries {mesh.boundaryCount()}")
# post-processing helpers relevant to a FEMTIC converter / QC
mesh.createNeighborInfos()
c = mesh.cell(0); print("neighbour API:", [ (c.neighborCell(i).id() if c.neighborCell(i) else -1) for i in range(4)])
print("findCell:", mesh.findCell([0.0, 55.0, -1.0]).id(), " cell volume sum:", sum(mesh.cellSizes()))
