# Building FEMTIC tetrahedral meshes

Internal guide for the MT group. It covers the makeTetraMesh, TetGen, makeMtr and TetGen2Femtic chain, with and without femticPy, and ends with a first-guess parameter set for the Vulcan survey.

Status (2026-09-25): written from a line-by-line reading of the tool sources and manuals listed in section 1.2, plus two measurements taken from this project's own files. **Nothing in section 8 has been meshed or forward-tested yet.** Section 9 is the test that must pass before a mesh is used for inversion.

---

## 0. The short version

If you read nothing else, read these nine points. Each one is expanded later, with its source.

1. **Seven steps, five sets of controls.** control.dat plus observing_site.dat set the surface triangles. makeMtr.param plus obs_site.dat set the volume tetrahedra. resistivity_attr.dat sets the parameter cells. The region seeds you append to output.poly decide which volume is air, sea or earth. analysis_domain.dat sets the box.
2. **`tetgen -Y` freezes the surface.** Every triangle makeTetraMesh puts on the Earth's surface and the domain walls survives unchanged into mesh.dat. makeMtr can only refine the volume. The size of the element that holds a site is therefore set by observing_site.dat, not by obs_site.dat alone (section 4).
3. **The high-frequency error is in H, not in the mesh generator.** With FEMTIC's default `OWNER_ELEMENT 0`, H at a site is curl E taken in the element below the surface, and it is constant over that element. The error grows with element size over skin depth. This project's own half-space test measured apparent resistivity too high by 22-75 % when the median surface edge was 0.47 of a skin depth (section 6.2). The FEMTIC manual's fix is to take H from the air element (`OWNER_ELEMENT -1` plus dummy VTF stations). Apply it before spending elements.
4. **Centre the coordinates.** TetGen2Femtic decides which outer face is -X or +X from the sign of the node coordinate. The domain must straddle 0 on x, y and z, otherwise the boundary conditions are wrong and no error is raised (section 10.7).
5. **Site z must be the mesh-surface z.** FEMTIC ignores site z; obs_site.dat and resistivity_attr.dat do not. femticPy writes minus the elevation. On a flat mesh surface at z = 0 that centres every Vulcan refinement sphere 65-124 m above the ground, so the finest (30 m) spheres sit entirely in the air (section 10.5).
6. **Do not use fix_output1.py as a fix.** It clamps any tetgen region attribute above 30 to 30, which hides seeds that missed their region. Seed every closed region and check the attribute set instead (section 10.2).
7. **control.dat is keyword-per-line.** The keyword goes alone on its line and the values go on the following lines, because the parser matches substrings. `EXTENDED_REGION` contains `END` (section 3.1).
8. **Sphere tables are not exactly what they say.** makeMtr's site spheres come out finer than their table inside each shell, then jump at the shell boundary. TetGen2Femtic's site circles can come out finer than their table if the profile is convex (sections 3.10 and 3.11).
9. **For Vulcan:** use a flat surface at z = 0, a domain of +-500 km on all three axes, a 15 m edge at each site, about 1.2 million tetrahedra and about 21 000 parameter cells. The machine-readable set is at the end of this file under `vulcan_first_guess`.

---

## 1. Conventions and sources

### 1.1 Units and frame

| Item | Convention | Source |
|---|---|---|
| Mesh-tool inputs | km everywhere: analysis_domain, control, observing_site, coast_line, topography, makeMtr.param, obs_site, resistivity_attr, region seeds | makeTetraMesh doc PDF p.4-13, p.35-36, p.42-44 |
| mesh.dat | metres. TetGen2Femtic multiplies nodes, sphere centres, radii, lengths and site coordinates by 1000 | TetGen2Femtic/src/MeshData.cpp:243-245, 605-607, 627-628, 672-674, 692-693 |
| observe.dat station X, Y | km, converted internally | femtic/doc/manual.txt:1038-1039; femtic/src/ObservedDataStationMT.cpp:281-283 |
| Axes | x = north, y = east, z = positive down. Land surface is stored as z = -altitude, sea floor as z = +depth | makeTetraMesh/src/TriangleList.cpp:2114, 2132 |
| ROTATION (control.dat, makeMtr.param, resistivity_attr.dat) | Degrees. The long axis points along (cos t, sin t) in (x, y), i.e. an azimuth measured from north towards east. femticPy's AusLAMP value of -45 puts the long axis NW-SE | makeTetraMesh/src/Ellipsoids.cpp:217-221 (the point is projected on (cos t, sin t)) |
| Visualisation files | makeTetraMesh .vtk in km, TetGen2Femtic output.N.femtic.vtk in m | femticPy projects/auslamp/prep_inversion.ipynb, markdown cell 35 |

### 1.2 Source versions

Every `file:line` citation below refers to these commits. The clones used for this study are read-only references.

| Repository | Commit |
|---|---|
| github.com/yoshiya-usui/makeTetraMesh | 92a9a32e0683458f7908f75743a8e3777753d0a1 (doc/How_To_Make_Tetra_Mesh_For_FEMTIC.pdf, cited as "doc PDF p.N") |
| github.com/yoshiya-usui/makeMtr | df8e2071f908dfd9dc30333ec548a42dc2e5a5c1 |
| github.com/yoshiya-usui/TetGen2Femtic | ceb8bfb1493092ed7c6a1a52352307be356d31e3 |
| github.com/yoshiya-usui/femtic (v5.0) | 26c8606ea61717a9386f93fff47203391836829c (doc/manual.txt is the text extracted from Manual_Of_FEMTIC.pdf) |
| github.com/libigl/tetgen (TetGen 1.6) | e05aca7df74e3f531bc35733ed87d36d437266c5 |
| github.com/hseille/femticPy (CSIRO) | 1b0fe316c01714d06a1c3be2bef5fa47daa67f0c |

Paths starting `scripts/`, `validation/` or `Vulcan/` are in this project (D:/BEN/FEMTIC_2026).

### 1.3 Build flags that change the file formats

The binaries in /home/tara/femtic_wsl/bin were built with the upstream Makefile flags (build log: `g++ -O2 -DNDEBUG` for makeMtr and TetGen2Femtic, `-O3 -fopenmp -D_USE_OMP -D_THICKNESS_FUNC -DNDEBUG` for makeTetraMesh). This matters in four places.

- makeMtr is built **without `_FINE_SURF`** (makeMtr/src/Makefile:3-4). The optional "fine surface" header block of makeMtr.param (makeMtr/src/main.cpp:181-222) is compiled out. The format in section 3.9 is the one this build reads, and it matches doc PDF p.35.
- makeTetraMesh is built **without `_MOD_FOR_NMT`**, so observation lines never insert mesh nodes (makeTetraMesh/src/BoundaryCurveList.cpp:1361-1367 is compiled out). It is also built without `_TOPO_FUNC`, so topography always comes from the files (makeTetraMesh/src/TopographyData.cpp:335-338).
- TetGen2Femtic is built **without `_ADDITIONAL_FIXED_AREA`**. resistivity_attr.dat ends after the site list (TetGen2Femtic/src/MeshData.cpp:710-766 is compiled out).
- `-DNDEBUG` turns asserts off. Some input mistakes, such as a missing `ELLIPSOIDS` block, then produce out-of-bounds reads instead of a clean message (makeTetraMesh/src/Ellipsoids.cpp:341).

---

## 2. The seven-step chain

These are femticPy's STEP 1-7 (femticPy/scripts/meshGen.sh:9-107). The project runner scripts/run_mesh_chain.sh does the same steps and adds checks. Run every step inside the directory that holds its inputs: all file names are fixed except the ALTITUDE and SEA_DEPTH file names.

```text
INPUTS (km; x=N, y=E, z=down)            STEP / COMMAND                           OUTPUTS (-> used by the next step)
=====================================================================================================================
control.dat                              [1] makeTetraMesh -stp 1                 node_bound_curve.stp1
analysis_domain.dat                          land/sea/lake boundary curves        boundary_curves.stp1
coast_line.dat                               from coast_line, roughened to the    boundary_curves_relation.stp1
observing_site.dat                           edge lengths of control.dat and      coastLine_fine.vtk, coastLine_rough.vtk
                                             observing_site.dat                   boundary_curve[_node]_stp1.vtk
                                                                                  makeTetraMesh.log (overwritten each step)
        |
control.dat, analysis_domain.dat         [2] makeTetraMesh -stp 2                 node_mesh.stp2, triangle_list.stp2
observing_site.dat, *.stp1                   2-D constrained Delaunay mesh of     node_curves2mesh.stp2, *.stp2 curves
                                             the surface, refined to the          surface_triangle.*.vtk
                                             ELLIPSOIDS + site circles
        |
control.dat, analysis_domain.dat         [3] makeTetraMesh -stp 3                 node_mesh.stp3, triangle_list.stp3
*.stp2, ALTITUDE file                        heights of the 2-D nodes by inverse  node_curves2mesh.stp3, *.stp3 curves
[SEA_DEPTH file] [lake.dat]                  distance weighting                   triangles_with_height.vtk
        |
control.dat, analysis_domain.dat         [4] makeTetraMesh -stp 4                 output.poly  (PLC; region list = "0")
*.stp3 [lake.dat]                            closed surface: Earth surface,       plc.vtk
                                             sea surface, walls, top, bottom
        |
        +--> YOU: replace the last line of output.poly ("0") by the seed count and append one seed per closed region
        |
output.poly (seeded)                     [5] tetgen -nVpYAakq3.0/0 output.poly    output.1.node .ele .face .edge .neigh .vtk
                                             first tetrahedralisation; region
                                             attributes from the seeds
        |
makeMtr.param, obs_site.dat              [6] for i in 1 2 3 4 5:                  output.i.mtr, then
output.i.node, output.i.ele                    makeMtr output.i                   output.(i+1).node .ele .face .edge
(.face, .edge read by tetgen -r)               tetgen -nmpYVrAakq3.0/0 output.i   .neigh .vtk
        |
resistivity_attr.dat                     [7] TetGen2Femtic output.6               mesh.dat (m)
output.6.node .ele .neigh .face              tets -> FEMTIC mesh + parameter      resistivity_block_iter0.dat
                                             cells                                output.6.femtic.vtk (m)
        |
mesh.dat + resistivity_block_iter0.dat + observe.dat + FEMTIC's own control.dat  -->  femtic
```

Where each input is read (the code, not the PDF, is authoritative):

| Step | Reads | Code |
|---|---|---|
| every makeTetraMesh step | control.dat, re-read at the start of each step (step 1 reads it twice) | makeTetraMesh/src/Control.cpp:338, 654 |
| 1 | analysis_domain.dat, observing_site.dat, coast_line.dat | Control.cpp:655-660 |
| 2 | analysis_domain.dat, observing_site.dat, *.stp1 | Control.cpp:710-720 |
| 3 | *.stp2, analysis_domain.dat, ALTITUDE/SEA_DEPTH files, lake.dat (optional) | Control.cpp:764-798; LakeList.cpp:51-55 (a missing lake.dat is silently accepted) |
| 4 | *.stp3, analysis_domain.dat, lake.dat; writes output.poly and plc.vtk | Control.cpp:828-847; TriangleList.cpp:2235-2237 |
| 5 and 6 | tetgen -r loads .node, .ele, then tries .face, .edge, .vol, .var, .mtr | tetgen/tetgen.cxx:2462-2487 |
| 6 | makeMtr: makeMtr.param, obs_site.dat, output.i.node, output.i.ele (element attributes required) | makeMtr/src/main.cpp:146-149, 447-452 |
| 7 | TetGen2Femtic: .node, .ele (attributes required), .neigh, .face (boundary-marker column required), resistivity_attr.dat | TetGen2Femtic/src/MeshData.cpp:51-61, 289-294, 397-402 |

makeTetraMesh opens makeTetraMesh.log with `std::ios::out` on every run (makeTetraMesh/src/OutputFiles.cpp:43). Copy the log after each step or you lose steps 1-3.

---

## 3. File-by-file reference

### 3.1 Parsing rules you must know

**Numeric files** (all except control.dat) are read with C++ `>>`. Line breaks do not matter, and `\r` counts as whitespace, so CRLF files parse. What matters is the count and the order of the numbers.

**control.dat is line-oriented.** Two parsers scan the whole file, each with `getline` followed by `line.find("KEYWORD")`. Control::readControlData looks for every keyword except the ellipsoid ones (makeTetraMesh/src/Control.cpp:113-237). Ellipsoids::readParameters looks only for CENTER, ROTATION, ELLIPSOIDS and END (makeTetraMesh/src/Ellipsoids.cpp:94-159). After a keyword matches, the values are read with `>>` **from the following lines**. Consequences:

- `NUM_THREADS 8` on one line does not work. `getline` has already consumed the 8, and `>>` then reads the next keyword line, fails, and makeTetraMesh stops with "Total number of threads is less than 1". Put each keyword alone on its line.
- The match is a substring match. Any line containing `END` stops the ellipsoid parser, and `EXTENDED_REGION` contains `END` (Ellipsoids.cpp:157-159). The ellipsoid parser also sees the value lines, including the ALTITUDE file name. **Write CENTER, ROTATION and ELLIPSOIDS first**, as femticPy does. Never give the topography file a name containing CENTER, ROTATION, ELLIPSOIDS or END.
- Unknown lines are ignored silently. A misspelt keyword just leaves its default in place. Read the "# ..." echo lines in makeTetraMesh.log (Control.cpp:256-316; Ellipsoids.cpp:163-174).

**Monotonic tables.** Ellipsoid and sphere lists must grow outwards. The checks differ between tools, and makeTetraMesh does not check the short horizontal axis (compare makeTetraMesh/src/Ellipsoids.cpp:143-146, commented out, with makeMtr/src/main.cpp:284-287 and TetGen2Femtic/src/MeshData.cpp:651-654). If an ellipsoid does not contain the one before it, makeTetraMesh aborts mid-run with "does't locate in the trasition region" (Ellipsoids.cpp:267-283). The first row's oblateness values are never range-checked, because the check loops start at i = 1. Keep every oblateness in [0, 1).

### 3.2 analysis_domain.dat

```text
x_min x_max
y_min y_max
z_min z_max        # z_min = top of the air (negative), z_max = bottom (positive)
```

The file is read at makeTetraMesh/src/AnalysisDomain.cpp:68-70, and each min must be below its max (72-85). **All three ranges must straddle 0.** Nothing checks this, but TetGen2Femtic labels outer faces by the sign of the node coordinate (TetGen2Femtic/src/MeshData.cpp:1545-1575). femticPy writes `' %4.1f %4.1f'`, i.e. to 0.1 km (femticPy/src/femticPy.py:727-732). Its DataGen default is +-500 km on all axes (femticPy.py:83-85), and the AusLAMP notebook uses +-1000 km (prep_inversion.ipynb cell 8).

### 3.3 control.dat (makeTetraMesh)

Values go on the lines after the keyword. The "Used" column gives the makeTetraMesh steps that read the keyword.

| Keyword | Values (next lines) | Units | Default | Used | Meaning | femticPy writes |
|---|---|---|---|---|---|---|
| `CENTER` | x y z | km | 0 0 0 | 1-4 | Common centre of all ELLIPSOIDS (Ellipsoids.cpp:100-102) | centre, AusLAMP `0 0 0`. The class default z is computed with the wrong sign (section 10.7.4) |
| `ROTATION` | angle | deg | 0 | 1-4 | Azimuth of the ellipsoids' long axis (Ellipsoids.cpp:103-105, 217-221) | 0; AusLAMP -45 |
| `ELLIPSOIDS` | N, then N rows `r L fh fb fa` | km, km, -, -, - | none (required) | 1-4 | Target edge-length field, see below (Ellipsoids.cpp:106-156) | 6 rows (class), 2 rows (AusLAMP) |
| `NUM_THREADS` | n | - | 1 | 3 | OpenMP threads for the height interpolation (Control.cpp:164-170; TriangleList.cpp:2071-2074) | `1` |
| `SURF_MESH` | none | - | off | 4 | Triangulate every boundary face (walls, top, bottom) with the ellipsoid sizes (TriangleList.cpp:3809-3836). The doc says it is always required (doc PDF p.7) | written |
| `INTERPOLATE` | search radius; max points (**integer**); epsilon | km; -; km | 100; 3; 1e-6 | 3 | Inverse distance weighting uses up to "max points" data points inside the radius, weight 1/(eps + d)^p (Control.cpp:149-153; TopographyData.cpp:356-423) | `100.0` / `3.0` / `0.0000010`. The `3.0` is a bug, see section 10.7.5 |
| `ALTITUDE` | file; min; max | -; km; km | none; 0.0; 1e10 | 3 | Land and lake-bottom heights, positive up, clamped to [min, max] (Control.cpp:154-158; TriangleList.cpp:2122-2139) | `topography.dat` / `0.0` / `1e20` |
| `SEA_DEPTH` | file; min; max | -; km; km | none; 0.01; 1e10 | 3 | Sea depths, positive down, clamped (Control.cpp:159-163; TriangleList.cpp:2105-2121) | `bathymetry.dat` / `0.0` (see section 10.7.5) / `1e20` |
| `IDW_FACTOR` | p | - | 1.0 | 3 | Distance power in the weighting (Control.cpp:185-192; TopographyData.cpp:416) | not written |
| `HEIGHT_DEVIATION` | threshold | km | off | 3 | Smooths spiky node heights (Control.cpp:178-184; TriangleList.cpp:7118) | not written |
| `OUTER_EDGE_LENGTH` | L | km | last ellipsoid L | 1-2 | Largest edge allowed on the domain's outer edges. Must not exceed the last ellipsoid L (Control.cpp:196-200, 246-254; CoastLineList.cpp:242-252) | not written |
| `MAX_EDGE_RATIO` | ratio | - | 3.0 | 1 | Coast-line roughening threshold (CoastLine.cpp:314) | not written |
| `COAST_SMOOTHING` | iterations; angle; distance | -; deg; km | 0; 10; 3 | 1 | Drops sharp or close coast points (Control.cpp:134-138; CoastLine.cpp:193-260) | not written |
| `ALPHA` | a | - | 1.5 | 2 | A triangle is refined while one of its edges exceeds a times the smaller target at that edge's two nodes, so **surface edges can end up to 1.5 times the target** (TriangleList.cpp:3083) | not written |
| `BETA` | b | - | 0.2 | 2 | Candidate points closer than b times the target are skipped (TriangleList.cpp:3097-3106) | not written |
| `ITER_MAX` | n_long; n_angle | - | 30; 0 | 2 | Maximum refinement sweeps. If n_long is reached, the log says "Reach maximum interation number" and **the surface stays under-refined without an error** (TriangleList.cpp:3051-3056) | not written |
| `MAX_ANGLE` | angle | deg | 150 | 2 | Large-angle refinement threshold. Only active if n_angle > 0 | not written |
| `LAPLACIAN` | n | - | 5 | 2 | Laplacian smoothing sweeps (TriangleList.cpp:119) | not written |
| `SUPER_TRIANGLE` | factor | - | 1.0 | 2 | Size of the Delaunay super-triangle | not written |
| `EXTENDED_REGION` | +x -x +y -y | km | off | 4 | Extra padding region. Incompatible with SURF_MESH (Control.cpp:241-244) | not written |
| `INVERT_YCOORD` | none | - | off | all | Flips the sign of y in the coast, site and topography inputs | not written |
| `EXCHANGE` | none | - | off | 1 | Swaps land and sea curve types (Control.cpp:688-691) | not written |
| `SEDIMENT` | thickness | km | 10 | 4 | Adds a sediment-layer facet, which creates another closed region that needs a seed | not written |
| `LAYERS` | n; d1 ... dn | km | off | 4 | Adds horizontal interface facets at depths d_i, one more closed region each. Useful for layered forward tests (section 9) | not written |
| `END` | none | - | - | - | Stops both parsers | written |

**An ELLIPSOIDS row is `r L fh fb fa`.** The columns are read in this order at makeTetraMesh/src/Ellipsoids.cpp:120, and makeMtr.param uses the same five columns (makeMtr/src/main.cpp:256).

| Col | Name | Exact meaning |
|---|---|---|
| 1 | r | Semi-axis along the rotated x' axis, the long horizontal axis (km) |
| 2 | L | Target maximum edge length inside this ellipsoid (km) |
| 3 | fh | Horizontal oblateness. The y' semi-axis is r (1 - fh) (Ellipsoids.cpp:227) |
| 4 | fb | Vertical oblateness **below** the centre (z > z_c; the Earth side when the centre is on the surface). The downward semi-axis is r (1 - fb) |
| 5 | fa | Vertical oblateness **above** the centre (z < z_c; the air side). The upward semi-axis is r (1 - fa) (Ellipsoids.cpp:224, 228; enum at Ellipsoids.h:59-62) |

The doc PDF (p.8) labels column 4 "Upper side" and column 5 "Lower side". The code uses column 4 for z below the centre (the `EARTH` slot) and column 5 for z above it (`AIR`), and the log header reads `<OblatenessVerticalEarth> <OblatenessVerticalAir>` (Ellipsoids.cpp:166). **Trust the code.**

How the size field is evaluated (Ellipsoids.cpp:184-329; makeMtr/src/main.cpp:516-554, 694-839):

- Inside ellipsoid 1 the target is L1.
- Outside the last ellipsoid it is L_N.
- In between, it is interpolated linearly along the ray from the centre. The point's distance is compared with the distances at which the ray crosses ellipsoids i-1 and i: L = L_{i-1} + (d - d_{i-1}) / (d_i - d_{i-1}) (L_i - L_{i-1}) (Ellipsoids.cpp:285).

On the Earth's surface makeTetraMesh evaluates the ellipsoids at z = 0, whatever the topography (makeTetraMesh/src/Util.cpp:259, 264-265). On the walls, top and bottom (SURF_MESH) it evaluates them at the 3-D wall points, and the wall nodes follow a geometric progression between the corner values (TriangleList.cpp:4584-4587; Util.cpp:311-353).

### 3.4 observing_site.dat (makeTetraMesh, surface only)

```text
N_sites
X Y  n  r1 L1  r2 L2 ... rn Ln        # one site; line breaks are free
...
N_lines                               # optional: observation lines (NMT dipoles)
X1 Y1 X2 Y2  n  r1 L1 ... rn Ln       # per line
```

- Read at makeTetraMesh/src/ObservingSiteList.cpp:77-113, with each site at ObservationPoint.cpp:62-86 and each line at ObservationLine.cpp:107-135. If N_lines is missing the stream just fails at EOF and there are no lines.
- **Meaning.** These are 2-D circles on the surface plane. The target edge is L1 within r1, interpolated linearly in horizontal distance between circles, and unconstrained beyond rn. The result is combined with the ELLIPSOIDS value and with every other site by taking the minimum (ObservationPoint.cpp:119-142; ObservingSiteList.cpp:143-163; Control.cpp:463-476).
- The circles also shorten coast-line segments near sites (CoastLineList.cpp:242-252).
- Site z is not an input here. **The site is not inserted as a mesh node** (section 4).
- femticPy writes one line per site as `north east n r1 L1 ...` (femticPy.py:798-809).

### 3.5 coast_line.dat

```text
N_boundaries                 # 0 = no land anywhere (all sea)
X Y end_flag fix_flag        # repeated; end_flag 0 = continue, 1 = last point of a closed boundary, -1 = last point of an open one
```

- Read at makeTetraMesh/src/CoastLine.cpp:66-91. Column 4 is a fix flag: 1 keeps the point during roughening (CoastLine.cpp:72-83).
- Land must lie on the right-hand side of the direction of travel (doc PDF p.6).
- For an all-land model, define one closed boundary that encloses the whole domain (doc PDF p.5). femticPy's dummy runs (x_min-1, y_min-1) -> (x_min-1, y_max+1) -> (x_max+1, y_max+1) -> (x_max+1, y_min-1) with end flag 1 on the fourth point (femticPy.py:812-833). The same order is used in femticPy projects/synthetic/input_data/coast_line.dat.
- Boundaries must not cross each other or themselves (doc PDF p.17; section 10.1).

### 3.6 topography.dat and bathymetry.dat (names set in control.dat)

- One `X Y value` per line (TopographyData.cpp:70-89). Altitude is in km, positive up; sea depth is in km, positive down (doc PDF p.12).
- Points farther than the INTERPOLATE radius outside the domain are discarded on reading (TopographyData.cpp:77-79).
- Each 2-D node gets an inverse-distance-weighted value from up to "max points" data inside the radius. If none are inside, it takes the nearest point's value and logs a warning (TopographyData.cpp:396-405).
- Coast nodes are forced to z = 0 (TriangleList.cpp:2092-2094). Land heights are clamped to [ALTITUDE min, max], so with the default min of 0 no land node goes below sea level (2126-2131).
- **ALTITUDE is required whenever there is land.** With no altitude data, step 3 aborts with "Point serial of the nearest point is negative" (TopographyData.cpp:398-401). SEA_DEPTH is only needed if there is sea.
- femticPy's dummies are a 10 km grid of 0.000 for topography and -0.010 for bathymetry (femticPy.py:837-853). The bathymetry value is clamped to the minimum depth anyway. `write_inputs()` does **not** write the dummy files, so call the `write_dummy_*` methods yourself (femticPy.py:892-898). meshGen.sh copies them from `input_data/` (meshGen.sh:5).

### 3.7 lake.dat (optional)

`N` followed by one `X Y Z` per lake: a point on each lake's surface, from which the lake level is taken (doc PDF p.23). If the file is missing, it is skipped (LakeList.cpp:51-55). Lake bottoms come from the ALTITUDE data. Every lake is a separate closed region and needs its own seed.

### 3.8 output.poly and the region seeds

makeTetraMesh writes Part 1 (nodes, no attributes or markers), Part 2 (facets, no boundary markers), Part 3 (`0` holes) and Part 4 (`0` regions) (makeTetraMesh/src/TriangleList.cpp:6299-6366; the zeros are at 6357-6361). **You must replace the final `0` with the number of seeds and append one line per seed:**

```text
index  x  y  z  region_attribute  max_volume
1      0.0 0.0 -250.0  10  1e9     # a point strictly inside the air
2      0.0 0.0  250.0  20  1e9     # a point strictly inside the earth
```

- tetgen skips the index and reads x y z, the attribute, and an optional maximum volume (tetgen/tetgen.cxx:1197-1233).
- The femticPy notebooks label the columns "region_attribute x y z region_number 1e9" (projects/auslamp/prep_inversion.ipynb markdown cell 30). That swaps the names: the 5th field is the attribute, and it must match resistivity_attr.dat.

What `-A` does with the seeds (tetgen.cxx:23837-23856, 24218-24336):

1. Each seed point is located. A seed outside the convex hull prints "The i-th region point lies outside the convex hull" and is dropped.
2. Starting from each seed, in file order, the attribute spreads to every tetrahedron reachable without crossing a PLC facet.
3. **Every closed region that no seed reached gets `max_attribute + 1`, `+2`, ...** (24275-24307). This is the source of the "31/32" attributes (section 10.2).
4. **Two seeds in the same region:** the first one spreads, and the later one relabels only its own tetrahedron (24242-24266). Never do this.

`-a` without a number applies the 6th column as a per-region volume bound (tetgen.cxx:3356-3373, 28380-28385); 1e9 km^3 means no bound.

Seed rules:

- One seed per closed region: air, the Earth, every separate sea body, every lake, every SEDIMENT or LAYERS slab.
- Put each seed well inside its region, never on a facet. The seed z must be above the highest topography for air and below the deepest bathymetry for earth.
- The set of seed attributes must equal the attributes in resistivity_attr.dat.
- femticPy's meshGen.sh examples (meshGen.sh:46-60):
  - land only: 10 = air at z = -40, 20 = earth at z = +10;
  - AusLAMP: 10 air (0, 0, -40), 20 sea (-400, -400, 0.5), 30 earth (0, 0, 40).

### 3.9 makeMtr.param

```text
Xc Yc Zc                              # centre of the ellipsoids (km)
rotation                              # deg (azimuth of the long axis)
N
r L fh fb fa                          # N rows, the same 5 columns as control.dat ELLIPSOIDS
n_sea_attr [attr_1 ... attr_n]        # optional (EOF -> 0): attributes of sea elements
n_regions                             # only if n_sea_attr > 0
X Y rotation  m  r1 L1 f1 ... rm Lm fm   # per region: nested 2-D ellipses, applied only at nodes touching sea elements
```

- Read at makeMtr/src/main.cpp:233-356 (this build has no fine-surface header; section 1.3). The checks include "each row's short horizontal axis >= the previous row's" (main.cpp:284-287), which makeTetraMesh does not check.
- The sea regions set sizes only at nodes that touch a listed sea attribute (main.cpp:530-532, 649-692).
- **Output.** For every node of output.i, makeMtr writes one target length to output.i.mtr: the minimum of the ellipsoid field, the site spheres and the sea regions (main.cpp:480-554).
- In `tetgen -m`, a tetrahedron is split while its **circumradius** exceeds the .mtr value at any of its four vertices (tetgen.cxx:28391-28402). So L is effectively a circumradius bound, and the edges of a regular tetrahedron that just meets it are 1.63 L long. Measured on the AusLAMP mesh, the mean edge came out close to L (Appendix B).
- femticPy writes the centre, the rotation and the rows, with no trailing sea line (femticPy.py:767-777).

### 3.10 obs_site.dat (makeMtr)

```text
N_sites
X Y Z                 # site position (km). Z is USED: it must be the mesh-surface z at the site
n
r1 L1 f1              # n rows: sphere radius, target edge, vertical oblateness
...
N_lines               # optional (EOF -> 0): NMT lines
```

- Read at makeMtr/src/main.cpp:361-394 and makeMtr/src/ObservationPoint.cpp:65-97.
- **Meaning.** Each row is a flattened sphere centred on (X, Y, Z), with horizontal radius r and vertical semi-axis r (1 - f), the same above and below. Inside sphere 1 the target is L1 (ObservationPoint.cpp:109-111). Outside the last sphere the site imposes nothing, so the global ellipsoids take over (115-117).
- **Oddity: the size between spheres is not the linear ramp the table suggests** (ObservationPoint.cpp:121-137). The interpolation variable is normalised to sphere i, and its end value is sqrt(3) r_{i+1}/r_i, not r_{i+1}/r_i. The target therefore reaches only about half-way to L_{i+1} at radius r_{i+1}, then **jumps** to L_{i+1}. At the last sphere it jumps to whatever the global ellipsoid gives. The mesh ends up finer than the table inside each shell, with jumps of about 1.4-1.5 in size at each sphere boundary. Worked example (the Vulcan table, surface level): 0.015 km up to r = 0.03; 0.027 km at r = 0.1-, then 0.040 at 0.1+; 0.069 km at 0.3-, then 0.100 at 0.3+; 0.141 km at 0.6-, then the global 0.2 km.
- femticPy writes `north east z` with z = -elevation (femticPy.py:780-794, 222). See section 10.5.

### 3.11 resistivity_attr.dat (TetGen2Femtic)

```text
N_regions
attr  rho  ndiv  ifix                 # N lines (isotropic; with -aniso the layout differs: MeshData.cpp:499-575)
Xc Yc Zc                              # centre of the cell-size ellipsoids (km)
rotation                              # deg
Ns
r B fh fv                             # Ns rows: 4 columns, ONE vertical oblateness used above and below
N_sites
X Y Z                                 # km; Z USED (3-D distance)
n
r1 B1                                 # n rows: radius, max cell length
...
```

Region lines (TetGen2Femtic/src/MeshData.cpp:476-596):

| Field | Meaning |
|---|---|
| attr | tetgen region attribute (the seed's 5th field) |
| rho | starting resistivity, ohm-m |
| ndiv | Number of forced recursive-bisection rounds (2^ndiv blocks before the length criterion). **Negative means the region is air or sea:** it stays one block and its interfaces with the earth count as the Earth's surface (MeshData.cpp:590-593, 1128-1154, 1914-1917) |
| ifix | >0 fixes the region's blocks in the inversion (MeshData.cpp:587) |

- **The first line must be the air**, with ndiv < 0, otherwise TetGen2Femtic exits (MeshData.cpp:579-586). The air becomes parameter cell 0, as FEMTIC requires (MeshData.cpp:1911, 1945-1955; femtic/doc/manual.txt:488).
- **Never give a subsurface region a negative ndiv to "fix" it.** Its faces would be written into mesh.dat's Earth-surface list, where FEMTIC searches for stations (femtic/src/MeshDataTetraElement.cpp:392-463), and a station above such a body could be attached to the body's top face. To fix a subsurface region, use ndiv >= 0 with ifix = 1.
- **Ellipsoid rows `r B fh fv`** (MeshData.cpp:604-659, 2151-2326):
  - The geometry matches control.dat, except that one vertical oblateness serves both sides (MeshData.cpp:2195).
  - B is the maximum cell "length" (section 5).
  - The checks cover radius, B, the short horizontal axis and the vertical semi-axis.
  - The length criterion runs only if Ns > 0. With Ns = 0 the only splits are the ndiv forced bisections (MeshData.cpp:1923-1926).
- **Site circles `r B`** (MeshData.cpp:664-708, 2329-2354):
  - They are true spheres in 3-D distance from (X, Y, Z).
  - **Oddity:** the code takes the minimum over every segment whose outer radius contains the point, not just the segment the point is in (2341-2347). If the profile's slope increases outwards (convex), the backward extrapolation of an outer segment gives a smaller, and possibly negative, length. Cells near the site then come out finer than the table, and may be reduced to single elements.
  - Use 2 circles, or keep the slopes non-increasing outwards.
- femticPy writes (femticPy.py:857-889):
  - land only: `2 / 10 1.0e+9 -1 1 / 20 100.0 9 0`;
  - with sea: `3 / 10 1e9 -1 1 / 20 0.250 -1 1 / 30 100.0 9 0`;
  - then the centre, rotation, rows, and sites with z = -elevation.

### 3.12 What FEMTIC receives

- **mesh.dat** (TetGen2Femtic/src/MeshData.cpp:1583-1633; femtic/doc/manual.txt:767-851):
  - `TETRA`;
  - the nodes (m, 0-based);
  - each element with its 4 neighbours (-1 for none) and 4 nodes;
  - six outer face lists (-X, +X, -Y, +Y, -Z = top of the air, +Z = bottom);
  - the Earth-surface face list.
  - Outer faces are classified by coordinate sign, and Earth-surface faces are those between a region with ndiv >= 0 and one with ndiv < 0 (MeshData.cpp:1115-1178).
- **resistivity_block_iter0.dat** (MeshData.cpp:1815-1888; manual.txt:961-982):
  - `N_elements N_cells`;
  - one element-to-cell line per element;
  - one line per cell: `index rho 1e-20 1e+20 1.0 ifix`.
  - Lower bound 1e-20, upper bound 1e+20 and n = 1.0 are hard-coded. Edit them afterwards if you want RESISTIVITY_BOUNDS to mean anything.
- **observe.dat station line**: `ID  H_station_ID  [owner_type]  [efield_type]  X  Y` in km, **with no Z** (manual.txt:1033-1072).
  - FEMTIC puts the station on the Earth-surface triangulation by (X, Y) (femtic/src/MeshDataTetraElement.cpp:387-469).
  - It fails with "Could not find element including point" if no surface triangle contains the station (465-466).
  - E is interpolated from the owner element's six edge values at the station point, which lies on the surface face (femtic/src/ObservedDataStationMT.cpp:350-364; Forward3DTetraElement0thOrder.cpp:287-317).
  - H is curl E / (i omega mu) of the owner element, a constant over that element: the station coordinates are passed in but not used (ObservedDataStationPoint.cpp:154-161; Forward3DTetraElement0thOrder.cpp:570-607).

---

## 4. How sites are embedded

**The site is never a node.** No compiled code path inserts site coordinates into the surface or the volume mesh (section 1.3). Sites act only through size fields, and FEMTIC finds each site afterwards inside a surface triangle. Three independent inputs describe the same sites:

| Layer | File | Geometry | Uses site Z? | What it controls |
|---|---|---|---|---|
| Surface triangles | observing_site.dat | 2-D circles, linear ramp | no | The triangle that will contain the site, frozen by `tetgen -Y` |
| Volume tetrahedra | obs_site.dat | Flattened spheres, the sqrt(3) ramp (section 3.10) | **yes** | Tetrahedra above and below the site, including the owner element's depth |
| Parameter cells | resistivity_attr.dat site circles | 3-D spheres, min-over-segments (section 3.11) | **yes** | Resistivity cells under the site |

Then FEMTIC locates the station by (X, Y) in the Earth-surface triangles. `OWNER_ELEMENT 0` uses the element below the triangle, `1` the element above, and `-1` lets you choose per station (manual.txt:186-213). The optional `MOVE_OBS_LOC` moves the station to the face centroid (manual.txt:247-265; femtic/src/ObservedDataStationPoint.cpp:71-85).

Consistency rules:

1. **Same x, y everywhere.** observe.dat, observing_site.dat, obs_site.dat and resistivity_attr.dat must use the same origin and the same axis order: x = north first. femticPy writes north then east in all four files (femticPy.py:378-380, 785-787, 803-804, 880-882).
2. **The z in obs_site.dat and resistivity_attr.dat is the mesh-surface z** at the site. It is not the GPS elevation. The mesh surface is the interpolated, clamped surface of section 3.6.
3. **The frozen surface must not be coarser than the volume target near it.** The metric test compares circumradius with the .mtr value (tetgen.cxx:28391-28402), and `-Y` forbids splitting a surface face (tetgen.cxx:29187-29194, 29377-29551). A tetrahedron sitting on a surface triangle larger than about 1.7 times the local .mtr value can never pass the test. tetgen then adds interior points without end, or leaves slivers against the face. Set the observing_site.dat circles to or below the **effective** obs_site.dat profile (section 3.10), and set control.dat's core L to or below makeMtr.param's core L.
4. **femticPy indexes sites by row, not by ID, in the mesh files** (femticPy.py:784, 802, 879). observe.dat is matched by ID (femticPy.py:374). Refinement lands on the observe.dat sites only if the coordinate file holds exactly the inverted sites. For Vulcan: 120 coordinates and 120 EDIs, with the IDs matching exactly.

---

## 5. How parameter cells are formed, and how to control their size

Algorithm (TetGen2Femtic/src/MeshData.cpp:1891-2148):

1. Tetrahedra are grouped by region attribute. Air and sea (ndiv < 0) become one block each; air is block 0 (1911-1917).
2. **Forced bisections.** ndiv rounds of recursive coordinate bisection split every block with at least 2 elements (1962-1982). The split direction is the one with the widest spread of element centroids, and the split point is the **median element**, i.e. equal counts, not the geometric middle (2089-2129). ndiv = 9 gives up to 512 blocks per region before any length criterion.
3. **Length criterion**, only if the ellipsoid count Ns > 0 (1924-1926). A block is split again, in the same way, until its centroid extent in the widest direction is below the smaller of B at its two extreme elements (2001-2086, 2132-2148). B at a point is the minimum of the ellipsoid field and the site circles (2151-2170).
4. With `-div_all`, every earth element becomes its own cell (1919-1921). That gives far more cells than data, so the data-space method is needed (doc PDF p.46).

Practical consequences:

- **Cells come out at about 0.9 B, not B.** Fitted on the AusLAMP mesh, the cell count is about 1.28 times the volume integral of 1/B^3 (Appendix B). Cells stay within their region: a cell never straddles the air/earth interface.
- The split is by element count, so a block that spans a size gradient splits towards the fine side. Cells in grading zones are uneven. That is normal.
- **Cells cannot be smaller than the tetrahedra.** Keep B at least 1.5-2 times the local tetrahedron size L. Otherwise a cell holds only a few elements, and its shape follows the mesh noise.
- **Cell size versus depth** is set by the vertical oblateness column fv. Each row i covers depth r_i (1 - fv_i) under the centre. Choose rows so that B(z) grows roughly as 0.3 z below the fine near-surface layer. MT depth resolution is a fraction of depth, and cells finer than that only add unconstrained parameters.
- ndiv interacts with the ellipsoids. With ellipsoids present, forced splits mostly cut up the padding: counts are dominated by the fine core, so the first splits happen there and the length criterion would have split it anyway. **ndiv = 0 leaves the ellipsoids in sole control**, which is easier to reason about.

---

## 6. Rules of thumb

### 6.1 Skin depth

delta [km] = 0.503 sqrt(rho [ohm-m] x T [s]). Vulcan values below come from the determinant apparent resistivity of all 120 EDIs (rho_a = 0.2 T |Z_det|^2 in mV/km/nT; computed for this guide):

| Period band (s) | rho_det p10 / median / p90 (ohm-m) | median phase | delta at band start, p10 rho (km) | delta at band end, median rho (km) |
|---|---|---|---|---|
| 0.005-0.01 | 2.9 / 4.8 / 9.9 | 36 | **0.061** | 0.110 |
| 0.01-0.03 | 3.6 / 5.9 / 11.3 | 38 | 0.096 | 0.21 |
| 0.03-0.1 | 4.3 / 6.8 / 11.9 | 40 | 0.18 | 0.41 |
| 0.1-0.3 | 4.7 / 7.1 / 12.3 | 37 | 0.35 | 0.73 |
| 0.3-1 | 6.1 / 10.2 / 19.5 | 26 | 0.68 | 1.6 |
| 1-3 | 10.1 / 20.9 / 40.9 | 21 | 1.6 | 4.0 |
| 3-10 | 19.9 / 41.6 / 82.3 | 28 | 3.9 | 10.3 |
| 10-30 | 29.6 / 60.9 / 106.9 | 41 | 8.7 | 21.5 |
| 30-100 | 26.2 / 51.8 / 88.2 | 47 | 14.1 | 36.2 |
| 100-300 | 26.1 / 52.7 / 87.1 | 45 | 25.7 | 63.2 |
| 300-1000 | 28.8 / 59.6 / 112.3 | 43 | 46.7 | **122.8** |

Reading: the conductive cover (about 3-10 ohm-m) controls T below about 0.3 s. The phase drops to about 20 degrees at 1-3 s, which is the resistive basement showing through. At longer periods the Earth looks like about 50-60 ohm-m out to 1000 s, not the 1000 ohm-m basement end-member. **delta_min is about 0.06 km and delta_max about 120 km.**

### 6.2 Element size at the sites, and why FEMTIC is harsher than the textbook rule

The mechanism:

- With OWNER_ELEMENT 0, H at the station is the element-constant curl E of the tetrahedron below the surface (ObservedDataStationPoint.cpp:154-161; Forward3DTetraElement0thOrder.cpp:570-607).
- In the Earth, H decays as exp(-(1+i) z / delta). A constant over an element of depth h is roughly H at depth h/4.
- So |H| comes out too small and its phase lags. rho_a is then too high by about +2 (h/4)/delta, and the phase too large by about (h/4)/delta radians.
- The manual states the effect qualitatively: the impedance amplitude is overestimated unless the element just below the station is small enough, and the cure is to take H from the element above (femtic/doc/manual.txt:1552-1577).

This project measured it with iteration 0 of the bundled INV_MT_01 example, a 100 ohm-m half-space (validation/wsl_2026-09-25/run_logs/VALIDATION.md, halfspace_check.txt, mesh_surface_size.txt). Median surface-element edge: 2.4 km.

| f (Hz) | edge / delta | rho_a error | phase error |
|---|---|---|---|
| 0.001 | 0.015 | +1.4 to +3.1 % | +0.3 to +0.6 deg |
| 0.01 | 0.05 | +3.5 to +8.4 % | +0.6 to +1.7 deg |
| 0.1 | 0.15 | +8 to +23 % | +1.7 to +4.7 deg |
| 1 | 0.47 | +22 to +75 % | +5.4 to +14 deg |

Empirically, then, with OWNER_ELEMENT 0 the rho_a error is about (0.5 to 2) times h/delta, and the phase error about (11 to 40) degrees times h/delta. The largest ratios are at 0.001 Hz, where 1-3 % errors from other sources also contribute. The low end matches the h/4 argument (0.5 h/delta in rho_a, 14 degrees times h/delta in phase); the high end comes from worse elements under particular sites. Rules that follow:

- **OWNER_ELEMENT 0:** a 5 % rho_a error needs h/delta of about 0.025-0.1. At Vulcan's delta_min of 0.061 km that is a 1.5-6 m element under every site, which is not affordable for 120 sites. Do not rely on the default.
- **OWNER_ELEMENT -1 with dummy VTF stations, H taken from the air element:** this removes the first-order H error. Use the ordinary finite-element rule, **h <= delta_min/4 within about 1 delta_min of the site**, and let the test in section 9 confirm it. Nothing has measured this configuration yet; it is the first thing section 9 measures.
- h here is the edge of the frozen surface triangle holding the site (observing_site.dat circle 1, up to ALPHA = 1.5 times its target) and the depth of the element below it (obs_site.dat sphere 1). Size both.

### 6.3 Element size away from the sites and at depth

- **Between sites near the surface:** fields at a site depend on the ground within about 1-2 delta of it. At the highest frequencies, delta (60-110 m) is far below the 1 km spacing, so the site spheres carry the accuracy. The inter-site background only has to resolve the mid band: aim for L <= delta/4 at about 0.3 s (3 Hz), which is 0.17-0.2 km at Vulcan with the p10 resistivity. The 0.2 km core therefore serves periods of about 0.3 s and longer between sites.
- **At depth:** the periods that sense depth z have delta of at least about z, so a size field of **L(z) ~ 0.15-0.2 z** keeps L <= delta/5 wherever those periods matter. Keep the fine near-surface layer (0.2 km) down to the base of the conductive cover. At Vulcan that is about 0.5-1 km: the Bostick depth 0.36 sqrt(rho_a T) km at 0.3-1 s, where the phase starts to fall.
- **Parameter cells:** B(z) ~ 2 L(z), i.e. about 0.3-0.35 z (section 5).

### 6.4 Domain size versus the longest period

- The bottom (+Z) face has tangential E = 0 for both polarisations: a perfect conductor. The top of the air carries the source. On each wall, the two faces parallel to the source field get 2-D solutions and the two faces normal to it get zero tangential E (femtic/src/Forward3DTetraElement0thOrder.cpp:1909-1925).
- A half-space over a perfect conductor at depth D has Z = Z_0 tanh((1+i) D/delta), so |Z| is off by about 2 exp(-2D/delta): 3.7 % at D = 2 delta, 0.5 % at 3 delta and 0.07 % at 4 delta. **Rule: distance from the survey to every face at least 3 delta(T_max, rho_deep); 4-5 delta if cheap.** With tetrahedra it is cheap, because the padding elements are 50-100 km.
- **Air thickness** at least the horizontal half-width.
- Precedents:
  - FEMTIC's INV_MT_01 (T_max = 1000 s) uses x, y = +-524 km, air top -328 km, bottom 528 km (computed from examples/INV_MT_01/Tetra/mesh.dat).
  - femticPy AusLAMP (T up to about 16 000 s) uses +-1000 km. That is only about 1.6 delta at 100 ohm-m, so the long periods there sit on the tight side.
  - Vulcan: +-500 km is 500/123, about 4 delta_max.

### 6.5 Growth ratios

- Along a linear size ramp, the size ratio between neighbours is about 1 + |dL/ds|, where dL/ds is the ramp's gradient.
- In the Earth near sites, keep gradients at or below 0.2-0.3, i.e. growth of 1.2-1.3 per element. In the air, up to about 0.5 is acceptable because H there is smooth.
- `-q3.0` only bounds tetrahedron shape. It does not smooth a bad size field.
- The makeMtr sphere jumps (section 3.10) are about 1.4-1.5 per shell boundary, so do not stack large L ratios between successive spheres on top of that.
- The Vulcan set uses gradients of 0.13-0.2 in the Earth and at most about 0.5 in the air.

### 6.6 Parameter budget

- Data: sites x frequencies x 8. Vulcan: 120 x 53 x 8 = 50 880 real data for the 53 bands common to all sites (Vulcan/frequency_table.csv).
- Memory scales with N_param^2 for the model-space normal matrix and with N_data^2 for the data-space one, plus the N_data x N_param sensitivity.
- With about 2e4 cells and 5e4 data, the model-space method (`INV_METHOD 0`, manual.txt:73-82) builds the smaller matrix: about 3.5 GB, against about 21 GB for the data-space one.

---

## 7. femticPy's AusLAMP defaults, translated

Source: femticPy projects/auslamp/prep_inversion.ipynb cells 8, 11-12 and 19-26, plus meshGen.sh:51-54. Survey: 109 sites over 620 km (E-W) by 814 km (N-S), median nearest-neighbour spacing 44 km (18-66 km), computed from input_data/coord_auslampSA. Impedance only; the Geo2030 talk quotes 19 frequencies from 0.03125 to 0.00006 Hz (32 s to about 16 000 s). The result was **1 453 333 tetrahedra and 206 736 cells** (notebook markdown cell 32; the talk's "200k Cells").

| File | femticPy AusLAMP value | Physical meaning |
|---|---|---|
| analysis_domain | +-1000 km on x, y, z | 2000 km cube, air 1000 km thick. About 1.6 delta at 16 000 s in 100 ohm-m (tight), about 35 delta at 32 s |
| control.dat | CENTER 0 0 0, ROTATION -45; `650 50 0.35 0 0`, `2000 500 0 0 0` | Surface triangles up to 50 km inside an ellipse 650 km (NW-SE) by 422 km (NE-SW), grading linearly to 500 km at 2000 km. The vertical columns are 0, so the walls use spheres |
| observing_site.dat | 6 circles `1/0.5, 5/1, 50/15, 100/25, 150/50, 200/100` | 0.5 km triangles within 1 km of each site: delta(32 s, 10-100 ohm-m) = 9-28 km, so h/delta = 0.02-0.06 and even OWNER_ELEMENT 0 stays within about 1-11 %. 1 km at 5 km, 15 km at 50 km, 100 km at 200 km |
| obs_site.dat | 4 spheres `1/0.5/0, 10/5/0, 100/25/0, 200/100/0` | 0.5 km tetrahedra within 1 km of each site. Because of the sqrt(3) ramp, the effective size at 10 km is 3.0 km (not 5) and at 100 km is 16 km (not 25). Spheres, not flattened |
| makeMtr.param | `400 50 0 0.1 0.1`, `2000 500 0 0 0` | 50 km tetrahedra within 400 km horizontally and 360 km up and down, grading to 500 km |
| resistivity_attr.dat | `400 50 0 0`, `2000 500 0 0`; sites `10/2, 50/10, 150/25`; regions 10 air 1e9 fixed, 20 sea 0.25 fixed, 30 earth 100 ohm-m ndiv 9 | 50 km cells in the core, but **2 km cells within 10 km of every site** (about 1/20 of the spacing), 10 km at 50 km, 25 km at 150 km. Most of the 206 736 cells are near sites. ndiv 9 forces 512 count-balanced blocks first |
| seeds | air (0, 0, -40), sea (-400, -400, 0.5), earth (0, 0, 40) | The sea seed is valid only if the water at (-400, -400) is deeper than 0.5 km (section 10.2) |

The femticPy MeshGen class defaults, used when a notebook does not override them (femticPy.py:658-725), are local-scale values in the style of Usui's example:

- control.dat: 40 km radius at 1 km, out to 500 km at 50 km;
- observing_site.dat: 20 m triangles within 100 m of a site;
- obs_site.dat: 0.1 km within 0.5 km;
- resistivity_attr.dat: 2 km cells within 40 km and 12 km depth.

They are not AusLAMP values.

---

## 8. Vulcan: first-guess parameter set

### 8.1 Facts used

| Fact | Value | Source |
|---|---|---|
| Sites | 120. x (north) +-7.25 km, y (east) +-6.62 km about the bounding-box centre E 697.384 km, N 6697.44045 km (UTM 53S WGS84). Farthest site 9.55 km from the centre. Nearest-neighbour spacing 0.84-2.15 km, median 0.98 | Vulcan/site_coords_femticpy.txt, the only trusted coordinates |
| Elevation | 65-124 m; neighbour slopes of at most 2 % (1.2 deg), median 0.5 %; regional gradient 0.2 %; 9 m RMS residual about a plane | computed from the same file |
| Periods | 0.005-797 s at all 120 sites (53 bands); 998 s at 116 sites | Vulcan/frequency_table.csv |
| Data | impedance only, no tipper | Vulcan/edi_inventory.md |
| Resistivity | about 3-10 ohm-m cover; basement felt from about 0.3 s; about 50-60 ohm-m apparent at 10-1000 s | section 6.1 |

### 8.2 Design, step by step

1. **Frame.**
   - Origin at the bounding-box centre, x = north, y = east, z down, rotation 0: the grid runs N-S and E-W, and the array is almost square (14.5 by 13.2 km).
   - The coordinates must be centred (section 10.7.1).
2. **Topography: flat at z = 0.**
   - The steepest inter-site slope is 1.2 degrees. Topographic galvanic effects at that slope are far below a 5 % error floor.
   - A real surface would add a DEM, interpolation, clamping and z consistency work for no measurable gain.
   - All site z values are then 0.0 in obs_site.dat and resistivity_attr.dat. Do not use femticPy's -elevation (section 10.5).
   - Use the dummy all-land coast line and a flat topography file. Leave SEA_DEPTH out: there is no sea.
3. **Domain: +-500 km on x, y and z.**
   - About 4 delta_max (section 6.4).
   - Enlarging to +-1000 km costs only about 5e4 extra tetrahedra and is the long-period fallback.
4. **Core.**
   - A disc of radius 10.5 km covers every site, the farthest being at 9.55 km.
   - Surface and volume target 0.2 km, which is about delta/4 at 0.3 s, i.e. 3 Hz (section 6.3). The fine layer is kept to 0.5 km depth, the cover (fb = 0.952), and to 0.1 km of air (fa = 0.99).
   - Outside the core the ellipsoids grade at 0.13-0.2 km/km in the Earth: 1.2 km at 17 km radius and 8 km depth; 8 km at 50 km and 45 km depth; 100 km beyond 800 km.
   - The same 9-row table is used in control.dat and makeMtr.param, so the frozen surface and the volume agree (section 4, rule 3).
5. **Sites.**
   - Target h = 0.015 km within 30 m: about delta_min/4 (delta_min = 0.061 km at 200 Hz, p10 resistivity).
   - The volume spheres in obs_site.dat are `0.03/0.015/0`, `0.1/0.04/0.3`, `0.3/0.1/0.6`, `0.6/0.2/0.6`. Vertical reach is 30, 70, 120 and 240 m.
   - The surface circles in observing_site.dat are `0.03/0.015`, `0.1/0.027`, `0.3/0.068`, `0.6/0.14`, `0.8/0.2`. These trace the **effective** makeMtr profile (section 3.10), so the frozen surface is never coarser than the volume beneath it.
   - Cost: about 5700 extra tetrahedra per isolated site.
6. **Parameter cells.**
   - Same ellipsoid geometry, with B = 1.5 L in the top 0.5 km and 2 L below: 0.3 km cells to 0.5 km depth, 0.6 km by 1.5 km, 2.4 km by 8 km, 16 km by 45 km. That is roughly B ~ 0.3-0.36 z.
   - Site circles `0.25/0.15`, `0.8/0.3`: 150 m cells within 250 m of each site, for near-surface freedom under the high-frequency data. Two circles avoid the TetGen2Femtic extrapolation oddity.
   - ndiv = 0.
7. **Starting model.**
   - 20 ohm-m, the geometric mean of rho_det over 0.005-1000 s (the median is 22). femticPy's 100 ohm-m default is 5 times too resistive for this data.
   - Air is 1e9 ohm-m and fixed.
8. **Seeds.** Air (0, 0, -250) with attribute 10; earth (0, 0, 250) with attribute 20. This is also what scripts/run_mesh_chain.sh generates by default for two-attribute models (run_mesh_chain.sh:100-108).
9. **FEMTIC side.**
   - `MESH_TYPE 1`, `OWNER_ELEMENT -1` with a dummy VTF station at every site (manual.txt:1552-1596).
   - `INV_METHOD 0`, because there are about 2e4 cells and 5e4 data (section 6.6).

### 8.3 Literal inputs

analysis_domain.dat

```text
-500.0 500.0
-500.0 500.0
-500.0 500.0
```

control.dat

```text
CENTER
0.0 0.0 0.0
ROTATION
0.0
ELLIPSOIDS
9
10.5 0.2 0.0 0.952 0.99
11.5 0.35 0.0 0.87 0.965
13.0 0.6 0.0 0.73 0.92
17.0 1.2 0.0 0.53 0.82
25.0 3.0 0.0 0.28 0.6
50.0 8.0 0.0 0.1 0.4
120.0 20.0 0.0 0.0 0.25
300.0 50.0 0.0 0.0 0.0
800.0 100.0 0.0 0.0 0.0
NUM_THREADS
8
SURF_MESH
ITER_MAX
60 0
INTERPOLATE
100.0
3
1e-06
ALTITUDE
topography.dat
0.0
10000000000.0
END
```

ITER_MAX is raised from 30 to 60 so that refining from about 100 km boundary edges down to 15 m cannot silently stop short (section 3.3). The run ends as soon as no point is inserted, so the extra headroom costs nothing.

coast_line.dat (all land)

```text
1
-501.0 -501.0 0 0
-501.0 501.0 0 0
501.0 501.0 0 0
501.0 -501.0 1 0
```

topography.dat: a 43 x 43 grid at 25 km spacing over +-525 km, every value 0.0. Every node then has data within the 100 km radius.

makeMtr.param

```text
0.0 0.0 0.0
0.0
9
10.5 0.2 0.0 0.952 0.99
11.5 0.35 0.0 0.87 0.965
13.0 0.6 0.0 0.73 0.92
17.0 1.2 0.0 0.53 0.82
25.0 3.0 0.0 0.28 0.6
50.0 8.0 0.0 0.1 0.4
120.0 20.0 0.0 0.0 0.25
300.0 50.0 0.0 0.0 0.0
800.0 100.0 0.0 0.0 0.0
0
```

observing_site.dat (the first site shown, A1; 120 lines, then `0`)

```text
120
-1.69695 -6.6224 5 0.03 0.015 0.1 0.027 0.3 0.068 0.6 0.14 0.8 0.2
...
0
```

obs_site.dat (per site: `x y 0.0`, `4`, then 4 rows; `0` at the end)

```text
120
-1.69695 -6.6224 0.0
4
0.03 0.015 0.0
0.1 0.04 0.3
0.3 0.1 0.6
0.6 0.2 0.6
...
0
```

resistivity_attr.dat

```text
2
10 1000000000.0 -1 1
20 20.0 0 0
0.0 0.0 0.0
0.0
9
10.5 0.3 0.0 0.952
11.5 0.6 0.0 0.87
13.0 1.2 0.0 0.73
17.0 2.4 0.0 0.53
25.0 6.0 0.0 0.28
50.0 16.0 0.0 0.1
120.0 40.0 0.0 0.0
300.0 100.0 0.0 0.0
800.0 300.0 0.0 0.0
120
-1.69695 -6.6224 0.0
2
0.25 0.15
0.8 0.3
...
```

Region seeds (Part 4 of output.poly; or region_seeds.dat, `x y z attr maxvol`, for scripts/run_mesh_chain.sh):

```text
2
1 0.0 0.0 -250.0 10 1e9
2 0.0 0.0 250.0 20 1e9
```

The generator below writes all of these from the `vulcan_first_guess` JSON block at the end of this file. It was checked on 2026-09-25 by writing the 120-site files to a scratch directory; the output matched the listings above (site coordinates are shown rounded there) and contained no CR characters.

```python
# python write_vulcan_inputs.py docs/mesh_tetra_pipeline.md Vulcan/site_coords_femticpy.txt RUN_DIR
import json, os, re, sys
import numpy as np
src, site_file, out = sys.argv[1:4]
txt = open(src, encoding="utf-8").read()
if src.endswith(".md"):
    txt = re.findall(r"```json\n(.*?)\n```", txt, flags=re.S)[-1]
g = json.loads(txt); os.makedirs(out, exist_ok=True)
ids, east, north = [], [], []
for line in open(site_file, encoding="utf-8"):
    p = line.split()
    if len(p) >= 3: ids.append(p[0]); east.append(float(p[1])); north.append(float(p[2]))
o = g["frame"]["origin_utm53s_wgs84_km"]
x = np.array(north) - o["north"]; y = np.array(east) - o["east"]; z = np.full(len(x), float(g["frame"]["site_z_km"]))
dom = g["analysis_domain"]
assert all(lo < 0 < hi for lo, hi in dom.values()), "domain must straddle 0 on every axis"
assert dom["x"][0] < x.min() and x.max() < dom["x"][1] and dom["y"][0] < y.min() and y.max() < dom["y"][1]
def w(name, lines):
    with open(os.path.join(out, name), "w", newline="\n") as f: f.write("\n".join(lines) + "\n")
def row(v): return " ".join(repr(float(a)) for a in v)
w("analysis_domain.dat", [row(dom[k]) for k in ("x", "y", "z")])
c = g["control_dat"]; ip = c["INTERPOLATE"]; al = c["ALTITUDE"]
L = ["CENTER", row(c["CENTER"]), "ROTATION", row([c["ROTATION"]]), "ELLIPSOIDS", str(len(c["ELLIPSOIDS"]))]
L += [row(e) for e in c["ELLIPSOIDS"]] + ["NUM_THREADS", str(int(c["NUM_THREADS"]))] + (["SURF_MESH"] if c["SURF_MESH"] else [])
L += ["ITER_MAX", " ".join(str(int(v)) for v in c["ITER_MAX"])]
L += ["INTERPOLATE", repr(float(ip["search_radius_km"])), str(int(ip["max_points"])), repr(float(ip["eps_km"]))]
L += ["ALTITUDE", al["file"], repr(float(al["min_km"])), repr(float(al["max_km"]))]
if c["SEA_DEPTH"]: sd = c["SEA_DEPTH"]; L += ["SEA_DEPTH", sd["file"], repr(float(sd["min_km"])), repr(float(sd["max_km"]))]
w("control.dat", L + ["END"])
cl = g["coast_line"]
w("coast_line.dat", [str(cl["boundaries"])] + [f"{row(p)} {e} {f}" for p, e, f in zip(cl["points_xy_km"], cl["end_flags"], cl["fix_flags"])])
t = g["topography"]; h, s = t["dummy_grid_half_extent_km"], t["dummy_grid_spacing_km"]
grid = np.arange(-h, h + 0.5 * s, s).tolist()
w(al["file"], [f"{a!r} {b!r} {float(t['z_km'])!r}" for a in grid for b in grid])
circ = g["observing_site_dat"]["circles"]
w("observing_site.dat", [str(len(x))] + [f"{a!r} {b!r} {len(circ)} " + " ".join(row(q) for q in circ)
  for a, b in zip(x.tolist(), y.tolist())] + [str(g["observing_site_dat"]["num_observation_lines"])])
sp = g["obs_site_dat"]["spheres"]; L = [str(len(x))]
for a, b, d in zip(x.tolist(), y.tolist(), z.tolist()): L += [f"{a!r} {b!r} {d!r}", str(len(sp))] + [row(q) for q in sp]
w("obs_site.dat", L + [str(g["obs_site_dat"]["num_observation_lines"])])
m = g["makeMtr_param"]
w("makeMtr.param", [row(m["center"]), row([m["rotation_deg"]]), str(len(m["ellipsoids"]))] + [row(e) for e in m["ellipsoids"]] + [str(m["num_sea_attributes"])])
r = g["resistivity_attr_dat"]; sc = r["site_circles"]
L = [str(len(r["regions"]))] + [f"{int(q[0])} {float(q[1])!r} {int(q[2])} {int(q[3])}" for q in r["regions"]]
L += [row(r["center"]), row([r["rotation_deg"]]), str(len(r["ellipsoids"]))] + [row(e) for e in r["ellipsoids"]] + [str(len(x))]
for a, b, d in zip(x.tolist(), y.tolist(), z.tolist()): L += [f"{a!r} {b!r} {d!r}", str(len(sc))] + [row(q) for q in sc]
w("resistivity_attr.dat", L)
w("region_seeds.dat", [f"{q[1]!r} {q[2]!r} {q[3]!r} {int(q[4])} {q[5]!r}" for q in g["region_seeds_output_poly"]["seeds"]])
print(f"wrote inputs for {len(x)} sites to {out}")
```

### 8.4 Expected size

| Quantity | Estimate | Range (factor 2) |
|---|---|---|
| Tetrahedra | **about 1.2 million** (0.68 M from the 120 site neighbourhoods, 0.51 M background) | 0.6-2.4 M |
| Parameter cells | **about 21 000** (13 000 background, 8000 from the site circles) | 10 000-42 000 |
| Earth-surface triangles | about 1e5 | - |
| Real data (53 bands) | 50 880 | - |

Method: the size functions coded in makeMtr and TetGen2Femtic, integrated over the box, then scaled by factors fitted to the AusLAMP mesh (Appendix B). This is an order-of-magnitude figure. **The mesh is too large if** output.6.ele has more than about 2.5 M elements; **it is too small if** it has fewer than about 0.5 M. Either way, compare the element sizes actually produced (ParaView on output.6.vtk) with the tables before changing any parameter.

Forward cost: FEMTIC's PARDISO factorisation for the 34 559-element example peaked at 42 MB (VALIDATION.md). Nested-dissection fill grows as N^(4/3), which suggests a few GB per factorisation at 1.2 M elements. Measure it in section 9 with one frequency before planning inversion runs.

### 8.5 Which knob to turn

| Symptom (section 9 test) | First knob | Then |
|---|---|---|
| **High-frequency failure** (rho_a high, phase high, getting worse with f) | FEMTIC `OWNER_ELEMENT -1` plus dummy VTF stations at the sites. No remesh needed (manual.txt:1552-1596) | Shrink **observing_site.dat circle 1 and obs_site.dat sphere 1 together** (e.g. 0.015 to 0.010 km). With `-Y` the triangle holding the site is frozen, so a change to obs_site.dat alone does nothing to it. If the error still exceeds the tolerance, drop or down-weight those bands. The control.dat and makeMtr.param core ellipsoids do not help at the site |
| Mid-band failure (about 0.3-10 s) | Core L 0.2 to 0.15 km in control.dat **and** makeMtr.param rows 1-2 | Deepen row 1 (fb 0.952 to 0.93, i.e. 0.74 km) |
| Long-period failure (worse towards 1000 s) | analysis_domain to +-1000 km on all axes; last ellipsoid radius 1500 km | Check the bottom resistivity of the test model |
| Too many elements | Drop obs_site sphere 1 and observing_site circle 1 (costs high-frequency accuracy) | Core L 0.2 to 0.25 km |
| Too many cells | Raise resistivity_attr rows 1-2 | Drop the site circles |

---

## 9. The forward accuracy test (gate before any inversion)

**Failure criterion, stated before running.** The mesh fails at a frequency if any site's off-diagonal rho_a differs from the half-space value by more than 5 %, or its phase differs from 45 degrees by more than 1.5 degrees. These tolerances are about half of a 5 % |Z| error floor, in rho_a and in phase.

Procedure:

1. Build the mesh, and check the attribute sets and element counts. scripts/run_mesh_chain.sh fails the chain if the tetgen attributes differ from the seeds or if the element counts or volumes disagree (run_mesh_chain.sh:155-198). Then run validation/mesh_2026-09-25/check_mesh.py on the product.
2. Make two starting models by setting every earth cell in resistivity_block_iter0.dat to one value:
   - **3 ohm-m**, the high-frequency worst case: delta(200 Hz) = 0.061 km;
   - **60 ohm-m**, the long-period and domain case: delta(1000 s) = 123 km.
3. Run FEMTIC on each model with the real observe.dat frequencies. The iteration-0 responses (result_*_iter0.csv) are the forward response of the starting model. Compare them per frequency with rho_a = rho and phase = 45 degrees, using the same method as validation/wsl_2026-09-25/scripts/halfspace_check.py.
4. Run it twice: once with OWNER_ELEMENT 0 and once with -1 plus the dummy VTF stations. The difference shows how much of the error is the H evaluation (section 6.2).
5. Turn knobs in the order of section 8.5. Do not widen the tolerance to pass. If a band cannot pass at an affordable size, record it and give that band a larger error floor, or drop it.

A layered check is optional. Put `LAYERS`, then `1`, then `0.5` on successive lines of control.dat. That gives a facet at 0.5 km, an extra closed region and an extra seed, and makes the mesh conform to a 2-layer model with its analytic 1-D answer. Without LAYERS, a layered model is represented by whichever cells straddle the interface, and that tests the parameterisation rather than the solver.

---

## 10. Known failure modes

### 10.1 Coast-line self-intersection

- **Symptom:** step 2 fails, or tetgen stops with "The input surface mesh contain self-intersections" (exit 3; tetgen/tetgen.h:2501-2503).
- **Cause:** crossing boundary curves after step 1's roughening (doc PDF p.17). Roughening removes points until segment lengths match the local target (CoastLine.cpp:263-452), so a convoluted coast can end up self-crossing.
- **Fix:**
  - Inspect boundary_curve_stp1.vtk.
  - Smooth or simplify the coast line, or use COAST_SMOOTHING.
  - Set fix_flag = 1 on critical points.
  - As a last resort, edit node_bound_curve.stp1 by hand (doc PDF p.17).
- Two close facets give exit 5, "Two very close input facets"; a tiny feature gives exit 4 (tetgen.h:2505-2515). A sea depth clamped to 0, so that the sea floor touches the sea surface, is one way to get there (section 10.7.5).
- Vulcan uses the dummy all-land boundary, so none of this applies there.

### 10.2 Region numbering 31/32 and fix_output1.py

- **Mechanism:** with `-A`, every closed sub-volume that no seed reaches gets max_attribute + 1, + 2, and so on (tetgen.cxx:24275-24307). With seeds 10, 20 and 30, stray regions become 31, 32, ...
- **Causes:**
  - A water body with no seed: a lake, or sea cut off within the domain.
  - A seed that missed its region, e.g. the AusLAMP sea seed at z = 0.5 km where the water is shallower. That seed lands in the Earth. The whole Earth then takes the sea attribute, the Earth seed relabels one tetrahedron, and the real sea becomes 31 (tetgen.cxx:24235-24270).
  - A seed outside the hull, which gets a warning (23849-23853).
  - SEDIMENT or LAYERS slabs with no seed.
- **fix_output1.py** rewrites output.1.ele, clamping every attribute above 30 to 30 (femticPy/scripts/fix_output1.py:26). The notebooks call it a temporary fix whose cause is unknown (prep_inversion.ipynb markdown cell 31). It is right only if every stray region really is earth. In the second cause above it silently turns sea into earth. In a land-only 10/20 model it cannot catch strays at all, because 21 is not above 30. TetGen2Femtic then stops with "Region attiribute ... cannot be found" (MeshData.cpp:1903-1905).
- **Fix instead:**
  - Seed every closed region.
  - Run tetgen with `-V` and read "Found N subdomains" (tetgen.cxx:24328-24335).
  - Require the attribute set in output.1.ele to equal the seed set, as run_mesh_chain.sh:155-157 does.
  - The script also needs pandas below 3 (`delim_whitespace`), and it drops the trailing `# Generated by` line.

### 10.3 CRLF line endings

- The C++ readers tolerate `\r`: stream `>>` treats it as whitespace, and tetgen's number scanner skips it (tetgen.cxx:2894-2948). **Shell steps do not.**
- femticPy's scripts are CRLF in this clone (`file` reports "with CRLF line terminators" for meshGen.sh, create_mesh.sh and fix_output1.py).
- A CRLF meshGen.sh breaks in a sneaky way: `echo "..." >> output.poly\r` appends the seeds to a **new file** called `output.poly\r`. output.poly keeps 0 regions, tetgen then numbers the regions 1, 2, ..., and TetGen2Femtic stops on an unknown attribute.
- `sed` patterns such as `s/^1$/2/` do not match `1\r`. This project hit exactly that when editing FEMTIC's control.dat (VALIDATION.md, "Aborted first attempt").
- femticPy run on Windows writes CRLF text files, because Python's `open(..., 'w')` translates newlines.
- **Rules:**
  - Keep scripts and inputs LF-only; check with `grep -c $'\r' file`.
  - Write files with `newline="\n"`.
  - Run the chain on ext4 inside WSL.
  - scripts/run_mesh_chain.sh converts its inputs (run_mesh_chain.sh:84-86).

### 10.4 Sites outside the domain, wrong axis order, uncentred coordinates

- A site outside every surface triangle stops FEMTIC with "Could not find element including point" (femtic/src/MeshDataTetraElement.cpp:465-466). The mesh tools do not check. A site outside the domain simply gets no refinement.
- The dangerous cases raise **no error at all**:
  - x and y swapped (east first): every site stays inside the symmetric domain, but refinement lands on the mirror-image positions;
  - metres entered as km;
  - raw UTM coordinates (section 10.7.1).
- **Check:** plot obs_loc.vtk from a FEMTIC run over surface_triangle.laplacian_last.vtk. Every site must sit inside its own refined patch.

### 10.5 Sites below (or above) the topography

- FEMTIC projects each station onto the mesh surface by (X, Y), so a wrong site z never reaches FEMTIC (section 3.12). **It does reach makeMtr and TetGen2Femtic.** A sphere 30 m in radius centred 100 m above the surface refines nothing where it is needed.
- **For Vulcan with femticPy as written, this happens.** femticPy writes z = -elevation, i.e. -0.065 to -0.124 km (femticPy.py:222, 787, 882). On a flat mesh at z = 0 that puts all four of each site's obs_site spheres (vertical reach 30-240 m) partly or wholly in the air.
- With real topography, the surface is the interpolated and clamped one: land cannot go below the ALTITUDE minimum (TriangleList.cpp:2126-2131). A GPS elevation is not the mesh z.
- **Rule:** write the mesh-surface z at the site. For a flat surface that is 0.0.

### 10.6 tetgen -Y preserves the boundary

- `-Y` forbids Steiner points on input facets and segments: the boundary splitting in Delaunay refinement is skipped (tetgen.cxx:3167-3186, 29187-29194, 29377-29551). Every surface and wall triangle from makeTetraMesh therefore ends up unchanged in mesh.dat, in both the first run and the five `-r` refinements.
- **Consequences:**
  1. Surface resolution, including the triangle that holds each site, comes only from control.dat and observing_site.dat.
  2. A surface coarser than the local .mtr value can never pass the metric test (section 4, rule 3).
  3. Poorly shaped makeTetraMesh triangles become poorly shaped tetrahedra that tetgen cannot repair.
  4. If boundary recovery needs a boundary Steiner point, tetgen stops (exits 3 and 5) instead of quietly altering the surface. That is deliberate: it guarantees the Earth-surface face list matches the PLC.
- Do not remove `-Y` to "fix" a failure. Fix the PLC.

### 10.7 Other traps found in the source

1. **Domain not straddling 0.** Outer faces are classified by coordinate sign (MeshData.cpp:1545-1575). With raw UTM coordinates both x faces become +X, and the boundary conditions are wrong with no error.
2. **control.dat layout.** Keyword alone on its line; CENTER, ROTATION and ELLIPSOIDS first; no keyword substrings in file names (section 3.1).
3. **ITER_MAX cap.** "Reach maximum interation number" in makeTetraMesh.log means the surface is under-refined (TriangleList.cpp:3054). Search the log for it and for "Error" and "Warning : No topography data" after every step.
4. **femticPy centre z sign.** `median_elevation = -median(mt_coords['z'])`, and mt_coords z is already -elevation, so the ellipsoid centre goes below the surface by the median elevation (femticPy.py:651-652; the mmt notebook repeats the pattern). Harmless at 100 m; a 13 km error for the 6.5 km-deep marine example. Set the centre explicitly.
5. **femticPy `%4.1f` formatting in control.dat** (femticPy.py:750-762).
   - INTERPOLATE's point count is written as `3.0`. `>>` into an int reads 3, and then **reads `.0` as the epsilon = 0**, so the written 1e-6 is lost. Any node lying exactly on a data point divides by zero (TopographyData.cpp:416).
   - The SEA_DEPTH minimum 0.01 is written as `0.0`. Sea nodes may then sit on the sea surface (section 10.1).
   - Write the integer as an integer and use `%g`.
6. **ndiv < 0 for a subsurface region.** Its faces become "Earth surface" faces (section 3.11).
7. **Non-nested ellipsoids.** makeTetraMesh does not check the short horizontal axis. It aborts later with a transition-region error (Ellipsoids.cpp:267-283).
8. **Seed at a region boundary or in the wrong region.** See section 10.2. Never place two seeds in one region.
9. **resistivity_attr.dat line 2 is not the air.** TetGen2Femtic exits (MeshData.cpp:579-586).
10. **femticPy frequency format.** Frequencies are written as `%.5f` (femticPy.py:385). 1.57e-4 Hz becomes 0.00016, 2 % off, and 6.3e-5 Hz becomes 0.00006, 5 % off. Irrelevant up to 1000 s (0.001 Hz, written 0.00100), but check before inverting longer periods.

---

## 11. Checklist before a mesh goes to FEMTIC

- [ ] Every input is LF-only; the coordinates are centred; x = north.
- [ ] makeTetraMesh.log for steps 1-4 contains no "Error" and no "Reach maximum interation number", and echoes the ELLIPSOIDS you intended.
- [ ] output.poly's last block holds your seeds; `tetgen -V` reports the expected number of subdomains; the attribute set in output.1.ele and output.6.ele equals the seed set, which equals the resistivity_attr.dat set.
- [ ] The obs_site.dat and resistivity_attr.dat site z equals the mesh-surface z.
- [ ] mesh.dat node extents equal analysis_domain; the element volumes sum to the box; no degenerate elements (check_mesh.py).
- [ ] resistivity_block_iter0.dat: block 0 is the air and fixed; the cell count is in the planned range.
- [ ] In a FEMTIC run, obs_loc.vtk falls on the refined patches.
- [ ] The section 9 half-space test passes at every frequency you invert, or its failures are recorded with the matching error floors.

---

## Appendix A. tetgen switches used by the chain

`tetgen -nVpYAakq3.0/0 output.poly` (the first mesh) and `tetgen -nmpYVrAakq3.0/0 output.i` (refinement), decoded against tetgen/tetgen.cxx (syntax list at 2965-3001):

| Switch | Meaning | Code | Why the chain needs it |
|---|---|---|---|
| `n` | Write the .neigh file | 3422-3423 | TetGen2Femtic reads .neigh (MeshData.cpp:324-375) |
| `V` | Verbose | 3596-3597 | Prints "Found N subdomains" (24328-24335) |
| `p` | Tetrahedralise a PLC | 3107 | Reads output.poly. With `-r` it is effectively a no-op: surface meshing and boundary recovery run only when `plc && !refine` (36165, 36203) |
| `Y` | Preserve the input surface mesh | 3167-3186 | Keeps the makeTetraMesh surface, so the Earth-surface faces are exactly the PLC's (section 10.6) |
| `A` | Region attributes from the seeds; unseeded closed regions get max + 1, ... | 3374-3375, 24218-24336 | Attributes drive resistivity_attr.dat. **Ignored with `-r`** (3727-3729); element attributes are carried over from .ele |
| `a` | No number: per-region volume bound from each seed's 6th field; with `-r`, a .vol file if present | 3356-3373, 28380-28385 | 1e9 means no bound. `-a` also switches on `-q` (3735-3743) |
| `k` | Write .vtk for ParaView | 3426-3433 | output.N.vtk |
| `q3.0/0` | Radius-edge ratio <= 3.0 (default 2.0), minimum dihedral angle 0 (default 3.5 deg, which disables the dihedral test) | 3216-3244; tetgen.h:811, 814 | A looser quality bound than the default. With a frozen surface it avoids runaway refinement next to small boundary triangles |
| `m` | Apply the sizing function in output.i.mtr: split a tetrahedron while its circumradius exceeds the .mtr value at any vertex | 3341-3355, 28391-28402 | Makes makeMtr's field effective |
| `r` | Reconstruct and refine an existing mesh; loads .node, .ele, then .face, .edge, .vol, .var, .mtr | 3187-3215, 2462-2487 | Each round refines the previous mesh |

Not used, and must not be used:

- `-B` suppresses the boundary markers that TetGen2Femtic requires (MeshData.cpp:397-402).
- `-z` numbers from 0, but makeMtr and TetGen2Femtic require numbering from 1 (makeMtr/src/main.cpp:461-464; MeshData.cpp:229-232, 303-306).

## Appendix B. How the size estimates were made

- The size functions were re-implemented exactly as coded:
  - the ellipsoid ray interpolation;
  - the makeMtr site spheres with the sqrt(3) term;
  - the TetGen2Femtic cell length with the min-over-segments rule.
- N_tet was taken as C_t times the integral of dV / L^3, and N_cell as C_c times the integral over the Earth of dV / B^3. The integration used a graded tensor grid for the background, and spherical grids of Voronoi-owned points around each site.
- The constants were fitted on the femticPy AusLAMP run: 109 sites, notebook parameters, 1 453 333 tetrahedra, 206 736 cells. That gave C_t = 7.67 (the mean tetrahedron volume is about 0.13 L^3, i.e. mean edge about L) and C_c = 1.28.
- One calibration point, and a mesh 1000 times larger in scale, so treat Vulcan's numbers as good to about a factor of 2.
- The estimator (size_estimator.py) and the EDI scan used for section 6.1 were scratch scripts; rerun them after the first real mesh and replace these estimates with measured counts.

## vulcan_first_guess

The Vulcan first-guess parameter set of section 8, in machine-readable form. It is the last fenced block tagged `json` in this file, and the generator in section 8.3 loads it with the regex shown there (a script can do the same). Lengths are in km, angles in degrees, resistivities in ohm-m. Ellipsoid rows follow the column lists given next to them.

```json
{
  "schema": "femtic-tetra-mesh-first-guess/1",
  "survey": "Vulcan, Stuart Shelf SA: 120 MT sites, impedance only, periods 0.005-1000 s",
  "status": "first guess, not yet meshed or forward-tested; gate on the half-space forward accuracy test before inverting",
  "units": {"length": "km", "resistivity": "ohm-m", "angle": "deg"},
  "frame": {
    "axes": "x = north, y = east, z = down (positive below the flat surface)",
    "origin_utm53s_wgs84_km": {"east": 697.384, "north": 6697.44045},
    "origin_rule": "centre of the site bounding box (femticPy DataGen.center_data)",
    "site_source": "Vulcan/site_coords_femticpy.txt (columns id east_km north_km elev_km)",
    "site_x_km": "north_km - 6697.44045",
    "site_y_km": "east_km - 697.384",
    "site_z_km": 0.0,
    "site_extent_km": {"x": [-7.255, 7.255], "y": [-6.622, 6.622], "max_radius": 9.55, "nn_spacing_median": 0.98}
  },
  "topography": {"type": "flat", "z_km": 0.0, "reason": "site elevations 65-124 m, max inter-site slope 2 % (1.2 deg), regional gradient 0.2 %", "dummy_grid_spacing_km": 25.0, "dummy_grid_half_extent_km": 525.0},
  "coast_line": {"type": "dummy all-land", "boundaries": 1, "points_xy_km": [[-501.0, -501.0], [-501.0, 501.0], [501.0, 501.0], [501.0, -501.0]], "end_flags": [0, 0, 0, 1], "fix_flags": [0, 0, 0, 0]},
  "analysis_domain": {"x": [-500.0, 500.0], "y": [-500.0, 500.0], "z": [-500.0, 500.0]},
  "control_dat": {
    "CENTER": [0.0, 0.0, 0.0],
    "ROTATION": 0.0,
    "NUM_THREADS": 8,
    "SURF_MESH": true,
    "ITER_MAX": [60, 0],
    "ELLIPSOIDS_columns": ["radius_x_km", "max_edge_km", "oblateness_horizontal", "oblateness_below_centre", "oblateness_above_centre"],
    "ELLIPSOIDS": [
      [10.5, 0.2, 0.0, 0.952, 0.99],
      [11.5, 0.35, 0.0, 0.87, 0.965],
      [13.0, 0.6, 0.0, 0.73, 0.92],
      [17.0, 1.2, 0.0, 0.53, 0.82],
      [25.0, 3.0, 0.0, 0.28, 0.6],
      [50.0, 8.0, 0.0, 0.1, 0.4],
      [120.0, 20.0, 0.0, 0.0, 0.25],
      [300.0, 50.0, 0.0, 0.0, 0.0],
      [800.0, 100.0, 0.0, 0.0, 0.0]
    ],
    "INTERPOLATE": {"search_radius_km": 100.0, "max_points": 3, "eps_km": 1.0e-6},
    "ALTITUDE": {"file": "topography.dat", "min_km": 0.0, "max_km": 1.0e10},
    "SEA_DEPTH": null
  },
  "observing_site_dat": {
    "circles_columns": ["radius_km", "max_edge_km"],
    "circles": [[0.03, 0.015], [0.1, 0.027], [0.3, 0.068], [0.6, 0.14], [0.8, 0.2]],
    "num_observation_lines": 0
  },
  "makeMtr_param": {
    "center": [0.0, 0.0, 0.0],
    "rotation_deg": 0.0,
    "ellipsoids_columns": ["radius_x_km", "max_edge_km", "oblateness_horizontal", "oblateness_below_centre", "oblateness_above_centre"],
    "ellipsoids": [
      [10.5, 0.2, 0.0, 0.952, 0.99],
      [11.5, 0.35, 0.0, 0.87, 0.965],
      [13.0, 0.6, 0.0, 0.73, 0.92],
      [17.0, 1.2, 0.0, 0.53, 0.82],
      [25.0, 3.0, 0.0, 0.28, 0.6],
      [50.0, 8.0, 0.0, 0.1, 0.4],
      [120.0, 20.0, 0.0, 0.0, 0.25],
      [300.0, 50.0, 0.0, 0.0, 0.0],
      [800.0, 100.0, 0.0, 0.0, 0.0]
    ],
    "num_sea_attributes": 0
  },
  "obs_site_dat": {
    "spheres_columns": ["radius_km", "max_edge_km", "vertical_oblateness"],
    "spheres": [[0.03, 0.015, 0.0], [0.1, 0.04, 0.3], [0.3, 0.1, 0.6], [0.6, 0.2, 0.6]],
    "num_observation_lines": 0
  },
  "region_seeds_output_poly": {
    "columns": ["index", "x_km", "y_km", "z_km", "region_attribute", "max_volume_km3"],
    "seeds": [[1, 0.0, 0.0, -250.0, 10, 1.0e9], [2, 0.0, 0.0, 250.0, 20, 1.0e9]]
  },
  "tetgen": {"initial": "-nVpYAakq3.0/0", "refine": "-nmpYVrAakq3.0/0", "refinement_rounds": 5, "final_mesh": "output.6"},
  "resistivity_attr_dat": {
    "regions_columns": ["attribute", "resistivity_ohmm", "ndiv", "ifix"],
    "regions": [[10, 1.0e9, -1, 1], [20, 20.0, 0, 0]],
    "center": [0.0, 0.0, 0.0],
    "rotation_deg": 0.0,
    "ellipsoids_columns": ["radius_x_km", "max_cell_length_km", "oblateness_horizontal", "oblateness_vertical"],
    "ellipsoids": [
      [10.5, 0.3, 0.0, 0.952],
      [11.5, 0.6, 0.0, 0.87],
      [13.0, 1.2, 0.0, 0.73],
      [17.0, 2.4, 0.0, 0.53],
      [25.0, 6.0, 0.0, 0.28],
      [50.0, 16.0, 0.0, 0.1],
      [120.0, 40.0, 0.0, 0.0],
      [300.0, 100.0, 0.0, 0.0],
      [800.0, 300.0, 0.0, 0.0]
    ],
    "site_circles_columns": ["radius_km", "max_cell_length_km"],
    "site_circles": [[0.25, 0.15], [0.8, 0.3]],
    "starting_resistivity_basis": "geometric mean 20 ohm-m (median 22) of det apparent resistivity over 0.005-1000 s, all 120 EDIs"
  },
  "TetGen2Femtic_args": "",
  "femtic_control_recommendations": {
    "MESH_TYPE": 1,
    "OWNER_ELEMENT": -1,
    "observe_dat": "one dummy VTF station (0 frequencies, owner type 1) at every MT site; MT station owner type 0 with its H-station ID set to the dummy ID (manual.txt:1552-1596)",
    "INV_METHOD": 0,
    "INV_METHOD_reason": "about 2e4 cells < about 5e4 data, so the model-space normal matrix is the smaller one"
  },
  "design_basis": {
    "T_min_s": 0.005,
    "T_max_s": 1000.0,
    "rho_det_hf_p10_median_p90_ohmm": [2.9, 4.8, 9.9],
    "delta_min_km": 0.06,
    "rho_det_long_period_median_ohmm": 60.0,
    "delta_max_km": 123.0,
    "site_surface_edge_over_delta_min": 0.25,
    "domain_over_delta_max": 4.1,
    "cell_to_tet_size_ratio_below_1p5km": 2.0,
    "tet_size_vs_depth": "about 0.15-0.18 z below 3 km",
    "cell_size_vs_depth": "about 0.3-0.36 z below 3 km"
  },
  "expected_size": {
    "tetrahedra": 1.2e6,
    "tetrahedra_range": [6.0e5, 2.4e6],
    "tetrahedra_split": {"near_sites": 6.8e5, "background": 5.1e5},
    "parameter_cells": 2.1e4,
    "parameter_cells_range": [1.0e4, 4.2e4],
    "earth_surface_triangles": 1.0e5,
    "method": "integral of dV/L^3 over the size functions coded in makeMtr and TetGen2Femtic, scaled by factors fitted to the femticPy AusLAMP mesh (1,453,333 tets, 206,736 cells); treat as +-factor 2"
  },
  "knobs": {
    "forward_test_fails_at_high_frequency": [
      "1: FEMTIC OWNER_ELEMENT -1 with dummy VTF stations so H comes from the air element (no remesh)",
      "2: shrink observing_site.dat circle 1 AND obs_site.dat sphere 1 together (e.g. 0.015 -> 0.01 km edge); tetgen -Y freezes the surface triangle holding the site",
      "3: drop or down-weight the bands that still fail"
    ],
    "forward_test_fails_at_long_period": ["enlarge analysis_domain to +-1000 km on all three axes and extend the last ellipsoid radius to 1500 km"],
    "forward_test_fails_at_mid_period_0p3_to_10_s": ["reduce max_edge of control/makeMtr ellipsoids 1-2 (0.2 -> 0.15 km) and deepen ellipsoid 1 (oblateness_below_centre 0.952 -> 0.93)"],
    "too_many_elements": ["drop obs_site sphere 1 and observing_site circle 1", "raise core edge 0.2 -> 0.25 km"],
    "too_many_parameters": ["raise resistivity_attr ellipsoid 1-2 cell lengths", "shrink or drop site_circles"]
  }
}
```
