# Alternative Python meshing kernels for the FEMTIC tetra chain (feasibility, 2026-10-06)

Question: can a Python-driven kernel replace makeTetraMesh + makeMtr + tetgen, so that only a FEMTIC converter (TetGen2Femtic equivalent) is left to write?

Evidence conventions. `R:` = repo worktree `D:/BEN/FEMTIC_2026/.claude/worktrees/femtic-work-9213a4` (read only). `S:` = this directory. All runs are toys on the Windows PC in a scratch conda env (`S:env`, Python 3.12). Every toy stayed under 50 k tets except one gmsh run at 56,171 tets (`S:out/gmsh_big_runs.jsonl:4`), a small overshoot of the cap. Nothing ran in WSL. FEMTIC and Usui's C++ tools were not run. GitHub was unreachable from this machine, so FEMTIC sources were not read (section 4.3).

## 0. Short answer

- None of the candidates is pure Python. Each one is a compiled kernel behind a wheel or a conda package. So the real choice is which compiled core to use, and how much of Usui's C++ to re-implement in Python.
- Any pure-Python surface mesher yields a mesh that is not the gated v2/v3 mesh. Section 9 must then be re-run whatever the volume kernel. "Same kernel" buys fidelity in the volume stage only.
- **Recommended: design in Gmsh.** Keep a TetGen 1.6.0 bridge (gmsh surface PLC -> conda-forge `tetgen` -> numpy makeMtr rounds) as the fidelity fallback. Do not port makeTetraMesh's own 2-D mesher.

## 1. What the kernel must produce

- **Today's chain.** makeTetraMesh steps 1-4 write a PLC (`output.poly`). `tetgen -nVpYAakq3.0/0` meshes it. Five rounds of `makeMtr` + `tetgen -nmpYVrAakq3.0/0` refine it. TetGen2Femtic then reads `.node/.ele(attr)/.neigh/.face(marker)` (`R:docs/mesh_tetra_pipeline.md:77-137`).
- **Invariants a replacement must keep:**
  - the surface is frozen (`-Y`; `:24`);
  - the site is never a node (`:385`);
  - one region seed per closed region; unseeded regions get new attributes (`:272-279`);
  - the .mtr value is a circumradius bound, not an edge length (`:301`);
  - mesh.dat outer faces are classified by coordinate sign, so the domain must straddle 0 (`:26`, `:361-369`);
  - Earth-surface faces are the faces between ndiv >= 0 and ndiv < 0 regions (`:369`).
- **Real target (v2):**
  - 2,446,095 tets and 401,334 nodes;
  - 218,292 Earth-surface faces;
  - site triangles 4.1-4.2 m;
  - 65,341 earth cells (`R:mesh/vulcan_v2/mesh_logs/mesh_stats.txt:1-2,93,103`);
  - v3 has 3,068,130 tets (`R:docs/mesh_tetra_pipeline.md:31`).
- **v2 cost (WSL).**
  - Wall time: makeTetraMesh 9.4 s; six tetgen runs 319 s at 0.70-0.98 GB max RSS; makeMtr 7.9 s; TetGen2Femtic 11.8 s; total 359.8 s (`R:mesh/vulcan_v2/mesh_logs/timings.tsv:2-17`, `summary.txt`).
  - makeTetraMesh lets surface edges reach 1.5 times their target (ALPHA). That is why v3's 2.75 m target came out as 4.1 m at 18 sites (`R:docs/mesh_tetra_pipeline.md:181,573`).

## 2. Gmsh Python API (pip `gmsh` 4.15.2)

- **Install.** One wheel, `py3-none-win_amd64`, 42 MB download, installed without trouble. PyPI also has 2 macOS wheels and 1 Linux wheel; conda-forge has `gmsh`/`python-gmsh` 4.15.2 (`S:out/availability.log:5,21-23,34`). The build includes HXT, OpenMP, OpenCASCADE, Netgen, Mmg and TetGen/BR (`:47`).
- **Footprint.** About 141 MB installed: an 86 MB DLL, a 40 MB import library and 15 MB of docs (`:43`).

### Toy model (`S:toy_gmsh.py`)

- A +-500 m cube.
- A DEM surface built as a gmsh discrete entity from a 25 m point grid with 6 m bumps, using the `terrain.py` pattern: `addDiscreteEntity` + `createGeometry` (`S:env/share/doc/gmsh/examples/api/terrain.py:50,75`).
- Air and earth volumes built on that shared surface, with physical groups 10 (air), 20 (earth) and 100 (earth surface).
- 3 sites, sized by a `Distance(PointsList)` -> `Threshold` field (4 m within 6 m, rising to 150 m at 600 m), a `MathEval` ellipsoid stand-in, and a `Min` of the two.

### What it showed

| Capability | Result | Evidence |
|---|---|---|
| Embedded DEM surface | Remeshed surface nodes lie within 0.087 m of the analytic DEM (25 m grid) | `S:out/gmsh_runs.jsonl:1` |
| Air/earth/region tags | Tets per volume come back with attributes 10/20, plus a separate list of Earth-surface triangles | `:1` (air 11,384 / earth 11,391) |
| makeMtr-like grading | Site-triangle max edge 3.97-4.19 m for a 4 m target; 2.63-2.85 m for 2.6 m; 1.30-1.33 m for 1.3 m. No 1.5x overshoot | `S:out/gmsh_cb_runs.jsonl:1,5`; `S:out/gmsh_big_runs.jsonl:4` |
| Full domain extent | +-500 km box in km units, 4 m sites, far-field edges up to 200 km, volume error 0, 0 inverted tets | `S:out/gmsh_extent.jsonl:1-2` |
| Export for a converter | Exact volume sum; 878 outer faces found from the tets = 878 exported boundary triangles; 3 orphan nodes left by the unembedded site points (the converter must drop them) | `S:out/gmsh_runs.jsonl:1`; toy stdout |
| Toy timing | Delaunay: 22,775 tets in 0.17 s. HXT: 18,006 in 0.07 s. Frontal: 34,824 in 0.39 s | `S:out/gmsh_runs.jsonl:1,3,8` |
| Throughput at 36-56 k tets | Delaunay about 0.13 M tets/s; HXT about 0.32 M tets/s (single-thread figures; 8 threads gave no gain at this size) | `S:out/gmsh_big_runs.jsonl:1-6` |
| Determinism | 1 thread: identical md5 on repeat (Delaunay; HXT). 8 threads with parallel 2-D meshing: 3 runs gave 3 different meshes (1599/1599/1565 surface triangles, a site triangle up to 4.54 m). With the 2-D mesher held to 1 thread and HXT on 8 threads: 3 identical runs | `S:out/gmsh_runs.jsonl:1-7,9-13` |
| Tet quality | Smallest dihedral 12.4 deg (Delaunay) / 14.2 deg (HXT), none below 10 deg. TetGen with q1.4 had 64 tets below 10 deg, the worst at 2.4 deg | `S:out/quality.log:1-3` |
| Exact Usui size laws | Possible through a Python size callback, but gmsh calls it 0.8 (Delaunay) to 3.1 (HXT) times per tet. With 120 sites in pure Python (assuming about 30 us per call) that adds roughly 1-5 min at 3 M tets; the C++ fields are preferable | `S:out/gmsh_cb_runs.jsonl:2,4` |

- **Sea and coast.** Not tested. The documented route is an OCC B-spline terrain fragmented with a box (`S:env/share/doc/gmsh/examples/api/terrain_bspline.py:20-26`), plus a sea-level plane: more boolean work, and a robustness risk to test before any marine survey.
- **HXT history.** HXT has accepted size fields and embedded points since 4.6.0 (`S:env/share/doc/gmsh/CHANGELOG.txt:264-267`). The changelog also records an earlier 2-D non-determinism regression (`:373-378`). Both fit the advice to pin `Mesh.MaxNumThreads2D = 1`.
- **Licence.**
  - GPL v2 or later, with an exception only for Netgen, METIS, OpenCASCADE and ParaView (`S:env/share/doc/gmsh/LICENSE.txt:1-21`).
  - Internal research use carries no obligation.
  - If a student tool that imports gmsh is distributed, the distributed whole falls under GPL terms. The student code can stay MIT, which is GPL-compatible, but the source must ship. This is a reading of the licence, not legal advice.
  - TetGen is AGPL-3 (`S:out/availability.log:20,31`), which is stricter, so neither route escapes copyleft.

## 3. TetGen front-ends

### 3.1 The three packages

All three were run on the same gmsh-made triangle PLC (`S:out/toy.poly`: 1,207 nodes, 2,441 triangles, seeds 10/20; script `S:toy_tetgen.py`).

| Front-end | Bundled TetGen | Platforms | PLC + regions (-pA) | -a per region | -m .mtr | -r refine | -n neighbours | Toy result |
|---|---|---|---|---|---|---|---|---|
| conda-forge `tetgen` (exe) | 1.6.0, Aug 2020 banner (`S:out/availability.log:40`) | win-64, linux-64, osx-64, osx-arm64 (`:16-19`); 0.5 MB | yes | yes | yes | yes | .neigh file | Round 0: 11,537 tets. With 3 mtr rounds: 31,321; md5 identical on repeat (`S:out/tetgen_runs.jsonl:1-3`). `-Y` kept all 2,441 surface faces through 3 rounds (`S:out/tetgen_Y_check.log:1-4`) |
| pip `tetgen` 0.8.4 (pyvista) | 1.6, Aug 2020 (`S:out/availability.log:39`) | cp310-312 abi3; win/linux/mac (`:6-7`) | yes (`add_region`, `pytetgen.py:287`) | yes (max_vol) | crashed (below) | **no**: input is a surface only (`_tetgen.pyi:6`) | face2tet only (`pytetgen.py:981`) | Round-0 md5 **identical to the exe** (`S:out/tetgen_runs.jsonl:1` vs `:7-8`): same kernel |
| pip `meshpy` 2026.1.1 | **1.6.1**, Aug 2026 (`S:out/availability.log:38`) | cp310-315; win/linux/mac (`:8-9`) | yes (`load_poly`) | yes | yes, via `load_mtr` only | yes | yes | Round 0: 11,545 tets, **not** 11,537. With 3 rounds: 31,086; deterministic (`S:out/tetgen_runs.jsonl:4-6`) |

### 3.2 Notes on each front-end

- **conda-forge exe (the fidelity anchor).** It carries the same version banner as the chain's libigl TetGen 1.6 (`R:docs/mesh_tetra_pipeline.md:59`), and Usui's switch strings work unchanged. A byte-for-byte match with the WSL-built binary was not tested, because that needs a 2.4 M-tet run, outside this study's limit.
- **pyvista `tetgen`: the `-m` background-mesh path segfaulted.** Both call paths (arrays, and `.node/.ele/.mtr` files) ended in an access violation in all 4 switch variants tried (`S:out/pyvista_bgmesh_arrays.log`, `S:out/pyvista_bgmesh_file.log`, `S:out/p1.log`). With no `-r` either, it cannot run the makeMtr refinement loop. It is usable only for single-shot `-pYAq` with per-region volumes. Loading a `.poly` from file also needs pyvista + vtk (`pytetgen.py:214-217`).
- **meshpy: the pybind view of the metric array is unusable.** `point_metric_tensors` reports unit 0 and raises on write, so the .mtr has to be passed through a file with `load_mtr` (toy stdout; `S:toy_tetgen.py`). meshpy also ships Triangle, which `S:toy_tri2d.py` uses as the makeTetraMesh step-2 stand-in: 3,255 triangles, 39,008 Python callback calls, 0.67 s (`S:out/tri2d_toy.log`). At v2's 218 k surface triangles that rate is about 40 s.
- **Speed at scale.** It is identical to today's chain, because the kernel is the same: about 320 s of serial tetgen for v2 (`R:mesh/vulcan_v2/mesh_logs/timings.tsv:6-16`). The 5 refinement rounds dominate.
- **Licences.** TetGen is AGPL-3 under a dual licence (`S:out/availability.log:20,31`). Triangle carries a no-compensation clause (`:32`).

## 4. pyGIMLi and SimPEG discretize

### 4.1 pyGIMLi 1.6.1 (pgcore 1.6.0)

- **It works on the toy.** `createCube` x2 + `mergePLC3D` + `createMesh` gave 4,318 tets with markers {10, 20} and an exact volume sum (`S:out/pygimli_toy.log`).
- **It is a PLC builder, not a size-field mesher.** 3-D meshing writes a .poly and calls an external tetgen: the exe on PATH, or the pyvista wrapper (`S:env/Lib/site-packages/pygimli/meshtools/mesh.py:166-262`; `polytools.py:1846-1898`). Its switches are only `pzAC`, `a`, `q` and an optional `Y`. There is no `-m` or `-r`, so local refinement means adding PLC nodes, which makes sites into nodes (against `R:docs/mesh_tetra_pipeline.md:385`).
- **Windows bug.** `pgcore/__init__.py:21` prepends to PATH with `':'`, so after `import pygimli`, `shutil.which('tetgen')` returns None (`S:out/pygimli_path_bug.log`). Workaround: pass `tetgen=<full path>`.
- **Packaging.** Not on conda-forge (`S:out/availability.log:26`). 48 MB installed (`:44`).
- **Useful for post-processing:** neighbours, `findCell`, cell sizes (`S:out/pygimli_toy.log`).

### 4.2 discretize 0.12.0 (MIT, 4.2 MB)

- **SimplexMesh is a post-processor, not a generator.** On the 31 k-tet TetGen toy it builds in 0.037 s and returns: `neighbors` (n, 4), with 878 boundary entries matching TetGen's `.neigh`; faces, edges and exact volumes; `point2index`; an interpolation matrix; `edge_curl` (`S:out/discretize_toy.log:1-4`; `unstructured_mesh.py:17,125,695,715`). That makes it a ready-made neighbour/QC layer for the converter.
- **TreeMesh does generate.** It builds 2:1-balanced octrees: the toy had 4,992 cells, 4 m at the sites, and 2,780 hanging nodes (`S:out/discretize_toy.log:5`).

### 4.3 TreeMesh -> FEMTIC MESH_TYPE 2: not realistic now

- **What is known.**
  - FEMTIC v5.0 contains `MeshDataNonConformingHexaElement.cpp` and `Forward3DNonConformingHexaElement0thOrder*.cpp` (`D:/BEN/FEMTIC_2026/hpc/phoenix_plan/build_foss_20260925_181212.log:64,144`).
  - Usui already ships makeDHexaMesh, with ellipsoids, cuboids, topography and sites in its sources (`D:/BEN/FEMTIC_2026/validation/wsl_2026-09-25/build_logs/makeDHexaMesh.log:1-10`; `D:/BEN/FEMTIC_2026/hpc/ported/README.md:27`).
- **What is unknown.** The mesh.dat layout for this element type was not read: GitHub was unreachable, and the source clones are inside WSL, which was off-limits. So these are open:
  - which refinement ratios and directions are allowed;
  - how the topography deformation is encoded;
  - the hanging-face neighbour format.
- **Verdict.** It would need its own section 9 gate, and Usui already provides makeDHexaMesh for this route. Spend no effort on it until `MeshDataNonConformingHexaElement.cpp` has been read.

## 5. Kernel assessment

| Kernel | Fidelity to gated v2/v3 | Robustness at about 3 M tets | Speed, v2-sized mesh | Health | Install | Python layer still to write |
|---|---|---|---|---|---|---|
| conda-forge `tetgen` 1.6.0 exe | Highest: same kernel; volume deterministic for the same PLC + .mtr. Surface differs unless makeTetraMesh's output is reused | Proven at 2.45-3.07 M (v2, v3) with 0.7-1.0 GB RSS (`timings.tsv:6-16`). Slivers (q3.0/0), yet v3 passed the gate | Measured about 320 s serial (5 rounds) | TetGen frozen at 1.6.0 since 2020; conda-forge rebuilt to `_2` (`S:out/availability.log:16-19`) | conda only, 0.5 MB | PLC designer (surface 2-D mesh, walls, DEM, seeds), makeMtr in numpy (small), the refinement driver, converter |
| pip `tetgen` (pyvista) | Same kernel (md5-identical round 0) | Unknown at scale; `-m` crashed on the toy | Single-shot only | Active (35 releases; 2026-05) (`:6`) | 0.7 MB + numpy | As above, but it cannot run the makeMtr loop: **disqualified for this chain** |
| `meshpy` | Close, not identical (TetGen 1.6.1) | Same algorithm family; untested at scale | About the exe's time, without file I/O | Active (2026-09 release, cp310-315) (`:8-9`) | 2 MB | As for the exe, all in-process |
| Gmsh (Delaunay / HXT) | Low: different surface and volume algorithms, so the gate must be re-run | Not measured at 3 M (toy cap). Gmsh scale and RAM must be tested on Phoenix | Extrapolated linearly from 36-56 k tets: about 20 s Delaunay, about 8 s HXT (weak evidence) | Very active (25 PyPI releases; 4.15.2 in 2026-03) (`:5`) | about 141 MB | Geometry + size fields (about 200-300 lines), export, converter. No makeMtr, no PLC writer, no refinement loop |
| pyGIMLi | Low: no metric | Relies on an external tetgen | n/a | Active (2026-09) (`:10-11`) | 48 MB | Not a kernel. QC helper only |
| discretize | n/a (not a tet generator) | n/a | n/a | Active (78 releases) (`:13`) | 4.2 MB | Use SimplexMesh inside the converter/QC; TreeMesh is out (4.3) |

**What the converter must do, for every kernel** (the TetGen2Femtic work: `R:docs/mesh_tetra_pipeline.md:361-369`, sections 3.11 and 5):

- tet neighbours, by numpy face hashing (0.03 s on the toy) or SimplexMesh;
- the six outer face lists by coordinate sign;
- the Earth-surface face list (air|earth faces);
- conversion to metres, z down, with the node order fixed so volumes stay positive;
- parameter cells by recursive median bisection under the ellipsoid and site B-laws;
- `resistivity_block_iter0.dat`;
- checks: domain straddles 0; every site falls in a distinct surface triangle; attribute set equals the seed set.

Gmsh adds two small duties: drop the orphan site nodes, and map physical groups to attributes. The TetGen routes add the PLC writer, makeMtr and the round driver.

## 6. Recommendation (efficient > robust > speedy)

| Option | Efficient (code to own, elements per accuracy) | Robust | Speedy | Verdict |
|---|---|---|---|---|
| A. Port Usui's PLC designer (makeTetraMesh steps 1-4) to Python + TetGen 1.6 (conda-forge exe; meshpy fallback) | Worst. Re-implements the 2-D mesher (ALPHA, BETA, Laplacian, ITER_MAX), coast roughening, IDW and SURF_MESH walls. Keeps the 1.5x surface overshoot (`R:docs/mesh_tetra_pipeline.md:181`). The surface still differs, so the gate must be re-run anyway | Kernel proven at scale; the port itself is new code | about 6 min (today's chain) | No |
| B. Design in Gmsh (geometry, DEM, regions, fields, 2-D + 3-D, export) | Best. One pip dependency on all three OSes. Site triangles at most 1.1x the target in every toy (4 m target -> 3.97-4.19 m; 2.6 m -> 2.63-2.85 m) (`S:out/gmsh_cb_runs.jsonl:1,5`). HXT used 21 % fewer tets than gmsh Delaunay for the same field (`S:out/gmsh_runs.jsonl:1,3`) | Sliver-free on the toys; deterministic with 2-D threads = 1; sea/coast untested; 3 M scale untested | Toy-extrapolated: seconds to tens of seconds | **Yes: primary** |
| C. Keep TetGen via conda-forge, with the PLC from gmsh 2-D (hybrid, proven on the toy: `S:toy_gmsh.py ... plc` -> `S:toy_tetgen.py exe`) | Middle. Gmsh does the surface; numpy makeMtr (about 100 lines) + a subprocess loop keep Usui's `-Y`/`.mtr` semantics and tables | Volume kernel proven at 2.45-3.07 M | about 5-6 min | **Fallback** if B fails the gate or misbehaves in FEMTIC |

**Verdict.** Design in Gmsh.

- **Fidelity buys little.** "Pure Python" is not available from any kernel, and fidelity to the gated meshes is lost as soon as makeTetraMesh's surface triangulation is replaced. So the value of "same kernel" is limited to the volume stage, and the section 9 half-space gate has to be re-run whichever route is taken.
- **Gmsh scores best on the stated priorities:**
  - it removes the PLC writer, makeMtr and the five-round refinement loop;
  - it holds the site triangle to at most 1.1x its target, instead of up to 1.5x (the defect that cost v3 its 2.75 m target);
  - it produced no slivers on the toys;
  - it was deterministic once 2-D meshing is single-threaded.
- **Gmsh's open risks are concrete:**
  - scale and RAM at 2.5-3 M tets;
  - sea/coast booleans;
  - GPL obligations on distribution.
- **Keep option C ready.** It is cheap (gmsh surface + conda-forge tetgen 1.6.0 + about 100 lines of numpy makeMtr) and keeps Usui's volume semantics if Gmsh fails.
- **Rejected.** Do not port makeTetraMesh's own 2-D mesher, do not use the pyvista wrapper for this chain, and do not pursue TreeMesh -> DHexa until FEMTIC's non-conforming hexa format has been read.

## 7. Tests to run before adopting B (on Phoenix, not the PC)

Each test states its failure criterion before it runs.

1. **Scale.** Build a v2-equivalent Gmsh mesh: the same 120 sites, a 4 m site target, the same domain and ellipsoid grading.
   - *Fails if:* it takes more than 10 min or more than 8 GB RSS; or two runs give different md5s; or any site is not in its own surface triangle; or any site triangle exceeds 4.2 m (v2's own figure, `R:mesh/vulcan_v2/mesh_logs/mesh_stats.txt:93`).
2. **Accuracy gate.** Run section 9 on that mesh.
   - *Fails if:* any site's rho_a is off by more than 5 % or its phase by more than 1.5 deg, at observe.dat's frequencies, the criterion v1-v3 were judged by (`R:docs/mesh_tetra_pipeline.md:819-835`).
   - *Also report:* tets and PARDISO memory against v2's 2.45 M tets and 22,903 MiB (`:795`).
3. **Fidelity anchor for C.** On the same PLC and .mtr, conda-forge tetgen must reproduce its own md5 across two runs. Separately, run makeTetraMesh's `output.poly` for v2 through conda-forge tetgen + the numpy makeMtr.
   - *Fails if:* the final tet count differs from 2,446,095. That would show the Python makeMtr or the binary differs from the WSL chain (`R:mesh/vulcan_v2/mesh_logs/products.md5`).
