# Mesh port progress: P1, the first slice of `femtic_mesh` (2026-10-06)

Plan: docs/dev/mesh_port_feasibility_2026-10-06.md (the study; "study" below), phase P1 (section 8). This page
records what exists, what the tests showed, and what P2 needs. Ben's checkout `D:/BEN/FEMTIC_2026/mesh` (M/ below)
holds the gitignored products the tests read; `FEMTIC_MESH_DATA` points the tests elsewhere.

## 1. Summary

- **TetGen2Femtic port: byte-identical to the C++ wherever a C++ output exists.** Fed tetgen-format files rebuilt
  from the C++ mesh.dat, the port writes mesh.dat, resistivity_block_iter0.dat and output.6.femtic.vtk
  byte-identical to TetGen2Femtic's, on chain_proof (27,501 tets) and on vulcan_v2 (2,446,095 tets, 9 ellipsoids,
  120 two-circle sites, a 329 MB VTK). On v2 it took 15.2-15.9 s and 577-582 MB peak RSS, against the C++'s
  11.79 s and 255 MB (M/vulcan_v2/mesh_logs/t2f.time).
- **No C++ golden exists yet for real tetgen files.** The conda-forge tetgen run allowed here makes a different
  round-0 mesh from the WSL build: 1,616 points and 7,938 tets, against 1,605 and 7,879. Rounds 1-5 cannot be
  rebuilt without makeMtr. The true golden is G0: runs/Run04 (chain_proof) and runs/Run05 (v2) keep
  `intermediates/output.6.*`. `test_port_on_g0_run` is ready for them.
- **mesh.dat I/O is byte-exact at Vulcan size.** The v2 mesh.dat (255,727,272 bytes) round-trips byte for byte:
  read 2.0 s, write 2.8-2.9 s, about 650 MB peak RSS. The limit was 20 min.
- **The D3 instrument works; B3 is complete.** `python -m femtic_mesh.repartition` rebuilds the block files of
  chain_proof, v1, v2 and v3 byte for byte from mesh.dat alone (v1 and v3 from the verifier's re-run). Air and earth
  come from a flood fill, not from the block file. The v2 partition takes about 5 s.
  - Rule table on v2 (section 5.2): the current rule gives 65,341 earth cells. Scaling every B by 1.94 gives
    20,849, the about-21k target; it halves the near-site cells and doubles their size cap, but their median size
    grows only about 30 %.
  - Rules that keep the 150 m cells near the sites level off at 24-42k.
- **Tests: 18 pass, 1 skips (the G0 hook), 0 fail.** `python tests/mesh/run_all.py` takes 79 s.

## 2. What exists

| Path | What it does |
|---|---|
| src/femtic_mesh/io/femtic.py | `read_mesh_dat` / `write_mesh_dat`, `read_resistivity_blocks` / `write_resistivity_blocks`, `write_t2f_vtk`, `read_resistivity_attr` (TetGen2Femtic's parse order and exit checks as ValueError), `blocks_from_partition` |
| src/femtic_mesh/io/tetgen.py | `read_/write_` `node`, `ele`, `face`, `neigh` (tetgen 1.6 formats; the trailer and CRLF are kept), `poly` (makeTetraMesh layout), `mtr` (makeMtr and tetgen layouts; a wrong count raises) |
| src/femtic_mesh/io/_fmt.py | exact fixed-width writers (numpy digit arithmetic for `%10d`, Python `%` for floats), chunked `np.loadtxt` reader |
| src/femtic_mesh/cells.py | `CellRule` (USUI = TetGen2Femtic), `BlockLengthField` (calcBlockLength), `centroids`, `partition`, `cell_report` |
| src/femtic_mesh/tetgen2femtic.py | the faithful port; `python -m femtic_mesh.tetgen2femtic PREFIX OUT_DIR [-rotate] [-div_all] [-thread N] [--attr F] [--no-vtk]` |
| src/femtic_mesh/repartition.py | `air_from_surface`, `repartition`, `explain_difference` (near-tie tracer), `rule_table`; `python -m femtic_mesh.repartition MESH.dat --attr F [--out X] [--compare B] [--table] [rule options]` |
| src/femtic_mesh/LICENSE_TetGen2Femtic.txt | MIT notice: the port and USUI are translations of Usui's code (LICENSE at ceb8bfb) |
| tests/mesh/*.py, run_all.py | plain-script tests (section 6); `FEMTIC_SKIP_V2=1` gives the 3 s subset |
| tests/mesh/data/chain_proof_round0/ | the conda-forge tetgen round-0 output (gzip), its log and provenance README |
| environment-mesh.yml | conda env: python, numpy>=1.23, psutil (optional) |

Data model, as the study proposes (section 4):
- node coordinates are (N, 3) float64;
- mesh.dat arrays are 0-based int32;
- tetgen readers keep the file's 1-based ids;
- faces keep the `.face` order.

## 3. I/O results (task items 1-2)

- **chain_proof:** mesh.dat (2,893,745 B) and the block file (888,744 B) round-trip byte for byte, and the VTK
  writer rebuilds TetGen2Femtic's output.6.femtic.vtk (3,653,860 B) byte for byte.
  - The VTK is an output the readers never saw, so this checks the writer's formats independently.
- **v2:** mesh.dat (255,727,272 B) round-trips: read 2.0 s, write 2.8-2.9 s, 649-653 MB peak RSS in the process.
  The block file (56,660,718 B) also round-trips. Every count equals M/vulcan_v2/mesh_logs/mesh_stats.txt, which
  scripts/mesh_stats.py wrote in WSL:
  - 401,334 nodes and 2,446,095 elements, of which 1,149,539 air and 1,296,556 earth;
  - 65,342 cells and 218,292 Earth-surface faces;
  - outer face lists 412, 412, 412, 412, 454, 454.
- **The reader fails loudly** on a truncated file, trailing data or a wrong index column. A CRLF copy parses to the
  same arrays, sign of zero included.
- **tetgen files:** output.1.{node,ele,face,neigh} from the conda-forge exe are rewritten byte for byte, CRLF and
  the `# Generated by` line included. Their counts equal tetgen's log, and the 644 `-1` neighbours equal the log's
  exterior faces. makeTetraMesh's unseeded output.poly is rewritten byte for byte.
- **Two layout notes:**
  - The seeded chain_proof output.poly has hand-spaced region lines (`1   0.0 0.0 -40.0  10 1e9`), so only its
    parse is checked.
  - No .mtr was kept by any run, so the .mtr test uses synthetic values.
- **.mtr count check:** `read_mtr` rejects a file whose row count differs from its header. tetgen silently ignores
  such a file and refines without sizing (study N3).

## 4. The TetGen2Femtic port (task item 3)

**What is ported, from the source at ceb8bfb:**
- the readers (`-rotate` included) and readResisitivity (isotropic);
- calcBoundaryFaces: the first (lowest-id) element holding each `.face` triangle, the air-side swap and the
  coordinate classification with EPS 1e-9 m;
- writeMeshData;
- makeResistivityBlock, including `-div_all`, the ndiv forced rounds, divideBlockUntilRequiredLength and
  calcBlockLength (`pow(x,2)` as `x*x`, C++ order of operations, PI = 3.14159265359);
- writeResisitivityData and writeMeshDataToVTK (isotropic).

`-thread` is accepted and ignored, as in the C++. `-sediment`, `-aniso`, the bound_attr.dat route (`#if 0`) and
`_ADDITIONAL_FIXED_AREA` raise NotImplementedError. Every C++ `exit(1)` becomes a ValueError or RuntimeError with
the C++ message, and the CLI then exits 1.

**The one permitted tetgen run, and what it shows.**
- **The run:** `tetgen.exe -nVpYAakq3.0/0 output.poly`, on M/chain_proof/output.poly (md5 ce9b5333...).
  - The switches are those of M/chain_proof/logs/tetgen_stp5.log and run_mesh_chain.sh:158.
  - The exe is conda-forge tetgen-1.6.0-hac47afa_2 (win-64).
  - It ran once, in 0.08 s.
- **Finding:** the conda-forge exe is not the chain's tetgen, already at round 0.
  - It makes 1,616 points and 7,938 tets; the WSL libigl e05aca7 build made 1,605 and 7,879.
  - The two logs agree through Delaunay and boundary recovery (2,714 subfaces, 4,057 segments). They first differ
    at "Added 270 / 259 Steiner points" in refinement.
  - So B5/TD4, the byte test of a student tetgen against the chain's build, would fail for this build. Students
    need Phoenix's or our own CI build if byte identity with Usui's chain matters. Under bar (a) of the study's
    section 1, which needs only the half-space gate, it may not matter.
  - The source of the difference was not investigated further: compile flags and predicates, or the WIAS
    tarball against libigl's source. A second run was not allowed.
- **Rounds 1-5 could not be rebuilt.** Each needs makeMtr's output.i.mtr. makeMtr may not run on the PC, and no
  .mtr from the WSL run was kept. The final round needs the four before it. So the port could not be compared with
  the C++ on any real tetgen file. Fixture and provenance: tests/mesh/data/chain_proof_round0/README.md.

**The tests that could be run:**

| Test | Input | Result |
|---|---|---|
| test_port_reproduces_chain_proof | output.6.* rebuilt from the C++ chain_proof mesh.dat: nodes as m/1000 at `%.17g`; neighbours; attributes 10/20 from the flood fill; the 7 face lists' triangles interleaved at random, corners rotated or reflected at random | mesh.dat, block file and VTK **byte-identical** to the C++. 1,030 of 2,070 Earth-surface faces took the air-element branch (MeshData.cpp:1137-1154) |
| test_port_reproduces_v2 | the same, from the C++ v2 mesh.dat | all three **byte-identical**, the 329 MB VTK included. 108,662 of 218,292 surface faces took the air branch. Port 15.2-15.9 s and 577-582 MB, against C++ 11.79 s and 255 MB (study N5 limits: 2x the C++ time, 1 GB) |
| test_port_on_real_tetgen_round0 | the conda-forge round-0 files | independent checks pass (see below) |

The round-0 checks:
- the volumes sum to the 600 km box (rel. 1e-6);
- the six outer lists hold exactly the 644 `.neigh` hull faces, each on its plane;
- the Earth-surface list holds exactly the earth side of the 2,070 air/earth adjacencies;
- cell 0 is exactly the air;
- the port's 1,423 cells equal cells.partition on the `.node` coordinates.

**What these tests cover, and what they do not.**
- **Covered:** everything mesh.dat carries.
  - node scaling and formats;
  - element/face lookup and local-face numbering;
  - hull classification and the air/earth swap;
  - neighbour translation and the partition (both rule sets);
  - the VTK.
- **Not covered:** the rebuilt `.face` lists only mesh.dat's faces, while tetgen's real `.face` also orders the
  faces in its own way. The list order follows `.face` order by construction (shuffling the interleave and the
  corners changed nothing), so a real-file mismatch would point at tetgen's files, not the port.
- **Classification of a G0 mismatch (B2):** cmp reports the first differing byte. A node-order difference shows
  first in the node block; a port bug in the face lists.

**The true golden is G0 on Phoenix:** runs/Run04 (chain_proof) and runs/Run05 (v2), made by the run-folder
workflow, keep `intermediates/output.6.{node,ele,face,neigh}` next to the C++ products. Fetch one back and run:
```
FEMTIC_G0_RUN=<fetched run folder> python tests/mesh/test_tetgen2femtic.py test_port_on_g0_run
```
It fails if mesh.dat, the block file or the VTK differs from Phoenix's TetGen2Femtic by one byte.
- The hook was exercised on a simulated run folder (the chain_proof rebuild) and passed.
- Its negative control first compared mesh.dat and did not fail: an attribute flip away from the PLC facets
  cannot reach mesh.dat. It now compares the block file.
- The working tree's hpc/phoenix_plan/RUNBOOK.md F3 (lines 112-116, uncommitted, from the run-folder workflow)
  submits Run04, then Run05, and names `intermediates/output.6.{node,ele,face,neigh}` as what to fetch.
  Committed HEAD 31b1b3b still uses the name Run05 for a v3 gate (RUNBOOK.md:97); the merge must keep one meaning.

## 5. The re-partitioner: the D3 instrument (task item 4)

### 5.1 It reproduces TetGen2Femtic

`repartition` reads only mesh.dat and resistivity_attr.dat.
- **Regions:** the air is every element reachable from the -Z list without crossing an Earth-surface face (a
  flood fill). It equals cell 0 on chain_proof (13,477 elements) and on v2 (1,149,539). A mesh with one surface
  face dropped from its list raises an error.
- **Scope:** two-row resistivity_attr.dat files only (air plus one earth row). Anything else raises
  NotImplementedError.
- **Result:** with rule `usui` it rewrites both block files byte for byte. chain_proof has 3,842 cells and v2 has
  65,342; v2 takes 4.9-5.6 s for the partition.
- **B3 complete (verifier, 2026-10-06).** `python -m femtic_mesh.repartition --out --compare` also rewrites v1's
  block file (55,993 cells, md5 9b3d07ce) and v3's (68,655 cells, md5 9bc8f7d4) byte for byte, 0 elements
  different, in 7 s and 10 s. What remains is the same check on Phoenix's mesh (section 10, step 1).
- **Mutants (study N1), each moves elements:**
  - floor split: 9,361 elements on chain_proof, 853,092 on v2;
  - no element tie-break: 3,554 (the study's mutant moved 3,748; its tie-break was removed differently);
  - B at the group centroid: 10,072.
  - The 9,361, the 10,072 and the alternative counts 3,374 / 3,574 below match the study's prototype.
- **Near-tie finding:** mesh.dat has only 10 significant digits, so in general it cannot reproduce TetGen2Femtic.
  - On the conda-forge round 0, the port (`.node` coordinates) and the re-partition of its own mesh.dat differ
    on 2 of 7,938 elements, 6062 and 7196.
  - Their z centroids differ by 3e-11 m in `.node` precision and become equal after mesh.dat's rounding. The
    count-median cut then falls between them the other way round.
  - `explain_difference` traces every such difference to the decision that diverged, and the test requires
    each to be a near-tie.
  - The test first required identity; that version failed on these 2 elements, and its docstring records the
    narrowing. Chain_proof and v2 showed no such tie.

### 5.2 Alternative rules on v2: counts and cell size against depth

Command:
```
python -m femtic_mesh.repartition M/vulcan_v2/inversion/mesh.dat --attr mesh/vulcan_v2/files/resistivity_attr.dat --table
```
11 rules took 55 s; no remesh. Depth is the cell's volume-weighted centre; size is cbrt(volume), as in
mesh_stats.py. The `usui` row equals mesh_stats.txt in every count and every band median (a test checks this).

| rule | earth cells | 1 element | <= 5 elements | 0-0.2 km | 0.2-1 km | 1-5 km | 5-20 km | 20-100 km | >100 km |
|---|---|---|---|---|---|---|---|---|---|
| usui | 65,341 | 1,040 | 18,393 | 32,825 | 22,005 | 6,594 | 1,818 | 1,289 | 810 |
| split=midpoint | 44,788 | 47 | 6,191 | 16,791 | 19,330 | 5,932 | 1,429 | 821 | 485 |
| B@centroid | 58,845 | 843 | 12,687 | 30,903 | 18,982 | 5,670 | 1,520 | 1,088 | 682 |
| min_split=10 | 62,364 | 0 | 14,540 | 31,065 | 21,467 | 6,472 | 1,690 | 1,033 | 637 |
| no_sites | 43,687 | 672 | 7,157 | 18,509 | 14,676 | 6,585 | 1,818 | 1,289 | 810 |
| Bx1.5 | 32,082 | 522 | 3,357 | 18,191 | 9,154 | 2,795 | 836 | 671 | 435 |
| Bx1.94 | 20,849 | 319 | 2,104 | 13,130 | 4,746 | 1,530 | 591 | 528 | 324 |
| ellBx2 | 46,241 | 786 | 13,301 | 29,026 | 14,352 | 1,464 | 570 | 513 | 316 |
| ellBx4 | 41,923 | 698 | 12,304 | 28,126 | 12,284 | 647 | 378 | 335 | 153 |
| split=midpoint,ellBx4 | 24,169 | 31 | 3,877 | 12,416 | 11,092 | 481 | 97 | 53 | 30 |
| split=midpoint,Bx1.5 | 17,966 | 0 | 230 | 4,573 | 9,582 | 2,800 | 536 | 318 | 157 |

| rule | median elements per cell | size 0-0.2 km | size 0.2-1 km | size 1-5 km | size 5-20 km | size 20-100 km | size >100 km |
|---|---|---|---|---|---|---|---|
| usui | 10 | 0.090 | 0.203 | 0.631 | 2.923 | 13.076 | 47.926 |
| split=midpoint | 11 | 0.125 | 0.229 | 0.521 | 2.797 | 16.397 | 62.693 |
| B@centroid | 10 | 0.090 | 0.208 | 0.668 | 3.106 | 14.211 | 48.964 |
| min_split=10 | 10 | 0.093 | 0.206 | 0.622 | 2.839 | 16.789 | 59.376 |
| no_sites | 10 | 0.132 | 0.255 | 0.632 | 2.923 | 13.076 | 47.926 |
| Bx1.5 | 20 | 0.096 | 0.277 | 0.861 | 3.740 | 14.151 | 48.517 |
| Bx1.94 | 39 | 0.096 | 0.356 | 1.292 | 4.242 | 13.843 | 46.967 |
| ellBx2 | 10 | 0.082 | 0.172 | 1.307 | 4.307 | 13.874 | 47.514 |
| ellBx4 | 10 | 0.081 | 0.164 | 2.339 | 4.307 | 13.677 | 45.502 |
| split=midpoint,ellBx4 | 11 | 0.119 | 0.174 | 0.951 | 3.836 | 37.867 | 247.701 |
| split=midpoint,Bx1.5 | 27 | 0.182 | 0.278 | 0.898 | 3.752 | 30.287 | 120.024 |

Rules:
- **split=midpoint** cuts at the middle of the centroid spread, not at the count median.
- **B@centroid** evaluates B at the group's mean centroid, not at its two extreme elements.
- **min_split=k** never splits a group of fewer than k elements.
- **no_sites** drops the site circles.
- **Bx s** multiplies every B, site circles included.
- **ellBx s** multiplies only the ellipsoid rows' B.

**What the table shows (facts).** Only rules that also coarsen near the sites reach about 21k.
- The 0-0.2 km band keeps 28-33k cells under every rule that keeps both the site circles and the count-median
  split (usui, B@centroid, min_split, ellBx2, ellBx4).
  - Coarsening the ellipsoids alone levels off near 42k (ellBx4), and the near-surface median size even falls
    (0.090 to 0.081 km).
- Dropping the site circles removes 21,654 cells, but 43,687 remain: 3.4 times the design's 13,000 background
  (docs/mesh_tetra_pipeline.md:783).
  - So the site circles are not the main excess; that is the D3 estimate's error, now measured.
- The count-median split alone accounts for 20,553 cells (usui 65,341 against midpoint 44,788).
- Bx1.94 reaches the target, but it coarsens the near-site cells, against the site-circle design
  (docs/mesh_tetra_pipeline.md:576-579). Cells whose centre lies within 0.25 km of a site, on v2 (verifier):

  | rule | cells | centroid spread median / p90 / max (km) | median cbrt(volume) (km) |
  |---|---|---|---|
  | usui | 11,476 | 0.097 / 0.138 / 0.159 | 0.058 |
  | Bx1.94 | 5,648 | 0.128 / 0.253 / 0.322 | 0.060 |

  - The B cap (0.15 to 0.29 km) and the upper tail double: p90 0.138 to 0.253 km, max 0.159 to 0.322 km.
  - The typical near-site cell grows much less: median spread about 30 % (0.097 to 0.128 km), median
    cbrt(volume) 0.058 to 0.060 km, while the number of near-site cells halves (11,476 to 5,648).
- **Caveat on extreme-B rules:** if B at a group's two extreme elements exceeds its spread, the group stops even
  when it holds the fine core. ellBx6 with the midpoint split stopped at **1** earth cell, since the outer B,
  1,800 km, exceeds the domain.
  - The same holds under usui for any resistivity_attr.dat whose last-row B exceeds the domain.
  - Midpoint plus ellBx4 already gives 248 km median cells below 100 km.

**Inference, not tested:** the count-median split in a graded mesh leaves many small remainder cells near the
fine zones. Of the knobs tried, the midpoint split is the one that cuts cells without coarsening B or the near-site
design (44,788; 47 single-element cells).
- **Every rule changes the inversion parameterisation.** Pick one only behind an inversion smoke test (study
  section 4) and the section 9 half-space test. This table is for Ben's D3 decision; it is not a recommendation.

## 6. Tests (task item 5; Invariant 10)

Plain scripts: `python tests/mesh/run_all.py`, or one module, or one test by name. Each docstring states
"This test fails if ...". Each test first runs its check on a broken case and requires it to fail, and only then
checks the real thing. A SKIP (missing data) is never counted as a pass.

| Test | Fails if | Negative control shown |
|---|---|---|
| io_femtic: mesh_dat_roundtrip_chain_proof | write(read(mesh.dat)) differs by a byte | `%20.8e` mutant writer; 2 surface entries swapped |
| io_femtic: block_roundtrip_chain_proof | the same for the block file | `%9d` fix-field mutant; 1 element moved |
| io_femtic: vtk_chain_proof | VTK differs from TetGen2Femtic's output.6.femtic.vtk | element 7 moved air/earth |
| io_femtic: crlf_and_layout_checks | CRLF parses differently; a malformed file is accepted | 1 neighbour digit changed |
| io_femtic: v2_roundtrip_and_counts | v2 round trip differs, > 20 min, or counts differ from mesh_stats.txt | compared with v3's counts; 1 node index changed |
| io_tetgen: tetgen_roundtrip_round0 | a tetgen file is not rewritten byte for byte | 1-ulp coordinate change; 1 marker changed |
| io_tetgen: tetgen_counts_match_log | counts differ from tetgen's log; .neigh asymmetric | compared with the WSL log |
| io_tetgen: poly_roundtrip | unseeded output.poly not byte-identical; seeded parse wrong | 1 polygon corner changed |
| io_tetgen: mtr_roundtrip_and_count_check | .mtr round trip differs; wrong-count file accepted | header 1000, 999 rows |
| t2f: port_reproduces_chain_proof | port products differ from the C++ by a byte | mutant face numbering; 1 element relabelled air |
| t2f: port_reproduces_v2 | the same on v2, or > 2x C++ time, or > 1 GB | 1 element relabelled air |
| t2f: port_on_real_tetgen_round0 | a geometric check fails, or an unexplained re-partition difference | mutant face numbering; midpoint run as "near-ties" |
| t2f: cli_exit_codes | exit 0 on broken input, or non-zero on the fixture | (broken inputs are the cases) |
| t2f: port_on_g0_run | port differs from Phoenix's C++ on real files (SKIP until G0 is fetched) | 1 attribute flipped (block file) |
| repartition: usui_reproduces_chain_proof | the CLI's block file is not byte-identical | floor split, no tie-break, centroid B |
| repartition: usui_reproduces_v2 | the same on v2 | floor split on v2 |
| repartition: cell_report_matches_mesh_stats | report differs from mesh_stats.txt's cell figures | cells 1 and 2 merged |
| repartition: flood_fill_regions | flood-fill air differs from cell 0; a leaking mesh is accepted | 1 surface face dropped |
| repartition: alternative_rules_differ | an alternative equals usui; Bx1.5 is not coarser | usui against itself |

Last full run: 18 passed, 1 skipped (port_on_g0_run), 0 failed, in 79 s. The suite process peaked at 1.75 GB; the
port's own subprocess at 577 MB. With `FEMTIC_SKIP_V2=1`, 13 tests pass in 3 s.

## 7. `[project]` entry for pyproject.toml (for Fable to merge; this workflow does not edit it)

```toml
[project]
# merge: femtic_mesh needs only numpy at run time
dependencies = ["numpy>=1.23"]

[project.optional-dependencies]
mesh-tests = ["psutil"]          # peak-RSS figures in tests/mesh; nothing else

[project.scripts]
femtic-tetgen2femtic = "femtic_mesh.tetgen2femtic:main"
femtic-repartition = "femtic_mesh.repartition:main"

[tool.setuptools.packages.find]  # adapt to the GUI workflow's backend; the package lives in src/
where = ["src"]
include = ["femtic_mesh*"]

[tool.setuptools.package-data]
femtic_mesh = ["LICENSE_TetGen2Femtic.txt"]
```

## 8. Deviations from the C++, and limits

- **Output folder.** The C++ writes mesh.dat and the block file in the current directory and the VTK at
  `<prefix>.femtic.vtk`. The port writes all three into OUT_DIR, the VTK as `<basename prefix>.femtic.vtk`.
  resistivity_attr.dat is read from the current directory unless `--attr` is given, as in the C++.
- **Stricter input checks.**
  - The port refuses inputs the C++ would misread silently: a `.face` file with `-nn` adjacency columns, more
    than one node attribute, non-integer region attributes, a wrong-count `.mtr`.
  - It also refuses inputs the C++ crashes on: a site with no circles, a node id out of range.
- **libm.** np.arctan2, np.tan and np.hypot come from this platform's C library, not glibc. v2's 9 ellipsoids,
  whose transition zones use them, still reproduced exactly. A near-tie elsewhere could differ: study risk 2.
- **Not ported.** -sediment, -aniso, the bound_attr.dat route and _ADDITIONAL_FIXED_AREA.
- **Mesh size limit.** More than 2,097,151 nodes raises NotImplementedError (21-bit face keys). v3 has 502,982.
- **Re-partition scope.** It needs a two-region (land-only) mesh, and mesh.dat's 10 digits can flip near-ties
  (section 5.1).

## 9. For Fable and Ben

- **LICENSES.md (not edited here).** TetGen2Femtic's LICENSE at the pinned commit ceb8bfb, not only at HEAD, is
  MIT, "Copyright (c) 2021 Yoshiya Usui". The clone in the study's scratchpad was at ceb8bfb. The port carries the
  notice in src/femtic_mesh/LICENSE_TetGen2Femtic.txt.
- **STATUS.md (not edited here).** Suggested line: "P1 (femtic_mesh first slice) done 2026-10-06:
  - port byte-identical to the C++ on chain_proof and v2 rebuilt inputs;
  - B2 on real tetgen files waits for Run04/Run05;
  - conda-forge tetgen differs from the WSL build at round 0;
  - D3 table in docs/dev/mesh_port_progress.md s5.2."
- **Ben's D3 call.** Read section 5.2.
  - Reaching about 21k cells needs coarser cells near the sites (Bx1.94) or dropping them.
  - Keeping the 150 m site cells, the floor is about 24k (midpoint split plus ellBx4) to 42k (count median).

## 10. Next steps (P2 and the rest of P1)

1. When Run04/Run05 return:
   - run `test_port_on_g0_run` on each (B2/TD2);
   - run `repartition --compare` on their mesh.dat (B3 itself is complete on v1-v3, section 5.1; this repeats it
     on Phoenix's mesh);
   - record a WSL md5 mismatch, do not fail on it (TD1).
2. The makeMtr port (B4), against Run04/Run05's output.1-5 and their `.mtr`. mesh_chain.sh keeps tetgen's own
   `.mtr` as output.i.tetgen.mtr and makeMtr's as output.i.mtr.
3. The tetgen wrapper (B5/TD4).
   - The conda-forge exe already differs at round 0 (section 4), so byte identity needs Phoenix's build or our
     own CI build of libigl e05aca7.
   - The wrapper must check the `.mtr` count and the stale `output.i.b.*` files (study section 3).
4. spec / inputs / check / chain driver (study section 4), and a P3 Gmsh prototype. P3 needs only this
   converter (study section 8, point 1).
5. D3: Ben picks a candidate rule. Then run an inversion smoke test on v2 with the re-partitioned block file
   (mesh.dat unchanged) before any remesh.

## 11. Verdict (independent verifier, 2026-10-06)

**Tally over P0 and P1: 56 claims upheld, 0 refuted, 10 missed.** Journal: docs/journal/2026-10-06_mesh_port_p0_p1.md.
The verifier re-ran everything on a non-hardlinked scratch copy of the worktree: tests/mesh 18 pass / 1 skip /
0 fail in 87 s (suite peak 1,749 MB), `FEMTIC_SKIP_V2=1` 13 / 0 in 3 s, and the six shell suites as reported.

**Upheld by independent re-runs (no femtic_mesh writer in the loop):**
- Its own rebuild of output.6.* (attributes from the golden block file, face lists in reverse order, other corner
  permutations) fed to the port CLI gives products cmp-identical to the C++: chain_proof mesh.dat 2,893,745 B, block
  888,744 B, VTK 3,653,860 B; v2 mesh.dat, block and VTK 329,384,712 B (port 15.9 s). One surface element relabelled
  air makes mesh.dat differ at byte 2,850,273.
- `repartition` is cmp-identical on chain_proof (block md5 119bb35f) and v2 (0c3ae9da). The section 5.2 table reran
  identically: band sums equal the totals, cell size grows with depth under every rule, air cell 0 keeps exactly
  1,149,539 elements under midpoint, Bx1.94 and midpoint+ellBx4; chain_proof alternatives give 3,374, 3,574, 2,033.
- Exactly one tetgen run exists (scratchpad p1/tg0, all files 22:50:33, md5-equal to the fixture). No real makeMtr,
  makeTetraMesh or TetGen2Femtic output was found. TetGen2Femtic's LICENSE at ceb8bfb is MIT.

**Missed, for this page** (applied 2026-10-07: B3 in sections 1, 5.1 and 10; the D3 nuance in sections 1 and 5.2):
- **B3 is complete.** `python -m femtic_mesh.repartition --out --compare` also rewrites v1's block file (55,993
  cells, md5 9b3d07ce) and v3's (68,655 cells, md5 9bc8f7d4) byte for byte, 0 elements different, in 7 s and 10 s.
  Section 10 step 1's B3 item is now only "on Phoenix's mesh".
- **D3 nuance (qualifies section 5.2's "doubles the near-site cells" line).** Cells whose centre lies within 0.25 km
  of a site, on v2:

  | rule | cells | centroid spread median / p90 / max (km) | median cbrt(volume) (km) |
  |---|---|---|---|
  | usui | 11,476 | 0.097 / 0.138 / 0.159 | 0.058 |
  | Bx1.94 | 5,648 | 0.128 / 0.253 / 0.322 | 0.060 |

  The cap and the upper tail double, as section 5.2 says; the median near-site cell grows only about 30 % while
  their number halves. "150 m to about 290 m" describes the B cap, not the typical cell.
- **Invariant 10, test_port_on_real_tetgen_round0:** the sub-check "the port's cells equal cells.partition on the
  `.node` coordinates" is self-consistency (the port calls cells.partition on those coordinates); it shows only that
  the flood-fill regions equal the attribute regions. The volume, hull-face, Earth-surface-set and log-count checks
  are the independent ones.

**Missed, for the kit (P0; details in the journal):** RUNBOOK F3 fails a count difference from WSL that TD1 and the
RUN.md files say to record, and would stop the student before Run05; G0 lacks the plan's check_mesh.py 17/17 score;
F3 omits R2 and R6; the --mem 64G -> 27G switch also touches three test suites, make_run.sh and both RUN.md files;
pc_scripts_test.sh and runbook_walk_test.sh exit 2 once Ben commits (fix: `commit --allow-empty`);
docs/dev/gui_design_2026-10-06.md:362,382 cite the old Run04 line (reconcile at merge); one pack file in Ben's
checkout's shared .git got a new mtime, content unchanged (verify-pack ok). Applied 2026-10-07: F3 (with R2 and R6),
--mem=27G everywhere, `--allow-empty` in both tests. Still open: G0's check_mesh.py score, the gui_design citation.

**Ready for Ben: yes,** with the --mem decision and the F3 Fails-if wording settled before Run04 is submitted.
