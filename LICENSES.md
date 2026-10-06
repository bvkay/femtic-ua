# Licences of third-party code

What this project builds, vendors or might adopt, and the licence of each as read from a licence file. Written
2026-10-06 on the PC. GitHub was not reachable from this machine that day (git clone and web fetch both failed
with "could not resolve host"), so a licence is stated only where a licence file is in this repository or in a
recorded package listing. The rest are marked **not read**: nothing is assumed about them. Not legal advice.

| Component | How this project uses it | Licence | Read from | Status |
|---|---|---|---|---|
| FEMTIC (github.com/yoshiya-usui/femtic, pinned 26c8606 in `hpc/phoenix_plan/01_build_femtic.sh`) | Built from source on Phoenix by 01; ported makefiles in `hpc/ported/femtic/`; FEMTIC's INV_MT_01 example files are committed in `validation/wsl_2026-09-25/femtic_example_INV_MT_01_Tetra/` | MIT, "Copyright (c) 2021 Yoshiya Usui" | `validation/wsl_2026-09-25/femtic_example_INV_MT_01_Tetra/LICENSE_femtic` (the copy committed with the example in 02cd1c4) | read from the committed copy; check it against the pinned commit's LICENSE once GitHub is reachable |
| makeTetraMesh (yoshiya-usui, pinned 92a9a32) | Built on Phoenix by 01 (ported makefile in `hpc/ported/makeTetraMesh/`); used by the WSL mesh chain | - | no copy in this repository | MIT (Copyright (c) 2021 Yoshiya Usui); LICENSE read 2026-10-06 from a shallow clone of the GitHub HEAD, not of the pinned commit |
| makeMtr (yoshiya-usui, pinned df8e207) | Built by 01; WSL mesh chain | - | no copy | MIT (Copyright (c) 2021 Yoshiya Usui); LICENSE read 2026-10-06 from a shallow clone of the GitHub HEAD, not of the pinned commit |
| TetGen2Femtic (yoshiya-usui, pinned ceb8bfb) | Built by 01; WSL mesh chain | - | no copy | MIT (Copyright (c) 2021 Yoshiya Usui); LICENSE read 2026-10-06 from a shallow clone of the GitHub HEAD, not of the pinned commit |
| makeDHexaMesh (yoshiya-usui, pinned 66afbfc) | Built by 01; not used for Vulcan | - | no copy | **not read** |
| mergeResultOfFEMTIC (yoshiya-usui, pinned 4fe54e1) | Built by 01 (upstream ships no makefile; ours is `hpc/ported/mergeResultOfFEMTIC/`) | - | no copy | **not read** |
| femticPy (github.com/hseille/femticPy, commit 1b0fe31) | **Vendored and patched** in `external/femticPy/` for `scripts/prep_vulcan.py` (`external/femticPy/UPSTREAM.txt`) | MIT, "copyright (c) Commonwealth Scientific and Industrial Research Organisation (CSIRO)" | `external/femticPy/LICENSE:1-5` (kept with the vendored copy, as MIT requires) | read. The file's last line names the MIT licence but links to the LGPL page; the licence text itself is MIT |
| TetGen 1.6 (the libigl fork, github.com/libigl/tetgen, pinned e05aca7) | Built on Phoenix by 01; `tetgen` in the WSL mesh chain; a conda `tetgen.exe` in the 10-06 toys | AGPL-3.0-or-later (TetGen is dual-licensed: AGPL or a commercial licence from WIAS) | `docs/dev/mesh_alternatives_2026-10-06/toys/out/availability.log:20` (conda-forge tetgen 1.6.0: "license AGPL-3.0-or-later") and `:31` (the PyPI tetgen wheel bundles `src/tetgen-license`, AGPL-3 dual licence) | read from package listings, not from the libigl fork's own LICENSE file |
| Gmsh (only if adopted; STATUS D10 is open) | Not used by the project; ran only in the 10-06 toys on the PC | GPL-2.0-or-later, with exceptions for Netgen, METIS, OpenCASCADE and ParaView | `docs/dev/mesh_alternatives_2026-10-06/toys/out/availability.log:5,34` (gmsh 4.15.2, `share/doc/gmsh/LICENSE.txt`); summary in `docs/dev/mesh_alternatives_2026-10-06/README.md:62-66` | read from the package listing; a tool that imports gmsh and is given to others ships under GPL terms, with source |
| This repository | - | **none**: there is no LICENSE file at the root (`git ls-files` finds only the femticPy and FEMTIC copies above) | - | Ben's choice. Until then it is all rights reserved by default. The vendored femticPy and the FEMTIC example keep their MIT notices whatever is chosen |

## What this means now
- Running the tools on Phoenix for research, and keeping the repository private, creates no licence obligation
  for any row above.
- AGPL (TetGen) and GPL (Gmsh) matter only when binaries or modified sources are given to someone else, or, for
  AGPL, offered over a network. Keeping tetgen as a separate program called by a script keeps that boundary clear
  (`docs/dev/mesh_port_feasibility_2026-10-06.md`, section 10, item 4).
- Before Usui's mesh tools (or ports of them) are given to students outside this repository, read their licences.

Note 2026-10-06: makeTetraMesh, makeMtr and TetGen2Femtic LICENSE files were read from the feasibility study's
scratch clones (HEAD of each repo); the pinned commits are older but by the same author under the same licence file
name. The TetGen fork named in hpc/ported/tetgen/BUILD.txt carries TetGen's dual licence (AGPL-3.0 or commercial).

## To fill in the rows marked "not read"
On a machine with GitHub access, for each repository: `git clone --depth 1 https://github.com/yoshiya-usui/<repo>`
(and `https://github.com/libigl/tetgen`), then read its LICENSE, COPYING or README licence section and record it
here with the file and commit. If a repository has no licence file at all: no licence file; all rights reserved by
default; ask the author (Yoshiya Usui) before redistributing it.

Not covered: system libraries loaded as Phoenix modules (GCC runtime, OpenMPI, Intel MKL) and the Python packages
prep and the tests import; none is vendored here.
