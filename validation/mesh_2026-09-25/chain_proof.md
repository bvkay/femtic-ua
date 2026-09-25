# FEMTIC tetra mesh chain: proof run in WSL (2026-09-25)

**Verdict: PASS.** All seven steps of the femticPy `meshGen.sh` chain ran end to end in WSL on two small
known inputs. Every step exited 0, and every product check passed:
17/17 independent geometry and topology checks per run, plus 39 assertions in the script tests and negative controls.
The python environment `femticpy` works, but only after pandas is pinned below 3. With the unpinned
command, `fix_output1.py` crashes (details in Section 1).

| | Run A: upstream femticPy `projects/synthetic` | Run B: femticPy `MeshGen` writers (tiny synthetic) |
|---|---|---|
| sites | 16, 4x4 grid, 5 km spacing | 9, 3x3 grid, 5 km spacing |
| analysis domain | +/-300 km (x, y, z) | +/-200 km (x, y, z) |
| final mesh (output.6) | 4,705 nodes / 27,501 tets | 70,324 nodes / 418,186 tets |
| parameter cells | 3,842 (cell 0 = air) | 3,931 (cell 0 = air) |
| earth-surface faces / outer faces | 2,070 / 644 | 46,274 / 1,404 |
| wall time, whole chain | 1.9 s | 51 s |
| peak RSS | 77 MB (fix_output1.py) / 16 MB (tools) | 181 MB (tetgen) |
| products | `D:/BEN/FEMTIC_2026/mesh/chain_proof/` | `D:/BEN/FEMTIC_2026/mesh/chain_proof_meshgen/` |

Deliverables:
- `D:/BEN/FEMTIC_2026/scripts/run_mesh_chain.sh`: the chain as a script (LF, `chmod +x`, passes
  shellcheck 0.11). It takes `RUN_DIR [N_ROUNDS]`.
- `validation/mesh_2026-09-25/`: this report, plus the following files:
  - `check_mesh.py`: independent product checker.
  - `make_meshgen_case.py`: writes the Run B inputs.
  - `chain_tests.out`: test transcript.
  - `scripts/`: every WSL script executed for this proof, verbatim.
  - `env_create.log`, `env_pin.log`, `femticpy_environment.yml`, `femticpy_env_from_history.yml`.
- conda env `femticpy` in WSL.

No femticPy, FEMTIC or tool sources were edited. Nothing under `hpc/` or `Vulcan/Processed_Data/` was
touched, and no git commands were run, so there are no commits. When you commit this work you will be
the only author, because no co-author trailers were added anywhere.

---

## 0. Failure criterion (fixed before any run)

The chain **FAILS** if any of the following is true:
1. Any step exits non-zero.
2. `mesh.dat` or `resistivity_block_iter0.dat` is missing.
3. The region attributes carried by the tetrahedra differ from the attributes that were seeded.

For (3), TetGen2Femtic prints no list of attributes. It only aborts with
`Region attiribute << N of element ... cannot be found !!` and exit 1. So the attribute set is read
independently from the last column of `output.1.ele` and `output.6.ele`.

Presence checks alone are not enough, for two reasons:
- TetGen2Femtic writes `mesh.dat` *before* it validates attributes (test T4 below).
- Seeds that are swapped between air and earth pass every tool with exit 0 (test T2a).

So two geometric checks were added. Each one states its own failure condition:
- **`check_mesh.py`** reads what FEMTIC will consume (`mesh.dat`, `resistivity_block_iter0.dat`) and
  fails if any of these hold:
  - node ids or element ids are not contiguous;
  - the node extents do not equal `analysis_domain.dat`;
  - any tet has zero volume, or the tets have mixed orientation;
  - the sum of tet volumes does not equal the box volume (relative error 1e-9);
  - the neighbour relation is not symmetric;
  - the faces with no neighbour do not match the faces listed on the 6 outer planes;
  - the earth-surface faces do not tile the horizontal domain area;
  - the element counts in `mesh.dat` and the resistivity block disagree;
  - any parameter cell is empty;
  - cell 0 is not 1e9 Ohm m with the fixed flag set, or any earth cell is fixed.

  With a flat surface (both runs), it also fails if any of these hold:
  - an element whose centroid is above z=0 is not in cell 0, or one below z=0 is in cell 0;
  - the earth-surface faces are not at z=0;
  - the air and earth volumes do not each equal half the box.
- **`run_mesh_chain.sh`** also fails if any of these hold:
  - an element that touches the top plane (z = zmin) does not carry the air attribute;
  - an element that touches the bottom plane (z = zmax) does carry it;
  - the seeded attributes do not equal the attributes in `resistivity_attr.dat`;
  - the element counts in `output.N.ele`, `mesh.dat` and the resistivity block disagree;
  - the tet volumes do not sum to the box volume.

Section 6 shows that each of these checks can fail.

---

## 1. Python environment `femticpy`

Commands, run in WSL as user tara:

```bash
source /home/tara/miniforge3/etc/profile.d/conda.sh
# (1) as specified (51 s, exit 0). Resolved pandas 3.0.6, numpy 2.5.3, python 3.12.14
mamba create -y -n femticpy -c conda-forge python=3.12 numpy scipy pandas matplotlib pyproj shapely rdp tabulate pyyaml jupyterlab
# (2) required fix (8 s, exit 0). pandas 3.0.6 -> 2.3.3; numpy was not changed
mamba install -y -n femticpy -c conda-forge "pandas>=1.5,<3"
# (3) verification
conda activate femticpy
PYTHONPATH=/mnt/c/Users/joint/AppData/Local/Temp/claude/D--BEN-FEMTIC-2026/4e858f54-ea4e-47a8-9815-7766aca9830d/scratchpad/femticPy/src \
  python -c 'import femticPy'        # exit 0, prints only SyntaxWarnings about invalid escape sequences
```

To recreate the environment in one step, use the command below. It was checked with `--dry-run`: it
solves to the same pandas 2.3.3 and numpy 2.5.3, 267 packages.
```bash
mamba create -y -n femticpy -c conda-forge python=3.12 numpy scipy "pandas>=1.5,<3" matplotlib pyproj shapely rdp tabulate pyyaml jupyterlab
```
The fully resolved list is in `femticpy_environment.yml`. The installed versions are: python 3.12.14,
numpy 2.5.3, scipy 1.18.1, pandas 2.3.3, matplotlib 3.11.2, pyproj 3.8.0, shapely 2.1.2, rdp 0.8,
tabulate 0.10.0, pyyaml 6.0.3, jupyterlab 4.6.4.

**Why the pin is needed.** pandas 3.0 removed `read_csv(delim_whitespace=...)`. femticPy uses it in
`scripts/fix_output1.py` line 17, `InvResults.plot_cnv` (femticPy.py:1156) and `read_distorsion`
(femticPy.py:1323). The unpinned env was tested on the real `output.1.ele` of Run A:
`TypeError: read_csv() got an unexpected keyword argument 'delim_whitespace'`, exit 1 (see
`mesh/chain_proof/logs/fix_output1_pandas3.log`). The lower bound 1.5 is needed because `fix_output1.py`
passes `lineterminator=`.

---

## 2. Input used

- `femticPy/projects/mmt/meshGen/files` and `projects/auslamp/meshGen/files` contain **only `.gitkeep`**,
  so neither input set is complete. Their `input_data/` folders also lack the `topography.dat`,
  `bathymetry.dat` and `coast_line.dat` that `meshGen.sh` line 5 copies in. The notebook
  `prep_topo_bathy.ipynb` produces those files, and they are not shipped.
- **Run A**, the known input: `femticPy/projects/synthetic` is complete. It has 6 files in
  `meshGen/files` (`control.dat`, `analysis_domain.dat`, `observing_site.dat`, `obs_site.dat`,
  `makeMtr.param`, `resistivity_attr.dat`) and 3 in `input_data` (`topography.dat`, `bathymetry.dat`,
  `coast_line.dat`). This is the toy land model that the femticPy authors inverted (their results ship
  in `projects/synthetic/inversion`). `meshGen.sh` has a commented "example synthetic" seed block for it.
  - 16 sites at +/-2.5 and +/-7.5 km, z = 0.
  - Flat topography at 0 on a 10 km grid out to +/-1011 km. Bathymetry is -0.01 km and unused.
  - The coast line is a closed box at +/-1001 km with land everywhere.
  - control.dat ellipsoids: radii 15, 30, 200 km with edges 2, 5, 100 km.
  - makeMtr.param: 4 ellipsoids.
  - resistivity_attr.dat: air attribute 10 (1e9 Ohm m, fixed); earth attribute 20 (100 Ohm m, NDIV 9).
  - All 9 files have **CRLF** line endings.
- **Run B**, the tiny synthetic case the task asked for, generated by femticPy's own writers.
  `make_meshgen_case.py` calls `MeshGen.write_inputs()`, `write_dummy_coast_line()`,
  `write_dummy_topo_file()` and `write_dummy_bathy_file()`. The case has:
  - 9 sites on a 3x3 grid at 5 km spacing, z = 0.
  - Domain +/-200 km.
  - MeshGen default ellipsoids, with every radius halved for the control, makeMtr and
    resistivity_attr ellipsoids. Edge lengths, oblateness and the site spheres keep their defaults.

  This run also tests the writers that the Vulcan prep script will call. It ran through
  `run_mesh_chain.sh` with the default land-only seeds.

---

## 3. Commands (Run A, exactly the meshGen.sh sequence)

The binaries are in `/home/tara/femtic_wsl/bin`: makeTetraMesh v1.3.2 and TetGen 1.6 (Aug 2020).
The working directory is `/home/tara/femtic_wsl/mesh_runs/chain_proof` (ext4). The 9 inputs are in
`files/`, converted CRLF to LF with `sed -i 's/\r$//' files/*`. Every command below was wrapped with
`/usr/bin/time`. The wrapper is in `scripts/cp_common.sh`.

```bash
export PATH=/home/tara/femtic_wsl/bin:$PATH
# STEP 1-4 makeTetraMesh
cp files/{control.dat,coast_line.dat,analysis_domain.dat,observing_site.dat} .
makeTetraMesh -stp 1
makeTetraMesh -stp 2
cp files/{topography.dat,bathymetry.dat} .
makeTetraMesh -stp 3
makeTetraMesh -stp 4
# region seeds ("example synthetic" block of meshGen.sh)
sed -i "$(( $(wc -l < output.poly) ))s/.*/2/" output.poly
echo "1   0.0 0.0 -40.0  10 1e9" >> output.poly
echo "2  0.0 0.0  10.0  20 1e9" >> output.poly
# STEP 5 tetgen
tetgen -nVpYAakq3.0/0 output.poly
# fix output.1.ele (femticpy env)
source /home/tara/miniforge3/etc/profile.d/conda.sh; conda activate femticpy
python /mnt/c/.../scratchpad/femticPy/scripts/fix_output1.py     # pandas 3.0.6: exit 1; after the pin (2.3.3): exit 0
# STEP 6 refinement, 5 rounds as in meshGen.sh
cp files/{obs_site.dat,makeMtr.param} .
for i in 1 2 3 4 5; do makeMtr output.$i; tetgen -nmpYVrAakq3.0/0 output.$i; done
# STEP 7
cp files/resistivity_attr.dat .
TetGen2Femtic output.6
# independent checks
python /mnt/d/BEN/FEMTIC_2026/validation/mesh_2026-09-25/check_mesh.py . --flat-surface-z 0
```

**What the seed lines mean.** makeTetraMesh always ends `output.poly` with the lines `# Part 4` and `0`,
where the 0 is the region count (verified in `TriangleList::writePLCsToPolyFile`). The `sed` command
replaces that last line with the number of regions. Each appended line then has the form
`index x y z attribute maxvolume`, in km in the FEMTIC frame: x north, y east, **z positive down**.

With `-A`, tetgen gives `attribute` to every tet it can reach from the point (x, y, z) without crossing
a PLC facet. With `-a`, it applies `maxvolume` in km^3; 1e9 means no limit. The land-only case has two
closed regions, split by the earth surface:
- air: seeded 40 km *above* the surface (z = -40), attribute 10;
- earth: seeded 10 km *below* it (z = +10), attribute 20.

The first line of `resistivity_attr.dat` must be the air attribute, and TetGen2Femtic enforces this.

Run B used `bash /mnt/d/BEN/FEMTIC_2026/scripts/run_mesh_chain.sh /home/tara/femtic_wsl/mesh_runs/chain_proof_meshgen 5`.
It had no `region_seeds.dat`, so the script used its land-only default seeds:
`0 0 -100 10 1e9` and `0 0 100 20 1e9`.

---

## 4. Timings and counts

Per step, from `logs/timings.tsv`. Wall time is in seconds, peak RSS in MB, and every exit code was 0
unless marked.

| step | Run A wall | Run A RSS | Run B wall | Run B RSS |
|---|---:|---:|---:|---:|
| makeTetraMesh -stp 1 | 0.02 | 4 | 0.00 | 4 |
| makeTetraMesh -stp 2 | 0.04 | 5 | 0.72 | 9 |
| makeTetraMesh -stp 3 | 0.06 | 6 | 0.30 | 10 |
| makeTetraMesh -stp 4 | 0.02 | 5 | 0.14 | 15 |
| tetgen -nVpYAakq3.0/0 output.poly | 0.06 | 13 | 3.72 | 146 |
| fix_output1.py, pandas 3.0.6 | 0.63, **exit 1** | 68 | not run | |
| fix_output1.py, pandas 2.3.3 | 0.69 | 77 | not run (see Gotcha 3) | |
| makeMtr, 5 rounds total | 0.05 | 6 | 0.63 | 33 |
| tetgen -nmpYVrAakq3.0/0, 5 rounds total | 0.85 | 16 | 39.72 | 181 |
| TetGen2Femtic output.6 | 0.11 | 7 | 3.34 | 47 |
| **total** | **1.9** | | **51.1** (including checks) | |

Mesh size after each round, from `logs/refinement.tsv`:

| mesh | Run A nodes / tets | Run B nodes / tets |
|---|---|---|
| output.1 (after tetgen) | 1,605 / 7,879 | 30,213 / 164,329 |
| output.2 | 3,279 / 18,587 | 57,434 / 338,204 |
| output.3 | 4,416 / 25,714 | 69,817 / 416,059 |
| output.4 | 4,832 / 28,269 | 68,244 / 405,223 |
| output.5 | 4,654 / 27,186 | 70,871 / 421,843 |
| output.6 (to TetGen2Femtic) | 4,705 / 27,501 | 70,324 / 418,186 |

Both runs plateau after round 3, so 5 rounds is enough here.

Region attributes:
- Run A: `output.1.ele` has {10: 3,919, 20: 3,960} and `output.6.ele` has {10: 13,477, 20: 14,024}.
- Run B: `output.1.ele` has {10: 82,217, 20: 82,112} and `output.6.ele` has {10: 196,091, 20: 222,095}.
- tetgen reports "Found 2 subdomains" in both runs.

Final tetgen quality: the smallest dihedral angle is 1.98 deg in A and 1.23 deg in B, and the largest
aspect ratio is 59 in A and 142 in B. `q3.0/0` sets no dihedral bound, so slivers are expected. This
is not a failure.

**Output headers:**
- `mesh.dat` starts `TETRA` / `4705` in A and `TETRA` / `70324` in B.
- `resistivity_block_iter0.dat` starts `27501 3842` in A and `418186 3931` in B.
- `output.6.femtic.vtk` is present: 3.7 MB in A and 56 MB in B.

**TetGen2Femtic log:**
- It reads 2 resistivities; entry 0 is air or sea (NDIV < 0) with rho_air = 1e9.
- It reports 3 spheres in A and 9 in B.
- It reports 16 sites in A and 9 in B.
- It prints no errors.

**Checksums** (md5 of `mesh.dat` and `resistivity_block_iter0.dat`):
- A: `8844b52f...` and `119bb35f...`.
- B: `bbea2b58...` and `bae16de0...`.

Rerunning gives byte-identical output, so tetgen is deterministic.

**Independent checks:** `check_mesh.py --flat-surface-z 0` passed **17/17 on both runs** (see
`mesh/*/logs/check_mesh.txt`). Every check passed:
- the volume sum equals the box exactly: 2.16e8 km^3 in A and 6.4e7 km^3 in B;
- the air and earth volumes are exactly half each;
- every centroid above z=0 is in air cell 0 and every centroid below z=0 is earth;
- the earth-surface faces lie on z=0 and tile 600x600 km^2 in A and 400x400 km^2 in B;
- the neighbour relation is symmetric;
- no parameter cell is empty.

---

## 5. Gotchas

1. **CRLF.** All nine upstream input files, and `meshGen.sh`, `create_mesh.sh` and `fix_output1.py`,
   are CRLF.
   - The C++ tools tolerate CRLF *data* files. Raw CRLF inputs gave a byte-identical `mesh.dat` (test T5).
   - The CRLF *shell scripts* fail under bash: `$'\r': command not found` and
     `cd: $'sub\r': No such file or directory` (test T5b). Running `meshGen.sh` as shipped will fail.
   - Write every script LF. The repo `.gitattributes` enforces LF on commit.
   - `run_mesh_chain.sh` converts CRLF inputs to LF in place and logs each file it converts.
2. **Region seeds.**
   - z is positive down, so the air seed needs a negative z.
   - tetgen gives every *unseeded* closed region the attribute max+1, then max+2, and so on
     (`tetgen.cxx`, "Spreading region attributes").
   - Swapped seeds (air attribute under the surface) pass every tool with exit 0 and give a model with
     the air at the bottom (T2a). Only a geometric check catches this: `check_mesh.py` (T2b) or the
     script's top/bottom-plane check (T2c).
   - tetgen's "Found N subdomains" count is not proof either. In T3 it reported 3 subdomains, but
     attribute 20 never reached `output.1.ele`.
   - Sea and lakes each need their own seed. The script refuses to guess seeds for them.
3. **The "31/32 bug" and `fix_output1.py`.**
   - In the three-region auslamp model (air 10, sea 20, earth 30), any closed pocket without a seed
     gets attribute 31, 32 and so on. TetGen2Femtic then aborts on the unknown attribute.
     `fix_output1.py` hides this by setting every attribute above 30 to 30, so it silently turns the
     pocket into earth, even if the pocket is really sea.
   - For a land-only model (10/20) it does nothing useful:
     - With correct seeds it is a no-op. The numeric content is identical, and `mesh.dat` is identical
       with and without it (T8).
     - With a missing seed the stray attribute is 11 or 21, which is 30 or less, so it survives and
       TetGen2Femtic exits 1 (T4).
   - It also needs 1.5 <= pandas < 3.
   - One fix is enough: `-r` switches `-A` off, so refined tets inherit their attributes. The set of
     attributes in `output.6.ele` stayed exactly the seeded one.
   - `run_mesh_chain.sh` runs `fix_output1.py` only with `FIX_OUTPUT1=1`. It always compares the
     attribute sets.
4. **`-Y`** means "preserve the input surface mesh": tetgen never splits a PLC facet, including during
   the `-r` refinements. Measured:
   - Run A: 2,714 facets in `output.poly`, 2,714 faces in `output.1.face` and in `output.6.face`, and
     644 outer plus 2,070 earth-surface faces in `mesh.dat`, which is 2,714.
   - Run B: 47,678 at every stage.

   So **the resolution of the earth surface around the sites is set only by makeTetraMesh**, through
   the control.dat ELLIPSOIDS and the `observing_site.dat` spheres. makeMtr and `obs_site.dat` refine
   only the volume. Size the surface mesh for the shortest period before step 4, because the
   refinement loop cannot fix it later.
5. **Missing files.**
   - Only `projects/synthetic` ships a complete input set. mmt and auslamp need `prep_topo_bathy.ipynb`
     and `prep_inversion.ipynb` to be run first.
   - The ALTITUDE and SEA_DEPTH file names come from `control.dat`, and `lake.dat` is optional.
   - The Vulcan prep script must write all 9 files. The region seeds are not written by femticPy
     MeshGen, so they must come from the script too, or from the land-only default in
     `run_mesh_chain.sh`.
6. **`mesh.dat` existing does not mean success.** TetGen2Femtic writes `mesh.dat` before it validates
   the region attributes. In T4 it exited 1 with `mesh.dat` present and no resistivity block.
   `run_mesh_chain.sh` deletes old products before it starts (T1b).
7. **makeTetraMesh overwrites `makeTetraMesh.log` on every step,** so only the step-4 log survives.
   The script keeps a copy per step in `logs/makeTetraMesh_stpN.log`. makeTetraMesh does exit 1 on its
   errors.
8. **Oblateness column order.** In `control.dat` ELLIPSOIDS and `makeMtr.param`, the 4th column is the
   **earth** (downward) axis and the 5th is the **air**. The evidence is the makeTetraMesh log header
   `<OblatenessVerticalEarth> <OblatenessVerticalAir>` and the makeMtr source. The PDF's "+ upper side"
   and "- lower side" labels read the other way if you think in z-up.
9. **MeshGen centre z has the wrong sign** (not exercised here, because z = 0).
   - `DataGen.read_MTdata_coordinates` negates the elevation, so `mt_coords.z` is FEMTIC z (down).
   - `MeshGen` then sets `center z = -median(mt_coords.z)`, which is +median elevation, meaning *below*
     ground in FEMTIC's frame. It should be `median(mt_coords.z)`.
   - For Vulcan (elevations 0.065 to 0.124 km, median 0.099 km) this shifts every ellipsoid centre down
     by about 0.2 km. That is negligible for ellipsoids of tens of km, but the prep script should set
     `m.center[2]` explicitly.
   - Also, `write_control` formats SEA_DEPTH min with `%4.1f`, so 0.01 becomes `0.0`. This is harmless
     for land-only.
10. **The MeshGen defaults are heavy.** Even with the radii halved, 9 sites gave 418k tets and 46k
    surface triangles. The site spheres in `observing_site.dat` dominate: 0.02 km edges within 0.1 km of
    every site. Vulcan has 120 sites, so expect a much larger mesh (not measured). Tune the
    `observing_site`, `obs_site` and control ellipsoids to the site spacing and the shortest period's
    skin depth before the first real mesh, and look at `logs/refinement.tsv`.
11. **Executable bit.** `run_mesh_chain.sh` is `chmod +x` in WSL, but NTFS does not store the bit, so
    Windows git will record mode 100644. Run it with `bash scripts/run_mesh_chain.sh`, or set the bit
    with `git update-index --chmod=+x scripts/run_mesh_chain.sh`.
12. **The femticPy clone is in a session temp folder** (the scratchpad). The `PYTHONPATH` above points
    there. Clone it to a persistent location, for example `/home/tara/femtic_wsl/femticPy`, before the
    prep script depends on it.
13. **`.gitignore` does not cover `resistivity_block_iter0.dat`**; it ignores only `iter[1-9]*`, and
    it does not cover `*.dat` inputs. `git add mesh/` would therefore commit
    `mesh/chain_proof_meshgen/resistivity_block_iter0.dat` (9.1 MB). A production Vulcan iter0 will be
    far larger. Decide whether iter0 belongs in the repo.
14. femticPy triggers `SyntaxWarning: invalid escape sequence` under Python 3.12 (for example
    `sep='\s+'`). It is harmless now and may become an error in a later Python.

---

## 6. Negative controls and script tests

These checks must be able to fail, so each test states its expected outcome. The harness is
`scripts/cp_tests.sh` and the transcript is `chain_tests.out`. **OVERALL: PASS (39 of 39 assertions).**

| test | set-up | expected, and observed |
|---|---|---|
| T0 | no arguments | exit 2 plus help text |
| T1 | raw CRLF upstream inputs, meshGen.sh seeds, run through the script | CHAIN OK; 9 files converted; `mesh.dat` and block md5 == manual Run A |
| T1b | rerun in the same directory | CHAIN OK, identical (old products wiped first) |
| T2a | **air and earth seeds swapped**, bare tool chain | every tool exits 0 and both products are written, so the tools cannot see the error |
| T2b | check_mesh.py on the T2a product | exit 1: 13,477 elements above the surface are not air, and 14,024 below it are in air |
| T2c | swapped seeds, through the script | CHAIN FAILED at the air-on-top check (263 of 263 top-plane elements are not air); no `mesh.dat` |
| T3 | both seeds in the air | CHAIN FAILED: attributes {10 21} != {10 20} |
| T4 | earth seed missing, bare chain plus fix_output1 | attributes {10 11} survive the fix; TetGen2Femtic exits 1 "Region attiribute << 11 ... cannot be found"; **`mesh.dat` exists** and the block does not |
| T4b | the same, through the script | refused in preflight |
| T5 | raw CRLF inputs, bare tools, no conversion | all exit 0; `mesh.dat` and block **byte-identical** to the LF run |
| T5b | the first lines of the CRLF `meshGen.sh` under bash | fails: `$'\r': command not found`, `cd: $'sub\r'` |
| T6 | `obs_site.dat` removed | refused: "missing input file(s): obs_site.dat" |
| T7 | seed at z = -400 km, outside the domain | refused |
| T8 | `FIX_OUTPUT1=1` path | CHAIN OK, `mesh.dat` identical, so fix_output1 is a no-op for 10/20 |
| T9 | `N_ROUNDS=0`, default seeds | CHAIN OK on output.1 (1,605 nodes / 7,879 tets) |

On T3: my first prediction was {10 20 21}, and the test failed on that expectation. Reading
`tetgen.cxx` showed why: the second seed relabels only its own seed tet as 20, which is why tetgen
says "Found 3 subdomains", and quality optimisation then replaces that tet. The script's verdict
(FAIL, exit 1) was correct from the start. I changed only the expected attribute set, and the test now
also asserts the "Found 3 subdomains" line.

The Run A manual chain, the script and the function in Section 7 all produce the same md5 for
`mesh.dat` and the resistivity block.

---

## 7. Copy-pasteable function

This is the minimal meshGen.sh-faithful version. It was tested: on Run A inputs the md5 is identical,
a rerun is identical, and with the earth seed missing it exits 1 with no `mesh.dat` (see
`scripts/cp_fn_test.sh`). It needs `RUN_DIR/region_seeds.dat` with one `x y z attr maxvol` line per
closed region, in km with z positive down. `scripts/run_mesh_chain.sh` is the full version, with a
preflight, land-only default seeds, the top/bottom-plane and volume checks, per-step logs and timings,
and optional fix_output1.

```bash
femtic_mesh_chain() {  # usage: femtic_mesh_chain RUN_DIR [N_ROUNDS=5]; needs RUN_DIR/region_seeds.dat ("x y z attr maxvol" per region)
  local dir=$1 n=${2:-5}
  ( set -eo pipefail
    export PATH=/home/tara/femtic_wsl/bin:$PATH
    cd "$dir"
    rm -f output.* mesh.dat resistivity_block_iter0.dat           # never let a stale product pass
    sed -i 's/\r$//' ./*.dat ./*.param                            # CRLF -> LF (harmless if already LF)
    for s in 1 2 3 4; do makeTetraMesh -stp "$s"; done            # makeTetraMesh.log is overwritten each step
    awk '!/^[[:space:]]*(#|$)/' region_seeds.dat > seeds.tmp
    sed -i "$(wc -l < output.poly)s/.*/$(wc -l < seeds.tmp)/" output.poly   # last line "0" = region count
    awk '{print NR, $0}' seeds.tmp >> output.poly                          # "i x y z attr maxvol"
    tetgen -nVpYAakq3.0/0 output.poly > tetgen_1.log
    want=$(awk '{print $4+0}' seeds.tmp | sort -nu | xargs)
    got=$(awk 'NR>1 && !/^#/ {print $NF+0}' output.1.ele | sort -nu | xargs)
    [ "$got" = "$want" ] || { echo "FAIL: tetgen region attributes {$got} != seeded {$want}" >&2; exit 1; }
    for i in $(seq 1 "$n"); do
      makeMtr "output.$i" > "makeMtr_$i.log"
      tetgen -nmpYVrAakq3.0/0 "output.$i" > "tetgen_r$i.log"
    done
    TetGen2Femtic "output.$((n + 1))" > t2f.log
    echo "OK: $(sed -n 2p mesh.dat | xargs) nodes; elements/cells: $(head -1 resistivity_block_iter0.dat | xargs)"
  )
}
```

Script usage, inside WSL. Heavy I/O should go on ext4; copy the finished products to `/mnt/d/...`
afterwards.
```bash
bash /mnt/d/BEN/FEMTIC_2026/scripts/run_mesh_chain.sh /home/tara/femtic_wsl/mesh_runs/<name> 5
# optional: region_seeds.dat in RUN_DIR; FIX_OUTPUT1=1 FIX_OUTPUT1_PY=<femticPy>/scripts/fix_output1.py; T2F_ARGS="-thread 8"
```
On success it prints `CHAIN OK` with a summary, which is also saved to `logs/summary.txt`. On failure
it exits 1 and writes `CHAIN FAILED: <reason>` to stderr and `logs/summary.txt`.
