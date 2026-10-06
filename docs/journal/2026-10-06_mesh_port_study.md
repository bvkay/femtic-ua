# 2026-10-06 - Mesh tools: Python port study and kernel choice

**Who/what:** Ben asked whether the FEMTIC mesh tools (makeTetraMesh, tetgen, makeMtr, TetGen2Femtic and the Python
drivers) can be ported to Python, **if feasible**, so students get a pure-Python toolchain on any OS with no compiler
and no tokens. His priority order: EFFICIENT > ROBUST > SPEEDY. Nothing was committed; docs/STATUS.md was not touched
(another session is editing it).

## What ran
- **Study A, port feasibility:** docs/dev/mesh_port_feasibility_2026-10-06.md. 11 agents, among them five tool studies
  and their five independent verifiers. The verifiers refuted 31 claims (orchestrator's count; section 11 lists them
  as 30 items in five groups). No femtic, tetgen, makeTetraMesh or WSL; light Python only.
- **Study B, alternative kernels:** docs/dev/mesh_alternatives_2026-10-06/README.md + toys/. 1 agent. Gmsh 4.15.2,
  conda-forge tetgen 1.6.0, pip tetgen (pyvista), meshpy, pyGIMLi and discretize, on toys of at most 56,171 tets.
  These toys ran tetgen.exe and gmsh on the PC (sub-second), against the 09-28 "no modelling on the PC" rule
  (STATUS:39 at 06d044f); every follow-up test is a Phoenix job.
- **Merge (this entry's agent):** A was rewritten into the single study (418 lines). New sections: 6 (B summarised
  with line citations), 7 (makeTetraMesh's role: binaries / faithful port / Gmsh, scored), 8 (reconciled sequence with
  day totals), 9 (tests TD1-TD8 with failure criteria). B stays as the detailed record.

## Merged verdict
- **Not achievable:** a pure-Python chain. Every kernel is compiled; tetgen is 92 % of the v2 run time.
- **Achievable:** `femtic_mesh`, installed with conda or pip, no compiler, Python everywhere except the meshing
  kernels: conda-forge tetgen + per-OS makeTetraMesh binaries, or one Gmsh wheel for both if Gmsh passes its gate.
- **Sequence:** P0 Phoenix reference chain (0.5-1 d + queue) -> P1 TetGen2Femtic port + re-partitioner for D3 (5-7 d)
  -> P2 `femtic_mesh` with makeMtr port and conda-forge tetgen wrapper (12.5-21 d) -> P3 Gmsh prototype gated on
  Phoenix (3-5 d est.), then a Gmsh backend (2-4 d est.) or makeTetraMesh binaries (2-4 d) -> P4 GUI hooks (not
  estimated). P0-P3: 23-38 days on either branch; 20-33 without the Gmsh prototype; a faithful makeTetraMesh port
  instead would be 43-69 (A defers that port, B rejects it).
- **Changes the evidence forced on the proposed sequence:** P3 needs only P1, so it can run alongside P2; B's
  fallback (Gmsh surface + conda-forge tetgen + makeMtr port) comes before reverting to binaries; B's gate was weaker
  than the D1 rule (no 2 % diagonal limit, not 3 + 100 ohm-m on 21 bands) and its option-C oracle was a WSL tet count.
- **Inconsistencies found and recorded in section 11:** A's own sums (16-27 and 21-35 should be 16-24 and 20-33;
  TetGen2Femtic 4-6 vs 5-7 days); "Python everywhere else" is wrong on the binary route; B's sliver comparison used
  `-q1.4`, not the chain's `q3.0/0`; B's "about 100 lines" of makeMtr understates the 3-5-day faithful port.

## Decision for Ben
The P3 branch is decided later by tests TD6-TD7 on Phoenix. The one call needed now: is "passes the D1 half-space
gate" an acceptable bar for a student mesh (keeps the Gmsh prototype; a distributed tool importing gmsh ships under
GPL with source), or must meshes be byte-identical to Usui's chain (drop P3, ship binaries)? Byte identity on Windows
and macOS is unproven even for binaries. Also open: Usui's licence for his tools is not recorded in the repo.

## Next step
P0: write and submit the G0 job on Phoenix (run_mesh_chain.sh, gcc build, on chain_proof, chain_proof_meshgen and v2,
keeping every intermediate). Code the re-partitioner on chain_proof while it queues.

## State
Both study documents (docs/dev/mesh_port_feasibility_2026-10-06.md, docs/dev/mesh_alternatives_2026-10-06/) and this
entry are **uncommitted** (docs/dev/ is untracked). docs/STATUS.md still needs a pointer to the study.
