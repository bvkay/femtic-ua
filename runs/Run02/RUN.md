# Run02

- purpose: Half-space gate at 3 ohm-m on mesh v2, all 21 bands (the high-frequency stress case; STATUS D1 with Run01)
- made: 2026-10-06 22:20 by scripts/make_run.sh on the PC
- job: half-space accuracy gate, START_RHO=3 ohm-m (06_forward_only.slurm)
- mesh: v2 (on Phoenix $VF/shared/mesh_v2/, linked into this folder by run.sh)
- layout: 3 ranks x 24 threads per node, --time=02:00:00, partition icelake
- data: mesh/vulcan_v2_rot/inversion (control.dat, observe.dat, station_map.csv copied from there)

A half-space gate runs one forward solve of a uniform 3 ohm-m model and compares it with the analytic
half-space at every site and band. The data values in observe.dat do not matter, only its sites and frequencies.

On Phoenix (VF=/hpcfs/users/$USER/vulcan_femtic): bash $VF/kit/run.sh Run02   then   bash $VF/kit/status.sh Run02

## Jobs
