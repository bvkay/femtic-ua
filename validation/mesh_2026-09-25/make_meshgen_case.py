#!/usr/bin/env python3
"""Write a tiny synthetic land-only mesh input set with femticPy's MeshGen writers (no femticPy edits).

9 sites on a 3x3 grid at 5 km spacing, flat topography at 0 km, analysis domain +/-200 km,
dummy coast line / topography / bathymetry from MeshGen, MeshGen default ellipsoids with every
ellipsoid length (radius) halved; edge lengths, oblateness and the site-local spheres are left at the
MeshGen defaults.

Usage: PYTHONPATH=<femticPy>/src python make_meshgen_case.py OUTDIR
"""
import os, sys, warnings
warnings.filterwarnings("ignore", category=SyntaxWarning)
import numpy as np
import pandas as pd
import femticPy

outdir = sys.argv[1]
os.makedirs(outdir, exist_ok=True)

g = np.array([-5.0, 0.0, 5.0])
nn, ee = np.meshgrid(g, g, indexing="ij")
mt = pd.DataFrame({"id": [f"S{i+1:02d}" for i in range(9)],
                   "north": nn.ravel(), "east": ee.ravel(),
                   "z": np.zeros(9)})          # FEMTIC z (positive down) of the sites, km
domain = [[-200.0, 200.0], [-200.0, 200.0], [-200.0, 200.0]]

m = femticPy.MeshGen(survey="chain_proof_meshgen", analysis_domain=domain,
                     center=[0.0, 0.0], mt_coords=mt, nRx=len(mt), outdir=outdir)

SCALE = 0.5   # halve the ellipsoid lengths so the chain runs in seconds
def scaled(ell, col=0):
    out = [ell[0]]
    for row in ell[1:]:
        row = list(row); row[col] *= SCALE; out.append(row)
    return out
m.ellipsoids_control = scaled(m.ellipsoids_control)
m.ellipsoids_mtr = scaled(m.ellipsoids_mtr)
m.ellipsoids_resistivity_attr = scaled(m.ellipsoids_resistivity_attr)

m.write_inputs()            # analysis_domain, makeMtr.param, obs_site, observing_site, resistivity_attr, control
m.write_dummy_coast_line()  # one closed boundary 1 km outside the domain -> land everywhere
m.write_dummy_topo_file()   # flat 0 km on a 10 km grid
m.write_dummy_bathy_file()  # -0.01 km (unused: no sea)
print("center used by MeshGen:", m.center)
print("wrote:", sorted(os.listdir(outdir)))
