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
  **Phase 2 (Ben, 2026-10-07):** a child process may run the four mesh tools on a student's own machine; FEMTIC,
  mpirun and WSL never, Ben's PC never: section 9.0.
- **Thin shell, KISS.** Every action is one existing command typed as a student would (3); no checksum, manifest,
  ledger, run database, auto-refresh or git step is added (STATUS.md:16-21).

## 0. Findings that change the brief (G1, G3 and G6 need Ben before or during M1; G2, G4 and G5 settled)
<!-- fixes 2026-10-07: was "G1, G3, G4 and G6 ...; G2 and G5 settled"; G4 closed by abbee8a (finding 8). -->
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
   <!-- fixes 2026-10-07: `make_run.sh --job mesh --files DIR [--seeds ...]` is in the committed make_run.sh
   (abbee8a) and the New-run form now offers it (2.4). -->
   **G2 reopened (Ben, 2026-10-07):** students may build meshes on their own machines; the cut held for Ben's PC
   only. Phase 2's "Build mesh: Local | Phoenix" is section 9.
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
   **G4 closed (fixes 2026-10-07):** R5's mask now skips only resistivity_block_iter0.dat, so the iteration models
   resistivity_block_iter<N>.dat (N >= 1) come back (RUNBOOK.md:74 at abbee8a). A model view of an iteration
   above 0 is still untested (no such file on the PC).
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
   **Confirmed by Ben in chat on 2026-10-06 (fixes 2026-10-07):** the Results tab is in phase 1, and no network,
   ever. Finding 14 is closed.

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
- **Phase 2 (2026-10-07):** with mesh.reuse_from null the mesh keys become editable, the plan view and size plot
  return, prep reports the derivable sizes, and "Build mesh: Local | Phoenix" appears: section 9.1-9.3. The
  phase-1 behaviour above stays for a config that reuses a mesh.

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
  <!-- fixes 2026-10-07: --job mesh is committed (abbee8a), and the form has it: --files (a folder picker, filled
  relative to the repository) and --seeds, shown only for --job mesh; --mesh, --data and --niv hidden for it
  (make_run.sh refuses them); an empty --layout or --time is left out (make_run.sh's 1x8 and 04:00:00), so the
  form types make_run.sh's header example character for character. After a made run the form clears --purpose and
  the job-specific fields (--start-rho, --iter-step, --iter-max, --files, --seeds). -->

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
  <!-- fixes 2026-10-07: both are committed in abbee8a; the form offers --job mesh. -->
- **2.4-3.1 M tetrahedra**: 6.2 s and 683 MB on v2 (v3 has 1.25x the tets); worker thread, surfaces and slices only.
- **mesh.dat in Python**: pandas' C parser, usecols, int32 connectivity suffice (measured); no chunking. **prep's
  functions are an internal API**: prep_api.py is the only importer; T4, T5 and T7 exercise it.
- **Line references drift** while several sessions edit this tree (STATUS.md:279).

## 8. Built (phase 1, 2026-10-07, build agent; committed in 2067eb0; fixes below, 2026-10-07)
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
  the committed jobs (gate, forward, t4, inversion, and mesh since the fixes below); the tooltips are read from
  make_run.sh's header.
  (e) T11/T12 live in tests/gui/; the b1 csv fixture is tests/gui/fixtures/b1/b1_result_0_iter0.csv because
  .gitignore drops result_*_iter*.csv (PROVENANCE.txt; gui_smoke.py copies it back to its FEMTIC name).
- **Not verified**: rendering on a real screen and over Remote Desktop (M5; offscreen Qt has no OpenGL, so the 3D
  test checks actors, not pixels, and the 2D tabs were seen only as font-less offscreen grabs); the M1 demo with
  real prep jobs through the GUI (the smoke test intercepts every job); a Results model view of an iteration > 0 (no
  such file on the PC, finding 8/G4). Open with Ben: G1, G6, finding 10 (G4 and finding 14 closed).
- **Fixes 2026-10-07** (six of the verifier's nine items; src/femtic_gui and tests/gui only): (1) jobs.py's
  CHILD_ENV adds PYTHONIOENCODING=utf-8 to PYTHONUNBUFFERED=1, so a Python job's non-ASCII output reaches the
  console intact. PYTHONUTF8 is deliberately not set: it would also change the child's open() default, and
  femticPy's MTtools.read opens EDIs without an encoding, so a cp1252 byte in an EDI would stop a GUI-launched prep
  but not a typed one (Vulcan's 131 prep inputs are all ASCII today). (2) Runs: --job mesh (above, 2.4); a made run
  clears --purpose and the job-specific fields; `_mine` is set before run() starts the job. (3) gui_smoke.py (277
  lines) runs gui_smoke_steps.py (285) on the same window. (4) tabs/__init__.py has the future import and lists
  results; Results' 'Choose mesh.dat...' and 'Open 3D viewer' have tooltips (the latter says to select a model
  first). (5) plots.SiteMap labels only the selected site, the hovered one, and every site in view once the view
  holds 20 or fewer (LABEL_ALL_AT_MOST); all markers stay. Tests: 44 -> 49 PASS, 0 FAIL, 0 NOT RUN: test_jobs +1
  (non-ASCII line: phase-1 environment shows U+FFFD, fixed shows the line; the job's file encoding equals a plain
  python's), gui_smoke 14 -> 18 (every push button has a tooltip; at most 1 map label at the default view, 120
  markers, all 10 sites labelled when zoomed; two makes cannot repeat --purpose or --start-rho; the mesh job types
  make_run.sh's header line for Run05 and Run04's line rebuilt from its RUN.md, --files through the picker).
  make_run.sh itself accepted both mesh lines (exit 0, scratch RUNS). Not in this round: Save as only inside
  config/, launching from MAIN while the editable install points elsewhere, the smoke step reading RUNBOOK's Run06
  line, and the KISS list (journal 2026-10-06).

## 9. Phase 2: mesh design and build, Local | Phoenix (2026-10-07, design only; nothing built)
<!-- design 2026-10-07 (design agent): reads only; no mesh tool, prep, FEMTIC, mpirun or WSL ran for this section, and
every figure is copied from the file cited. M/ = D:/BEN/FEMTIC_2026/mesh (gitignored logs of the 2026-09-25 WSL
builds); STUDY = docs/dev/mesh_port_feasibility_2026-10-06.md; PROG = docs/dev/mesh_port_progress.md; MC =
hpc/phoenix_plan/mesh_chain.sh; MR = scripts/make_run.sh; RUN = hpc/phoenix_plan/run.sh; CFG and PREP as in the
header. Line numbers hold for commit 384968c. -->

**Decision (Ben, 2026-10-07).** Students may build a mesh on their own machine when it has the tools and the
resources. The Mesh tab gets "Build mesh: Local | Phoenix", with detection of the available tools and a resource
estimate. G2's cut (finding 5) rested on Ben's PC, where nothing may run (RUNBOOK.md:8; STATUS.md 1.4); that rule
stands for Ben's PC. FEMTIC and the half-space gate stay on Phoenix, and the gate is the acceptance test of every
mesh (D11, STATUS.md "D11").

### 9.0 What phase 2 depends on, and what it changes
- **Not in the repo yet.** The chain driver `femtic_mesh.chain` is a proposal (STUDY section 4, chain.py; phase P2
  in STUDY section 8). Committed src/femtic_mesh holds the readers and writers, the TetGen2Femtic port
  (byte-identical to the C++ on chain_proof and v2, PROG section 1) and the re-partitioner. A makeMtr port is being
  written by another session (src/femtic_mesh/makemtr.py, untracked, seen 2026-10-07 20:17); its byte test B4
  needs G0's output.1-5 from Phoenix (PROG section 10), so until B4 passes, makeMtr counts as a binary-only step.
- **A complete local backend is one per step.** makeTetraMesh: a C++ binary only (STUDY section 7 rejects a port).
  tetgen: a TetGen 1.6.0 binary run as a subprocess, never a Python binding (STUDY section 3; conda-forge builds
  it for win-64, linux-64, osx-64 and osx-arm64). makeMtr: a C++ binary until the port passes B4. TetGen2Femtic:
  the Python port, or the binary. hpc/ported/ holds GCC makefiles only (hpc/ported/README.md), so no Windows build
  of makeTetraMesh or makeMtr exists: on a Windows student PC "Local" stays disabled until per-OS binaries or the
  Gmsh route exist. STUDY section 8.1 (addendum of this date) says which test decides.
- **Two routes never give the same mesh.** conda-forge tetgen already differs from the chain's build at round 0,
  1,616 against 1,605 points (PROG section 4), and libm differs between platforms (STUDY section 10, risk 2). Under
  D11 that is harmless, with one rule: **the gated mesh is the file that was put in shared/**, never "the same
  design built again on the other route".
- **Never list, amended for phase 2.** The GUI process still runs no tool. The Local route is one child process,
  `python -m femtic_mesh.chain <run_dir>`, which runs the four mesh tools on the student's own machine. FEMTIC,
  mpirun and the gate never run locally, WSL is never a backend (the doctor refuses a WSL or UNC path, 9.2), and on
  Ben's PC the doctor finds no tools, so "Local" stays disabled there without any special case.
- **A student machine needs the repository, the EDIs and the env.** Today students work on the PC that holds
  D:\BEN\FEMTIC_2026 (RUNBOOK.md:3-4). prep reads paths.edi_dir and coords_file (CFG:24-25) even when only mesh keys
  change, and the driver needs femtic_mesh in the GUI env (pyproject.toml ships both packages; `pip install -e .`).
  How a student gets these is not designed here (9.7, B1).

### 9.1 The Mesh tab in phase 2: design a new mesh
- **Two modes, chosen by mesh.reuse_from (CFG:86).** Set: phase 1 as in 2.2, every mesh key read-only (C17,
  PREP:1335-1359). Null: a new design, mesh keys editable. "New mesh design..." is Save as (3) with
  mesh.reuse_from written as `null` and a new name and paths.run_dir (CFG:20, 27), default `mesh/<name>`. The name
  is the mesh's name everywhere: the local folder mesh/<name>/ and, on Phoenix, $VF/shared/mesh_<name>/ (9.3). A
  name is never reused, like a run name. Save as refuses an existing target (finding 13), so one saved config makes
  one run_dir, one files/ and one mesh.
- **Editable keys** (new design only; one widget each, the CFG line of the reference config in brackets):
  analysis_domain_km x, y, z (88-90); center_km (91); rotation_deg (93); topography.mode flat or dem and dem_file
  (100-101, a file picker, dem only; prep requires the file, PREP:349-355); control.ellipsoids (111-119) and
  mtr.ellipsoids (150-158), one table with a "same table for surface and volume" lock, on by default, since v1-v3
  use one 9-row table for both (PIPE section 8.2 step 4; unlocking can trip prep's rule-3 warning, PREP:1895-1898);
  observing_sites.circles (132-137); obs_sites.spheres (142-146); resistivity_attr.ellipsoids (166-174);
  resistivity_attr_sites.circles (179-180); starting_resistivity_ohmm (182).
- **Read-only, with the reason as tooltip:** control.num_threads, surf_mesh, iter_max (104-106); interpolate and
  altitude (120-121); sea_depth `null` (122: land only); resistivity_attr air and earth; region_seeds (188-189: the
  land-only pair, whose attribute set must equal resistivity_attr's, MC:238-239).
- **"Layers".** The depth layering of a design is set by each ellipsoid row's Earth and air oblateness (fb, fa):
  the size zone reaches r(1-fb) down and r(1-fa) up (CFG:107-109). The table shows both reaches in km as derived,
  read-only columns, and the depth section below draws them. FEMTIC's own conforming `LAYERS` facets (PIPE:191) are
  not in schema prep_vulcan/2 ("not written" there) and need one seed per slab (PIPE:279): out (9.6, 9.7 B5).
- **Rows are written line by line.** config_io gains set_row, insert_row and delete_row: each touches only that
  row's line, keeps its trailing comment on an edit, copies the previous row's indentation on an insert, and refuses
  a table that is not one flow list per line. A ruamel dump would respace 35-36 lines (finding 1). Validation is
  unchanged: Save as runs PREP.load_config on a temp file (3), so prep's own checks decide, among them nesting
  (check_nested_ellipsoids, PREP:200-230, called at :385-387) and a domain that straddles 0 (:333).
- **Previews (restored from the review's cut in 2.2(a)), pyqtgraph, redrawn on every edit, km:** a plan view (east
  across, north up, as the site map) with the sites, every control/mtr row's outline (semi-axes r and r(1-fh),
  rotated by rotation_deg about center_km) and the resistivity_attr rows dashed, and a zoom on the selected site with
  its observing circles; a depth section through the centre with each row's r(1-fb) and r(1-fa); and the size plot,
  max edge L and cell length B against radius on log axes for the control/mtr, obs-sphere, observing-circle and
  resistivity_attr tables. The previews draw config values; they compute no rule.
- **Predicted sizes, where PIPE's rules make them derivable, come from prep, not from the GUI.** The thin-shell rule
  that cut the GUI's delta_min/20 readout (2.2(b)) still holds, so this is G6 grown: a prep function
  `design_report(c, sites)` beside design_warnings (PREP:1880-1901), printed by Check and Run prep as well, so a
  student without the GUI sees the same lines. The Mesh tab shows them as a table, one row per rule:

| # | figure (from the config alone) | rule and source | warns when |
|---|---|---|---|
| R1 | largest site triangle: at most 1.5 x observing circle-1 edge t1 | PIPE:573; measured max 12.58 / 4.21 / 4.12 m for t1 = 15 / 4 / 2.75 m (v1 / v2 / v3, PIPE 8.2 src note) | 1.5 t1 > delta_min/20 at fmax_hz in 3 ohm-m ("may exceed"; v2 is such a case and passed at 100 Hz, h/delta 0.048); t1 itself above it ("exceeds") |
| R2 | distance from the sites to each side face and to the bottom, in skin depths at the lowest selected band, 100 ohm-m | PIPE:485 (at least 3 delta); v1-v3: 3.10 side, 3.14 bottom at 0.001 Hz (M/vulcan_v3/mesh_logs/mesh_stats.txt:174) | below 3 |
| R3 | air thickness against the horizontal half-width | PIPE:486 | thinner |
| R4 | size growth between successive ellipsoid rows, (L2 - L1)/(r2 - r1) | PIPE:495 (0.2-0.3 in the Earth; v1-v3 0.100-0.225) | above 0.3 |
| R5 | cell length against element size per row, B / L | PIPE:417 (B at least 1.5-2 L); v1-v3 1.5-3 | below 1.5 |
| R6 | prep's existing warnings: core coverage, rule 3, rotation | PREP:1880-1901 | as now |

- **Counts are not predicted.** No estimator is in the repo (PIPE:994), and the old one was off 1.3x in tets and
  2.7x in cells (PIPE:793-794); finding 6 stands. The tab shows the measured counts of v1, v2 and v3 as references
  (M/vulcan_v*/mesh_logs/mesh_stats.txt:1-2), with their one design difference, the site sizes (observing circle 1:
  15 / 4 / 2.75 m; resistivity_attr.dat is identical, PIPE:794), and "counts: known after the build".
- **prep writes files/.** Run prep (2.1) on the saved design writes <run_dir>/files/, the 10 inputs that MC:65 and
  MR:53 name, region_seeds.dat included (PREP:1836-1876), and <run_dir>/inversion/ with control.dat, observe.dat
  and station_map.csv. C17 reports N/A (PREP:1341). No new prep command.

### 9.2 "Build mesh": Local | Phoenix
- **One group box under the previews**, enabled only when the design is saved (finding 13), mesh.reuse_from is null,
  <run_dir>/files/ holds all 10 inputs (MC:65), and <run_dir>/config_used.yml, which prep copies byte for byte
  (PREP:2176), equals the open config (so files/ is this design's, not an earlier one's; a plain byte compare of two
  local files, no student step). Route by two radio buttons; Phoenix is the default.
- **"Check this PC"** runs the driver's own doctor through the JobRunner (3), as a student would type it:
  `python -m femtic_mesh.chain --doctor <run_dir>`. Its exit code alone enables "Local" (0 = complete backend,
  3 = incomplete); its text goes to the console and to a read-only pane, and its last line is the disabled button's
  tooltip. Nothing runs at start-up; the result holds for the session (Check again re-runs it).
- **What the doctor reports** (driver code, femtic_mesh; the GUI parses nothing but the exit code):
  - one line per step, `STEP <tool> binary <path>`, `STEP <tool> python <module>` or `STEP <tool> MISSING (<why>)`.
    Search order: the folder in FEMTIC_MESH_BIN, then the env's own bin (sys.prefix/Library/bin on Windows, where
    conda-forge puts tetgen.exe; sys.prefix/bin elsewhere), then PATH. A candidate under System32, WindowsApps or a
    UNC path (`\\wsl$`, `\\wsl.localhost`, `//host`) is never a backend (the rule of find_bash, jobs.py:34, and
    config_io.local_path). Python ports count when they import: TetGen2Femtic's now, makeMtr's after B4;
  - **it never runs a tool** (presence and the executable bit only), so it is safe on any machine, Ben's PC
    included; a broken binary fails loudly at its first step instead;
  - `MACHINE cores N  RAM free X of Y GiB  disk free Z GB at <run_dir>` (psutil when importable, else
    "RAM unknown"; never a refusal);
  - the reference needs below, with their sources, and a last line `DOCTOR: COMPLETE` or
    `DOCTOR: INCOMPLETE (<missing steps>)`.
- **Resource estimate: the measured WSL builds on Ben's PC**, not a prediction (counts are not predictable, 9.1).
  The chain is serial: tetgen runs at 96-101 % of one core; only makeTetraMesh step 3 is parallel, 1.1 s on v2 at
  545 % (M/vulcan_v2/mesh_logs/timev_table.tsv). Cores barely matter; single-core speed and free RAM do.

| class | tets | wall time | peak RSS | source |
|---|---|---|---|---|
| chain_proof | 27,501 | about 1 s | 16 MB (tetgen) | M/chain_proof/logs/timings.tsv |
| v1-class (site triangles 15 m) | 1,534,902 | 257.5 s (4.3 min) | 584 MiB | M/vulcan_v1/mesh_logs/timev_table.tsv, chain_total row |
| v2-class (4 m) | 2,446,095 | 359.8 s (6.0 min), tetgen 319.5 s of it | 956 MiB (tetgen round 2, 979,196 KB) | M/vulcan_v2/mesh_logs/timev_table.tsv, timings.tsv; STUDY section 1 |
| v3-class (2.75 m) | 3,068,130 | 1,022.2 s (17 min) | 1,211 MiB | M/vulcan_v3/mesh_logs/timev_table.tsv |

- **Also:** the TetGen2Femtic port takes 15.2-15.9 s and 577-582 MB on v2 (PROG section 1), after tetgen has exited;
  the v2 build wrote about 3 GB (M/vulcan_v2/mesh_logs/chain_total.timev: 5,829,736 output blocks of 512 B; STUDY
  section 11) and keeps about 2 GB in intermediates/ (RUNBOOK.md:113 for Run05); a later 3D view adds 683 MB (2.6).
  Other machines will be faster or slower: the table is a class guide. The GUI shows it beside the design's circle-1
  edge, so the student can place the design in a class and choose Local or Phoenix.
- **LOCAL** runs `python -m femtic_mesh.chain <run_dir>` through the JobRunner (argv [sys.executable, "-m",
  "femtic_mesh.chain", <run_dir>], cwd the repository root, as 3 says). What the GUI relies on from the driver (P2
  work in femtic_mesh, specified here only that far):
  - **the chain of MC**, step for step: makeTetraMesh -stp 1-4, the seeds into output.poly, tetgen -nVpYAakq3.0/0,
    five rounds of makeMtr and tetgen -nmpYVrAakq3.0/0, TetGen2Femtic, with MC's checks (seeded attribute set, air
    on the top plane only, one .mtr value per node, element counts agree, volumes sum to the box; MC:45-51). Also
    STUDY's N3 controls, which MC lacks: a makeTetraMesh ITER_MAX line (STUDY section 2.4) and a stray output.i.b.*
    (STUDY section 3). No FIX_OUTPUT1, five rounds always (MC:62);
  - **prep's layout, not MC's:** reads <run_dir>/files/, works in <run_dir>/intermediates/, puts mesh.dat and
    resistivity_block_iter0.dat into <run_dir>/inversion/ (beside observe.dat, where 2.2's 3D button and a later
    mesh.reuse_from look), the VTK into <run_dir>/vtk/, and logs into <run_dir>/mesh_logs/, among them
    mesh_summary.txt with MC's two lines, `MESH COUNTS: nodes N  tets N  cells N  surface_faces N  outer_faces N`
    and `MESH CHAIN DONE: OK, exit 0 (...)` or `... FAILED, exit N at <step>: ...` (MC:42-43, 95, 120-121). One
    format for both routes, so one reader serves a local build and a copied-back Phoenix run;
  - **input_md5.txt and products.md5 in mesh_logs/,** as the WSL builds left them: developer records, no student step
    (STATUS.md 1.7), and what C17 needs (PREP:1336-1338) when a later config reuses this mesh;
  - **refusals before any write** (exit 1, nothing changed): an earlier build, i.e. any of
    <run_dir>/inversion/mesh.dat, <run_dir>/inversion/resistivity_block_iter0.dat, <run_dir>/intermediates/ or
    <run_dir>/mesh_logs/mesh_summary.txt (MC:156-158), so mesh/vulcan_v1-v3 can never be overwritten; a
    missing input; and an incomplete backend (exit 3, the doctor's lines). Exit 2 is usage. A cancelled or failed
    build leaves intermediates/ for the logs; the GUI says to move it away before building again and deletes
    nothing.
- **Cancel kills the tree.** Phase 1's cancel() kills the QProcess (jobs.py:176-184); on Windows that ends the
  driver and leaves tetgen running. Phase 2: on Windows `taskkill /T /F /PID <pid>`, elsewhere the driver starts in
  its own session and cancel() kills the group (T21).
- **PHOENIX** switches to the Runs tab's New-run form (2.4), prefilled `--job mesh --files <run_dir>/files --purpose
  "Build mesh <name> on Phoenix"`, which types MR's own mesh line (MR:6, 21-27); --layout and --time stay empty
  (make_run.sh's 1x8 and 04:00:00, MR:59). The rest is the RUNBOOK: R2 WinSCP, R3 run.sh, R4 status.sh, and F3's
  check that status.sh shows `MESH CHAIN DONE: OK` (RUNBOOK.md:111-117). The built mesh stays in
  $VF/runs/RunNN/ (MC:37) and needs no upload (9.3).

### 9.3 After the build: counts, 3D, and the gate on Phoenix
- **Counts summary.** On exit 0 the tab reads <run_dir>/mesh_logs/mesh_summary.txt and shows its MESH COUNTS line
  as a table beside v1-v3's counts (9.1), with the wall time from its DONE line. A failed build shows the DONE
  line (it names the step) and the path of intermediates/logs/<step>.log. readers.mesh_stats_lines
  (readers.py:117) also learns the MESH COUNTS line, since a local build has no mesh_stats.txt (that is
  scripts/mesh_stats.py's file, which needs scipy, not in the GUI env).
- **3D.** "Open 3D viewer" opens <run_dir>/inversion/mesh.dat with its iteration-0 block (2.6; about 6 s and 683 MB
  at v2 class). Nothing else is offered: whether the mesh is good enough is the gate's question (D11), and R1 of 9.1
  was the cheap check before the build.
- **Into shared/, local route** (a new RUNBOOK step, S6, once per mesh, written like S4, RUNBOOK.md:44-47):
  on Phoenix `mkdir $VF/shared/mesh_<name>` (no -p: it fails if the name was used, which is the never-reuse rule's
  only guard), then WinSCP <run_dir>\inversion\mesh.dat and resistivity_block_iter0.dat into it (about 312 MB at
  v2 class, RUNBOOK.md:147), then `ls -l $VF/shared/mesh_<name>`. Fails if: a size differs from the local one; the
  Mesh tab shows both local sizes in bytes for this. No checksum (D0).
- **Into shared/, Phoenix route:** `mkdir $VF/shared/mesh_<name> && cp $VF/runs/RunNN/mesh.dat
  $VF/runs/RunNN/resistivity_block_iter0.dat $VF/shared/mesh_<name>/`, then the same `ls -l` against the run's
  copies. To look at it on the PC, WinSCP the two files into <run_dir>\inversion\ by hand (R5's mask skips them by
  design, RUNBOOK.md:74).
- **The gate run folders.** Two New-run jobs, as RUNBOOK F1 (RUNBOOK.md:88-91): `--job gate --mesh <name> --data
  <run_dir>/inversion --start-rho 100`, and again with 3, each with a layout (v2-class 3x24, v3-class 2x36 as now;
  run.sh's memory rule reads the shared mesh itself and refuses a layout that does not fit, STATUS.md 1.2). Both
  PASS on all 21 bands: the mesh is usable (D11). Either FAIL: change the design under a new name (PIPE:799-807,
  which knob to turn).
- **Kit change this needs.** MR:61 and RUN:100 accept only v2 and v3. Both must accept a name (letters, digits,
  `_`; v2 and v3 stay valid) and keep refusing a missing or empty shared mesh file, which run.sh already does
  (STATUS.md 1.2). run.sh is in the kit, so this is a new kit export (STATUS.md 1.2) and RUNBOOK S6.

### 9.4 Tests (each states "This test fails if ..." and shows its failing case first; on Ben's PC only fakes run)
| # | where | This test fails if ... | failing case shown first |
|---|---|---|---|
| T14 | config_io, no Qt | set_row, insert_row or delete_row on mesh.control.ellipsoids changes a byte of CFG outside that row's line, the table read back differs from the rows meant, or an edited row loses its comment | a ruamel load and dump (35-36 lines change, finding 1) |
| T15 | gui_smoke | a mesh widget is editable while mesh.reuse_from is set, or either Build route is enabled while reuse_from is set, edits are unsaved, files/ lacks one of MC:65's 10 inputs, or config_used.yml differs from the open config | CFG (reuse_from set) with a complete files/ copied into a temp run_dir |
| T16 | prep's design_report, no Qt; needs M/ (NOT RUN, exit 2, without it; never PASS) | a measured largest site triangle of v1, v2 or v3 (12.58 / 4.21 / 4.12 m, M/vulcan_v*/mesh_logs/mesh_stats.json, per-site tri_max_edge) exceeds R1's bound for its config (22.5 / 6.0 / 4.125 m; v3 is 0.4 mm under it, so the 1.5 factor is the real limit); R2 at 0.001 Hz, 100 ohm-m differs from line 174 of each mesh_stats.txt (3.10 side, 3.14 bottom) in the second decimal; or R4 or R5 warns on v1-v3 (0.100-0.225 and 1.5-3, inside the limits) | R1 without the 1.5 factor (v2 4.21 > 4.0 m and v3 4.12 > 2.75 m must show as exceedances); R2 in 60 ohm-m |
| T17 | femtic_mesh, doctor, fakes | --doctor exits 0 while a step has no backend, or non-zero with all four; a fake tool that writes a marker when run leaves a marker (the doctor ran a tool); a candidate under System32, WindowsApps or a UNC path counts as a backend; the last line is not exactly DOCTOR: COMPLETE or DOCTOR: INCOMPLETE (...) | a doctor that resolves names with shutil.which alone, on a PATH whose first tetgen is a WindowsApps fake |
| T18 | femtic_mesh, driver, fakes that copy tests/mesh/data/chain_proof_round0 as each round's output | any of these ends other than exit 1 with a DONE line naming the right step: a makeMtr fake that exits 0 and writes nothing, a .mtr with the wrong count, a stray output.i.b.node, an ITER_MAX line in makeTetraMesh.log, seeds whose attributes differ from resistivity_attr.dat; or a run_dir with an earlier build is not refused before any write (its files compared byte for byte) | the WSL chain's `[ -f output.i.mtr ]` (run_mesh_chain.sh:182), which passes the first case |
| T19 | real tools: a Phoenix login node with $VF/bin (as MC:20-21) and a conda env with femtic_mesh, or a student's Linux machine; NOT RUN (exit 2) elsewhere, never PASS, never on Ben's PC | on chain_proof's inputs with the same binaries, the driver's and MC's mesh.dat or resistivity_block_iter0.dat differ by one byte (cmp), or their MESH COUNTS lines differ. Run twice: TetGen2Femtic binary (driver parity), then the port (B2 on real files, PROG section 4) | the driver with 4 rounds, which must differ |
| T20 | gui_smoke, JobRunner recorder | Local records anything but [sys.executable, "-m", "femtic_mesh.chain", <run_dir>]; Local is enabled after a doctor that exited 3, whatever its text; Phoenix does not type MR's mesh line for <run_dir>/files character for character; the counts shown differ from a fake mesh_summary.txt; any upload, socket or tool call is recorded (T6, T11) | a GUI that enables Local when the text contains "COMPLETE" ("INCOMPLETE" contains it) |
| T21 | jobs, real QProcess, light | a fake tool that sleeps 60 s under the driver is still alive 5 s after cancel() | phase 1's cancel(), expected to leave the child running on Windows |
| T22 | pc_scripts_test.sh, run_sh_test.sh | make_run.sh accepts `--mesh ../x`, `--mesh v2/..` or an empty name, or refuses `--mesh vulcan_v4_bk`; run.sh submits MESH=<name> whose $VF/shared/mesh_<name> lacks either file | today's MR:61 (refuses every new name), then a mutant without the name pattern (accepts ../x) |

- **Acceptance is not a GUI test:** the two gates of 9.3 on the mesh in shared/ (D11; RUNBOOK F1's "Fails if").
- T16-T19 live with prep and femtic_mesh (tests/mesh), T22 with the kit (STATUS.md 1.9); the GUI suite gains T14,
  T15, T20 and T21.

### 9.5 Order of work (milestones after M5)
| M | content | needs | demo |
|---|---|---|---|
| M6 | 9.1 (modes, row writer, previews, prep's design_report and G6), 9.2's Phoenix route, 9.3's counts reader, the kit names and RUNBOOK S6 | prep and kit changes only; no mesh tool | a copy of v2's design with circle 1 at 3 m: R1 to R6 shown, Run prep writes files/, the New-run form types the mesh line |
| M7 | 9.2's Local route: Check this PC, Build, cancel of the tree | femtic_mesh.chain and --doctor (P2) | T19 on a Phoenix login node; then a v2-class design on a student's Linux machine |
| M8 | Local on Windows student PCs | STUDY section 8.1: (i) Windows binaries or (iii) Gmsh, each behind its test | doctor COMPLETE on a Windows PC that is not Ben's |

M6 is useful on its own: every design goes to Phoenix as a mesh run today (MR:6). M7 and M8 add speed of iteration
(about 6 min locally for a v2-class design against a queue, a Phoenix job and two WinSCP steps), not a new ability.

### 9.6 What stays out
- **Editing an existing gated mesh in place.** With mesh.reuse_from set the mesh keys stay read-only (C17); a change
  is a new name, a new folder, a new mesh and a new gate. The driver refuses a folder with an earlier build, so
  v1-v3 and any gated student mesh cannot be overwritten.
- **Any automatic upload or download** (the Never list): the student moves files with WinSCP; the GUI shows which
  two files, their sizes and the target folder (9.3).
- FEMTIC, mpirun and the gate on a student machine; WSL as a backend; any run on Ben's PC.
- Installing mesh tools from the GUI: the doctor reports, the student or Ben installs.
- LAYERS facets, sea, lakes and coast lines (land only, CFG:122; femtic_mesh raises NotImplementedError for them,
  STUDY section 5), DEM editing (dem mode only picks a file), FIX_OUTPUT1, a round count other than 5.
- Predicted tetrahedron or cell counts (9.1), and any automatic class-to-layout choice (run.sh's rule decides).
- A post-build site-triangle measurement (scripts/mesh_stats.py needs scipy; R1 is the check before the build).
- A re-partition-only route (femtic_mesh.repartition, PROG section 5): a new block file on an unchanged mesh.dat
  would need no new gate (a uniform model ignores the cells), but which cell rule to use is Ben's D3 call first.

### 9.7 For Ben
- **B1. Student machines.** Local needs the repository, the 120 EDIs and the env on each student's own machine;
  RUNBOOK.md:3-4 assumes the one PC. Without a plan for that, phase 2 is M6 only.
- **B2. The Never list** is amended as 9.0 says (pointer in the list): the GUI's child process may run the four mesh
  tools on a student's own machine; FEMTIC and mpirun never; never on Ben's PC. Confirm.
- **B3. Windows backends:** per-OS binaries of makeTetraMesh and makeMtr, or wait for Gmsh (STUDY section 8.1).
  Shipping Usui's binaries needs his licence terms, not recorded in this repo (STUDY section 10, risk 4).
- **B4. Mesh names** in shared/: `mesh_<name>`, never reused, `mkdir` without -p as the guard (9.3). A kit change.
- **B5. "Layers"** here means each size zone's depth reach (9.1). Conforming LAYERS facets need prep schema /3 and
  seeds per slab: wanted?
- **B6. G6:** the rules R1-R5 go into prep (design_report), which phase 2 assumes. Confirm.
