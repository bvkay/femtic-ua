# Archive: the 2026-09-28 Phoenix runbook and its checker

These five files are the verified long-form runbook of 2026-09-28 (revised to 2026-09-30) and the tools that
checked it. On 2026-10-06 Ben replaced them with the student runbook `hpc/phoenix_plan/RUNBOOK.md`, under his KISS
rule: no checksum or md5 step anywhere in the student workflow, no upload manifest, no jobs ledger, one command per
step. They are kept unchanged, as the reference for the reasoning behind each step (why the gates use all 21 bands,
how the layout rule and the T4 memory band were derived, what the B2 smoke run proved). Nothing in them was fixed.

| File | Was | What it is |
|---|---|---|
| `RUNBOOK_first_inversion.md` | `hpc/phoenix_plan/` | Steps B1-B6 with a failure criterion per step: kit upload with an md5 manifest, self-tests on Phoenix, the B2 smoke run (passed, job 16153670), input upload with md5 checks, the v2/v3 half-space gates (B4a), forward memory (B4b), T4 (B5), the Q4 grant (B6). |
| `UPLOAD_LIST_2026-09-28.txt` | `hpc/phoenix_plan/` | Every file of that upload, with measured sizes and md5 sums (parts A-D). |
| `runbook_check.sh` | `hpc/phoenix_plan/tests/` | PC-only checker: ran the runbook's own command blocks in a sandbox against the kit (391 passed, 0 failed on 2026-09-30). |
| `runbook_mutate.py` | `hpc/phoenix_plan/tests/` | Makes the runbook mutants that the checker must catch (54 of 54 caught). |
| `gen_upload_list.sh` | `hpc/phoenix_plan/tests/` | Wrote `UPLOAD_LIST_2026-09-28.txt` from the files on the PC. |

What the new runbook keeps from this one: the gate rule (v2 only if both the 100 and the 3 ohm-m gate pass on all
21 bands, else v3), the layouts (v2 3 x 24, v3 2 x 36), the wall times (gate 2 h on v2, 4 h on v3; T4 12 h), the
expected T4 memory (70,754 MiB per rank on v2) and the harmless `Failed to modify UD QP` lines.

What it drops: the md5 manifest (B1.1-B1.3), the kit self-tests on Phoenix (B1.4; tests now run on the PC only:
`hpc/phoenix_plan/tests/`), the `install -m 644 femtic_lib.sh $BIN/` step (since femtic_lib.sh version 5 every job
reads the kit's own copy), the md5 checks of the inputs (B3.4), the `inputs/` and `work/<mesh>/<name>` folders (now
`$VF/shared/mesh_vN/` and `$VF/runs/RunNN/`), `jobs_ledger.txt` (now `runs/INDEX.md` and each run's `RUN.md`), and
the hand-run binding, CPU-efficiency and memory-band awk checks.

**These files no longer run from here.** `runbook_check.sh` and `gen_upload_list.sh` find the kit as `../` of their
own folder, and the checker tests the version-4 kit, `inputs/` and `work/` folders and md5 rows that the version-5
kit has dropped (the kit agent measured 369 passed, 26 failed against it on 2026-10-06). To rerun them as they were, use commit 06d044f, where they sit
in `hpc/phoenix_plan/` and `hpc/phoenix_plan/tests/`.
