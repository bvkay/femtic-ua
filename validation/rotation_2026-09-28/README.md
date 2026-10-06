# Sensor frame -> mesh frame rotation (2026-09-28)

**Decision (Ben, 2026-09-28):** the Vulcan sensors were aligned to geomagnetic north. All 120 EDIs carry
DECLINATION 0 and ZROT 0, so the impedance tensors are in the magnetic frame. FEMTIC's mesh x axis is UTM 53
grid north. Every tensor must be rotated before observe.dat is written.

**Acquisition dates (Ben, 2026-09-28; the EDIs carry only the dummy ACQDATE 01/01/01):**
2022 grid A1-J10 = Oct-Nov 2022 (epoch 2022.83); infill Vul24-xx = April 2024 (2024.29);
Vul25_xxx = March 2025 (2025.21).

## Facts established (Opus scout, read-only; evidence in the files here)
- FEMTIC v5.0 has no data or frame rotation: AnalysisControl.cpp's keyword list has no ROTATION/DECLINATION;
  ObservedDataStationMT.cpp:216-323 reads no angle. DISTORTION 2 is a left-multiplication C.Z, not R Z R^T.
- femticPy `mesh.rotation_deg` -> control.dat ROTATION / makeMtr.param / resistivity_attr.dat only orients
  the refinement ellipsoids (Ellipsoids.cpp:220-221, 253-254); the coordinate frame does not change.
  No impedance rotation helper exists in femticPy or mtpy.
- Insertion point in scripts/prep_vulcan.py: operate on `dg.data_Z` after the id checks (~line 1323 of the pre-C5
  script) and before `dg.write_observe` (then line 1351; now :1771-1783 and :1812); R is real so it commutes with unit conversion and conjugation but
  must precede the error floor. Self-checks C08/C09 compare against unrotated conj(Z_EDI) and must apply the
  same rotation, implemented independently.
- Declination, IGRF-14 via ppigrf 2.1.0 (cross-checked to 1e-4 deg with an independent SH synthesis):
  centre (-29.838, 137.043): 6.418 E (2022.5), 6.402 (2024.5), 6.396 (2025.5); spread over the 120 sites 0.07 deg.
  Shifting to the real epochs above changes alpha by < 0.005 deg (secular variation -0.008 deg/yr).
- Grid convergence, pyproj meridian_convergence at the centre: -1.0168 deg (hand formula -1.0165);
  per site -1.051 .. -0.982. Sign checked by finite difference: grid north is 1.017 deg WEST of true north.
- Total angle alpha = D - gamma = 6.40 + 1.02 = **7.42 deg: magnetic north is 7.42 deg clockwise of grid north.**
  Per group: 2022 grid 7.365-7.460 (mean 7.413), 2024 7.452-7.487 (7.471), 2025 7.404-7.467 (7.434).

## Formula
R(t) = [[cos t, sin t], [-sin t, cos t]] (new x axis t clockwise of the old). Z_grid = R(-alpha) Z_mag R(-alpha)^T.
With c = cos(alpha), s = sin(alpha):
  Z'xx = c^2 Zxx - cs (Zxy + Zyx) + s^2 Zyy
  Z'xy = cs Zxx + c^2 Zxy - s^2 Zyx - cs Zyy
  Z'yx = cs Zxx - s^2 Zxy + c^2 Zyx - cs Zyy
  Z'yy = s^2 Zxx + cs (Zxy + Zyx) + c^2 Zyy
Variance (uncorrelated components; EDIs carry no covariances): Var' = (M o M) . Var with M = kron(R, R).
Rows of (M o M) sum to 1, so Var'_ij <= max_k Var_k. At 7.42 deg: Var'xx = 0.967 Vxx + 0.0164 (Vxy + Vyx) + 0.0003 Vyy.

## Tests (rot_test.py; each states its failure criterion)
- T1 fails if the rotated tensor differs by > 1e-12 from an independently built grid-frame 2D tensor with
  strike at +alpha. Result 2.2e-16. With the wrong sign (+alpha) the difference is 0.28, so T1 can fail.
- T2 fails if the strike recovered from the rotated tensor is not 7.42 deg. Result 7.42.
- T3 fails if a 400k-sample Monte Carlo variance differs from (M o M) V by > 2 %. Max difference 0.3 %.

## C5 done (2026-09-28): what prep now does

**Status.** `scripts/prep_vulcan.py` rotates the data when the config asks, and `mesh/vulcan_v2_rot/` holds the
rotated observe.dat for mesh v2. It was first written by the WSL femticpy env, and the Windows base Python gives
byte-identical products (13 of 13 files). No mesh tool was run: the mesh is v2's, and check C17 verifies that.
The follow-ups of the same night (section "Follow-ups" below; run_followups.log) added check C18, the per-frame
angle column, the script's sha256 in the records, and regenerated the product: observe.dat unchanged.

### Config block: `data.rotation` in config/vulcan_mesh_v2_rot.yml

```yaml
schema: prep_vulcan/2        # needed with data.rotation or mesh.reuse_from
data:
  rotation:
    frame_in: magnetic       # magnetic | grid | true
    rotate_to: grid          # the only choice
    angle_deg: 7.42          # a number within +-45, or 'auto' with angle_file (column: see below)
    provenance: "..."        # required unless frame_in is grid
mesh:
  reuse_from: mesh/vulcan_v2
```

**What prep refuses** (tests R7a-R7e, R9a, R10, R11):
- frame_in magnetic or true without angle_deg ("refusing to guess the rotation");
- frame_in grid with an angle other than 0;
- unknown keys, e.g. a misspelt `angle_degs`;
- `auto` without angle_file, or an angle_file that lacks a site. The angle file is checked before anything is written.
- `auto` with a column other than the one of frame_in (ROT_ANGLE_COLUMN, prep_vulcan.py:107): `alpha_deg`
  (= D - gamma) for magnetic, `alpha_true_deg` (= -gamma) for true. angle_column may be left out; it then
  defaults to that column. alpha_per_site.csv has no alpha_true_deg, so `frame_in: true` + `auto` is refused on it.
  Its conv_pyproj_deg is gamma itself, i.e. the true-north angle with the wrong sign.
- data.rotation or mesh.reuse_from under `schema: prep_vulcan/1`.
- EDIs that record a rotation of their own (check C18, below): the run stops at the checks, nothing is written.

**Why the schema bump.** R9c shows the hazard: the pre-C5 script (sha256 52c25de1) accepts a `prep_vulcan/1`
config with data.rotation. It ignores the block, writes the **unrotated** observe.dat (byte-identical to v2's)
and passes every check. Under `prep_vulcan/2` it refuses instead (R9b).

**Without the block** nothing changes, byte for byte:
- observe.dat and station_map.csv keep the old layout;
- a design warning in the README says the data are in the EDI (magnetic) frame;
- v1-v3 configs are untouched.

### Where the rotation happens

Line numbers below are those of prep_vulcan.py sha256 328932c2 (2,236 lines, after the follow-ups).

- **Function.** `rotate_Z(Z4, var4, alpha)` at prep_vulcan.py:117 is pure:
  - Z' = R(-alpha) Z R(-alpha)^T;
  - Var' = (M o M) Var, with M = kron(R(-alpha), R(-alpha));
  - R(t) = [[cos t, sin t], [-sin t, cos t]] (rot_matrix, :110).
- **Call site.** build() applies it at :1771-1783. That is after the id checks and before `dg.write_observe`
  (:1812), whose prep_data converts units, conjugates and applies the floor. So the floor uses the rotated
  |Z'xy| and |Z'yx|.
- **Record of the angle** (:161, `rotation_text`):
  - both READMEs (a "Frame rotation" section and a Provenance row);
  - prep.log;
  - `station_map.csv`, new last column `rot_deg` (:1834);
  - a `#` header line in `prep_manifest.sha256` (:2199), after the line `# written by scripts/prep_vulcan.py
    sha256 <64 hex>`. `sha256sum -c --strict` skips both (run.log Part 5; run_followups.log Part D). prep's own
    manifest reader skips them too (:1967).
- **Record of the script.** Its sha256 is in the README Provenance row `script`, in the first line of
  inversion/README.md and in the manifest header (follow-up 4; test R12).

### Self-checks

**C08 and C09** (prep_vulcan.py:1163, :1171) compare observe.dat against `rotate_Z_check` (:819). That function
is written independently of rotate_Z: it uses the four explicit formulas above, and their squared coefficients
for the variances.
- C09 also takes the floor from the rotated tensor.
- C08 also fails if station_map.csv's rot_deg is not the angle applied (:1136).

**C15, rotation sanity** (:841, :1325) runs T1-T3 of rot_test.py on rotate_Z on every run, at 7.42 deg and at the
configured angle(s):
- T1: rotate_Z of a 2-D tensor with strike along the sensor x axis must equal the tensor built in the grid frame
  with strike at +alpha, to 1e-12. The opposite sign must miss by more than 0.1; it gives 0.28.
- T2: the strike recovered from rotate_Z's output must be within 0.01 deg.
- T3: the variances must match the explicit formulas to 1e-12, and a 200k-sample Monte Carlo to 2 % (0.5 % found).

**C16, isotropic invariance** (:878, :1332): a 1-D tensor and equal variances must be unchanged to 1e-12 at
-60, 0/7.42, 30 and 90 deg.

**C17, mesh reuse** (:1336) runs only with mesh.reuse_from. It fails unless:
- every files/* is byte-identical to `<reuse_from>/files`;
- every file in `<reuse_from>/mesh_logs/input_md5.txt` (what the mesh chain read) has that md5;
- products.md5 names mesh.dat and resistivity_block_iter0.dat.

**C18, EDI frame** (edi_frame_problems :894, frame_check :951, :1363) runs on every run, with or without
data.rotation. It reads every EDI's ZROT block, the ROT= option of its Z blocks, DECLINATION and the HMEAS/EMEAS
lines, and fails if any EDI records a rotation of its own:
- a Z block whose ROT= names anything but ZROT, or a ZROT other than 0 at any band (tolerance 1e-6 deg);
- an HX or EX azimuth other than 0, or HY or EY other than 90 deg: the AZM of HMEAS/EMEAS where given, else an
  EMEAS dipole's X,Y -> X2,Y2 direction when it has a length (0.5 deg, polarity ignored). HZ is not tested;
- DECLINATION missing or not 0, for frame_in magnetic, frame_in grid and runs without data.rotation (whose
  README states the EDIs are magnetic with DECLINATION 0 and ZROT 0). Under frame_in true DECLINATION is
  information only: a true-north layout does not need it, and a non-zero value is consistent with it.
Which north the sensor x axis pointed to cannot be read from an EDI; frame_in states it (decision D2). C18 stops
prep from rotating a tensor a second time. The Vulcan EDIs: 120 ZROT blocks all 0, 120 DECLINATION 0, 440
HX/HY AZM 0/90 (remote-reference channels included), 220 EMEAS lines without AZM and of zero length
(orientation not recorded, not testable).

With mesh.reuse_from set, both generated READMEs say to reuse v2's mesh.dat and resistivity_block_iter0.dat
and not to re-mesh (inversion/README.md said "not yet: produced by the mesh chain" until the follow-ups; test
R12). prep never ran a mesh tool: it writes only text inputs through femticPy MeshGen. So no data-only mode was
needed.

### Per-site angle at the real epochs (decl.py rerun, run.log Part 4)

decl.py now uses the real epochs (2022.83, 2024.29, 2025.21) and writes `alpha_per_site.csv` with site ids.
It was run in the conda base env (ppigrf, pyproj). Its independent SH synthesis agrees with ppigrf to 1.0e-5 deg
at the 15 corner points.

| group | sites | D (deg E) | gamma (deg) | alpha (deg) | mean | max abs(alpha - 7.42) |
|---|---|---|---|---|---|---|
| 2022 grid, 2022.83 | 100 | 6.380-6.428 | -1.030 to -0.982 | 7.362-7.458 | 7.410 | 0.058 |
| Vul24, 2024.29 | 10 | 6.415-6.438 | -1.051 to -1.039 | 7.454-7.488 | 7.473 | 0.068 |
| Vul25, 2025.21 | 10 | 6.396-6.426 | -1.042 to -1.009 | 7.405-7.468 | 7.435 | 0.048 |
| all | 120 | 6.380-6.438 | -1.051 to -0.982 | **7.362-7.488** | 7.417 | **0.068** |

- The lowest alpha is J1 (7.36233), the highest Vul24-24 (7.48830).
- The move from the scout's mid-year epochs changed alpha by -0.0028 to +0.0018 deg.
- **The single 7.42 deg is within 0.068 deg of every site.** The per-site `auto` run (R6) changes the written tensors by at most 6.5e-4 |Z|_F
  against 7.42 over 2,520 data lines, far below the 5 % floor.
- ppigrf warns that its IGRF-13 file ends at 2025.0. That affects only the IGRF-13 cross-check column at 2025.21;
  IGRF-14 covers the epoch.

### Tests (rot_prep_checks.py; Windows: 66 of 66 PASS, run_followups.log Part B; 39 of 39 before the follow-ups, run.log Part 1)

Each test prints "This test fails if ..." before it runs. Each is shown FAILING on a mutant of the current script,
built by exact text replacement with the occurrence count asserted (section M).

| test | fails if | result | failing case (mutant) |
|---|---|---|---|
| R1 angle 0 regression | exit != 0, or observe.dat, control.dat or a files/* differs from mesh/vulcan_v2, or station_map.csv is anything but v2's plus a rot_deg column of 0 | PASS; observe.dat sha256 f4678d0522a6a8d0 = v2's | MZ (alpha + 1e-3 deg): exit 1 |
| R2 full 7.42 run | exit != 0; any of C01-C18 not PASS; rot_deg not 7.42; the data.rotation manifest header line missing or a manifest mismatch; control.dat/files differ from v2; observe.dat NOT different | PASS, 18 of 18 checks | MR1 wrong sign: C08, C09, C15 FAIL. MR2 applied twice: C08, C09. MR3 VAR not rotated in rotate_Z: C09, C15. MR3b VAR not rotated in build: C09. MR4 R Z R: C08, C09, C15, C16. MR6 not applied: C08, C09. MR9 rot_deg written 0: C08. MR10 manifest header dropped. MR6+MR15 (feature silently off): exit 0, observe.dat = v2's |
| R3 invariants, full precision (7,257 tensors, 120 EDIs) | rotate_Z at 7.42 changes abs(det Z) by more than 1e-10 relative, det Z by more than 1e-10 abs(Z)_F^2, Zxx+Zyy or Zxy-Zyx by more than 1e-10 abs(Z)_F, or abs(Z)_F by more than 1e-10 | PASS: 6.5e-16, 2.3e-16, 2.2e-16, 3.2e-16, 4.4e-16 | MR4: Zxx+Zyy 0.37, Zxy-Zyx 0.25 |
| R4 invariants, written files (R2 vs v2) | abs(det Z) differs by more than 3e-4 abs(Z)_F^2, or Zxx+Zyy, Zxy-Zyx or abs(Z)_F by more than 3e-4 abs(Z)_F, or no component moved by more than 1e-2 abs(Z)_F | PASS: 4.4e-5, 2.9e-5, 6.3e-5, 4.5e-5; largest move 0.113 abs(Z)_F | MR6+MR15: nothing moved |
| R5a check-only of R2's output, own config | exit != 0, a check other than C03/C05 not PASS, or the directory changes | PASS, 16 PASS + 2 N/A | MR15 (C08 compares with the unrotated tensor): C08 FAIL |
| R5b R2's output checked with the v2 config | C08 does not FAIL | PASS: C08 and C09 FAIL | (expects a FAIL) |
| R5c mesh/vulcan_v2 checked with the v2_rot config | C08 does not FAIL | PASS: C08, C09 FAIL | MR15+MR16. MR15 alone still fails C08, through the rot_deg record (observation) |
| R6 `auto` per site | exit != 0, a check not PASS, or rot_deg differs from the CSV by more than 1e-9 | PASS, alpha 7.36233-7.4883 | MR14 (auto ignores the CSV): off by 0.068 |
| R7a-e, R9a refusals | exit != 1, output or staging written, or message missing | PASS | MR5, MR18, MR19, MR20, MR17, MR21 |
| R8 reuse_from mesh/vulcan_v3 | exit != 1 or C17 not FAIL | PASS: obs_site.dat, observing_site.dat differ | MR11 (C17 always passes) |
| R9b old script vs the v2_rot config | the pre-C5 script exits 0 or writes output | PASS: exit 1, schema refused | R9c: under prep_vulcan/1, exit 0 with unrotated data |
| R10a-c frame guard: a scratch copy of the 120 EDIs with E5's ZROT 7.42 at all 62 bands / DECLINATION 6.4 / first HX AZM 7.42, config v2_rot | exit != 1, C18 not FAIL, C18 not naming E5 and the value, or output written | PASS: exit 1, 'E5: ZROT 7.42 at 62 of 62 bands' / 'E5: DECLINATION 6.4' / 'E5: HMEAS HX AZM 7.42 (must be 0)' | MR22 (C18 always passes); MR25 (ZROT ignored), MR26 (DECLINATION ignored), MR27 (AZM ignored). The script before the follow-ups: exit 0, E5 rotated twice (run_followups.log Part A) |
| R10d DECLINATION 6.4 under frame_in true (the documented exception) | exit != 0 or a check not PASS | PASS, 18 PASS | MR30 (DECLINATION tested under true too) |
| R10e ZROT 7.42 under frame_in true | as R10a | PASS | MR22, MR25 |
| R11a-c angle column: true + auto on alpha_per_site.csv (no column given) / true + alpha_deg / magnetic + conv_pyproj_deg | exit != 1, output written, or message missing ('alpha_true_deg', 'does not match frame_in true', '... magnetic') | PASS | MR23 (alpha_deg for every frame, the old default): R11a, R11b; MR24 (column not compared): R11b, R11c. The script before: exit 0 in all three |
| R11d accepted case: true + auto with a CSV holding alpha_true_deg = -conv_pyproj_deg | exit != 0, a check not PASS, rot_deg not the CSV's value for all 120 sites, or outside (0.9, 1.1) | PASS: rot_deg 0.98181-1.05062 | MR23: rot_deg 7.36-7.49 |
| R12 records of a mesh-reuse run | inversion/README.md says 'not yet' or does not say it reuses mesh/vulcan_v2; either README or the manifest header lacks the sha256 of the script under test | PASS | MR28 (template unconditional), MR31 (wrong sha recorded), MR10 (header dropped) |

**How much the rotation moves the data** (7.42 deg; observe.dat of v2_rot against v2's, 2,520 data lines).
Component order xx / xy / yx / yy:

| measure | xx | xy | yx | yy |
|---|---|---|---|---|
| median abs(dZ)/abs(Z) | 0.22 | 0.028 | 0.024 | 0.21 |
| max abs(dZ)/abs(Z) | 109 | 0.38 | 0.38 | 10 |
| max abs(dZ)/abs(Z)_F | 0.113 | 0.095 | 0.095 | 0.113 |

- The written SEs change by a median of 0.17 %, because the floor (active for 96-100 % of the data) follows
  sqrt(abs(Z'xy) abs(Z'yx)). Unfloored SEs change by up to 50 %: Var' mixes in the other components' variances.
- The floor-active fractions are unchanged at 100 / 97 / 96 / 100 %.

**Blind spots, shown on mutants.**
- A wrong sign or a doubled angle leaves every invariant (R3, R4) and C16 unchanged. C08 (against the explicit
  formulas) and C15 (against a tensor built in the grid frame) are what catch them.
- C16 catches only non-similarity errors such as R Z R (MR4).

**Other runs in run.log.**
- Part 1b: the femticpy env repeats section R, 17 of 17 PASS, and mutants MZ, MR1 and MR2. It was stopped during
  MR3: about 2 min per prep through /mnt, and the PC runs MT processing.
- Part 3: the prep harness (validation/prep_checks_2026-09-28/inject_and_check.py, not edited then) gives 81 of
  85. Its negative controls C1-C4 required exactly 14 check lines (`len(st) == 14`, inject_and_check.py:348).
- Part 3b: a scratch copy with only that number set to 17 gives 85 of 85.
- Fixed in the follow-ups (run_followups.log Part C): the harness now requires N_CHECKS = 18 check lines and runs
  its subprocesses with -B. 85 of 85; the mutant with 14 gives 81 of 85; the mutant without -B leaves
  scripts/__pycache__.

### Product: mesh/vulcan_v2_rot/

Written with `python scripts/prep_vulcan.py config/vulcan_mesh_v2_rot.yml` (WSL femticpy, final run with
`--force`), then regenerated in the follow-ups with the Windows base Python and `--force` (prep_vulcan.py sha256
328932c2; run_followups.log Part D). Results:
- 18 checks, 18 PASS.
- inversion/observe.dat is unchanged by the regeneration (sha256 d501abcf5a7dde5f), as are control.dat,
  station_map.csv and files/*. Only README.md, inversion/README.md, config_used.yml (comment lines),
  prep.log and prep_manifest.sha256 changed.
- Against mesh/vulcan_v2:
  - inversion/observe.dat (sha256 d501abcf5a7dde5f) differs;
  - station_map.csv (12701a8c38881ebc) differs by the added rot_deg column only;
  - control.dat and all 10 files/* are byte-identical.
- The Windows base Python gives the same 13 files byte for byte.
- `sha256sum -c --strict prep_manifest.sha256`: 17 OK (two '#' header lines: the script's sha256 and the
  rotation).
- No CR bytes.

**The mesh is v2's.** Take mesh.dat and resistivity_block_iter0.dat from the main checkout's
mesh/vulcan_v2/inversion/ (md5 in mesh/vulcan_v2/mesh_logs/products.md5).

**The half-space gate applies unchanged**: a uniform half-space is isotropic, so the rotation does not touch it.

## Follow-ups (2026-09-28, late evening; from the C5 verdict's 'missed' list)

All run with the Windows base Python; evidence in run_followups.log (fail cases first, Part A).
1. **Frame guard, check C18** (above). Fail case: E5's ZROT 7.42 in a scratch copy of the EDIs; the script
   before the follow-ups rotated E5 a second time with every check PASS, now C18 FAILs and nothing is written
   (R10a). Pass case: the real 120 (R2, and every --check-only in Part F).
2. **Angle column of `auto`** per frame_in (above). `frame_in: true` + `auto` no longer takes the magnetic
   alpha_deg (R11a-c refused; R11d accepted with an alpha_true_deg column).
3. **inversion/README.md of a mesh-reuse run** says the mesh is reused (not "not yet: produced by the mesh
   chain"); the files/ row of README.md says the inputs are a record, not to be meshed again. mesh/vulcan_v2_rot/
   regenerated; observe.dat sha256 d501abcf5a7dde5f unchanged (Part D).
4. **Script provenance**: prep_vulcan.py's sha256 in both READMEs and the manifest header (R12).
5. **Prep harness**: `len(st) == 14` replaced by N_CHECKS = 18 (C01-C18, the current count: C18 was added by
   item 1, so 17 would already be stale); -B for its subprocesses and no bytecode for its in-process import.
   85 of 85 (Part C).
6. **scripts/edi_inventory.py** writes the acquisition-dates/frame section of Vulcan/edi_inventory.md itself
   (ACQUISITION table in the script; ACQDATE, DECLINATION, ZROT, HMEAS AZM from the EDIs; angles from
   alpha_per_site.csv and the v2_rot config). Re-running reproduces the file except the sentence that said the
   section was hand-made (Part E). Its CSVs are now written with LF on Windows too.
7. **--check-only tallies** (Part F): v1, v2, v3 18 checks, 15 PASS, 3 N/A (C03, C05, C17); v2_rot 16 PASS,
   2 N/A (C03, C05); 0 FAIL.

## Files

- decl.py: IGRF-14 declination and pyproj convergence per site at the real epochs. Writes alpha_per_site.csv.
  Run it with `conda run -n base python`.
- alpha_per_site.csv: columns site_id, group, epoch, lat, lon, elev_m, D_igrf14_deg, conv_pyproj_deg, alpha_deg
  (120 rows).
- rot_test.py: the scout's T1-T3, which C15 now runs inside prep.
- rot_prep_checks.py: the tests above. Usage:
  `python validation/rotation_2026-09-28/rot_prep_checks.py WORKDIR [--old-prep PRE_C5_SCRIPT] [--only IDS]`.
  It takes about 2.5 min on Windows and writes only below WORKDIR. `--only R10a,R11a` runs just those tests,
  e.g. against an older `--prep` to show them failing.
- run.log: Parts 1-5 (scratch paths shown as `<scratch>`).
- run_followups.log: the follow-ups, Parts A-F (fail cases first; harnesses; product regeneration;
  scripts/edi_inventory.py; --check-only tallies).

## Open points

- Rotation ignores Z covariances: the EDIs carry none. With 7.42 deg the leak between components is small
  (cos^2 = 0.983).
- A true-north frame (`frame_in: true`) is implemented, but no config uses it. Its angle would be -gamma, about
  +1.02 deg: a number, or `auto` with a CSV column alpha_true_deg, which alpha_per_site.csv does not have.
- EMEAS orientation is not recorded in these EDIs (no AZM, zero-length dipoles), so C18 cannot test the
  E-field axes; it tests the H axes (HX 0, HY 90) and ZROT.
