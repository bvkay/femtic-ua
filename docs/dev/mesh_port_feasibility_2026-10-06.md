# Mesh tools: Python port feasibility and kernel choice (2026-10-06)

This is the mesh-tool study, a feasibility study and not a port. Sections 2-5 draw on five tool studies, each re-checked
by an independent verifier (refuted claims are listed in section 11); for them nothing was meshed or run. Section 6
merges the alternative-kernels study (ALT), which stays the detailed record. Sections 7-9 turn both into one plan.

**Citation keys** (pins at docs/mesh_tetra_pipeline.md:55-59; the clones were in a temporary scratchpad, so re-clone):
- MTM = makeTetraMesh/src @92a9a32 · MTR = makeMtr/src @df8e207 · T2F = TetGen2Femtic/src @ceb8bfb ·
  FEM = femtic/src @26c8606 · TG = libigl/tetgen @e05aca7, i.e. TetGen 1.6.0 (hpc/phoenix_plan/01_build_femtic.sh:182, 191).
- M/ = D:/BEN/FEMTIC_2026/mesh/; other paths are repo-relative. v2 step times (M/vulcan_v2/mesh_logs/timings.tsv) sum to
  348.5 s, against 359.8 s of wall time (summary.txt:8).
- ALT = docs/dev/mesh_alternatives_2026-10-06/README.md; toys/ = its toys/ (ALT's `S:`; its `S:env` was not kept).
  PIPE = docs/mesh_tetra_pipeline.md. STATUS = docs/STATUS.md at commit 06d044f.

## 1. The decision

On 2026-10-06 Ben asked to port the mesh tools to Python, **if feasible**, so the student toolchain is pure Python on
any OS. His criteria, in order: (1) **EFFICIENT**, meaning memory and CPU on Vulcan-size meshes; (2) **ROBUST**, meaning
it fails loudly and is reproducible; (3) **SPEEDY**, meaning wall time.

**Recommendation in one line.** Pure Python is out of reach, so build `femtic_mesh` (conda or pip install, no compiler,
Python everywhere except the compiled meshing kernels): start with the Phoenix reference run (P0) and the TetGen2Femtic
port (P1), and let a Phoenix gate at P3 decide whether Gmsh replaces makeTetraMesh, makeMtr and tetgen for students.

- **Not achievable: a pure-Python chain.** Every candidate kernel is compiled behind a wheel or conda package (ALT:9);
  tetgen alone takes 319.5 of the 348.5 s and is about 45k lines of exact-predicate C++ (section 3).
- **Achievable: a conda or pip install on Windows, macOS and Linux, no compiler.** Python does the inputs, makeMtr,
  TetGen2Femtic, the parameter cells, the checks and the driver. Compiled stays either conda-forge tetgen plus our
  per-OS makeTetraMesh binaries (sections 2.1, 3), or one Gmsh wheel for both, and no makeMtr, if P3 passes (ALT:35, 149).
- **First two steps.** P0: submit the Phoenix reference chain (0.5-1 day + queue). P1: the TetGen2Femtic port and the
  standalone re-partitioner (5-7 days); the re-partitioner starts on chain_proof while P0 queues (section 8).
- **The one decision for Ben now.** Tests TD6-TD7 (section 9), not Ben, pick the P3 branch. His call today is the bar
  a student mesh must meet. (a) "Passes the D1 half-space gate" (STATUS:181): P3 stays in (23-38 days on either
  branch), and a distributed tool that imports gmsh ships under GPL terms with source (ALT:63-65). (b) "Byte-identical
  to Usui's chain": drop P3, ship makeTetraMesh binaries (20-33 days). Byte identity on Windows and macOS is unproven
  even for binaries (libm drift, section 2.1), so (b) means "byte-identical to one reference build". P0-P2 are the same.

| Tool | v2 time | Verdict | Effort (days) | Byte identity |
|---|---|---|---|---|
| makeTetraMesh | 9.4 s (2.7 %) | WRAP as binaries, or REPLACE by Gmsh if P3 passes; no port (section 7) | binaries 2-4; Gmsh 5-9 (est.); port 25-40 | possible, unproven, no oracle yet |
| tetgen | 319.5 s (91.7 %) | KEEP binary, as subprocess; students drop it only if Gmsh passes P3 | 1.5-4 | exact with the same build; md5-test each build |
| makeMtr | 7.9 s (2.3 %) | GO on the TetGen route; Gmsh needs no makeMtr (ALT:149) | 3-5 | text should match; shell nodes depend on libm |
| TetGen2Femtic | 11.8 s (3.4 %) | GO, first: every kernel needs this converter (ALT:125-135) | 5-7 with the re-partitioner | partition reproduced on chain_proof |
| Python side | - | GO, as new package `femtic_mesh` | 8-12 | inputs byte-exact against the md5 goldens |

## 2. The tools

### 2.1 makeTetraMesh (surface mesh and PLC): WRAP now, or replace by Gmsh (section 7)

**What it does.** Four processes, `-stp 1..4`, hand fixed-name text files to each other (MTM Control.cpp:323-368):
1. clip the coast lines to the domain box (BoundaryCurveList.cpp:902-1353);
2. build a 2-D incremental Delaunay surface, refine it by long-edge sweeps against ellipsoid shells plus 2-D site rings,
   then smooth it (TriangleList.cpp:85-124, 3032-3137, 3727-3786);
3. compute IDW heights (2059-2154);
4. assemble the PLC with meshed top, bottom and side faces (3801-3857, 4547-4729, 5380-5811).

Size: 51 files and 18,749 physical lines, of which about 8,500 are logic (about 4,300 of those in TriangleList.cpp).

**Inputs and output.** Inputs are control.dat, parsed by substring keywords (Control.cpp:94-320; Ellipsoids.cpp:82-181),
plus the domain, site, coast, topography and bathymetry files and an optional lake.dat. The output is output.poly
(`%30.15e`; TriangleList.cpp:6299-6366) with **0 holes and 0 regions**: run_mesh_chain.sh:147-155 appends the seeds.

**Hotspots.**
- Steps 1-4 take 9.4 s with a 54 MB peak; step 2 is 7.7 s for 109,123 insertions over 22 sweeps (makeTetraMesh_stp2.log).
- Each size query evaluates the ellipsoid field 121 times (ObservationPoint.cpp:125; ObservingSiteList.cpp:147-152),
  which can be removed with identical results. Also: an O(k^2) proximity scan (TriangleList.cpp:3096-3101), walks that
  always start at triangle 0 (50, 542-546), and a brute-force IDW, the only OpenMP region (2071-2085).

**Python mapping.** numpy/scipy for the parsers, size field, IDW (cKDTree), flood fill and writers; numba `@njit` over
flat int32 arrays for the sequential mesher (walk, insert, flip, recovery, Laplacian). Bit identity also means copying
glibc `rand()` as one stream per process across all 10 face meshes (579); the 13-digit round trip at each step
(NodeList.cpp:186-197, 244-255) and -0.0 for land z; `x*x` wherever GCC folds `pow(x,2)` (Util.cpp:225-254;
Ellipsoids.cpp:233-235; ObservationPoint.cpp:124); std::map's first-key-wins (TriangleList.cpp:3240); the flip in
2-triangle recovery (6471-6472); the wall- and bottom-edge sizing quirks (5525-5544, 4659-4700).

**Fidelity: possible, not guaranteed, and untestable at Vulcan scale today.** A byte-identical output.poly plus the same
tetgen gives the same mesh (validation/mesh_2026-09-25/chain_proof.md:256). The obstacles:
- **libm drift.** The goldens came from WSL2 Ubuntu 24.04, glibc 2.39 (validation/wsl_2026-09-25/build_logs/SUMMARY.md:7);
  Phoenix is RHEL 8.4 (docs/STATUS.md:284), hence glibc 2.28, and hypot, atan2 and tan changed between the two.
  CPython's `math.hypot` is not libm's: they differ on 50,407 of 300,000 pairs on this PC.
- **Untested IDW.** IDW distances feed z directly (TopographyData.cpp:371, 416), and every golden is flat.
- **`rand()` is rare.** It runs only when the absolute 1e-12 test hides a crossing (Util.cpp:74-82), which needs edges
  under about 1.6 m; Vulcan's site triangles are 4.1 m.
- **Oracle.** Only a gcc build can be the reference (icpx: fast FP, hpc/ported/makeTetraMesh/Makefile.intel_oneapi:21-25).
- **No reference outputs.** v1-v3 kept no output.poly and no *.stp* files, so the reference must come from G0.

**Effort.** A faithful port takes 25-40 days; the study said 15-21, but the verifier found about 5k lines that must be
bit-exact. Sea, lake and layer paths add 8-12 days. A Triangle redesign is 7-12 days plus full re-validation, under a
non-commercial licence. Per-OS CI binaries take 2-4 days. **Why WRAP:** a port costs more than all the other ports
together, saves 2.7 % of the time and cannot be verified before G0, and a CI binary meets "no compiler" (section 7).

### 2.2 makeMtr (per-node size field for `tetgen -m`): GO

**What it does.** For each node it computes L = min(site spheres, sea ellipses, ellipsoid shells) (MTR main.cpp:516-554)
and writes output.i.mtr, which tetgen reads in each of the 5 rounds (run_mesh_chain.sh:180-183). About 600 lines are
live; about 24 % of main.cpp is dead.

**Inputs and output.** It reads makeMtr.param (main.cpp:170-359), obs_site.dat (361-394), the .node file (396-420) and
the .ele file (423-479), whose body only the sea test uses. It writes `%10d%10d`, then one `%15.6e` per node, and exits
1 on any value below 1e-12 (480-514).

**Hotspots.** Each round is 427k nodes x 120 sites: 0.46-2.56 s on v2 and up to 8.4 s on v3
(M/vulcan_v3/mesh_logs/timings.tsv). RSS is 61-235 MB, mostly the Element array and node lists (main.cpp:53-57, 437,
454), both of which serve only the sea test.

**Python mapping.** cKDTree pruning: 0.28 s for 427k nodes, bitwise equal to brute force (8.9 s). `np.loadtxt`
node read: 0.23 s, exact (pandas' default parser is wrong on 24 %). Write: 0.13 s. Imports: 0.55 s. The biggest round
takes about 1.2 s, beating the C++, but round 1 is slower.
- **Keep the quirks:** `val1 = sqrt(3*(r_{i+1}/r_i)^2)` (ObservationPoint.cpp:135); PI = 3.14159265359 (main.cpp:68);
  missing counts read as 0 (298-299, 382), because femticPy omits them (femticPy.py:806-832). Use `take_along_axis`,
  not `np.choose`, which is capped at 32 or 64 choices.

**Fidelity.** Site, core, outer and sea values are pure IEEE arithmetic, so they are bit-exact with `x*x`. Shell values
depend on libm's atan2, tan and hypot. numpy differs from a scalar mirror on 9,622 of 20,000 shell nodes (at most
1.3e-15 relative), yet no 7-digit text changed, nor under 2,000,000 one-ulp perturbations. chain_proof covers the shells
(4 ellipsoids, M/chain_proof/inputs/makeMtr.param) but not site-sphere interpolation, since it has 1 sphere per site.

**Effort, verdict.** 3-5 days, after G0 (no output.1-5 were kept). **GO**: pure arithmetic, a drop-in for `makeMtr output.i`.

### 2.3 TetGen2Femtic (mesh.dat and parameter cells): GO, first

**What it does.** It reads output.6.{node,ele,neigh,face} and resistivity_attr.dat (201-417, 465-708) and writes:
- mesh.dat, with 7 face lists, the last of them the Earth surface (T2F MeshData.h:114-123; MeshData.cpp:1583-1633);
- the block file, with count-median bisection cells (1891-2086, written at 1815-1888); its bounds 1e-20/1e+20 and
  weight 1.0 are hard-coded (1878-1882);
- a VTK (1636-1812). About 1,000-1,190 lines are on the chain's path; `-thread` is a no-op (49).

**Hotspots.** v1 / v2 / v3 take 8.8 / 11.8 / 19.4 s and 164 / 261 / 320 MB (M/vulcan_v*/mesh_logs/t2f.time). On v3 it
reads about 37M tokens and writes about 29M lines, 22.5M of them in the VTK.

**Python mapping (numpy only).**
- **Faces.** Neighbours and face-to-(element, local face) come from sorted node triples. The local face is 6 minus the
  sum of the three local indices (1475-1489).
- **Face order.** Keep the .face order: FEMTIC's walk starts at `m_elemOnLandSurface[0]`
  (FEM MeshDataTetraElement.cpp:355), and the first matching triangle wins (392-462).
- **Partition** (MeshData.cpp:2028-2071, 2132-2148, 2388-2436). Lexsort on (coordinate, element), cut at ceil(n/2),
  and send axis ties to the higher axis. Split while the spread is not strictly below min(B at the extreme centroids).
  Compute each centroid as `((((0+x0)+x1)+x2)+x3)*0.25`.
- **Arithmetic.** Use `x*x` for `pow(.,2)`, which GCC folds (2197-2199, 2334). Use `math.atan2` and `math.tan`, and
  libm's hypot via `np.hypot` or ctypes. Never use `math.pow` or `math.hypot`. PI = 3.14159265359 (34).
- **Reading.** Use `np.loadtxt` or pandas' C engine, never `f.read().split()`, which peaked at 2.1 GB on v3
  (M/vulcan_v3/mesh_logs/mesh_stats.timev).

**Fidelity: partly shown.**
- About 150 lines of Python rebuilt chain_proof's block file (md5 119bb35f...) and VTK byte-for-byte from mesh.dat:
  3,842 blocks, 0 of 27,501 elements different (scratchpad proto/rcb_check.py). The mutants fail as they should:
  floor split 9,361 elements, no element tie-break 3,748, B at the group centroid 10,072.
- **Not yet covered:** Vulcan's 2-circle sites and oblate ellipsoids (M/chain_proof/inputs/resistivity_attr.dat vs
  M/vulcan_v2/files/resistivity_attr.dat); the axis-tie rule; a rounding-dependent hard exit (2263-2279) that the
  chain's grep misses (run_mesh_chain.sh:196); and tetgen's .face file, which full mesh.dat identity needs and no run kept.

**Effort.** 3-5 days, plus 1 for alternative rules and a cell report. **Why GO first: D3 is formed here.** Every cell is
a leaf of a count-balanced tree (MeshData.cpp:2057-2071). v2 has 65,341 earth cells: 5/10/20 elements at p10/median/p90,
18,393 cells with 5 or fewer, and 1,040 with exactly 1 (M/vulcan_v2/mesh_logs/mesh_stats.txt:103-106), against about 21k
designed (docs/mesh_tetra_pipeline.md:790-796). A standalone re-partitioner can test D3 fixes without remeshing.

### 2.4 Python side (femticPy MeshGen, prep_vulcan.py, shell drivers): GO, as `femtic_mesh`

**What it is.** prep_vulcan.py validates config.yml and writes 9-10 mesh inputs via femticPy MeshGen (femticPy.py:636-943)
and its own writers (scripts/prep_vulcan.py:1836-1876); run_mesh_chain.sh (gated) and 03_mesh.slurm (ungated) run it.

**Gaps closed.**
- **Two seed formats.** prep writes 5 columns (prep_vulcan.py:1872-1876). 03 reads a 6-column regions.txt and silently
  uses synthetic seeds when that file is absent (03_mesh.slurm:109-113). A misread file is caught at :120-122.
- **Vacuous .mtr check.** `[ -f output.i.mtr ]` cannot fail for i >= 2 (run_mesh_chain.sh:182).
- **Missed log line.** ITER_MAX exhaustion (MTM TriangleList.cpp:3054, 3273, 3382) escapes `grep error`
  (run_mesh_chain.sh:143). Also, femticPy loads matplotlib and pandas at import (femticPy.py:36-45).

**Cautions.** femticPy.py:677-678 is a real z-sign bug, worked around at prep_vulcan.py:1841. femticPy.py:824-826 is
not a bug: prep zeroes site z only for flat meshes (prep_vulcan.py:1838-1839). Byte identity also needs femticPy's
arithmetic order. After centring (femticPy.py:236-245), 9 of the 120 eastings sit exactly on a `%2.3f` halfway point,
and a metres-first rewrite flips 2 of them.

**Effort and verdict.** 8-12 days; the study said 6-9, but 03 is woven into the Phoenix kit (03_mesh.slurm:68-96,
femtic_lib.sh). **GO.** Keep femticPy frozen behind an adapter for EDI-to-observe.dat, so its patch series survives
(external/femticPy/patches/series).

## 3. The tetgen question, plainly

**Use a subprocess to TetGen 1.6.0, not a Python binding.** The chain calls `-nVpYAakq3.0/0 output.poly` once
(run_mesh_chain.sh:158), then `-nmpYVrAakq3.0/0 output.i` five times (:183).

| Option | Runs the chain? | What it cannot do |
|---|---|---|
| **subprocess + TetGen 1.6.0** (conda-forge `tetgen=1.6.0`, linux-64/aarch64, osx-64/arm64, win-64; or own CI) | yes, unchanged | conda-forge builds the WIAS tarball, not e05aca7, with optimised predicates. md5-check the sources, then byte-test each platform (B5). |
| pyvista `tetgen` 0.8.4 | step 5 only | Cannot load existing tets, attributes, faces or edges, so no `-r`. `-m` only via a background mesh, a different algorithm. The keyword API caps Steiner points at 100k (pytetgen.py:533) against Vulcan's 225-284k. Segfaulted on a toy. Returns no neighbours. |
| meshpy 2026.1.1 | yes (`load_tetmesh` + .mtr file) | Bundles a pre-release TetGen 1.6.1 without fix 43e7bbd, so every mesh changes. `Options()` forces quiet (meshpy/tet.py:135). Predicates not at -O0. `save_*` writes `%.16g`. |
| Port to Python | no | About 45k lines of exact-predicate C++. |

**What this means for the chain.**
- **Students get a conda binary, not pure Python:** only the same TetGen source and FP flags reproduce the meshes.
- **Licence.** TetGen is AGPLv3-or-later for every use, not "non-commercial". A subprocess keeps it separate from our
  code; both wheels claim MIT yet embed AGPL code.
- **The wrapper must be stricter than the shell script.** A wrong-count .mtr is ignored with exit 0, and the mesh is
  refined without sizing (TG tetgen.cxx:757-762). Exit 1 always prints "Out of memory" (tetgen.h:2493-2495). A stray
  output.i.b.* silently becomes a background mesh (tetgen.cxx:36540-36543). Every output ends with
  `# Generated by <argv[0]> ...` (3089-3096, 33684), which must be stripped before any md5.
- **Speed lives inside tetgen.** Smoothing takes 24-28 s per round (tetgen_r*.log). The 5 `-m` rounds coarsen and
  re-refine without converging: 2.10M, 2.61M, 2.36M, 2.59M and 2.45M elements (refinement.tsv; tetgen.cxx:36283-36285).
  TetGen 1.5.x coarsened only under `-R`. Running fewer rounds is a chain-design experiment, not part of the port.

## 4. Proposed `femtic_mesh` package

```
femtic_mesh/
  spec.py       MeshSpec dataclasses + validators from prep_vulcan.py:200-230, 327-401; every count = len()
  io/inputs.py  control.dat, domain, observing_site, obs_site, makeMtr.param, resistivity_attr, coast, topo, seeds
  io/tetgen.py  .poly/.node/.ele/.face/.neigh/.mtr readers + writers (skip the '# Generated by' line)
  io/femtic.py  mesh.dat, resistivity_block_iter0.dat, legacy VTK (exact printf widths, newline='\n')
  sizefield.py  ellipsoid ray radii + the THREE site rules kept apart (MTM 2-D rings, MTR spheres, T2F circles)
  surface/      backend 'binary' (makeTetraMesh) or 'gmsh' (if P3 passes, section 8); no numba port planned
  metric.py     makeMtr port (numpy + cKDTree)
  tetra.py      tetgen subprocess: timeout, exit-code map (1/2/3/4/5/10/200), '!!' scan, stale-file guard
  femtic.py     TetGen2Femtic faces and boundary lists (numpy)
  cells.py      parameter-cell partition: rule='usui' (byte-exact) + alternatives; cell-quality report
  check.py      product checks from run_mesh_chain.sh:71-88, 172-175, 189-191, 200-217
  chain.py      run(spec, workdir, backends={...}, rounds=N): replaces run_mesh_chain.sh and 03's chain section
  cli.py        python -m femtic_mesh {prep, build, repartition, check, report}
```

**Data model: arrays between Python steps, files only at process boundaries.**
- `TetMesh`: nodes (N,3) float64 in km, tets (M,4) int32 0-based, attr (M,) int32, neigh (M,4) int32, faces (F,3) int32.
- Tets keep tetgen's corner order, because FEMTIC's search depends on winding (FEM MeshDataTetraElement.cpp:1389-1410).
  Faces keep the .face order.
- Two text roundings are part of the algorithm and stay: the 7-digit .mtr, which is all tetgen reads (tetgen.cxx:792),
  and makeTetraMesh's 13-digit rounding between steps.

**Efficient on Vulcan (2.4-3.1M tets, 120 sites).**
- **Memory.** On v3, int32 tets take 49 MB and float64 nodes 12 MB: each Python step stays under 1 GB (tetgen: 0.98 GB).
- **I/O.** `np.loadtxt` reads 2.61M .ele lines in 0.77 s, exactly; pandas' C engine with `float_precision='round_trip'`
  also works. Chunked `%` writes take about 3 s per 3M lines.
- **Compute.** Vectorisation covers makeMtr, TetGen2Femtic and the checks. **numba would be needed only for a
  makeTetraMesh port, option (ii), which section 7 rejects.**

**Callers.** prep_vulcan.py becomes a thin CLI (config.yml → MeshSpec → `femtic_mesh.io`). femticPy DataGen sits behind
an adapter. A GUI calls `spec.validate` and `chain.run(progress=cb)`. 03_mesh.slurm keeps its Slurm and walltime shell
and calls `python -m femtic_mesh build`.

**Parameter cells become a designed, tested step.**
- `cells.partition(mesh, table, rule)` defaults to `rule='usui'`, which serves as the regression oracle.
- Candidate alternatives: a midpoint split (chain_proof earth cells 3,841 → 3,374); B at the mean element centroid
  (→ 3,574); a minimum-k merge; global B scaling to a target count; separate horizontal and vertical B.
- `report()` turns mesh_stats.txt:102-125 into a function that runs on every build.
- `repartition` rewrites only the block file. That is valid for 2-region meshes, where block 0 is air and the rest is
  earth (rcb_check.py:44).
- **Any new rule changes the inversion parameterisation.** It is a scientific choice, gated by an inversion smoke test.

## 5. Test strategy (Invariant 10: each test states how it fails)

**G0, the Phoenix reference. Every byte test depends on it.**
- **Run.** run_mesh_chain.sh with the gcc build (not TOOLCHAIN=intel) on M/chain_proof/inputs,
  M/chain_proof_meshgen/inputs and vulcan_v2. Keep output.poly, *.stp1-3, output.1-6.* and every .mtr.
- **Fails if** a chain gate fails or check_mesh is below 17/17.
- **Recorded, not failed:** a mismatch with the WSL md5s, 8844b52f / 119bb35f (M/chain_proof/products.md5) and
  5f3d3ffb / 0c3ae9da (M/vulcan_v2/mesh_logs/products.md5). If they differ, Phoenix becomes the oracle. G0 also
  closes "no tested Phoenix mesh-build route" (docs/STATUS.md:289-292).

**Byte tier: each Python step against the C++ on the same files.**
- **B1. Writers** on config/vulcan_mesh_v{1,2,3}.yml. **Fails if** any md5 differs from
  M/vulcan_v*/mesh_logs/input_md5.txt. Include the 9 halfway-point sites; bathymetry is covered only by
  M/vulcan_v2_rot/prep_manifest.sha256.
- **B2. TetGen2Femtic port** on G0's output.6.*. **Fails if** mesh.dat, the block file or the VTK differs from the C++
  run on the same files. Report the first differing byte (`cmp`).
- **B3. Partition** of the v1/v2/v3 mesh.dat (55,993 / 65,342 / 68,655 cells incl. air). **Fails if** any element's
  block differs. mesh.dat has only 10 digits, so trace each mismatch to a near-tie, then re-run from G0's output.6.*.
- **B4. makeMtr port** on G0's output.1-5. **Fails if** any byte differs, except ±1 in the 7th digit at a shell node,
  or if a `precision(17)` C++ build differs by an ulp at any non-shell node.
- **B5. tetgen driver**, same executable. **Fails if** any output.N.* byte differs outside the `# Generated by` line
  (repeat for each conda-forge or CI build).
- **B6. makeTetraMesh port** (option ii only). **Fails if** output.poly differs from M/chain_proof/output.poly (up to
  `# Part 4`) or from M/chain_proof_meshgen/logs/output.poly.unseeded. Then diff G0's v2 stp1-3 to localise the stage.
- **B7. End to end** on chain_proof. **Fails if** the mesh.dat or block md5 differs from G0.

**Statistical tier: a Python-built PLC, or another tetgen build.**
- **S1.** **Fails if** check_mesh scores below 17/17 (chain_proof.md:258).
- **S2.** **Fails if** node, element or Earth-surface counts differ from the C++ v2 by more than 5 %, or the edge
  quantiles in the mesh_stats.txt distance bands by more than 10 %. Never assert "every edge <= ALPHA x L".
- **S3.** The D1 half-space gate on Phoenix: 3 and 100 ohm-m, 21 bands (docs/STATUS.md:51, 181). **Fails if** any fails.
- **S4.** Windows, macOS, Linux (`NUMBA_DISABLE_INTEL_SVML=1`). **Fails if** outputs differ without a traced libm cause.

**Negative controls: these prove the tests can fail.**
- **N1.** The three TetGen2Femtic mutants must fail B3; a symmetric-cube fixture covers the axis-tie rule.
- **N2.** ALPHA 1.5 → 1.49, BETA 0.2 → 0.21, or moving one site by 0.001 km must each change output.poly. Mutants that
  allow constrained flips, or skip the 13-digit rounding, must fail B6.
- **N3.** The driver must fail on each of these: a makeMtr stub that exits 0 without writing (today's chain passes it
  for i >= 2); an ITER_MAX log line; a .mtr with the wrong count; a stray output.i.b.node.
- **N4.** Each validator must raise on its case: non-nested ellipsoids, a domain not straddling 0, a seed outside the
  domain, seed attributes ≠ regions, or air with ndiv >= 0. With the validator disabled, its test must fail.
- **N5.** **Fails if** a ported step exceeds 2x the C++ wall time or 1 GB RSS on v2 (makeTetraMesh port: 60 s, warm cache).

**Coverage gap.** Every golden is a land-only box with flat zero topography, and chain_proof sites have a single sphere.
Before claiming parity beyond Vulcan's path, add G0 cases with non-flat topography, a coastline crossing the box,
multi-sphere sites, rotation != 0, and sea. Until then the port raises NotImplementedError for sea, lakes, sediment,
LAYERS and the extended region.

## 6. Alternative kernels (merged from the alternatives study)

One agent asked whether a Python-driven kernel could replace makeTetraMesh, makeMtr and tetgen, leaving only a FEMTIC
converter (ALT:3), and ran toys of at most 56,171 tets on the PC (ALT:5). Verdict: **design in Gmsh**, keep a TetGen
1.6.0 bridge as fallback, do not port makeTetraMesh's 2-D mesher (ALT:11). Section 11 lists six corrections to it.

| Kernel | Toy evidence | Verdict here |
|---|---|---|
| Gmsh 4.15.2 (pip wheel for win/linux/mac; conda-forge) | DEM surface within 0.087 m (ALT:49); air/earth tags plus an Earth-surface list (ALT:50); site triangles 3.97-4.19 m for a 4 m target, 2.63-2.85 m for 2.6 m (ALT:51); +-500 km box, 0 inverted tets (ALT:52); HXT about 0.32 M tets/s on one thread (ALT:55); identical md5 with the 2-D mesher on 1 thread, 3 different meshes with 8 (ALT:56, 61); 0 tets under 10 deg (ALT:57) | design candidate; untested at 3 M tets and on sea/coast (ALT:60, 154) |
| conda-forge `tetgen` 1.6.0 exe (win-64, linux-64, osx-64, osx-arm64; 0.5 MB) | Usui's switch strings with 3 .mtr rounds; md5 identical on repeat; `-Y` kept all 2,441 surface faces (ALT:76) | the fidelity anchor; byte match with our build untested (ALT:82) |
| pip `tetgen` 0.8.4 (pyvista) | round-0 md5 equals the exe's; `-m` segfaulted in all 4 variants; no `-r` (ALT:77, 83) | disqualified (ALT:119) |
| pip `meshpy` 2026.1.1 | bundles TetGen 1.6.1: 11,545 tets at round 0 against 11,537 (ALT:78) | every mesh changes (section 3) |
| pyGIMLi 1.6.1 | PLC builder that calls an external tetgen; no `-m`/`-r`; Windows PATH bug (ALT:93-94) | QC helper only |
| discretize 0.12.0 | SimplexMesh: neighbours, faces, volumes in 0.037 s on 31k tets (ALT:100); TreeMesh -> FEMTIC hexa needs a format nobody has read (ALT:105-112) | SimplexMesh as converter QC; TreeMesh out |

**What ALT adds to sections 2-5.**
- **Every kernel needs the converter** (ALT:125-135): neighbours, outer and Earth-surface lists, metres with z down and
  positive volumes, parameter cells, block file. Gmsh adds only orphan-node removal and group mapping (ALT:135), so
  P1 is no-regret.
- **Site-size control.** makeTetraMesh lets site edges reach 1.5x the target (PIPE:573); the site rule wants about 3.1 m
  at 200 Hz and 4.4 m at 100 Hz (PIPE:571-572), and any rebuild, a D3 fix included, must keep it (PIPE:574; STATUS:196).
  Gmsh held 1.1x on every toy (ALT:51).

## 7. The designer decision: makeTetraMesh's role

Section 2.1 chose (i), ALT chose (iii), both reject (ii) (ALT:141, 158); (iii) also drops makeMtr and tetgen (ALT:149).

| Criterion | (i) Ship per-OS binaries | (ii) Faithful Python port | (iii) Redesign in Gmsh |
|---|---|---|---|
| Efficient | 9.4 s, 54 MB (2.1); keeps the 1.5x site overshoot, so a 3.1 m site needs a 2.1 m target and more elements (PIPE:573) | same algorithm and overshoot (ALT:141) | 1.1x site control (ALT:51); HXT 21 % fewer tets than Delaunay (ALT:142); RAM at 3 M unknown (ALT:154) |
| Robust | built v1-v3; v3 passed the WSL gate, v2 failed one diagonal (STATUS:45-48); per-OS libm drift unproven (2.1) | about 5k lines must be bit-exact; IDW untested; flat goldens only (2.1; section 5) | deterministic only with 2-D threads = 1 (ALT:56, 61); sea/coast and 3 M tets untested (ALT:60, 154) |
| Speedy (v2) | about 6 min, 92 % of it tetgen (section 1; ALT:85) | same | volume 8-20 s extrapolated from 36-56k tets, weak (ALT:121); no makeMtr rounds (ALT:149) |
| Fidelity to the gated v2/v3 | byte-identical with the same build; across OSes unproven (2.1) | possible, not guaranteed; no oracle before G0 (2.1) | none: a new mesh (ALT:10, 147) |
| Student install | conda-forge tetgen + our CI binaries | conda-forge tetgen + numba | pip `gmsh` only (ALT:35); tetgen stays for the Usui route |
| Licence | Usui's terms (not recorded in this repo: check before shipping); TetGen AGPL-3 (section 3; toys/out/availability.log:20) | as (i), and the port is a derivative of Usui's code | GPLv2+ on distribution; with TetGen, no route escapes copyleft (ALT:63-66) |
| Effort (days) | 2-4 (2.1) | 25-40, + 8-12 for sea, lakes, layers (2.1) | prototype + gate 3-5, backend 2-4: estimates made here; ALT sizes it at 200-300 lines (ALT:121) |
| Re-gate | per-OS parity S4; half-space only if outputs differ | B6, N2, S1-S3 (section 5) | TD6 and TD7 on Phoenix, then the D3 cell report |
| Helps D3? | no | no (section 1) | indirectly: a D3 rebuild must meet PIPE:574 |

**Verdict.** (ii) is out: the highest cost, 2.7 % of the run time, nothing for D3. Between (i) and (iii) the evidence
cannot decide yet, because (iii) has never run above 56k tets; P3 decides. ALT's option C, a Gmsh surface fed to
conda-forge tetgen and the makeMtr port, reuses P2 and suits a Gmsh that fails only on volume scale (ALT:143, 157).

## 8. Sequence, reconciled with both studies

| Phase | Work | Days | Needs | Deliverable |
|---|---|---|---|---|
| P0 | G0 on Phoenix: run_mesh_chain.sh (gcc) on chain_proof, chain_proof_meshgen and v2; keep every intermediate (section 5) | 0.5-1 + queue | Ben submits | golden intermediates; first run of the Phoenix mesh tools (STATUS:289-292); the route any D3 rebuild needs (STATUS:196, 291-292) |
| P1 | TetGen2Femtic port + `cells.py`, `repartition`, cell report; B2, B3, N1 | 5-7 | chain_proof now; G0 for B2 | D3 options with no remesh; the converter every kernel needs (ALT:125) |
| P2 | `femtic_mesh` spec, io, check, chain driver (8-12); makeMtr port (3-5); conda-forge tetgen wrapper and its byte test (1.5-4); B1, B4, B5, N3, N4 | 12.5-21 | G0 | `python -m femtic_mesh build` on the TetGen route; option C ready |
| P3 | **Decision point.** Gmsh v2-equivalent prototype, gated on Phoenix (TD6, TD7) | 3-5 + queue (est.) | P1 only | the branch |
| P3 pass | Gmsh backend as designer and volume mesher | 2-4 (est.) | TD6, TD7 pass | pip-only student install |
| P3 fail | makeTetraMesh per-OS CI binaries; S4 | 2-4 (2.1) | | conda + binaries, as section 2.1 planned |
| P4 | GUI hooks: `spec.validate`, `chain.run(progress=cb)` (section 4) | not estimated by either study | P2 + branch | |

**Person-days, P0-P3 (P4 excluded).** Common P0-P2: 18-29. Gmsh passes: 23-38. Gmsh fails, binaries: 23-38. Bar (b)
of section 1, no prototype: 20-33. Option C after a volume-only Gmsh failure: add 1-3 (est.) and one gate. Port (ii)
instead of P3: 43-69, + 8-12 beyond Vulcan's land-only path. P3's days are this merge's estimates (ALT gave lines).

**Where the evidence changes the proposed sequence.**
1. **P3 needs P1, not P2.** The prototype needs only the converter (ALT:125-135) and Phoenix. Start it once P1 reads
   Gmsh output, before or alongside P2: the branch is known up to 12.5-21 days sooner, for the same effort.
2. **"Else ship binaries" skips ALT's fallback.** If Gmsh fails only on volume scale or RAM (TD6) and its surface is
   good, try option C first (ALT:143, 157). Ship binaries if the surface or the accuracy (TD7) fails.
3. **P2's TetGen pieces are not wasted if Gmsh wins.** Any v2/v3 rebuild for the current inversion uses the Phoenix
   TetGen route (STATUS:196, 291-292), and option C needs makeMtr and the tetgen wrapper.
4. **Order inside P1.** The re-partitioner needs no Phoenix time; B2 waits for G0's .face file, which no run kept (2.3).

### 8.1 Addendum 2026-10-07: local builds shift the designer choice (sections 7 and 8)

**What changed.** Ben decided on 2026-10-07 that students may build meshes on their own machines when the resources
allow; FEMTIC and the half-space gate stay on Phoenix, and the gate accepts any mesh (D11, STATUS "D11"). The GUI
design is docs/dev/gui_design_2026-10-06.md section 9. Section 7 weighed (i) and (iii) for builds that in practice
ran on Phoenix; a student machine turns its "Student install" row into a hard requirement, Windows first. No new
numbers here: every figure is in sections 2-7 or in the files they cite.

**How it shifts the argument.**
1. **(i) loses its main advantage for student meshes.** Its strength was fidelity, byte-identical to the gated
   v2/v3 with the same build (section 7, "Fidelity"). Under D11 a student mesh is a new design that passes its own
   gate, so fidelity to v2/v3 buys a student nothing; byte identity stays a developer test of the ports.
2. **(i)'s cost moves to Windows and macOS.** Locally, (i) needs per-OS binaries of makeTetraMesh and, until the
   makeMtr port passes B4, of makeMtr; hpc/ported/ holds GCC makefiles only (hpc/ported/README.md). Shipping them
   waits on Usui's licence terms (section 10, risk 4). conda-forge's tetgen exists for every OS but already differs
   from the chain's build at round 0 (docs/dev/mesh_port_progress.md section 4), so a local (i) build is a new mesh
   anyway, which point 1 makes harmless.
3. **(iii)'s install argument becomes a requirement.** One pip wheel, no makeMtr, no per-OS CI (ALT:35, 149). Its
   risks are unchanged: scale and RAM at 3 M tets, determinism only with 2-D threads = 1, sea and coast
   (ALT:56, 60, 154), GPL on distribution (ALT:63-65).
4. **New constraint: one designer for both routes.** The Phoenix route is hpc/phoenix_plan/mesh_chain.sh, a bash
   TetGen chain with no python (mesh_chain.sh:55). With Gmsh locally and makeTetraMesh on Phoenix, one config would
   make two kinds of mesh. So if (iii) wins, the Phoenix route must run the same Python driver (a conda env on
   Phoenix, which the kit avoids today) or stop serving student designs. If (i) wins, the routes share tools and
   switches and differ only by build (point 2).
5. **(ii) stays out:** still the costliest, 2.7 % of the time, nothing for D3 (section 7).

**What decides it.** The tests are section 9's; what changes is where two run and what one gates.
- **TD6 also on a student-class Windows machine**, not only on Phoenix: its 10 min / 8 GB limits are the local
  budget. If it passes on Phoenix and fails there, (iii) is Phoenix-only and point 4 applies. Ben's PC is not a
  test machine (STATUS 1.4).
- **TD7 on Phoenix**, as before: the gate decides accuracy (D11).
- **(i) per OS:** TD8 stays as written, a developer test (D11), but no longer gates shipping (i) to students: a
  per-OS difference makes a new mesh, which its own gate judges. What gates it is the driver's doctor reporting a
  complete backend on that OS and the local chain on chain_proof meeting S1 (check_mesh 17/17) and S2 against
  Phoenix's Run04 (section 5).
- **Sequence:** P3 now also picks the student install, so start it as soon as P1 reads Gmsh output (section 8,
  point 1). The GUI's Local route needs P2's chain driver on either branch; on Windows it stays disabled until (i)'s
  binaries exist or (iii) passes TD6 there (gui_design section 9.0).

## 9. Tests that decide (Invariant 10: each states how it fails; all run on Phoenix)

None compares FEMTIC outputs byte for byte: FEMTIC is not bitwise reproducible (STATUS:29-31). Mesh-tool outputs
reran byte-identically (validation/mesh_2026-09-25/chain_proof.md:256, 375), so TD2-TD5 and TD8 compare bytes.

| # | Phase | Test | Fails if |
|---|---|---|---|
| TD1 | P0 | G0 reference chain (section 5) | a chain gate fails or check_mesh scores below 17/17. A WSL md5 mismatch is recorded, not failed: Phoenix becomes the oracle |
| TD2 | P1 | TetGen2Femtic port on G0's output.6.* (B2) | mesh.dat, the block file or the VTK differs by one byte from the C++ on the same files (`cmp`) |
| TD3 | P1 | re-partitioner on v1-v3 mesh.dat (B3); control N1 | any element's block differs without a traced near-tie; or a mutant (floor split, no tie-break, group-centroid B) passes |
| TD4 | P2 | conda-forge tetgen against the Phoenix gcc build (B5), fed G0's output.poly and G0's .mtr each round so makeMtr stays out of the loop | any output.N.* byte differs outside the `# Generated by` line. Then use our own CI build (section 3) |
| TD5 | P2 | makeMtr port on G0's output.1-5 (B4) | any byte differs, except +-1 in the 7th digit at a shell node |
| TD6 | P3 | Gmsh scale (ALT:164-165): 120 sites, 4 m target, v2's domain and ellipsoids, 2-D threads = 1, run twice | more than 10 min or 8 GB RSS; the two md5s differ; a site is not in its own surface triangle; a site triangle exceeds 4.2 m (v2's figure, inside the 4.4 m rule at 100 Hz, PIPE:571-572). Control: an 8-thread 2-D run must trip the md5 check (ALT:56) |
| TD7 | P3 | Gmsh accuracy under D1 (STATUS:181): 3 and 100 ohm-m, all 21 observe.dat bands | any site's rho_a is off by more than 5 %, its phase by more than 1.5 deg, or its abs(Zxx) or abs(Zyy) exceeds 2 % of abs(Zxy) (PIPE:821, 840). Report tets and PARDISO memory against v2's 2.45 M and 22,903 MiB (ALT:168). Two jobs, about 172.8 SU each at v2 size (STATUS:182) |
| TD8 | P3 fail | per-OS binaries (S4) | Windows or macOS outputs differ from Linux without a traced libm cause |

## 10. Risks

1. **No oracle on an allowed platform yet:** WSL is off-limits and the Phoenix mesh tools never ran (STATUS:39-40, 289-292).
2. **libm drift** (glibc 2.39 vs 2.28, MSVC, Apple, SVML). It affects makeMtr's shell nodes, TetGen2Femtic's
   transition-zone B and all of makeTetraMesh. Mitigations: md5 per platform, text-level .mtr comparison, `x*x`.
3. **Thin goldens.** Flat, land-only cases hide IDW, coastline, sea and spacing errors.
4. **Licences.** TetGen AGPLv3+ (keep the subprocess boundary); Triangle non-commercial; Gmsh GPLv2+ on distribution
   (ALT:63-65). Usui's own licence for his tools is not recorded in this repo: check it before shipping binaries or ports.
5. **Windows paths and speed.** pip hit WinError 206 in a deep path, so students need short env paths or conda. An
   in-memory hand-off saves at most about 13 %; the real levers are tetgen's smoothing and its rounds.
6. **Gmsh is unproven at 3 M tets and on sea/coast** (ALT:60, 154); until TD6-TD7 pass, binaries stay the default.

## 11. Corrections from verification (dropped or changed above)

- **makeTetraMesh.** 18,749 physical lines (not 13,100) · 109,123 insertions (not 123k) · no MKL in the gcc port
  (Makefile.gcc_mkl) · "Linux = identical libm" is false · `math.hypot` is not libm · `rand()` fires on suppressed
  crossings, not vertex hits · 2-triangle recovery is a flip · 25-40 days, not 15-21 · no Phoenix-vs-WSL md5 test without G0.
- **makeMtr.** About 24 % dead code (not 40 %) · memory is mostly the Element array · chain_proof covers the shells, not
  site-sphere interpolation · round 1 is slower than the C++ once the 0.55 s import is counted · easier to build, not
  more reproducible.
- **TetGen2Femtic.** `pow(x,2)` is `x*x`; never `math.pow` or `math.hypot` · about 29M output lines (not 10M) ·
  1,000-1,190 lines on the chain path (not 700) · chain_proof does not cover Vulcan's sites or ellipsoids · the "-7 %" rule
  is B at the mean element centroid.
- **tetgen.** The Phoenix binary is unvalidated · `# Generated by` breaks md5 · a bad .mtr count exits 0 · reconstruction
  averages 9.5 s per round, not 12.5 · the T8 case references were wrong.
- **Python side.** Arithmetic order matters, not only the formats · femticPy.py:824-826 is not a bug · a misread seed file
  is caught loudly; only an absent one is silent · I/O is at most about 13 %, not 7 % · the 3 GB includes the products ·
  the driver takes 8-12 days.
- **This merge, study A.** Three ports: 16-24 days, not 16-27 · old P0-P5 rows: 20-33, not 21-35 · TetGen2Femtic: 4-6
  days in 2.3, 5-7 in the rows; plan uses 5-7 · "Python everywhere else" is wrong on the binary route, where
  makeTetraMesh stays compiled · renumbered: old P1 + P3 are P1, old P2 + P4 + tetgen's half of P5 are P2,
  makeTetraMesh's half of P5 is "P3 fail", old P6 is option (ii).
- **This merge, ALT.** Toy scale only: 3 sites and at most 56k tets against 120 sites and 2.45 M (ALT:5, 24) · its
  tetgen ran `-pYAq1.4` (toys/toy_tetgen.py:34), not the chain's q3.0/0, and v3 passed the gate with q3.0/0 slivers
  (ALT:118), so "no slivers" is not yet an accuracy gain · its gate (ALT:166-167) omits the 2 % diagonal limit behind
  v2's only failure (PIPE:840; STATUS:47) and D1's 3 and 100 ohm-m on 21 bands (STATUS:181): TD7 uses D1 · its option-C
  oracle is a WSL tet count (ALT:169-170); G0 is the oracle (section 5) and TD4 compares bytes · tetgen.exe and gmsh ran
  on the PC (toys/out/tetgen_runs.jsonl:1-3), sub-second but against "no modelling on the PC" (STATUS:39) · option C's
  "about 100 lines" of numpy makeMtr (ALT:157) is section 2.2's 3-5-day port once its quirks and B4 count.
