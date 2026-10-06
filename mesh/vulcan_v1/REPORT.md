<!-- Saved by the session from the mesh-vulcan-v1 agent's return value on 2026-09-25; the agent was blocked from writing this file itself. -->

# Vulcan tetrahedral mesh v1: build report (2026-09-25)

**The chain succeeded on the first run (CHAIN OK), and every check passed.** It took 257.5 s of wall time (4 min 18 s) and peaked at 584 MB. No input had to change, so `config/vulcan_mesh_v1.yml` was not edited and `prep_vulcan.py` was not re-run.

| quantity | value |
|---|---|
| nodes | 251,875 |
| tetrahedra | 1,534,902 (689,949 air, 844,953 earth) |
| edges (about the number of FEMTIC unknowns) | 1,788,054 |
| parameter cells | 55,993 (cell 0 = air at 1e9 ohm-m, fixed; 55,992 earth cells at 20 ohm-m) |
| earth-surface triangles | 144,316 (106,692 inside the site footprint) |
| outer boundary faces | 2,556 |

**Fitness for 200 Hz to 1000 s (geometric judgement only; section 6):**
- **Long periods:** every criterion passes from 1000 s to 10 s in 3 ohm-m ground, and from 1000 s to 0.3 s in 100 ohm-m.
- **Around 1 s:** at Vulcan's real resistivities (p10 at least 10 ohm-m for T >= 1 s), the mesh is fit down to about 1 s.
- **3 to 100 Hz:** conditional. At every site, the triangle containing it (12 m) and the earth element under it (7-19 m deep) pass. However, in 3 ohm-m ground the volume within one skin depth of the sites is only about delta/4 to delta/3. The volume between sites at depth delta is 0.5 to 1 delta.
- **200 Hz in 3 ohm-m:** not fit. This band is not in observe.dat, which stops at 100 Hz.
- **The deciding test** is the half-space forward test in section 9 of `docs/mesh_tetra_pipeline.md`. It has not been run.

**Two numbers that change the plan:**
1. **There are 55,992 earth cells**, against an estimate of 21,000 (guide range 10,000 to 42,000). That is 2.7 times the estimate and 2.8 times the 20,160 data values.
   - Keep `INV_METHOD 1` (data space); `inversion/control.dat` already sets it. The data-space normal matrix is 3.3 GB; the model-space one would be 25 GB.
   - The sensitivity matrix (20,160 x 55,992) takes about 9.0 GB in double precision.
2. **There are 1.53 M tetrahedra**, against an estimate of 1.2 M (range 0.6 to 2.4 M). That is in range.

## 1. Inputs

- **Files:** `mesh/vulcan_v1/files/`, generated from `config/vulcan_mesh_v1.yml` (sha256 5d00fe5e...). md5 sums are in `mesh_logs/input_md5.txt`.
- **Sites and surface:** 120 sites on a flat surface at z = 0.
- **Domain:** +/-500 km in x, y and z.
- **Frame:** x = north, y = east, z points down. The origin is E 697.384 km, N 6697.44045 km (UTM 53S).
- **Region seeds:** air at (0, 0, -250) with attribute 10; earth at (0, 0, 250) with attribute 20.

## 2. Commands

I ran these from Git Bash. The run directory is on ext4 at `/home/tara/femtic_wsl/mesh_runs/vulcan_v1/`. S is the scratchpad `wsl_scripts` directory; copies of the scripts are in `mesh_logs/scripts/`.

```bash
wsl.exe -d Ubuntu -- bash -c "sed 's/\r$//' $S/v1_run.sh > /home/tara/femtic_wsl/mesh_runs/v1_run.sh && bash /home/tara/femtic_wsl/mesh_runs/v1_run.sh vulcan_v1 5"
wsl.exe -d Ubuntu -- bash -c "sed 's/\r$//' $S/v1_post.sh > /home/tara/femtic_wsl/mesh_runs/v1_post.sh && bash /home/tara/femtic_wsl/mesh_runs/v1_post.sh"
wsl.exe -d Ubuntu -- bash -c "sed 's/\r$//' $S/v1_copyback.sh > /home/tara/femtic_wsl/mesh_runs/v1_copyback.sh && bash /home/tara/femtic_wsl/mesh_runs/v1_copyback.sh"
```

**`v1_run.sh`**
- Copies `files/*` into the run directory.
- Runs the **unmodified** chain script:
  ```bash
  FEMTIC_BIN=$RUN/timewrap_bin /usr/bin/time -v -o chain_total.timev \
    bash /mnt/d/BEN/FEMTIC_2026/scripts/run_mesh_chain.sh $RUN 5
  ```
- `timewrap_bin/` holds one wrapper each for makeTetraMesh, tetgen, makeMtr and TetGen2Femtic. Each wrapper runs `exec /usr/bin/time -v` on the real binary, so every tool call gets a full `-v` record in `mesh_logs/timev/`. The chain's own checks are untouched.

**What the chain executed:**
```bash
makeTetraMesh -stp 1; makeTetraMesh -stp 2; makeTetraMesh -stp 3; makeTetraMesh -stp 4
# the last line of output.poly ("0") becomes "2", followed by "1 0 0 -250 10 1000000000" and "2 0 0 250 20 1000000000"
tetgen -nVpYAakq3.0/0 output.poly
for i in 1 2 3 4 5; do makeMtr output.$i; tetgen -nmpYVrAakq3.0/0 output.$i; done
TetGen2Femtic output.6
```

**`v1_post.sh`** (femticpy conda env):
```bash
python validation/mesh_2026-09-25/check_mesh.py $RUN --flat-surface-z 0
python scripts/mesh_stats.py $RUN --observe mesh/vulcan_v1/inversion/observe.dat \
  --station-map mesh/vulcan_v1/inversion/station_map.csv --surface-z 0 --json $RUN/logs/mesh_stats.json
```
After that, `v1_xcheck.py` runs an independent check of where each site lands (section 4).

## 3. Timings and memory

All figures come from `/usr/bin/time -v`, and every step exited with code 0.

| step | wall (s) | CPU % | peak RSS (MB) | mesh after the step (nodes / tets) |
|---|---:|---:|---:|---|
| makeTetraMesh -stp 1 | 0.01 | 33 | 4.7 | |
| makeTetraMesh -stp 2 | 5.57 | 100 | 24.1 | |
| makeTetraMesh -stp 3 (8 OpenMP threads) | 0.83 | 525 | 24.5 | |
| makeTetraMesh -stp 4 | 0.43 | 100 | 36.4 | |
| tetgen -nVpYAakq3.0/0 output.poly | 17.51 | 100 | 450.0 | 95,608 / 528,045 |
| round 1: makeMtr + tetgen -r | 0.25 + 27.74 | 100 | 40.6 / 472.7 | 217,613 / 1,322,413 |
| round 2: makeMtr + tetgen -r | 0.87 + 41.74 | 100 | 93.1 / **584.2** | 256,299 / 1,562,977 |
| round 3: makeMtr + tetgen -r | 1.54 + 46.15 | 100 | 109.4 / 574.3 | 244,929 / 1,491,519 |
| round 4: makeMtr + tetgen -r | 1.27 + 49.12 | 100 | 104.8 / 582.9 | 255,483 / 1,557,588 |
| round 5: makeMtr + tetgen -r | 1.31 + 45.36 | 100 | 109.1 / 581.5 | 251,875 / 1,534,902 |
| TetGen2Femtic output.6 | 8.79 | 104 | 160.6 | |
| **whole chain, including its checks** | **257.5** | 102 | **584.2** | |
| check_mesh.py | 3.7 | 133 | 1,364 | |
| mesh_stats.py (final run) | 13.8 | 114 | 1,132 | |

Notes:
- **tetgen dominates:** 228 of the 258 s, and it is single-threaded.
- **Refinement plateaus:** the element count stays within +/-3 % from output.3 onward, so rounds 3 to 5 cost about 145 s for no net change. Three rounds are enough while iterating on the design; keep five for the final mesh.
- **Step 2 converged:** it stopped after 21 of its 60 allowed iterations.
- **Logs are clean:** no makeTetraMesh log contains "Error", "Warning" or "Reach maximum interation number". tetgen reported "Found 2 subdomains".
- **Stale row in the timing table:** the mesh_stats row in `mesh_logs/timev_table.tsv` (9.9 s) comes from the first stats run. The final run is in `mesh_logs/mesh_stats.timev`.

## 4. Checks

Each check states how it would fail. All of them passed.

**Chain script checks:**
- **Tool exits:** every tool exited 0 and every product exists.
- **Region attributes:** the attribute set is exactly {10, 20} in both output.1.ele and output.6.ele. output.1 has 263,927 air and 264,118 earth tetrahedra.
- **Air on top:** of the 1,185 elements touching the top plane, 0 are not air. Of the 1,179 touching the bottom plane, 0 are air.
- **Counts:** the counts in output.6, mesh.dat and the resistivity block all agree.
- **Volume:** the element volumes sum to the box volume (1e9 km^3) with a relative error of 5.5e-14.

**check_mesh.py: 17/17 PASS.**
- No degenerate element (the smallest volume is 11.9 m^3), and all elements have the same orientation.
- The neighbour relation is symmetric.
- The surface faces tile 1000 x 1000 km at z = 0.
- Every element is air above z = 0 and earth below it, and the air and earth volumes are exactly half the box each.
- No parameter cell is empty. Cell 0 is 1e9 ohm-m and fixed, and every earth cell is free.

**v1_xcheck.py** checks the site locations independently of mesh_stats.py.
- **Failure criterion:** it fails if matplotlib's trifinder disagrees about any site's triangle, if it finds a point outside the domain, or if random points in the array do not see triangles more than twice as large as the sites do.
- **Result: PASS.** The trifinder agrees for 120 of 120 sites, and the outside point returns -1.
- Site triangles have a median maximum edge of 12.2 m, against 114.7 m for random points.

## 5. Mesh statistics (`scripts/mesh_stats.py`; lengths in km)

"Footprint" means the convex hull of the sites: x from -7.25 to 7.25 km, y from -6.62 to 6.62 km. "Within r of a site" is the horizontal distance from an edge midpoint or element centroid to the nearest site.

### 5.1 Measured counts against the design estimate (guide section 8.4)

| quantity | measured | estimate (range) | status |
|---|---:|---:|---|
| tetrahedra | 1,534,902 | 1.2 M (0.6-2.4 M) | in range |
| earth parameter cells | **55,992** | 21,000 (10,000-42,000) | **above range, 2.7 times the estimate** |
| earth-surface triangles | 144,316 | about 1e5 | as expected |

### 5.2 Edge lengths at the surface

**Earth-surface triangle edges.** tetgen's -Y flag keeps the surface exactly as makeTetraMesh built it.

| region | n edges | min | median | max |
|---|---:|---:|---:|---:|
| all | 216,498 | 0.0055 | 0.050 | 116.7 |
| inside the footprint | 160,026 | 0.0055 | 0.037 | 0.222 |
| within 0.5 km of a site | 158,818 | 0.0055 | 0.034 | 0.132 |
| within 0.1 km of a site | 49,766 | 0.0055 | 0.017 | 0.031 |
| within 0.03 km of a site | 10,735 | 0.0061 | 0.012 | 0.016 |
| footprint, more than 0.5 km from any site | 17,518 | 0.050 | 0.109 | 0.222 |

**Edges of all tetrahedra that share a face with the surface:**

| region | side | n edges | min | median | max | vertical extent (min / median / max) |
|---|---|---:|---:|---:|---:|---|
| inside the footprint | earth | 640,140 | 0.0055 | 0.043 | 0.390 | 0.006 / 0.035 / 0.356 |
| inside the footprint | air | 640,188 | 0.0055 | 0.043 | 0.344 | 0.007 / 0.035 / 0.281 |
| within 0.5 km of a site | earth | 636,498 | 0.0055 | 0.038 | 0.209 | 0.006 / 0.032 / 0.187 |
| within 0.5 km of a site | air | 636,510 | 0.0055 | 0.038 | 0.217 | 0.007 / 0.032 / 0.207 |
| within 0.1 km of a site | earth | 200,400 | 0.0055 | 0.018 | 0.045 | 0.006 / 0.015 / 0.038 |

Counting instead every tetrahedron with at least one node on the surface (316,722 earth and 314,442 air), the edge lengths are:
- inside the footprint: 0.0055 min, 0.048 median, 0.394 max;
- within 0.5 km of a site: 0.0055 min, 0.042 median, 0.237 max.

### 5.3 Elements by depth shell

Earth elements are binned by centroid depth, air elements by centroid height. "Mean edge" is each element's mean edge length; the table shows the median over the shell.

| shell (km) | earth elements | earth, under footprint | median mean edge, all earth | median mean edge, under footprint | air elements | median mean edge, air |
|---|---:|---:|---:|---:|---:|---:|
| 0-0.2 | 528,732 | 434,728 | 0.057 | 0.050 | 514,262 | 0.058 |
| 0.2-1 | 185,617 | 114,278 | 0.247 | 0.201 | 116,733 | 0.276 |
| 1-5 | 84,947 | 35,706 | 0.587 | 0.460 | 30,600 | 0.869 |
| 5-20 | 22,719 | 4,201 | 2.47 | 1.31 | 9,473 | 6.42 |
| 20-100 | 12,555 | 230 | 18.0 | 5.39 | 8,971 | 25.5 |
| >100 | 10,383 | 10 | 70.6 | 25.3 | 9,910 | 71.6 |

**Core-column size profile** (median mean edge L, in km, against depth z):

| z (km) | 0.05 | 0.1 | 0.2 | 0.5 | 1 | 2 | 5 | 10 | 20 | 50 | 100 | 200 | 400 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| L (km) | 0.06 | 0.09 | 0.15 | 0.24 | 0.38 | 0.54 | 0.94 | 1.9 | 4.4 | 10.8 | 23.5 | 41 | 79 |

L is 0.3 to 0.4 times z at 1 to 2 km depth, and about 0.2 times z from 5 km down.

### 5.4 Sites (all 120)

- Every site lies inside an earth-surface triangle, each in a different triangle, and all at z = 0. So every site is on the surface mesh as FEMTIC requires; sites are never mesh nodes.

| quantity | min | median | max |
|---|---:|---:|---:|
| distance to the nearest surface node | 0.0001 | 0.0039 | 0.0062 (C8, B9) |
| maximum edge of the site's triangle | 0.0118 | 0.0122 | 0.0126 (Vul25_005, F8) |
| depth of the earth element under the site | 0.0075 | 0.0108 | 0.0186 (C10, I6, E7) |
| maximum edge of that earth element | 0.0126 | 0.0172 | 0.0240 |
| height of the air element above the site (H with OWNER_ELEMENT -1) | 0.0078 | 0.0109 | 0.0234 (J7) |
| maximum edge of that air element | 0.0124 | 0.0174 | 0.0268 |

### 5.5 Parameter cells

"Size" is the equivalent size V^(1/3), shown as median (p10-p90).

| cells | count | size | median horizontal extent | elements per cell (median) |
|---|---:|---|---:|---:|
| all earth | 55,992 | 0.18 (0.09-1.0) | | 12 (p10 6, p90 26) |
| 0-0.2 km deep | 23,051 | 0.12 (0.075-0.21) | 0.25 | |
| 0.2-1 km | 22,682 | 0.20 (0.13-0.37) | 0.41 | |
| 1-5 km | 6,431 | 0.62 (0.38-1.6) | 1.2 | |
| 5-20 km | 1,756 | 3.0 (1.4-13) | 5.6 | |
| 20-100 km | 1,269 | 16 (5.7-53) | 33 | |
| >100 km | 803 | 45 (19-112) | 95 | |
| within 0.5 km of a site, top 1 km | 26,295 | 0.12 (0.077-0.20) | 0.25 | 12 |
| cell containing each site's earth element | 120 distinct | 0.074 (0.052-0.092) | 0.13 | 412 (206-825) |

What stands out:
- **82 % of the cells are in the top 1 km.**
- **3,347 cells hold 5 or fewer elements, and 304 hold exactly one.** They sit at a median depth of 0.44 km, a median 0.63 km from a site, at the base of the fine layer.
  - There, the cell size B is only about 1.5 times the element size L (0.3 vs 0.2 km in row 1; 0.6 vs 0.35 km in row 2). The guide asks for 1.5 to 2 times.
  - Across all cells, the median of cell size divided by element mean edge is 1.03, so cells are only about two elements across.

### 5.6 Element quality (tetgen, final round)

- The smallest dihedral angle is 1.03 degrees and the largest is 176.9 degrees; 2,908 of the 9.2 M dihedral angles are below 5 degrees.
- The largest aspect ratio is 92, with 64 elements between 50 and 100.
- The chain-proof mesh B was similar (1.23 degrees, aspect ratio 142).
- This is not a failure criterion (`q3.0/0` sets no dihedral bound), but it is worth watching in the forward test.

## 6. Is the mesh fit for 200 Hz to 1000 s?

**Criteria**, taken from guide sections 6.2 to 6.4 and fixed before the run. Each is a ratio against the skin depth delta = 0.503 sqrt(rho T) km, and a criterion fails when its ratio is exceeded.
- **C1:** the maximum edge of each site's surface triangle is at most delta/4, at every site.
- **C2:** the depth of the earth element under each site is at most delta/4, at every site.
- **C3:** earth elements within 1 delta (3-D) of any site are at most delta/4. Reported as the median of the element mean edge and the p90 of the element maximum edge.
- **C4:** at depth delta in the core column, the median element mean edge is at most delta/4.
- **C5:** the distance from the sites to each side face, and from the surface to the bottom, is at least 3 delta.

**At 3 ohm-m** (the p10 cover resistivity for T < 0.1 s). C5 is always at least 17.9, so it is not shown.

| f (Hz) | delta (km) | C1 max | C2 max (median) | C3 median / p90 | C4 | verdict |
|---:|---:|---:|---:|---|---:|---|
| 200 | 0.062 | 0.20 | **0.30** (0.18) | **0.33 / 0.47** | **1.01** | fails C2, C3 and C4 |
| 100 | 0.087 | 0.14 | 0.21 | **0.25 / 0.41** | **1.02** | site elements pass; volume within delta marginal; between sites too coarse |
| 62.9 | 0.110 | 0.11 | 0.17 | 0.22 / **0.39** | **0.81** | site neighbourhood passes only on the median; between sites too coarse |
| 31.5 | 0.155 | 0.08 | 0.12 | 0.17 / **0.39** | **0.80** | same as 62.9 Hz |
| 10.0 | 0.275 | 0.05 | 0.07 | 0.13 / **0.34** | **0.64** | same as 62.9 Hz |
| 3.15 | 0.491 | 0.03 | 0.04 | 0.10 / **0.32** | **0.48** | same as 62.9 Hz |
| 1.00 | 0.871 | 0.01 | 0.02 | 0.07 / 0.25 | **0.37** | site neighbourhood about passes; between sites coarse |
| 0.315 | 1.55 | 0.01 | 0.01 | 0.05 / 0.19 | **0.29** | marginal between sites |
| 0.100 | 2.75 | <0.01 | <0.01 | 0.03 / 0.13 | 0.23 | pass |
| 0.0315 to 0.001 | 4.9-27.6 | <0.01 | <0.01 | <0.02 / <0.09 | 0.18-0.23 | pass |

**At 100 ohm-m:**

| f (Hz) | delta (km) | C1 | C2 | C3 median / p90 | C4 | C5 side / bottom | verdict |
|---:|---:|---:|---:|---|---:|---|---|
| 200 | 0.36 | 0.04 | 0.05 | 0.12 / **0.33** | **0.56** | >1000 | site neighbourhood passes only on the median; between sites coarse |
| 100 | 0.50 | 0.03 | 0.04 | 0.10 / **0.32** | **0.47** | 980 / 994 | same as 200 Hz |
| 31.5 | 0.90 | 0.01 | 0.02 | 0.07 / 0.25 | **0.36** | 550 / 558 | marginal between sites |
| 10.0 | 1.59 | <0.01 | 0.01 | 0.05 / 0.19 | **0.28** | 310 / 315 | marginal between sites |
| 3.15 | 2.83 | <0.01 | <0.01 | 0.03 / 0.12 | 0.23 | 174 / 176 | pass |
| 1 to 0.0063 | 5.0-63 | <0.01 | <0.01 | <0.02 / <0.09 | 0.17-0.23 | 98 to 7.8 | pass |
| 0.0032 | 89.6 | | | | 0.20 | 5.5 / 5.6 | pass |
| 0.00126 (796 s, longest selected period) | 142 | | | | 0.21 | 3.5 / 3.5 | pass |
| 0.001 (1000 s) | 159 | | | | 0.19 | **3.1 / 3.1** | pass, small margin |

**Judgement:**
- **Long periods:**
  - Strictly, every criterion passes from 1000 s to 10 s at 3 ohm-m, and from 1000 s to 0.3 s at 100 ohm-m.
  - At Vulcan's own resistivities for T >= 1 s (p10 of 10 to 20 ohm-m, guide 6.1), C4 is about 0.28 at 1 s and passes from about 3 s. So in practice the mesh is fit from about 1 s to 1000 s.
- **Domain size:** the domain is 3.1 delta at 1000 s in 100 ohm-m, which means a bottom-boundary error in |Z| of about 0.4 %. The margin falls below 3 delta if the deep resistivity is above about 110 ohm-m at 1000 s. Vulcan's deep apparent resistivity is 50 to 60 ohm-m.
- **3 to 100 Hz: conditional.**
  - What the design sizes directly passes at every site: the 12 m triangles and the 7-19 m earth elements.
  - What does not pass in 3 ohm-m ground: within 1 delta of the sites, the tail of element sizes is delta/3 to delta/2.5 (p90 0.32 to 0.41). This is because fine 15 m elements extend only 30 m from each site, and 40 m elements extend to 100 m.
  - Between the sites, the 0.2 km core is 0.5 to 1 delta at depth delta.
  - Resistivities as low as 3 to 5 ohm-m occur only above about 3 Hz (T < 0.3 s).
  - Errors of a few percent, the same order as the 5 % floor, are plausible at the top of this band. Only the forward test can measure them.
- **200 Hz in 3 ohm-m: not fit.** C2 is 0.30 at the worst site, C3 is 0.33 for a typical element, and C4 is 1.0. observe.dat stops at 100 Hz. Adding the 125 to 200 Hz bands would require shrinking obs_site sphere 2 (for example 0.1/0.04 to 0.1/0.025 km) and observing_site circle 2 together.
- **Caveat:** this is a geometric judgement against rules of thumb, not a measurement of forward error.

## 7. Recommendations, in order

1. **Run the section 9 half-space test on this mesh before inverting.**
   - Use 3 and 100 ohm-m starting blocks and the 21 frequencies in observe.dat.
   - Run it with OWNER_ELEMENT -1 (as written) and with 0.
   - Pass if rho_a is within 5 % and phase within 1.5 degrees at every site.
   - FEMTIC's forward cost has not been measured. Scaling the 42 MB PARDISO peak of INV_MT_01 by N^(4/3) suggests about 6 to 7 GB per factorisation; that is an extrapolation, so measure one frequency first.
2. **Keep INV_METHOD 1**, and plan MPI ranks and memory around the roughly 9 GB sensitivity matrix.
3. **Decide whether 56 k cells is intended.** It is a modelling choice, not a failure.
   - The knob is guide section 8.5: raise resistivity_attr rows 1 and 2 (0.3 to 0.4 km and 0.6 to 0.8 km) and/or the site circles (0.15 to 0.2 km).
   - Getting B to at least 2 L also removes most of the 3,347 cells with 5 or fewer elements.
   - Replace the guide's section 8.4 and Appendix B estimates with these measured counts; the estimator was 2.7 times low.
4. **If the high-frequency test fails:**
   - shrink obs_site spheres 2 and 3 together with observing_site circles 2 and 3;
   - then reduce the core size from 0.2 to 0.15 km in both control.dat and makeMtr.param;
   - regenerate with `--out mesh/vulcan_v2`.

## 8. Files (mesh/vulcan_v1/)

| file | size | md5 | notes |
|---|---|---|---|
| inversion/mesh.dat | 160.6 MB | 3ff87942b8a48c5f47810b3ad2dc236f | git-ignored |
| inversion/resistivity_block_iter0.dat | 36.8 MB | 9b3d07ce40cfc83791a0e435fbb76a22 | **not git-ignored** |
| vtk/output.6.femtic.vtk | 206 MB | 29b32999fa25b2c61ee90d60c43a3dd4 | git-ignored |

- **mesh_logs/:**
  - chain logs: `timings.tsv`, `refinement.tsv`, `summary.txt`, `timev/` (one `/usr/bin/time -v` record per tool call) and `timev_table.tsv`;
  - check results: `check_mesh.txt`, `mesh_stats.txt` and `.json`, `xcheck_sites.txt`;
  - the run scripts, in `scripts/`.
- **scripts/mesh_stats.py:** new, LF line endings.
- **Full run directory:** it stays on ext4 at `/home/tara/femtic_wsl/mesh_runs/vulcan_v1/`, with output.1 to output.6 and output.poly.
- **Cautions:**
  - `.gitignore` only ignores `resistivity_block_iter[1-9]*`, so `git add mesh/` would commit the 36.8 MB iter0 file. Add `mesh/**/resistivity_block_iter0.dat` if it should stay out; I did not edit `.gitignore`.
  - `prep_vulcan.py --force` ran rmtree on this whole directory when this report was written, including the mesh products, `mesh_logs/` and a saved REPORT.md. Since 2026-09-28 it deletes a directory only if every file in it is listed, unchanged, in its prep_manifest.sha256. This directory predates the manifest, so `--force` refuses it and lists what it holds, and only `--force --force-delete-foreign` would delete it. Regenerate with a new `--out` instead.
  - The generated README.md still says "Mesh chain not run".

## 9. What changed

- No config change: nothing failed. No tool sources were edited. Nothing under `hpc/` or `Vulcan/Processed_Data/` was touched. `run_mesh_chain.sh` ran unmodified, with the timing wrappers injected through FEMTIC_BIN.
- **Authorship:**
  - I ran no git commands, so there are no commits.
  - I added no Co-Authored-By or other attribution line to any file.
  - When you commit this work, you will be the only author.
