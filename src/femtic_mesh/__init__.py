"""femtic_mesh: Python side of the FEMTIC tetrahedral mesh chain (first slice, P1).

What exists (docs/dev/mesh_port_progress.md):
  femtic_mesh.io.femtic     mesh.dat, resistivity_block_iter0.dat, resistivity_attr.dat, TetGen2Femtic's VTK
  femtic_mesh.io.tetgen     .node .ele .face .neigh .poly .mtr readers and writers
  femtic_mesh.cells         parameter-cell partition: rule 'usui' (TetGen2Femtic's) and alternatives
  femtic_mesh.tetgen2femtic faithful port of TetGen2Femtic @ceb8bfb (python -m femtic_mesh.tetgen2femtic)
  femtic_mesh.repartition   re-partition an existing mesh.dat (python -m femtic_mesh.repartition)

Units follow the files: tetgen files and resistivity_attr.dat in km, mesh.dat in metres; FEMTIC frame
(x north, y east, z down). Arrays: float64 coordinates, int32 indices.
"""
__version__ = "0.1.0"
