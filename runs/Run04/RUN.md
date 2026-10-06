# Run04

- purpose: P0 reference chain, small case; keep intermediates
- made: 2026-10-06 23:12 by scripts/make_run.sh on the PC
- job: mesh build from files/ (mesh_chain.sh: makeTetraMesh -stp 1-4, tetgen, 5 x makeMtr + tetgen -r, TetGen2Femtic; --mem=27G)
- mesh: built by this run (mesh_chain.sh), into this folder
- layout: 1 ranks x 8 threads per node, --time=04:00:00, partition icelake
- files: mesh/chain_proof/inputs (copied into files/); files/region_seeds.dat written from --seeds "0.0 0.0 -40.0 10 1e9; 0.0 0.0 10.0 20 1e9"

The job builds mesh.dat, resistivity_block_iter0.dat and output.6.femtic.vtk in this folder from files/,
and keeps every intermediate (output.poly, output.1-6.*, each round's .mtr, the logs and timings) in intermediates/.
mesh_summary.txt holds the counts (nodes, tets, cells, surface faces) and the MESH CHAIN DONE line.

The inputs are the 9 files of the WSL chain_proof run A (md5 equal to mesh/chain_proof/logs/input_md5_lf.txt) and its
region seeds, the "example synthetic" block of meshGen.sh (validation/mesh_2026-09-25/chain_proof.md section 3). WSL
built 4,705 nodes / 27,501 tets / 3,842 cells; mesh.dat md5 8844b52f..., block 119bb35f... (mesh/chain_proof/products.md5).
A different count or md5 here is a fact about Phoenix's build (glibc 2.28 vs 2.39), to record, not a failure of the job.

On Phoenix (VF=/hpcfs/users/$USER/vulcan_femtic): bash $VF/kit/run.sh Run04   then   bash $VF/kit/status.sh Run04

## Jobs
