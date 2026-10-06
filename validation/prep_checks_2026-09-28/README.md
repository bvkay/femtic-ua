# prep_vulcan.py: can its checks fail? (2026-09-28)

This folder covers STATUS.md items C3, C4 and part of C7. It shows that each self-check of
`scripts/prep_vulcan.py`, its `--force` guard and its DISTORTION guard can FAIL, and that each passes on
the clean case. It follows CLAUDE.md Invariant 10: a test that cannot fail is not a test.

**Round 2 (evening).** An adversarial verifier checked round 1 and found: the guard could be bypassed
through a junction or symlinked parent; 6 of the 13 `--force` tests had no real failing case; the staging
marker was dropped too early; C06, C08 and C09 passed on zero comparisons; and several smaller gaps. This
version fixes all of them. Every guard test now has a failing case on a **mutant** of the current script
(section M), not on an older script that merely lacks a flag.

| file | content |
|---|---|
| `inject_and_check.py` | the harness: 59 tests on the script itself, 26 tests on 18 mutants of it, and 4 observations. Each test prints "This test fails if ..." before it runs |
| `run.log` | Part 1: the current script, Windows base Python (junctions), **85/85 PASS**. Part 1b: the same in the WSL femticpy env (symlinks), **85/85 PASS**. Part 2: the HEAD copy (55bbf44), 32 PASS, 27 FAIL. Parts 3 and 4: the real v2 `--check-only` and a full prep compared with mesh/vulcan_v2, in both interpreters |

Re-run it (light: single-threaded Python, 6 sites, about 60 s on Windows and 100 s in WSL; no FEMTIC or
mesh tools):

    python validation/prep_checks_2026-09-28/inject_and_check.py <empty scratch dir> [--prep <script>] [--skip-mutants]

The harness writes nothing outside the scratch directory. The fixture is 6 real EDIs (A1, J5, J6_BxRepaced,
J7, Vul24-19, Vul25_004), their rows of `Vulcan/site_coords_femticpy.txt`, and `config/vulcan_mesh_v2.yml`
with the paths and `sites.expected_count: 6` changed. Every injection is applied to a fresh copy of the
clean fixture run, and then `--check-only` is run on it. Before that, the harness checks that the sha256 of
**the injection's own target file** changed (round 1 only checked that some file changed).

## What changed in prep_vulcan.py

- **C3, the `--force` guard.** A full run writes `prep_manifest.sha256` last, in `sha256sum -c` format.
  - `--force` deletes an existing directory only if every file in it is listed there with an unchanged
    sha256. Anything else is refused and listed, with sizes, and nothing is deleted: mesh.dat, half-space
    runs, mesh_logs, hand-edited products, and pre-manifest directories such as today's v1-v3.
    `--force --force-delete-foreign` deletes those too.
  - Refused whatever the flags:
    - a directory that holds a symlink or junction, **or is reached through one**: `link_components()`
      tests every directory on the path, not only the last one (round 2);
    - a directory that is or contains the repository root, the config, the EDI directory, the site table,
      femticPy, the script itself or the home directory. `inside()` now compares **realpath on both
      sides**, so an alias cannot hide them (round 2);
    - a path with a `.git` component (checked on the path as given and on its realpath), a directory that
      holds a nested `.git`, and a filesystem root.
  - The inventory is taken again just before the delete. Anything added during the run stops it.
  - `RUN.staging` is removed only if it holds prep's marker `.prep_vulcan_staging`. **Round 2:** the
    marker is now dropped only after the last abort point (the late CR scan and the re-inventory), just
    before the rename; the manifest never lists it. In round 1 it was dropped before those two checks, so
    a run that stopped there left an unmarked staging directory, and the next run refused it with the
    false message "was not created by this version of prep".
  - The generated README gives the safe re-run, `prep_vulcan.py <config> --out <new dir>`. **Round 2:**
    its "Next steps" no longer say WSL, ext4, 60 ohm-m or OWNER_ELEMENT 0; they name the gated chain, the
    half-space gate as run (3 and 100 ohm-m) and `hpc/phoenix_plan/RUNBOOK_first_inversion.md`.
- **C4, check status.** N/A is never counted as a pass.
  - Under `--check-only`, C03 and C05 report N/A (they need femticPy's in-memory results). With an explicit
    `sites.origin`, C03 is N/A instead of being skipped silently.
  - **Round 2:** C06, C08 and C09 skip every station that fails C07. When that leaves nothing to compare
    they now report **N/A** ("nothing compared: 6 of 6 station(s) failed C07"), not PASS. When some
    stations are skipped, the detail says how many. C06 reports "over N of M data lines", counting only
    the lines it compared.
- **C7, DISTORTION.** `load_config` rejects `inversion.DISTORTION != 0`: FEMTIC reads
  `distortion_iter<iterInit>.dat` whenever distortion is estimated and exits if it is missing (FEMTIC src
  `AnalysisControl.cpp:282-286`, `ObservedData.cpp:489-500`), and no writer exists. femticPy only reads
  that file, for plotting (`femticPy.py:1365`). The Phoenix kit only checks for it
  (`06_forward_only.slurm`, the line `distortion_iter0.dat is missing`, line 141 at 21:07 on 09-28).

## Results

"new" is Part 1 (and Part 1b, identical verdicts); "old" is the HEAD copy (Part 2). For the guard tests the
failing case that counts is the mutant in section M, because an old script that exits 2 on an unknown flag
never runs the guard at all.

### A. Clean runs

| test | this test fails if | new | old |
|---|---|---|---|
| A1 full run of the fixture | exit != 0 or any of C01-C14 is not PASS | PASS (14 PASS) | PASS (14 PASS) |
| A2 `--check-only` of the clean run | C03 or C05 is not N/A, or anything else is not PASS | PASS (12 PASS, 2 N/A) | **FAIL**: C03 and C05 report PASS (vacuous) |
| A3 full run, explicit `sites.origin [697.0, 6699.5]` | C03 is missing or not N/A, or another check is not PASS | PASS | **FAIL**: 13 check lines, C03 absent |

### B. The five named injections, plus the low-band case (new = old)

| injection (target file) | check that must FAIL | observed |
|---|---|---|
| B1 flip the sign of Im(Zxy), station 1, 100 Hz (observe.dat) | C08 | C08 FAIL only, max rel diff 2.0 |
| B2 scale the Re **and** Im SE of Zxy by 1.01 (observe.dat) | C09 | C09 FAIL only, max rel diff 1.0e-2 |
| B3 move station 1 **and** its dummy VTF H-station 2 m (observe.dat) | C04 | C04 FAIL only, "within 1 m of 0 sites" |
| B4 frequency x (1 + 2e-6), 100 Hz (observe.dat) | C06 | C06 FAIL only, 2.00e-6 |
| B5 swap the **site_id fields** of station_map rows 1 and 2 (station_map.csv) | C04 | C04, C08, C09 FAIL (the swapped stations are compared with the wrong EDI) |
| B6 frequency + 1e-5 Hz at 0.0012553 Hz, 8e-3 relative (observe.dat) | C06 | C06 FAIL, 7.97e-3 |

### C. Negative controls: the change must NOT trip any check (new = old)

| change | observed | what it shows |
|---|---|---|
| C1 swap whole rows 1 and 2 of station_map.csv | all PASS | row order carries no meaning (station_map is keyed by station id) |
| C2 frequency + 1e-5 Hz at 100 Hz (1e-7 relative) | all PASS, C06 1.00e-7 | STATUS C4's "1e-5 Hz would not trip it" holds only above 10 Hz; B6 trips it |
| C3 frequency x (1 + 5e-7) | all PASS, C06 5.00e-7 | the 1e-6 relative tolerance is real; B4 trips at 2e-6 |
| C4 move station 1 by 0.2 m | all PASS | '%.3f' rounding already puts stations up to 0.67 m from their site (1 m limit), so a move trips C04 only beyond about 0.3-1.7 m; 2 m always trips it (B3) |

### D. One injection for every other check (new = old)

| injection (target file) | check | observed |
|---|---|---|
| D1 one CRLF (inversion/control.dat) | C01 | C01 FAIL only |
| D2 DATAID of A1.edi changed to A1x (a fixture copy of the EDI) | C02 | C02 and C07 FAIL |
| D3 drop station 1's last data line and its count (observe.dat) | C07 | C07 FAIL only; C06, C08, C09 still PASS on the other 5 stations and now say "1 of 6 station(s) skipped" |
| D4 conjugate every impedance (observe.dat) | C10 | C08 and C10 FAIL (median phase Zxy +36.6 deg) |
| D5 move site 1 of files/obs_site.dat 2 m | C11 | C11 FAIL only |
| D6 makeMtr.param core edge 0.2 -> 0.21 km | C12 | C12 FAIL only |
| D7 one topography.dat height 0 -> 0.001 km (flat mode) | C13 | C13 FAIL only |
| D8 control.dat TRADE_OFF_PARAM 3 -> 1 | C14 | C14 FAIL only |

### N. C06, C08 and C09 when nothing could be compared (new in round 2)

| test | this test fails if | new | old | mutant |
|---|---|---|---|---|
| N1 every MT station loses its last data line and its count, so every station fails C07 | observe.dat is unchanged, exit != 1 or C07 is not FAIL, or any of C06, C08, C09 is not N/A | PASS: C06, C08, C09 N/A, "nothing compared: 6 of 6 station(s) failed C07" | **FAIL**: C06 "0.00e+00 over 120 data lines", C08, C09 PASS | M15 (N/A condition removed): **FAIL**, C06/C08/C09 PASS on nothing |

### E. Full-run faults for C03 and C05, which are N/A under `--check-only` (new = old)

| fault | check | observed |
|---|---|---|
| femticPy centres the sites 2 m north of the bbox centre, consistently for every site | C03 | C03 FAIL only; exit 1; no output directory. C04 and C11 cannot see a consistent shift, so C03 is the only guard |
| the femticPy path drops its lowest selected band | C05 | C05, C07 and C10 FAIL; C06, C08 and C09 now N/A ("nothing compared"); C10's median is nan because every station failed C07 |

### F. The `--force` guard

"mutant" names the section-M mutant on which the test FAILs; each is the current script with that one guard
disabled by an exact text replacement.

| test | this test fails if | new | old | mutant (test FAILs) |
|---|---|---|---|---|
| F1 `--force` on an unchanged prep directory | exit != 0, or no manifest that verifies | PASS: 17 files, 0 mismatches | FAIL: no manifest | (old) |
| F2 `--force` with inversion/mesh.dat, resistivity_block_iter0.dat, halfspace/, mesh_logs/ added | exit 0, anything deleted or changed, or the 4 not named | PASS | **FAIL: all deleted** | (old) |
| F3 `--force` after a hand edit of observe.dat | exit 0, or the edit not listed as CHANGED | PASS | **FAIL: edit deleted** | (old) |
| F4 `--force --force-delete-foreign` with the same 4 | exit != 0, a foreign file survives, or the manifest fails | PASS | exit 2 (flag unknown) | M3: exit 1, all 4 left |
| F5a a link inside the run dir, `--force` | not refused, or the link, its target or the run dir touched | PASS | **FAIL: run dir and link deleted** | M1: exit 0, run dir and link deleted |
| F5b the same, `--force --force-delete-foreign` | as above | PASS | exit 2 | M1: exit 0, run dir and link deleted |
| F6a `--out` = the fixture root (config, EDIs), `--force` | not refused with "refusing to delete", or any fixture file changes | PASS | **FAIL: config, EDIs, site table deleted** | M2: not refused by this rule (the foreign-file rule still stops it) |
| F6b the same, `--force --force-delete-foreign` | as above | PASS | exit 2 | M2: exit 0, fixture replaced by prep output |
| F7 an unmarked RUN.staging holding notes.txt | exit 0, or notes.txt deleted | PASS | **FAIL: deleted silently** | (old) |
| F8 a stale RUN.staging with prep's marker | exit != 0, or the stale dir survives | PASS | PASS | M6 (marker ignored): exit 1, stale dir kept |
| F9 no `--force` on an existing dir | exit 0, or the dir changes | PASS | PASS | M5+M7: exit 0, dir replaced. M5 alone still PASSes: the re-inventory is a second layer (observation in run.log) |
| F10 `--force` on a copy of the committed mesh/vulcan_v2 (145 files, no manifest) | exit 0, the copy changes, or halfspace/, mesh_logs/ or the missing manifest not named | PASS | **FAIL: copy wiped** | (old) |
| F11 `--force-delete-foreign` without `--force` | exit 0, or output written | PASS | exit 2 | M4: exit 0, output written |
| F12 a mesh.dat copied into the run dir during a `--force` run (new) | exit 0, or the added file or any original deleted or changed | PASS: "changed during the run", all kept | **FAIL: exit 0, mesh.dat deleted** | M7 (re-inventory blind): exit 0, mesh.dat deleted |
| F13 a nested `halfspace/.git` in the run dir, `--force --force-delete-foreign` (new) | not refused with "contains a git repository", or the dir changes | PASS | exit 2 | M14: exit 0, dir replaced |

### J. Links on the path: the round-1 bypass (new in round 2)

Each test builds `WORK/Jn_real/...` and a link `WORK/Jn_alias -> WORK/Jn_real`: a **junction** on Windows
(what `mklink /J` makes; symlinks need a privilege there) and a **symlink** in WSL. The junction variant is
Part 1, the symlink variant Part 1b; both give the same verdicts. M11 is the round-1 guard logic (abspath in
`inside()` and a link test on the last component only).

| test | this test fails if | new | round-1 logic (M11) | one layer removed |
|---|---|---|---|---|
| J1 `--out alias/fixture` (the fixture root through the link), config by its real path, `--force --force-delete-foreign` | not refused, or any file below the real dir deleted, changed or added | PASS: refused ("... is a link ... on that path") | **FAIL: exit 0, the fixture's config, EDIs and site table deleted and replaced by prep output** | M9 alone and M10 alone: still refused, the other layer holds (observations in run.log) |
| J2 config given as `alias/fixture/config/fixture.yml`, `--out` the real fixture root, same flags | as above | PASS: refused ("it is or contains the repository root") | **FAIL**, same damage | M9 (abspath in `inside()`): **FAIL**, same damage |
| J3 `--out alias/run`, an ordinary run dir with the 4 foreign files, same flags | not refused, or any file of the real run dir deleted, changed or added | PASS: refused (link on the path) | **FAIL: exit 0, foreign files deleted** | M10 (last component only): **FAIL**, same |

J3 is the case only the new path test catches: nothing protected lies below the target, so realpath alone
would let `--force-delete-foreign` delete through the link. Behaviour change: a directory reached through a
symlinked or junctioned parent is now refused whatever the flags; the message gives its real path, which
the user can pass instead.

### K. The staging marker after a late abort (new in round 2)

| test | this test fails if | new | old | mutant |
|---|---|---|---|---|
| K1 a run stopped by the late CR scan (a CR written into README.md after the checks), then the same command | first run not stopped with "CR bytes", staging lacks the marker, or the rerun exits != 0, says "not created by this version", leaves RUN.staging or writes a manifest that fails | PASS: marker kept; rerun "removing ... left by an earlier run", exit 0, 17 files verify | FAIL (no marker at all) | M8 (round-1 order): **FAIL**, staging unmarked, rerun exit 1 "not created by this version". M6: **FAIL** |
| K2 a `--force` run stopped by the re-inventory; the added mesh.dat moved out; then the same command | first run not stopped by the re-inventory, or as K1 | PASS | **FAIL: exit 0, mesh.dat deleted** | M8: **FAIL**, as K1. M6: **FAIL** |

### L. Refusals of `delete_plan`, called directly (new in round 2)

`delete_plan` never deletes. The harness replaces its directory walk (`inventory`) with a sentinel that raises,
so "reached the walk" means no refusal came first, and nothing is ever walked.

| test | this test fails if | new | mutant |
|---|---|---|---|
| L1 a link (junction/symlink) as the directory itself | no "is a link" refusal before the walk | PASS | M16 (no link test): reached the walk |
| L2 a directory inside `.git` (`WORK/.../L2_repo/.git/objects`) | no "inside a .git directory" refusal | PASS | M12: reached the walk |
| L3 the filesystem root of the scratch dir (`C:\`, or `/` in WSL) | no "filesystem root" refusal | PASS | M13: refused only by the protected-path rule (it holds the fixture and home); M13+M2: reached the walk of the root |
| L4 a directory holding the home directory (HOME and USERPROFILE pointed into the scratch tree) | no "the home directory" refusal | PASS | M2: reached the walk |
| L5 the directory holding the script under test (`scripts/`) | no "this script" refusal | PASS | M2: reached the walk |

On the HEAD copy all five end in a traceback (no `delete_plan`), which is not a fail case.

### M. Mutants: each guard test fails when its guard is gone

`section_m()` reads the script under test, applies exact text replacements and writes the mutant to
`WORK/mutants/`. If an anchor is not found exactly once, the mutant is not built and its tests FAIL, so a
mutant cannot silently equal the original. Each listed test is then run on the mutant with a fresh work
tree; the M test PASSes only if that test FAILs there. All 26 did, in Part 1 and in Part 1b.

| mutant | replacement in prep_vulcan.py | must FAIL | observed on the mutant |
|---|---|---|---|
| M1 | `if links:` -> `if False:` (links inside the dir) | F5a, F5b | exit 0; run dir and link deleted |
| M2 | `if inside(p, top):` -> `if False:` (protected paths) | F6a, F6b, L4, L5 | F6a refused only by the foreign-file rule; F6b exit 0, fixture replaced; L4, L5 reached the walk |
| M3 | foreign refusal -> `if True:` | F4 | exit 1, the 4 foreign files left |
| M4 | `if a.force_delete_foreign and not a.force:` -> `if False:` | F11 | exit 0, output written |
| M5 | up-front `if not a.force:` -> `if False:` | (observation) | F9 still PASSes: the re-inventory refuses |
| M7 | re-inventory made blind (`plan1` emptied before the comparison) | F12 | exit 0, the added mesh.dat deleted |
| M5+M7 | both | F9 | exit 0, directory replaced without `--force` |
| M6 | `marked = ...` -> `marked = False` | F8, K1, K2 | stale staging refused as "not created by this version" |
| M8 | marker removal moved back before the manifest, CR scan and re-inventory (round-1 order) | K1, K2 | staging unmarked after the abort; rerun exit 1, "not created by this version" |
| M9 | `inside()` with abspath instead of realpath | J2 (J1 observed) | J2 exit 0, fixture deleted; J1 still refused by the path test |
| M10 | `links_up = [top] if is_link(top) else []` (last component only) | J3 (J1 observed) | J3 exit 0, foreign files deleted; J1 still refused by realpath |
| M11 | M9 + M10: the round-1 guard | J1, J2, J3 | all exit 0 with the damage listed in J |
| M12 | `if ".git" in re.split(` -> `if False and ...` | L2 | reached the walk |
| M13 | `if os.path.dirname(top) == top:` -> `if False:` | L3 | refused, but only as "contains the repository root" |
| M13+M2 | root and protected checks both removed | L3 | reached the walk of the root |
| M14 | `if gits:` -> `if False:` (nested .git) | F13 | exit 0, directory replaced |
| M15 | `(not fbad) if ncmp else None` -> `not fbad`, same for C08, C09 | N1 | C06, C08, C09 PASS on zero comparisons |
| M16 | `links_up = link_components(top)` -> `links_up = []` | L1 | reached the walk of the link |

Tests with no mutant have their failing case elsewhere: A2, A3, F1-F3, F7 and F10 fail on the HEAD copy
with real damage or a vacuous PASS (Part 2); B, D and E fail on their injections; C are negative controls
paired with B3, B4 and B6; G1 fails on HEAD (exit 0); H and I are listed below.

### G. DISTORTION

| test | this test fails if | new | old |
|---|---|---|---|
| G1 `DISTORTION: 1`, `TRADE_OFF_PARAM: [3.0, 1.0]` | exit 0, output written, or no clear message | PASS: exit 1, "DISTORTION 1 is not supported ..." | **FAIL: exit 0.** The control.dat written would make FEMTIC exit at start, and C14 passes it |

### H. The misspelt site id J6_BxRepaced (reported, not renamed)

**Origin.** The Geotools 4.0.5 EDI export (FILEDATE 09/25/26). The LEMIMT processing name in `>INFO` is
`P-J6_RR-RR_S-10Hz_1`, with no suffix. `scripts/edi_inventory.py:40` takes the id from the file name, and
prep's C02 requires the file name, DATAID and table id to agree, so it spreads to every file below.

**Every file that carries the string** (grep of the worktree, of the D:/BEN/FEMTIC_2026 checkout
excluding .git/.claude and files of 50 MB or more, and of WSL /home/tara/femtic_wsl, on 2026-09-28):

| where | files | occurrence |
|---|---|---|
| source | `Vulcan/Processed_Data/J6_BxRepaced.edi` | file name; DATAID (line 2), LOC (7), REFLOC (37), SECTID (50) |
| site tables | `Vulcan/site_coords_femticpy.txt:97`, `Vulcan/site_coords_utm53.csv:98`, `Vulcan/edi_inventory.md:134` | site id |
| prep outputs, v1, v2, v3 each | `mesh/vulcan_vN/inversion/station_map.csv:98`, `inversion/README.md:246`, `README.md` (line 399 in v1, 401 in v2 and v3), `prep.log:119` ("reading J6_BxRepaced.edi") | 12 files |
| mesh logs, v1, v2, v3 each | `mesh/vulcan_vN/mesh_logs/mesh_stats.json` | 3 files |
| WSL run tree | `/home/tara/femtic_wsl/mesh_runs/vulcan_v{1,2,3}/logs/mesh_stats.json` | 3 files (copies of the above) |
| main checkout | the same 19 files as the source, site-table, prep-output and mesh-log rows above (tracked copies); no gitignored file under 50 MB carries it | - |
| notes | `docs/STATUS.md`, `docs/journal/2026-09-28_pickup.md`, and this folder (`README.md`, `inject_and_check.py`, `run.log`: the fixture site list) | reports only |

It is **not** in observe.dat, control.dat or files/*, which hold numbers only (FEMTIC station ids 97 and
1097), and not in mesh.dat or resistivity_block_iter0.dat.

| test | this test fails if | result |
|---|---|---|
| H1 rename to J6_BxReplaced in the fixture (file name, the 4 EDI fields, site table), full run | observe.dat, inversion/control.dat or any files/* differ from the clean run, or station_map.csv differs in more than J6's row | PASS: only station_map.csv differs, in J6's row |
| H2 J6's station number among all 120 EDIs (femticPy numbers stations in `np.sort` order of the file names) | the index changes | PASS: station 97 before and after (J5 < J6_... < J7) |

H1 and H2 are equivalence claims; their failing case would be a rename that reorders stations, which H2
rules out. **A rename would change:** the EDI and the three site tables at the source, then (after
re-running edi_inventory.py and prep into a new `--out`) station_map.csv, both READMEs and prep.log.
mesh_stats.json copies the site ids from station_map, so it changes only if mesh_stats.py is re-run; the
existing half-space logs keep the old name. Nothing numerical changes, so leaving it until the next
Geotools re-export is equally safe.

### I. Dead keys of config/vulcan_mesh_v2.yml

- **I0 (observation): every key is read** by `load_config` (read tracking).
- **Mutation tests.** Two positive controls change a product: `data.error_floor_Z` (observe.dat) and
  `inversion.NUM_THREADS` (control.dat). These change no product: `data.error_floor_VTF` (invert_VTF is
  false), `sites.utm_zone`, `sites.hemisphere`, `sites.datum` (README text only) and
  `mesh.topography.dem_file` (read only in dem mode).
- **Reasoned, not tested:** `mesh.control.interpolate.*`, `mesh.control.altitude` and
  `mesh.control.sea_depth: null` reach files/control.dat but should be inert on flat, all-zero topography
  (testing needs makeTetraMesh). `schema`, `data.invert_Z` and `data.invert_VTF` have one legal value each.
  `paths.run_dir` is overridden by `--out`.
- **Overwritten on Phoenix** (line numbers at 21:20 on 2026-09-28; other agents are editing these files):
  `inversion.NUM_THREADS` by `femtic_ctl_set control.dat NUM_THREADS` in `04_inversion.slurm:231` and
  `06_forward_only.slurm:173`; `inversion.ITERATION` by `04_inversion.slurm:251` only with AUTO_RESTART=1,
  and always by `06_forward_only.slurm:172` (`ITERATION "0 0"`). Round 1 cited the HEAD lines 04:187,
  04:202-208, 06:90 and 06:109.

### Real v2 config (Parts 3 and 4 of run.log)

Both were run with the same script (sha256 52c25de114503165), once with Windows base Anaconda Python 3.13.5
(numpy 2.3.4, pandas 2.3.3) and once in the WSL conda env `femticpy` of
`validation/mesh_2026-09-25/femticpy_environment.yml` (Python 3.12.14, numpy 2.5.3, pandas 2.3.3), which built
the committed v1-v3 on 09-25. Both give the same results:

- **`python scripts/prep_vulcan.py config/vulcan_mesh_v2.yml --check-only mesh/vulcan_v2`.** This test
  fails if it exits non-zero, any check FAILs, a check other than C03 and C05 is not PASS, or the
  mesh/vulcan_v2 tree changes. Result: **14 checks: 12 PASS, 0 FAIL, 2 N/A (C03, C05)**, exit 0.
  - C04 and C11: max offset 0.67 m.
  - C06: 0.00e+00 over 2520 of 2520 data lines.
  - C08: max rel 5.0e-05 over 20160 values.
  - C09: max rel 4.9e-05 over 10080 SE pairs; the floor is active in 100/97/96/100 % of Zxx/Zxy/Zyx/Zyy.
  - The tree hash of mesh/vulcan_v2 (145 files) was the same before and after, in each interpreter.
- **Full prep into a scratch `--out`, compared with mesh/vulcan_v2.** This test fails if prep exits
  non-zero, observe.dat, inversion/control.dat, station_map.csv or any files/* differs by sha256, or the new
  manifest fails `sha256sum -c`. Result: exit 0, 14 PASS; **13 of 13 files byte-identical** (observe.dat
  f4678d0522a6a8d0, control.dat 8fba4e299c817ab3, station_map.csv 4964e2f5be9204ab, and the 10 files/*);
  `sha256sum -c prep_manifest.sha256` gives 17 OK; no staging directory or marker is left.
  The Windows and WSL outputs are also identical to each other in all 13 files.
- **Fail case of that comparison.** The same products compared with mesh/vulcan_v3 give DIFF for
  files/obs_site.dat and files/observing_site.dat (the site refinement), and exit 1.

## Limits and notes

- **Behaviour changes for Ben.**
  - The existing v1-v3 directories have no manifest, so `--force` alone refuses them. That is intended:
    MAIN/mesh/vulcan_v2 holds the gated mesh.dat, resistivity_block_iter0.dat, vtk/ and halfspace/.
  - An `--out` reached through a symlinked or junctioned parent is refused whatever the flags, also
    for cleaning a leftover staging directory there; pass the real path the message prints. A run into
    a new directory through a link still works, because nothing is deleted, and `--force` on the real
    path then works too (both checked by hand on a junction, not part of the harness).
- **Tolerances:** C04 and C11 positions 1 m; C06 1e-6 relative; C08 and C09 the '%.4e' rounding bound
  (5e-6 to 5e-5 relative).
- **The C03 and C05 N/A under `--check-only` are permanent**: only a full run has femticPy's origin and
  frequency table. Test E shows both failing in a full run.
- **`--check-only` does not verify prep_manifest.sha256.** Run `sha256sum -c prep_manifest.sha256` in the
  directory for that.
- **Mutants are anchored on exact text.** A later edit of prep_vulcan.py that changes an anchor makes
  section M report "mutant not built" as a FAIL, which is the intended signal to update the harness.
- **Hand-edited committed files** (round 2, outside prep): `mesh/vulcan_v{1,2,3}/README.md` "Next steps"
  (line 3 already matched the new template), `mesh/vulcan_v1/REPORT.md:311` (the `--force` sentence), and
  `validation/mesh_2026-09-25/halfspace_accuracy.md:101` (v1 and v3 do not bracket v2). Line 271 of that
  report still says "v1 and v3 bracket it ... but that is an inference"; it was outside this item.
