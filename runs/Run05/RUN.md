# Run05

- purpose: P0 reference chain on the gated v2 design; goldens for the port; expect 2,446,095 tets
- made: 2026-10-06 23:12 by scripts/make_run.sh on the PC
- job: mesh build from files/ (mesh_chain.sh: makeTetraMesh -stp 1-4, tetgen, 5 x makeMtr + tetgen -r, TetGen2Femtic; --mem=27G)
- mesh: built by this run (mesh_chain.sh), into this folder
- layout: 1 ranks x 8 threads per node, --time=04:00:00, partition icelake
- files: mesh/vulcan_v2/files (copied into files/)

The job builds mesh.dat, resistivity_block_iter0.dat and output.6.femtic.vtk in this folder from files/,
and keeps every intermediate (output.poly, output.1-6.*, each round's .mtr, the logs and timings) in intermediates/.
mesh_summary.txt holds the counts (nodes, tets, cells, surface faces) and the MESH CHAIN DONE line.

The 10 inputs are those of the gated WSL v2 build (the 9 it hashed equal mesh/vulcan_v2/mesh_logs/input_md5.txt).
WSL built 401,334 nodes / 2,446,095 tets / 65,342 cells in 360 s; mesh.dat md5 5f3d3ffb..., block 0c3ae9da...
(mesh/vulcan_v2/mesh_logs/products.md5). A different count or md5 here is a fact about Phoenix's build, to record.

On Phoenix (VF=/hpcfs/users/$USER/vulcan_femtic): bash $VF/kit/run.sh Run05   then   bash $VF/kit/status.sh Run05

## Jobs
