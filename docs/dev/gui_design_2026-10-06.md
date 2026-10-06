<!--
docs/dev/gui_design_2026-10-06.md - phase-1 design of the FEMTIC student GUI (src/femtic_gui), for Ben and the build agent;
merged from two drafts of 2026-10-06 plus Ben's scope changes that evening. Lines hold for commit 31b1b3b. MAIN/ =
D:/BEN/FEMTIC_2026; CONV = docs/dev/gui_conventions_from_mt_workbench.md; PIPE = docs/mesh_tetra_pipeline.md; CFG =
config/vulcan_mesh_v2_rot.yml; PREP = scripts/prep_vulcan.py; FPY = external/femticPy/src/femticPy.py; 04/06 = hpc/
phoenix_plan/04_inversion.slurm, 06_forward_only.slurm. "Measured" = this PC, 2026-10-06, env femtic_gui; no FEMTIC or WSL.
-->
<!-- review 2026-10-06 (adversarial design review: light reads, a ruamel probe, a pip freeze; no prep run, no WSL).
Reviewed: this file as rewritten at 23:08 (299 lines), a merge by another agent of two drafts. Its first draft
(scratchpad gui_design/gui_design_full.md) was the design under review; the merge keeps most of it. The scope this
merge adds as "Ben's scope changes" (the Never list, the Results tab, readers.py) appears in no brief or repo file the
review saw (grep of docs/: none), so the review left that scope in and only trimmed it where it fails KISS. Ben:
confirm it (finding 14). Other sessions are changing this worktree now (scripts/make_run.sh uncommitted, adds --job
mesh; src/femtic_mesh untracked); cited make_run.sh lines are 31b1b3b's. Every change is marked "review 2026-10-06". -->
<!-- review 2026-10-06 (second pass, 23:21, on the text above): the main session's coordination notice of 23:08 states
that the Never list, the Results tab (model, fits, misfit map, convergence) and readers.py with femtic_mesh owning the
canonical readers later are Ben's decisions; this pass keeps them and restores readers.py (2.6). It also closes G5
(FEMTIC's source is on the PC, finding 9), fixes a test that could not fail (T11), says how the 3D guard knows VTK is
missing without importing it (2.6), and marks the R5 mask as a runbook fix (finding 8). -->

# FEMTIC GUI, phase 1: design (2026-10-06)

## Never (standing constraints for every phase)
- **No network, ever (Ben).** No SSH, SCP, HTTP, Phoenix, cloud, update check, telemetry or remote file access: local
  files and local scripts only. Enforced by a static import test (T6) and the smoke test, which records socket calls
  (T11). <!-- review 2026-10-06: the run-time socket guard in app.py is dropped. The GUI has no network code, so T6
  fails on the first network import; a process-wide patch of socket.connect and getaddrinfo, in a process where
  pyqtgraph and pyvista import socket themselves (measured, T11), guards a hypothetical and adds a failure mode. -->
  UNC paths from any dialog (`\\server\...`, `\\wsl$\...`, `\\wsl.localhost\...`, `//host/...`) are
  refused, which also keeps WSL from starting.
- **No Phoenix status, queue, SSH or job monitoring (Ben).** Students copy outputs back with WinSCP themselves
  (RUNBOOK.md:77-81) and open them in the Results tab.
- **No compute in the GUI process, no modelling on the PC, never WSL** (RUNBOOK.md:10; STATUS.md:94). The GUI never
  runs femtic, tetgen, makeTetraMesh, makeMtr, TetGen2Femtic or mpirun; bash is Git Bash, found explicitly (3).
- **Thin shell, KISS.** Every action is one existing command typed as a student would (3); no checksum, manifest,
  ledger, run database, auto-refresh or git step is added (STATUS.md:16-21).

## 0. Findings that change the brief (G1, G3, G4 and G6 need Ben before or during M1; G2 and G5 settled)
<!-- review 2026-10-06 (second pass): G5 settled by finding 9. -->
<!-- review 2026-10-06: was "G1-G5"; the review settled G2 and added findings 12-14 and G6. -->
1. **ruamel round trip does not keep these configs' layout.** Comments survive, but a load and dump changes 35-36
   lines of each of the four configs, even with indent(2, 4, 2) and a `null` representer: the hand-aligned flow lists
   (CFG:111-119, 132-137, 142-146, 150-158, 166-174) are respaced (measured). The writer patches only the edited
   value's text on its line (3).
2. **Schema prep_vulcan/2 has no site selection.** prep uses every *.edi in paths.edi_dir (CFG:24; PREP:2111) and stops
   unless the EDI ids equal the coordinate table and sites.expected_count (PREP:1762-1769). An include/exclude column
   needs a prep change first (new key, schema /3, checks C02/C04/C07). **G1: leave it out of phase 1 (recommended).**
3. **`bash` on this PC is the WSL launcher.** From a Windows parent it resolves to C:\Users\joint\AppData\Local\
   Microsoft\WindowsApps\bash.exe (measured), so CONV:57's "bash as argv[0]" would start WSL. The runner uses Git's
   bin\bash.exe (3); through it make_run.sh refused a 4x24 layout (exit 1) and made a run in a temp RUNS (measured).
4. **NUM_THREADS and ITERATION never reach Phoenix as configured:** the jobs rewrite them (04:240, 254-260; 06:178-179;
   make_run.sh:73-77). The FEMTIC tab shows both read-only with that reason.
5. **The mesh Build button can never be enabled on a student PC.** run_mesh_chain.sh runs "inside WSL"
   (run_mesh_chain.sh:8, FEMTIC_BIN default :42), modelling on the PC or in WSL is forbidden, and no Phoenix mesh route
   is tested (PIPE:809-812). **G2: drop it (recommended). Review: dropped (2.2).**
   Another workflow is adding `make_run.sh RunNN --job mesh
   --files DIR` and hpc/phoenix_plan/mesh_chain.sh (uncommitted, seen 23:07): once that passes the gate (STATUS.md:207-214),
   "Build" is just that New-run job (2.4), run on Phoenix like any other run.
6. **No predicted mesh counts:** the estimator is not in the repo (PIPE:994) and was off 1.3x in tets, 2.7x in cells
   (PIPE:782-783, 793-794); the Mesh tab shows measured counts.
7. **prep has no --check-config** (PREP:2093-2105): the GUI calls PREP.load_config (PREP:232-434) on a temp file next
   to the target, because paths.root is relative to the config file (PREP:239).
8. **R5 never copies models back.** Its WinSCP mask skips resistivity_block_iter*.dat and mesh.dat (RUNBOOK.md:78), so
   the Results model view has nothing to open. **G4: change the mask to skip only resistivity_block_iter0.dat (each
   later model is about 57 MB), or add an R5 line for the iterations wanted.**
   <!-- review 2026-10-06: confirmed (RUNBOOK.md:78 masks resistivity_block_iter*.dat). This is a runbook fix for the
   workflow that owns RUNBOOK.md; this review does not edit it. Until it lands, the model view can open only MAIN's
   iter0 models, which is why M3's demo uses the v1 half-space fixture. -->
9. **FEMTIC's source is on the PC after all.** A FEMTIC clone that holds 26c8606, the build in use, is in this session's
   scratchpad (port_study/femtic, HEAD 9feced9). 2.3 cites src/AnalysisControl.cpp at 26c8606 (AC) for the five keys
   that rested on the femticPy writer. **G5 closed.** The scratchpad is not kept, so the GUI cites by commit, file and
   keyword, which any FEMTIC clone reproduces.
   <!-- review 2026-10-06: replaced "FEMTIC's source is only inside WSL (PIPE:58)" and G5; AC:107, 331-356, 636-655,
   738-755, 848-862 and 912-924 read with git show 26c8606:src/AnalysisControl.cpp. -->
10. D8 is decided (STATUS.md:194) but RUNBOOK S1 still links Ben's build (RUNBOOK.md:32-36): fix S1 first.
11. **G3: build order.** Students reuse the v2 mesh (CFG:86; PREP:1684-1687), so the riskiest piece comes last: Data,
   FEMTIC, Runs, Results (2D), then viewer3d (7).
<!-- review 2026-10-06: findings 12-14 added by the review. -->
12. **fmax_hz above 100 Hz breaks the mesh, and nothing catches it.** fmax_hz is editable (2.1); neither v2 nor v3
   meets the site-size rule delta_min/20 at 200 Hz (PIPE:570-575; STATUS.md:270-271); prep's design_warnings
   (PREP:1880-1901) test only ellipsoid cover and nesting. So the fmax_hz box stops at 100 Hz, the top band the gates
   run (RUNBOOK.md:90-92), with that reason as tooltip. **G6: also add the rule to prep's design_warnings (a prep
   change, outside the GUI)?**
13. **prep reads the file, not the screen.** Run prep and Check pass the saved config, so after an unsaved edit they
   would run the old values; and "the open file is never overwritten" (3) does not stop Save as from overwriting a
   reference config through the file dialog's own "Replace?" prompt. Rules (3): both job buttons are disabled while
   edits are unsaved, and Save as refuses a target that exists.
14. **Scope to confirm (Ben).** The Never list and the Results tab come from "Ben's scope changes that evening"; the
   first draft left Results out (no inversion iteration has run on a Vulcan mesh, STATUS.md:93). Kept as merged, with
   the Results text and data groups cut (2.5). If Ben did not ask for Results in phase 1, drop 2.5, T8, T9 and M3.
   <!-- review 2026-10-06 (second pass): the main session's notice (23:08) states the Never list, the Results tab and
   readers.py are Ben's decisions, so they stay; only Ben can withdraw them. -->

## 1. Purpose and users
The GUI takes a student from the EDIs to a Phoenix-ready run folder, and from a copied-back run to plots, without
hand-editing YAML or typing long commands. The YAML config is the session (CONV:23-24): the GUI edits a few keys,
checks the file with prep's own loader, previews with prep's own functions and launches the existing scripts. Users:
students on the group's Windows PC with Git Bash, WinSCP and a Phoenix account (RUNBOOK.md:3-4).

| tab | job, in one sentence |
|---|---|
| Data | Choose error floors and bands, see what they do to the data, and run prep. |
| Mesh | See the reused mesh's counts and prep's design warnings, and look at a mesh or a model in 3D. |
| FEMTIC | See every control.dat key prep writes, what it does and where that is stated; edit the few the config owns. |
| Runs | Make a run folder with make_run.sh, read its RUN.md, record the verdict in runs/INDEX.md. |
| Results | Open a copied-back run folder or file and see the model, the data fit and the convergence. |

## 2. Tabs and widgets
File menu (Open Ctrl+O, Save as, recent configs and run folders (CONV:57), Quit Ctrl+Q); Help > Runbook
(hpc/phoenix_plan/RUNBOOK.md read-only, QTextBrowser.setMarkdown; review 2026-10-06); tabs over the console strip
in a splitter (CONV:12); each tab a (state, parent) widget with reload() that imports no other tab (CONV:13-15); every
tooltip names the command it runs (CONV:38). prep_api.py imports PREP once in-process (it needs only numpy and PyYAML
at import, PREP:73-74; femticPy only in a full run, :2166), so every preview is prep's own code.

### 2.1 Data
- **Sites** (QTableWidget, sortable): id, east/north/elev km from paths.coords_file via PREP.read_site_table
  (PREP:438-464; CFG:25,30-32; Vulcan/site_coords_utm53.csv agrees within 0.050 m, measured, and is not read); band
  count and f range per EDI via PREP.parse_edi (PREP:482-536; 120 EDIs in 0.1 s). No include column (G1).
- **Site map**: pyqtgraph ScatterPlotItem + TextItem, east across, north up, km about the bbox centre (PREP:2122-2124),
  aspect locked 1:1 (UTM km; CONV:27's cos(lat) is for lat/lon maps). Map and table select together.
- **Bands** (table): every EDI band with its site count, flagged candidate (unmasked at every site when
  require_all_sites, as check C05 builds it, PREP:1061-1065) and selected (PREP.select_bands, PREP:563-596). Controls
  bound to frequencies.fmax_hz, fmin_hz, per_decade, require_all_sites (CFG:79-82); explicit_hz (CFG:83) read-only.
  The fmax_hz box stops at 100 Hz (finding 12; review 2026-10-06).
  Counts as in Vulcan/frequency_table.csv. Measured: 53 candidates, 21 selected, those of the v2_rot observe.dat.
- **Error floors**: four spin boxes on data.error_floor_Z (CFG:52; meaning CFG:44-51) and a live readout "floor active
  in a/b/c/d % of Zxx/Zxy/Zyx/Zyy (N site-band pairs)", worded and counted as check C09 (PREP:1123-1126, 1175): after
  rotation (prep floors the rotated tensor, PREP:1771-1783), floor_i sqrt(|Z'xy| |Z'yx|) > sqrt(VAR'_i) over the
  selected bands present and unmasked at that site. Measured on CFG: 2514/2443/2413/2511 of 2520 = 100/97/96/100 %,
  C09's line (mesh/vulcan_v2_rot/README.md:291), under 0.05 s per update.
  <!-- review 2026-10-06: "present and unmasked at that site" added: the scratch probe took the nearest band at every
  site, which with require_all_sites false counts a neighbouring band where a site lacks one; prep floors only the
  lines it writes (C07). Kept under the thin-shell rule as a preview: prep's functions, nothing written, and prep's
  C09 line stays the authority (T4). -->
- **Rotation** (read-only): CFG:61-71 and PREP.rotation_text (PREP:161-170); without the block, PREP:1882-1885.
- **Curves** of the selected site: linked plots over log period of rho_a = 0.2 T |Z|^2 (PIPE:427) and phase, xy and yx
  (xx, yy on a checkbox); EDI frame dashed, rotated (PREP.rotate_Z, PREP:117-127, angle from PREP.rotation_angles,
  :130-158) solid; the selected bands as vertical lines.
- **Buttons**: "Check" = `python scripts/prep_vulcan.py <config> --check-only <dir>`; "Run prep" = `python
  scripts/prep_vulcan.py <config> --out <dir>`; dir defaults to paths.run_dir (CFG:27). Never --force or
  --force-delete-foreign: prep refuses a non-empty dir (PREP:2136-2143) and the field says so before the run. Both
  buttons are disabled while edits are unsaved, the tooltip saying so (finding 13; review 2026-10-06).

### 2.2 Mesh
- **Readouts**: PREP.design_warnings (PREP:1880-1901) and the counts of mesh.reuse_from's mesh_logs/mesh_stats.txt:1-2
  (v2: 2,446,095 tetrahedra, 65,342 cells with air). Mesh keys are read-only: with mesh.reuse_from set, any change
  fails C17 (PREP:1335-1359).
  <!-- review 2026-10-06: removed (a) the plan-view design preview, its zooms and the size-table plot: they draw
  settings no student can change in phase 1 (C17), so they belong to the mesh-editing phase; (b) the delta_min/20
  readout, a design rule the GUI would compute and prep does not (thin-shell rule); its one student-reachable case,
  fmax_hz above 100 Hz, is now a widget bound and G6 (finding 12); (c) the Build bullet: G2 is settled, no button. -->
- **3D**: "Load mesh" opens viewer3d (2.6) on MAIN/<reuse_from>/inversion/ (mesh.dat + iter0 block) or a .vtk.

### 2.3 FEMTIC
One row per control.dat key in femticPy's order (FPY:533-572). The four curated rows are editable, the rest never, each
saying why (review 2026-10-06: no "Advanced" box, see the table); a pane shows <out>/inversion/control.dat
(format: hpc/phoenix_plan/femtic_lib.sh:23-28). AC = src/AnalysisControl.cpp of FEMTIC at 26c8606 (finding 9). The
GUI's source column names a file and a keyword, never a line number (they drift, STATUS.md:279); the line numbers here
are for review. <!-- review 2026-10-06 (second pass): AC added; no line numbers on screen. -->
The GUI never writes control.dat: prep does, through FPY (PREP:1815-1819), and check C14 verifies it (PREP:1291-1321).

| key | now (CFG) | kind | meaning | source |
|---|---|---|---|---|
| NUM_THREADS | 8 (:195) | read-only | OpenMP threads per rank; every Phoenix job sets the layout's | 04:240; 06:179 |
| MESH_TYPE | 1 (fixed) | read-only | tetrahedral mesh | FPY:535-536; PREP:1305; PIPE:585 |
| OUTPUT_PARAM_VTK | 2 / 0 4 (fixed) | read-only | output fields: resistivity (0) and sensitivity (4) | FPY:537-539; CFG:193 |
| OFILE_TYPE | 0 (fixed) | read-only | 0: ASCII, one VTK file per iteration; any other value, or no key (FEMTIC's default): binary EnSight case, as FEMTIC's example wrote (validation/phoenix_2026-09-28/restart/result.case:1-2) | FPY:540-541; AC:107, 331-334, 353-356, 848-862 |
| DISTORTION | 0 (:210) | read-only | distortion correction; prep refuses anything but 0 | PREP:419-424 |
| ALPHA_WEIGHT | 1 1 1 (:209) | curated | roughness weights in x (north), y (east), z | CFG:209; FPY:544-547 |
| INV_METHOD | 1 (:204) | read-only | 0 model space, 1 data space; 1 always here: 65,341 (v2) or 68,654 (v3) cells > 120 x 53 x 8 = 50,880 data at most (review 2026-10-06) | PIPE:500-505 (manual.txt:73-82) |
| BOTTOM_RESISTIVITY | 100 (:211) | curated | ohm-m below the mesh bottom, in the roughening matrix | CFG:211-212; FPY:550-551 |
| BOTTOM_ROUGHNING_FACTOR | 1.0 (fixed) | read-only | roughening factor at the mesh bottom; FEMTIC refuses a negative value | FPY:552-553; AC:912-924 |
| OUTPUT_OPTION | 0 0 (fixed) | read-only | 0 0: the backward element in x and in y (AC's m_useBackwardOrForwardElement) | FPY:554-555; AC:636-655 |
| TRADE_OFF_PARAM | 3 (:205) | curated | regularisation trade-off (femtic.cnv column Alpha); one value for DISTORTION 0; bracket it per run | CFG:205-206; PREP:425-427 |
| ITERATION | 0 10 (:207) | read-only | first and last iteration; every Phoenix job sets it (finding 4) | 06:178; make_run.sh:73-77; 04:254-260 |
| RETRIAL | 2 (fixed) | read-only | maximum step-length cut-backs; reaching the limit ends the job STALLED, exit 2 | FPY:562-563; AC:738-745; README_phoenix.md:624 |
| CONVERGE | 0.2 (:208) | curated | % change of the objective function that ends the iterations | CFG:208; README_phoenix.md:622 |
| STEP_LENGTH | 0.5 0.1 1.0 / 3 / 0.5 1.25 (fixed) | read-only | damping: start 0.5, min 0.1, max 1.0; x1.25 after 3 iterations, x0.5 to decrease; grew 0.5, 0.625, 0.78125 in FEMTIC's example; restarts at its start value | FPY:566-569; AC:746-755; validation/wsl_2026-09-25/run_logs/femtic.cnv:2-7; README_phoenix.md:638-640 |
| OWNER_ELEMENT | -1 (:217) | read-only | H from the element above the site via dummy VTF stations; the meshes and the gate assume -1 | CFG:213-216; PIPE:393, 466 |

Phoenix jobs also add SENSE_MAT_DIRECTORY, FWD_SOLVER and MEM_LIMIT (04:241-249); a note under the table says so.
<!-- review 2026-10-06 (second pass): G5 closed: OFILE_TYPE, BOTTOM_ROUGHNING_FACTOR, OUTPUT_OPTION, RETRIAL and
STEP_LENGTH cite AC. OFILE_TYPE's "unverified" is settled: 0 = ASCII VTK, anything else binary EnSight, and the
default without the key is binary (AC:107), which is why FEMTIC's example wrote EnSight. CFG:193 was right. -->

### 2.4 Runs
- **Table** of runs/INDEX.md (run, mesh, purpose, layout, job id(s), verdict; make_run.sh:121; runs/INDEX.md:3-7) and
  the selected run's RUN.md (QTextBrowser.setMarkdown); its job lines arrive only with R5 (RUNBOOK.md:77-81).
- **New run**, one field per make_run.sh option (make_run.sh:6-18): name (next free RunNN over runs/ and INDEX.md;
  :64-65 refuse reuse), --mesh (default from mesh.reuse_from), --data (default <paths.run_dir>/inversion; RUNBOOK.md:61
  uses mesh/vulcan_v2_rot/inversion), --job, --start-rho / --iter-step --iter-max enabled as :52-62 require, --layout
  (v2 3x24, v3 2x36, RUNBOOK.md:63), --time, --partition, --niv, --mail, --purpose (required, :49). A preview shows the
  exact command; "Make run folder" runs it as an argv list; make_run.sh alone validates (its `REFUSED:` line, :28).
  Each field's tooltip is that option's line of make_run.sh's own header (its `#   --` lines, read at start-up).
- **After exit 0** the console holds make_run.sh's own `made <folder>` and `next: WinSCP ... run.sh RunNN` lines (R2,
  R3), and the table and RUN.md pane show the run; R4-R6 are in Help > Runbook. **Record result**: job id(s) and
  verdict; the GUI rewrites those two cells of that line only and shows R6's git line to copy (:83-85); it runs no git.
  <!-- review 2026-10-06: "Copy instructions" (R2-R6 as text) replaced: a second copy of the RUNBOOK drifts (S1 is
  stale already, finding 10) and repeats make_run.sh's own output. Tooltips come from make_run.sh's header so a
  student does R1 without reading code; R2 is WinSCP, outside the GUI. Build the form against the committed
  make_run.sh at M2: the working copy adds --job mesh with --files and --seeds (finding 5), uncommitted. -->

### 2.5 Results (phase 1: reads and plots, launches nothing)
"Open folder..." (default runs/) and "Open file..." fill one list, grouped; selecting an entry opens it. EnSight files
(Mesh.geo, *.iter*, BlockIDs, result.case) and anything unrecognised are not listed.

| group | files | opens as |
|---|---|---|
| model | resistivity_block_iter<N>.dat | viewer3d on the run's mesh.dat; iteration selector over the N found |
| data fit | result_<rank>_iter<N>.csv, the ranks of one N concatenated | curves, misfit map, residual table |
| convergence | femtic.cnv and logs/run_*/femtic.cnv | RMS and ObjFunc against iteration |

<!-- review 2026-10-06: the "data" group (observe.dat as the Data tab's curves again) and the "text" group (RUN.md,
run.env, control.dat, slurm-*.out, logs/*.txt as read-only text: a second text viewer; RUN.md is already in the Runs
tab) are cut. Results keeps what its one sentence promises: model, data fit, convergence. -->

- **Model**: the mesh defaults to <repo>/mesh/vulcan_<MESH>/inversion/mesh.dat, MESH from run.env (make_run.sh:81),
  else the dialog asks; a block whose element count differs from mesh.dat's is refused with both numbers. (G4.)
- **Data fit** (readers.read_result_csv): line 1 "MT,", line 2 the header (StaID, Freq[Hz], Re/Im of Zxx..Zyy for
  _Cal, _Res, _Obs, _SD), the MT block ending at "VTF," (MAIN/mesh/vulcan_v1/halfspace/acc_100/b1/
  result_0_iter0.csv:1-2,243); _Res = (Obs - Cal)/SD (checked on line 3). Names: station_map.csv femtic_station_id ->
  site_id (PREP:1827-1834). Per site: observed (points, error bars 2 rho SD/|Z| and SD/|Z| rad, CFG:48-49) and
  calculated (line) rho_a and phase, xy and yx, xx/yy on a checkbox. Misfit map: site RMS = sqrt(mean _Res^2),
  coloured on the site map. Residual table: site, RMS, worst |_Res| with band and component; a row selects the site.
  (Per-site RMS is plotting work no script does, so it belongs here; T8 ties it to femtic.cnv.)
- **Convergence** (readers.read_cnv): FEMTIC truncates femtic.cnv at each start, so 04 archives it into
  logs/run_<stamp>/ (04:162-166), which R5 brings back (RUNBOOK.md:79). Read archives in name order, then femtic.cnv;
  keep the last row per Iter# (the accepted one, as hpc/phoenix_plan/femtic_lib.sh:91-94 does).
- **Units**: observe.dat and the csv hold Z in ohm, exp(-i omega t) (PREP:76, 1117): rho_a = |Z|^2/(2 pi f mu0), phase
  of conj(Z). mtcalc.rho_phase_ohm serves both tabs, so both draw the same datum the same way (T7).
- A gate's csv files stay in fwd0_<jobid>/ (06:124), which R5 skips; its verdict is logs/fwd0_report_<jobid>.txt
  (06:360), which status.sh already prints on Phoenix (R4).

### 2.6 viewer3d.py (pyvistaqt), used by Mesh and Results
- The only module that imports vtk, pyvista or pyvistaqt, inside its functions, and no module imports it at load
  time. Start-up asks importlib.util.find_spec for pyvistaqt and vtkmodules (nothing is imported); if either is
  missing the 3D buttons are disabled with the reason as tooltip. The first "Load" imports viewer3d inside try/except
  (ImportError, OSError: a VTK DLL or OpenGL failure) and shows "3D viewer unavailable: <reason>"; the rest works.
  <!-- review 2026-10-06 (second pass): said how availability is known without importing VTK, and that a failed import
  at Load is caught too (find_spec cannot see a broken DLL). -->
- Loads in a QThread (CONV:21-22; the plotter is touched on the GUI thread only): readers.read_mesh + read_block, or
  pyvista.read(.vtk) (readers.py's mesh part: below).
  Measured on v2 (2,446,095 tets): mesh.dat 2.4 s, block 0.8 s, grid 0.3 s, earth cells + surface + one slice 2.6 s,
  683 MB peak; the 329 MB ASCII MAIN/mesh/vulcan_v2/vtk/output.6.femtic.vtk 7.1 s, 399 MB.
- Shows the site area (x, y within +-12 km, z -2 to 10 km, clipped for display), never the full grid: the earth
  surface (air is cell 0 at 1e9, CFG:161), three orthogonal slices with sliders, a log10 rho threshold drawn as the
  surface of the kept cells, colour by log10 rho (one colour bar) or by parameter cell, sites from station_map.csv.
  Display axes east, north, up = (y, x, -z) of FEMTIC's frame, metres (PIPE:43,45).
- readers.py holds the phase-1 mesh.dat and block reader; src/femtic_mesh (another workflow; its untracked
  femtic_mesh.io.femtic reads both, with its own tests) will own the canonical readers, and readers.py switches to it
  when it lands, with T10 as the contract. viewer3d is built last (M5): if femtic_mesh is committed by then,
  readers.py's two mesh functions are thin calls into it, not a second parser; time it on v2 first (it parses with
  numpy.loadtxt; the timings above used pandas). <!-- review 2026-10-06 (second pass): restored readers.py as the
  phase-1 owner, which the main session's notice lists as Ben's decision; the first pass had removed it. Its
  no-second-parser point stays as the build note. -->

## 3. Data flow
- **The config is the session**: ruamel (rt) load into State, prep import, EDI parse, config_changed, tabs reload().
- **Writing (config_io.set_value): line-targeted.** ruamel gives each key's line (CommentedMap.lc.key); only the value
  text on that line is replaced, its comment kept (finding 1). Floats as repr, lists in flow style, None as `null`; a
  key whose value spans lines is refused (none in phase 1). Widgets and keys:

| widget | key | CFG line |
|---|---|---|
| Data: fmax, fmin, per decade, all sites | frequencies.fmax_hz, fmin_hz, per_decade, require_all_sites | 79-82 |
| Data: four floor boxes | data.error_floor_Z | 52 |
| FEMTIC: curated rows | inversion.TRADE_OFF_PARAM, CONVERGE, ALPHA_WEIGHT, BOTTOM_RESISTIVITY | 205, 208, 209, 211 |
| Save as | name, paths.run_dir | 20, 27 |

- **Save as only** (default config/<name>_<initials>.yml): the open file is never overwritten, so the reference
  configs, records of built meshes (STATUS.md:184-186), stay as they are; Save as refuses a target that exists, and
  Run prep and Check are disabled while edits are unsaved (finding 13; review 2026-10-06).
  **Validation before save**: write a temp file next to the target, PREP.load_config on it (finding 7),
  os.replace() onto the target only if no PrepError (PREP:84-89),
  whose message is shown verbatim (measured: a 3-value floor is refused by name).
- **prep outputs read back**: the GUI chose --out, so it knows the folder (no regex on output, CONV:56). After exit 0
  it shows <out>/README.md; after a failure the console, which holds every line prep printed (<out>.staging/prep.log
  exists only when a self-check failed, PREP:2183). <!-- review 2026-10-06: dropped the prep_manifest.sha256 file
  listing (prep's --force guard, nothing for a student) and the claim that a failure always leaves prep.log. -->
- **JobRunner (jobs.py).** One job at a time: run(label, argv) returns False while busy and the start buttons are
  disabled; no queue (deviation from CONV:43; nothing needs batching). argv is a list, never a shell string: argv[0]
  is sys.executable for .py, Git Bash for .sh; repo-relative paths with forward slashes; cwd = repo root =
  Path(jobs.py).resolve().parents[2] (editable install), checked to hold scripts/prep_vulcan.py. QProcess, merged
  channels, system environment plus PYTHONUNBUFFERED=1, ANSI stripped, lines to the console. `$ <command>` before;
  `--- <label>: done (exit 0)`, `failed (exit N)` or `failed to start (<argv0>)` after; cancel() kills, waits 3 s,
  writes `--- cancelled: <label>`. Signals started, finished(ok), line; tabs reload on finished.
- **find_bash()**: Git\bin\bash.exe beside the git.exe on PATH (Git\cmd or Git\mingw64\bin), else C:\Program Files\
  Git\bin\bash.exe; anything under WindowsApps or System32 is refused (finding 3); none found disables the bash buttons.
- **Commands**: exactly those quoted in 2.1 and 2.4; each is also its button's tooltip. <!-- review 2026-10-06
  (second pass): 2.2 launches nothing since the Build bullet went. -->

## 4. Package, pins, entry points
src/femtic_gui/: `__main__.py` (argparse [config], QT_API=pyside6, theme.apply(), MainWindow, main()); `app.py`
(MainWindow, menus, cross-tab wiring); `state.py` (State(QObject): config, ruamel doc, EDIs, selection,
job_running, signals); `config_io.py` (load, set_value, validate, save_as, local_path refusing UNC); `prep_api.py` (the
one importer of PREP); `mtcalc.py` (rho/phase in EDI units and in ohm, error bars; numpy); `readers.py` (result csv,
femtic.cnv merge, mesh.dat + block (2.6), station_map.csv, INDEX.md rows, control.dat; numpy and pandas' C parser,
no Qt);
`jobs.py`, `console.py`, `theme.py`, `plots.py` (shared rho/phase stack, site map); `viewer3d.py`; `tabs/{data,mesh,
femtic,runs,results}.py` (split off <tab>_plots.py before 350 lines). tests/ with fixtures/ (b1 csv, femtic.cnv).
pyproject.toml: setuptools, src layout, python ==3.11.*, `femtic-gui = "femtic_gui.__main__:main"`, also `python -m
femtic_gui`; one root pyproject shared with src/femtic_mesh (agree it with that workflow; viewer3d imports it).
<!-- review 2026-10-06: app.py's socket guard removed (Never list). readers.py's mesh.dat + block reader was removed
by the first pass and restored by the second (2.6). -->
environment.yml: name
femtic_gui, conda-forge only (nodefaults), python=3.11, pip, the pins below, then `-e .`.

**Pins, installed and working together on 2026-10-06** (env femtic_gui, conda-forge Python 3.11.17, `pip check`
clean): PySide6 6.11.2 (PySide6_Essentials, PySide6_Addons, shiboken6 6.11.2), pyqtgraph 0.14.0, pyvista 0.49.0,
pyvistaqt 0.13.1, QtPy 2.4.3, vtk 9.7.1, ruamel.yaml 0.19.1, numpy 2.4.6, pandas 2.3.3 (femticPy needs < 3,
PREP:1718-1719), matplotlib 3.11.2 and PyYAML 6.0.3 (prep and femticPy only, PREP:22-23). Rest of the freeze: attrs
26.1.0, certifi 2026.7.22, charset-normalizer 3.5.2, colorama 0.4.6, contourpy 1.3.3, cycler 0.12.1, cyclopts 5.1.1,
docstring_parser 0.18.0, fonttools 4.66.1, idna 3.20, kiwisolver 1.5.1, markdown-it-py 4.2.0, mdurl 0.1.2, packaging
(conda), pillow 12.3.0, platformdirs 4.12.3, pooch 1.9.0, Pygments 2.21.0, pyparsing 3.3.3, python-dateutil
2.9.0.post0, pytz 2026.5, pyvista-validation 0.2.2, requests 2.34.2, rich 15.0.0, rich-rst 2.2.0, scooby 0.12.0, six
1.17.0, typing_extensions 4.16.0, tzdata 2026.5, urllib3 2.8.0. Evidence: a full prep of CFG into a scratch --out
passed 18/18 with its 13 products byte-identical to mesh/vulcan_v2_rot's; --check-only on mesh/vulcan_v2_rot gave
16 PASS, 2 N/A; an offscreen pyqtgraph log plot and locked-aspect scatter rendered; a pyvistaqt QtInteractor rendered
on this PC's console session; the mesh timings of 2.6.

## 5. Deliberately not in phase 1
- Site include/exclude (G1); editing mesh tables or rebuilding meshes (no tested route, PIPE:809-815; every rebuild
  must pass the gate, STATUS.md:212-214); mesh-port integration (src/femtic_mesh, D10/D11); DEM topography editing
  (Vulcan is flat, CFG:95-101); a job queue, git buttons, run comparison, figure export (no current need).
- **Never, not deferred:** Phoenix status, queue, SSH or monitoring, and any network use (the Never list).
- Cut by the review (2026-10-06): a mesh Build button (G2, finding 5: a Phoenix mesh build will be a New-run job);
  the "Advanced" FEMTIC keys (2.3); the 2D mesh design preview and a GUI delta_min/20 readout (2.2; with mesh-key
  editing, the readout as a prep design warning, G6); a RUNBOOK copy in the Runs tab (2.4); the Results "data" and
  "text" groups (2.5); a second mesh parser once femtic_mesh lands (2.6); a run-time socket guard (Never list).
  <!-- review 2026-10-06 (second pass): "a second mesh reader" narrowed: readers.py keeps the phase-1 reader. -->

## 6. Tests (plain scripts with test_ functions; each states "This test fails if ..." and shows its failing case first)
Without Qt:
- **T1** config_io: fails if set_value on data.error_floor_Z changes any byte of CFG outside line 52's value, or the
  re-read value differs. Failing case: a plain ruamel dump (36 lines change, measured).
- **T2** fails if validate accepts a 3-value floor or touches the target. **T3** fails if local_path accepts a UNC path.
- **T4** fails unless the floor readout's four counts on CFG are 2514/2443/2413/2511 of 2520, the counts recovered
  from mesh/vulcan_v2_rot/inversion/observe.dat (SE equal to floor x sqrt(|Zxy| |Zyx|) within the write rounding), and
  unless, with require_all_sites false, they equal those of a prep run of that variant into a temp --out. Failing
  cases: VAR instead of sqrt(VAR) (100/100/99/100 %, measured); no rotation (Zyx 2412, measured); the nearest band at
  a site that lacks it. <!-- review 2026-10-06: was whole percent against C09's line, with "a missing rotation ...
  is invisible at whole percent; T7 catches it". T7 tests mtcalc, not the floor readout, so that case could not fail
  anywhere; counts from the written observe.dat are the independent observable that catches it. -->
- **T5** fails unless the selected bands equal the 21 of mesh/vulcan_v2_rot/inversion/observe.dat (failing: per_decade 5).
- **T6** fails if any .py under src/femtic_gui imports socket, ssl, http, urllib.request, urllib3, requests, pooch,
  paramiko, ftplib, smtplib, asyncio, PySide6.QtNetwork or PySide6.QtWebEngine* (AST scan). Failing case: a temp
  copy with one `import urllib.request`.
- **T7** fails if rho_a or phase from observe.dat (mtcalc.rho_phase_ohm) differs from the rotated EDI value beyond the
  4-digit write bound (PREP:1121) at any of the 2,520 site-bands. Failing cases: no conjugation; no rotation.
- **T8** fails unless sqrt(mean _Res^2) over tests/fixtures/result_0_iter0.csv equals femtic.cnv's iteration-0 RMS to
  7 digits (2.180320e+01, measured). Failing case: a reader that takes _SD for _Res or runs past the "VTF," line.
- **T9** fails unless merging validation/phoenix_2026-09-28/restart/femtic.cnv.leg1 and .leg2 gives exactly the rows
  of straight/femtic.cnv. Failing case: plain concatenation (two iteration-1 rows).
- **T10** (needs MAIN's v2 mesh; prints NOT RUN and exits 2 without it, never PASS): fails unless the counts equal
  mesh_stats.txt:1, the element volumes sum to the (1000 km)^3 box within 1e-6 (the chain's rule,
  run_mesh_chain.sh:207-217), and iter0 puts 1,149,539 elements at 1e9 and 1,296,556 at 20 ohm-m (CFG:161,182). All
  hold (measured; the reader also equals TetGen2Femtic's VTK). Failing case: node columns read one to the left.
With Qt:
- **T11** tests/gui_smoke.py (QT_QPA_PLATFORM=offscreen; JobRunner start replaced by a recorder; socket calls patched
  to record; QFileDialog and QMessageBox stubbed, so no modal dialog blocks): opens CFG, clicks every tab with QTest
  (site, per_decade, floors, new-run form, Results on tests/fixtures/), presses every job button.
  Fails if a tab raises, a recorded argv differs from the expected list (e.g. RUNBOOK.md:96's Run04 line), a file
  outside the temp folder changes, vtk, vtkmodules, pyvista or viewer3d is in sys.modules
  after the 2D clicks, a connection is attempted, or PySide6.QtNetwork is loaded; a second pass with
  sys.modules["vtkmodules"] = None fails unless the 3D buttons are disabled with a tooltip and Load shows the reason.
  Failing case: a tab importing viewer3d at module level. <!-- review 2026-10-06 (second pass): was
  sys.modules["vtk"] = None, which cannot fail: pyvista imports vtkmodules, not vtk, and pyvistaqt imported fine with
  only "vtk" blocked (measured, review_gui/vtk_block_probe.py); with "vtkmodules" blocked the import raises
  ImportError. vtkmodules added to the first-pass list for the same reason. -->
  pyqtgraph and pyvista import socket themselves (measured), hence connections plus T6, not
  sys.modules. Rendering is not automated (M5 demo).
- **T12** tests/jobs_test.py (real QProcess; light): make_run.sh with RUNS=<temp> (make_run.sh:27). Fails unless
  `--layout 4x24` ends `failed (exit 1)` with its REFUSED line (:46), the 3x24 run ends `done (exit 0)` with Run99 and
  its INDEX.md line in the temp folder only, and find_bash returned no WindowsApps or System32 path.
- **T13** (review 2026-10-06) fails if Save as writes over an existing file, or Run prep or Check is enabled while
  the State has unsaved edits. Failing case: Save as through QFileDialog's own "Replace?" prompt.

## 7. Milestones and risks
| M | content | demo |
|---|---|---|
| M1 | env, skeleton, theme, console, JobRunner, config_io, Data | per_decade 5 moves the ticks; floors read 100/97/96/100; Check prints 16 PASS, 2 N/A; Save as, then Run prep into a new folder: 18 PASS |
| M2 | FEMTIC, Runs | the key table; Run04 made exactly as RUNBOOK.md:96 in a temp RUNS; a verdict recorded |
| M3 | Results, 2D | MAIN/mesh/vulcan_v1/halfspace/acc_100/b1: fit, misfit map, convergence (no Vulcan inversion output yet) |
| M4 | Mesh tab (counts, design warnings) | v2's counts from mesh_stats.txt; no design warning on CFG |
| M5 | viewer3d | v2 mesh + iter0 in under 10 s: slices, threshold, sites; also over Remote Desktop |

- **VTK over Remote Desktop** may lack OpenGL; only the console was tested (isolated module; M5 tests it). **Pins**:
  rendered together today; QtPy picks the binding, so __main__ sets QT_API=pyside6 first. <!-- review 2026-10-06: the
  14 named pins re-checked against pip freeze of anaconda3/envs/femtic_gui: all match. QT_API is harmless but not
  needed: QtPy 2.4.3 uses an already-imported binding (qtpy/__init__.py), and the GUI imports PySide6 first. -->
- **Moving targets** (review 2026-10-06): make_run.sh (--job mesh) and src/femtic_mesh are being changed by other
  sessions, uncommitted today. Build the Runs form and viewer3d against their committed versions.
- **2.4-3.1 M tetrahedra**: 6.2 s and 683 MB on v2 (v3 has 1.25x the tets); worker thread, surfaces and slices only.
- **mesh.dat in Python**: pandas' C parser, usecols, int32 connectivity suffice (measured); no chunking. **prep's
  functions are an internal API**: prep_api.py is the only importer; T4, T5 and T7 exercise it.
- **Line references drift** while several sessions edit this tree (STATUS.md:279).

## 8. Built (phase 1, 2026-10-07, build agent; uncommitted in this worktree)
Everything in 2-7 is built as amended by both review passes, including Results (Ben's decision, finding 14) and
readers.py's mesh functions (2.6). Nothing heavy ran: no FEMTIC, mesh tool, mpirun or WSL; prep_vulcan.py ran in
full only inside T4 (about 3 s, temporary --out) and make_run.sh only inside T12 (temporary RUNS).
- **Package** src/femtic_gui (lines): config_io 314, prep_api 179, readers 258, mtcalc 65, state 134, jobs 185,
  console 62, theme 92, plots 136, app 209, viewer3d 238, `__main__` 43, `__init__` 31; tabs/: data 167,
  data_panel 209, femtic 182, mesh 121, runs 171, runs_form 123, results 338, common 127. All under 350, LF only,
  pyflakes clean, compileall clean. `python -m femtic_gui --help` and `femtic-gui --help` exit 0.
- **Env**: femtic_gui (conda-forge Python 3.11.17) with the 4. pins plus loguru 0.7.3 and win32_setctime 1.2.0
  (pip, for the console sink); `pip check` clean; the full freeze is in environment-gui.yml (this file's
  "environment.yml"). `pip install -e . --no-deps` points the env at THIS worktree: rerun it from MAIN after the merge.
  environment-gui.yml itself was not tested with `conda env create`.
- **Tests** (tests/gui, `python tests/gui/run_all.py`, 19 s): 44 PASS, 0 FAIL, 0 NOT RUN; each prints its "fails if"
  line, its failing case, then the real case. T1-T3, T13 (save) test_config_io (7); T4, T5 test_prep_api (4: also
  raised floors recovered from observe.dat alone, Zxy 0.1 gives 2503 of 2520); T6 test_static (2: also VTK only
  inside viewer3d's functions); T7 test_mtcalc (worst 0.9995 of the write bound: the bound is tight by
  construction); T8, T9 test_readers (5); test_state (4); T12 test_jobs (5: also cancel, busy, failed to start);
  T10 test_mesh_reader (v2 read in 2.5 s; NOT RUN, exit 2, without MAIN); test_viewer3d (scene actors on
  chain_proof, offscreen); T11, T13 gui_smoke.py + _smoke_harness.py (14 steps, incl. Results on the b1 fixture and
  the RUNBOOK's own Run06 line typed character for character; vtkmodules blocked in the second pass).
- **Deviations**: (a) pyproject requires-python >=3.10 and numpy>=1.23 (shared with femtic_mesh, whose env says
  so); exact pins in the `gui` and `viewer` extras; no licence field (LICENSES.md: none chosen yet; the module
  headers carry CONV's ":license: MIT", Ben to confirm). (b) readers.read_mesh/read_block are thin calls into
  src/femtic_mesh (another workflow's, untracked): commit it with the GUI, or the 3D buttons stay disabled with
  "femtic_mesh not installed". (c) Save as also refuses a target whose paths.root would resolve to another root
  (save next to the open config); its default name uses the login name, not initials. (d) The New-run form offers
  the committed jobs (gate, forward, t4, inversion); the tooltips are read from the working copy's header.
  (e) T11/T12 live in tests/gui/; the b1 csv fixture is tests/gui/fixtures/b1/b1_result_0_iter0.csv because
  .gitignore drops result_*_iter*.csv (PROVENANCE.txt; gui_smoke.py copies it back to its FEMTIC name).
- **Not verified**: rendering on a real screen and over Remote Desktop (M5; offscreen Qt has no OpenGL, so the 3D
  test checks actors, not pixels, and the 2D tabs were seen only as font-less offscreen grabs); the M1 demo with
  real prep jobs through the GUI (the smoke test intercepts every job); a Results model view of an iteration > 0 (no
  such file on the PC, finding 8/G4). Open with Ben: G1, G4, G6, finding 10.
