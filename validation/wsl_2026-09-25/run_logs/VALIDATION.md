# FEMTIC v5.0 GCC/OpenMPI/MKL build: validation on the bundled example INV_MT_01/Tetra

**Verdict on the stated criterion: PASS.** 5 of 5 Gauss-Newton iterations completed. RMS fell from 2.2346 to 0.8406 (misfit down 85.9 %). Exit 0 after 36.9 s, peak about 1.0 GiB across both ranks.

## Failure criterion (stated before running)
The validation fails if any of these happens:
- femtic completes fewer than 2 Gauss-Newton iterations.
- The data misfit in femtic.cnv does not decrease between the first and last completed iteration.
- The run crashes, runs out of memory, or hangs beyond 45 min. The hang limit is enforced with `timeout 2700`.

## What was run
- Binary: `/home/tara/femtic_wsl/bin/femtic`. Sources are byte-identical to upstream v5.0 (see ../build_logs/SUMMARY.md).
- Environment: conda env `femtic-build`, with conda-forge gcc 15.3.0, OpenMPI 5.0.10 and MKL 2026.1.0 (ILP64, gnu_thread).
- Case: `examples/INV_MT_01/Tetra` copied to `/home/tara/femtic_wsl/run_INV_MT_01_Tetra`. It has 36 MT stations, 4 frequencies (0.001, 0.01, 0.1, 1 Hz), 34 559 tetrahedra and 289 parameter blocks (block 0 is fixed air). The initial model is a uniform 100 ohm-m half-space.
- control.dat edits: NUM_THREADS 1 -> 2. ITERATION stays at `0 5`, because the first iteration took about 6 s, far under the 8 min limit. The file has CRLF endings. The script edits it with a CRLF-aware sed and then checks that the values actually changed.
- Command, from the run directory:

      export OMP_NUM_THREADS=2
      /usr/bin/time -v -o time_v.log timeout 2700 mpirun -np 2 --oversubscribe --bind-to none /home/tara/femtic_wsl/bin/femtic > run.log 2>&1

  The script is `../run_inv_mt01.sh`, launched through `wsl.exe -d Ubuntu`.
- **Aborted first attempt (disclosed):** the first launch at 12:07 ran with NUM_THREADS still set to 1. The plain `s/^1$/2/` sed did not match `1\r`. I killed it after about 10 s (exit 143) and relaunched at 12:08:07 with the fix. All numbers below come from the second run. Its output is at `launcher_aborted_numthreads1.log`.

## Ranks and threads (independent observables)
- **MPI ranks: 2.** `run.log` is empty (0 bytes) because femtic writes to `femtic_[PE].log`, not to stdout. It therefore says nothing about the process count. The evidence for 2 ranks is:
  - Two per-rank logs were written: `femtic_0.log` and `femtic_1.log`.
  - A `ps` sampler every 2 s saw 2 femtic processes in 17 of 17 samples.
  - The data were split across the ranks: rank 0 computed 0.001 and 0.01 Hz, and rank 1 computed 0.1 and 1 Hz. Summing both ranks' residuals reproduces the global misfit.
- **Threads: 2 per rank.**
  - femtic_0.log reports "Number of threads is specified to be 2".
  - Each process ran 4 kernel threads: 2 OpenMP threads plus MPI helper threads.
  - `time -v` reports 383 % CPU, consistent with 2 x 2 compute threads actually running.

## Convergence (femtic.cnv; columns from AnalysisControl.cpp: Iter#, Retrial#, Alpha, Damp, Roughness, Misfit, RMS, ObjFunc)

| Iter | Retrial | Damp | Roughness | Misfit | RMS | ObjFunc | Misfit recomputed from result CSVs | rel. diff |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 0 | 0.500 | 0.000 | 5752.642 | 2.234639 | 5752.642 | 5752.641 | 1.0e-7 |
| 1 | 0 | 0.500 | 99.357 | 2331.502 | 1.422629 | 2430.859 | 2331.502 | 1.7e-7 |
| 2 | 0 | 0.500 | 241.095 | 1309.987 | 1.066369 | 1551.083 | 1309.987 | 3.7e-7 |
| 3 | 0 | 0.500 | 340.476 | 991.2418 | 0.927606 | 1331.718 | 991.2419 | 8.3e-8 |
| 4 | 0 | 0.625 | 412.492 | 858.8092 | 0.863420 | 1271.302 | 858.8093 | 9.0e-8 |
| 5 | 0 | 0.781 | 448.560 | 813.9625 | 0.840574 | 1262.522 | 813.9624 | 1.4e-7 |

- Iter 0 is the forward response of the starting model. Iterations 1-5 are the 5 Gauss-Newton updates, each followed by a forward solve.
- No retrials (step cut-backs) occurred.
- The misfit decreases monotonically.
- femtic_0.log ends with "Converged." The objective changed by 0.69 % from iteration 4 to 5, under the CONVERGE 1.0 % threshold. Iteration 5 was also the configured maximum.
- The recompute column is an independent cross-check (`misfit_recompute.txt`, script `../recompute_misfit.py`). It computes sum(((Obs-Cal)/SD)^2) over N = 1152 data (36 stations x 4 freqs x 8 components) from the raw Cal/Obs/SD columns of both ranks' `result_*_iter*.csv`. It matches femtic.cnv to print precision. This validates the misfit accounting and the MPI reduction, not the forward physics.

## Outputs present
- `resistivity_block_iter0.dat` through `iter5.dat`.
- `result_{0,1}_iter{0..5}.csv`.
- The EnSight Gold set `result.case`, `Mesh.geo`, `BlockIDs`, `Resistivity.iter0-5` and `Sensitivity*.iter0-4`. femtic writes parameter visualisation as EnSight binary by default ("Following variables are written to BINARY file"). There is no sensitivity at the final iteration because no further update is computed.
- The only `.vtk` file is `obs_loc.vtk` (station locations), which is expected for this control.dat.

## Errors and warnings
`grep -i -E 'error|warning'` finds 0 matches in run.log, femtic_0.log and femtic_1.log.

## Wall time and memory
- Wall time: 36.9 s (`time -v`), from 12:08:07 to 12:08:44 +08:00.
- CPU time: 134.6 s user and 6.9 s system.
- Max RSS of the largest single process (`time -v`): 530 748 KB.
- Peak summed RSS of both femtic ranks (`ps` sampler, 2 s): 1 057 500 KiB, about 1.01 GiB. The machine has 117 GB RAM.
- PARDISO reports a 42 MB peak during analysis/factorisation.

## Supplementary physics check (my addition; FAILS at its tolerance, not revised)
The iteration-0 response comes from a uniform 100 ohm-m half-space, so the analytic answer is rho_a = 100 ohm-m, phase = 45 deg and Zxx = Zyy = 0.
- **Failure criterion:** any off-diagonal rho_a outside 100 +/- 10 % or phase outside 45 +/- 3 deg.
- Details: `halfspace_check.txt`, script `../halfspace_check.py`.

| freq | rho_a range (xy/yx) | phase range (deg) | failing |
|---|---|---|---|
| 0.001 Hz | 101.4 - 103.1 | 45.3 - 45.6 | 0/72 |
| 0.01 Hz | 103.5 - 108.4 | 45.6 - 46.7 | 0/72 |
| 0.1 Hz | 108.1 - 123.4 | 46.7 - 49.7 | 62/72 |
| 1 Hz | 122.4 - 175.2 | 50.4 - 59.0 | 72/72 |

**Result: FAIL (134/288).** I did not loosen the tolerance. Investigation (`mesh_surface_size.txt`) points to the example mesh, not the build:
- Tetrahedra touching the surface inside the station footprint have edges of 0.5-5.4 km (median 2.4 km).
- In units of skin depth, that median edge is 0.47 at 1 Hz (skin depth 5.0 km), 0.15 at 0.1 Hz, 0.05 at 0.01 Hz and 0.01 at 0.001 Hz.
- The error grows monotonically with h/skin depth, which is the signature of discretisation error for lowest-order edge elements. A bottom-boundary or domain-truncation error would show at low frequency instead.
- An independent toolchain produced the same femtic.cnv and responses to the last printed digit: GCC 12.3 / OpenMPI 4.1.5 / MKL 2023.1 (../build_logs/smoke_crosscheck.txt).

**Remaining gap:** none of these checks proves the forward physics against an external reference at 0.1-1 Hz. To close it, run the half-space on a surface-refined mesh (h <= skin depth/10 at 1 Hz, i.e. about 500 m near the stations) and confirm the error shrinks. Alternatively, obtain a femtic.cnv for INV_MT_01 from an upstream Intel build.

## Verdict
**PASS** on the stated criterion:
- 5 >= 2 Gauss-Newton iterations completed.
- Misfit went from 5752.64 at iteration 0 (2331.50 at iteration 1) to 813.96 at iteration 5, a decrease.
- No crash, OOM or hang: exit 0 in 37 s.

The supplementary half-space check fails at 0.1-1 Hz. The evidence points to the coarse example mesh rather than the build. It is flagged as the open item above, not counted as a build failure.

## Files (this folder)
run.log (empty), femtic.cnv, femtic_0.log, femtic_1.log, control.dat (as run), time_v.log, rss_samples.log, results_csv/, misfit_recompute.txt, halfspace_check.txt, mesh_surface_size.txt, launcher.log, launcher_aborted_numthreads1.log
