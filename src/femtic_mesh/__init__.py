"""femtic_mesh: Python side of the FEMTIC tetrahedral mesh chain (P1 and the first slice of P2).

What exists (docs/dev/mesh_port_progress.md):
  femtic_mesh.io.femtic     mesh.dat, resistivity_block_iter0.dat, resistivity_attr.dat, TetGen2Femtic's VTK
  femtic_mesh.io.tetgen     .node .ele .face .neigh .poly .mtr readers and writers
  femtic_mesh.io.makemtr_inputs  makeMtr.param and obs_site.dat, read and echoed as makeMtr does
  femtic_mesh.cells         parameter-cell partition: rule 'usui' (TetGen2Femtic's) and alternatives
  femtic_mesh.tetgen2femtic faithful port of TetGen2Femtic @ceb8bfb (python -m femtic_mesh.tetgen2femtic)
  femtic_mesh.makemtr       faithful port of makeMtr @df8e207 (python -m femtic_mesh.makemtr ROOT)
  femtic_mesh.repartition   re-partition an existing mesh.dat (python -m femtic_mesh.repartition)
  femtic_mesh.backends      which tool serves each chain step on this machine; RAM, cores, a resource estimate
  femtic_mesh.checks        the checks of hpc/phoenix_plan/mesh_chain.sh as functions
  femtic_mesh.chain         the chain driver, mesh_chain.sh's steps on any machine (python -m femtic_mesh.chain)
  femtic_mesh.doctor        can this machine build a mesh? (python -m femtic_mesh.doctor; exit 0 only if complete)

Units follow the files: tetgen files and resistivity_attr.dat in km, mesh.dat in metres; FEMTIC frame
(x north, y east, z down). Arrays: float64 coordinates, int32 indices.
"""
__version__ = "0.2.0"
