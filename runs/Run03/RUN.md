# Run03

- purpose: T4 on mesh v2: one inversion iteration, measures sensitivity-step memory, N_iv and time per iteration (submit after Run01 and Run02 pass)
- made: 2026-10-06 22:20 by scripts/make_run.sh on the PC
- job: T4, one inversion iteration (04_inversion.slurm; control.dat ITERATION 0 1)
- mesh: v2 (on Phoenix $VF/shared/mesh_v2/, linked into this folder by run.sh)
- layout: 3 ranks x 24 threads per node, --time=12:00:00, partition icelake
- data: mesh/vulcan_v2_rot/inversion (control.dat, observe.dat, station_map.csv copied from there)

Measures the sensitivity step (memory, N_iv) and the time of one iteration. The model is not kept for later runs.

On Phoenix (VF=/hpcfs/users/$USER/vulcan_femtic): bash $VF/kit/run.sh Run03   then   bash $VF/kit/status.sh Run03

## Jobs
