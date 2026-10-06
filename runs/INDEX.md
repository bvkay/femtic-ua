# Runs

| run | mesh | purpose | layout | job id(s) | verdict |
|---|---|---|---|---|---|
| Run01 | v2 | Half-space gate at 100 ohm-m on mesh v2, all 21 bands (STATUS D1: v2 only if Run01 and Run02 both pass) | 3x24 | - | - |
| Run02 | v2 | Half-space gate at 3 ohm-m on mesh v2, all 21 bands (the high-frequency stress case; STATUS D1 with Run01) | 3x24 | - | - |
| Run03 | v2 | T4 on mesh v2: one inversion iteration, measures sensitivity-step memory, N_iv and time per iteration (submit after Run01 and Run02 pass) | 3x24 | - | - |
| Run04 | none | P0 reference chain, small case; keep intermediates | 1x8 | - | - |
| Run05 | none | P0 reference chain on the gated v2 design; goldens for the port; expect 2,446,095 tets | 1x8 | - | - |
