#!/bin/bash
# gitfree_head_test.sh -- WSL test of 01_build_femtic.sh's version check on nodes WITHOUT git (added 2026-09-25:
# on p2-dmv-1 every repo cloned on the login node printed "line 176: .../COMMIT_SHA.txt: No such file or directory"
# and was reported UNKNOWN), and of COMMIT_SHA.txt being recorded wherever git runs. FETCH_ONLY=1 exits right
# after the source step, so nothing is built and no network is used (every tree already exists).
# "No git" = PATH is a copy of /usr/bin without git*. Fake .git layouts are written by hand (G1-G3); G4/G5 use
# real repositories made by git (git init/commit, git pack-refs, detached checkout).
# Failure criterion: the harness FAILS if any observable below differs from the value each case states.
# Run in WSL:  bash gitfree_head_test.sh      (PLAN=... to test another copy of the kit)
# BASH_UNDER_TEST=<bash binary> runs 01 (and femtic_env.sh / femtic_lib.sh inside it) with that bash (default: bash).
BASH_UNDER_TEST=${BASH_UNDER_TEST:-bash}
PLAN=${PLAN:-/mnt/d/BEN/FEMTIC_2026/hpc/phoenix_plan}
T=$(mktemp -d); fail=0; npass=0; nfail=0
chk(){ if [ "$2" = "$3" ]; then echo "  PASS $1 ($2)"; npass=$((npass+1)); else echo "  FAIL $1: got '$2' want '$3'"; fail=1; nfail=$((nfail+1)); fi; }
cnt(){ grep -c -- "$1" "$2" 2>/dev/null || true; }
# pinned commits, copied by hand from 01_build_femtic.sh's REF table
declare -A REF=([femtic]=26c8606ea61717a9386f93fff47203391836829c [makeTetraMesh]=92a9a32e0683458f7908f75743a8e3777753d0a1
  [makeMtr]=df8e2071f908dfd9dc30333ec548a42dc2e5a5c1 [TetGen2Femtic]=ceb8bfb1493092ed7c6a1a52352307be356d31e3
  [makeDHexaMesh]=66afbfcaf8fea8c64ddcf686e52e553895559238 [mergeResultOfFEMTIC]=4fe54e1e6c0a55f636fc15a6b1d5bd646d739487
  [tetgen]=e05aca7df74e3f531bc35733ed87d36d437266c5)
ORDER=(femtic makeTetraMesh makeMtr TetGen2Femtic makeDHexaMesh mergeResultOfFEMTIC tetgen)
NOGIT=$T/nogit; mkdir -p "$NOGIT"
for f in /usr/bin/*; do case "${f##*/}" in git|git-*) ;; *) ln -s "$f" "$NOGIT/" ;; esac; done
run01(){  # run01 <out> <PATH> [ENV=VAL ...] -> exit status of 01 FETCH_ONLY=1 (login-node context: no Slurm)
  local o=$1 p=$2; shift 2
  env -u SLURM_JOB_ID -u SLURM_JOB_PARTITION PATH="$p" FETCH_ONLY=1 BIN="$T/bin" "$@" "$BASH_UNDER_TEST" "$PLAN/01_build_femtic.sh" 2>&1 | cat > "$o"
  return "${PIPESTATUS[0]}"
}
OTHER=0123456789abcdef0123456789abcdef01234567

echo "P0 precondition: git is not reachable through the no-git PATH"
chk no_git "$(PATH=$NOGIT command -v git | wc -l)" 0

echo "G1 no git, PIN=1, one layout per repo: detached HEAD / branch ref (CRLF) / packed-refs only / dangling ref /"
echo "   git-free tree without COMMIT_SHA.txt / .git without HEAD + COMMIT_SHA.txt (CRLF) / loose ref beating packed-refs."
echo "   Expect exit 0, 5 commits resolved without git, 2 UNKNOWN (informational), no 'No such file' anywhere"
S=$T/src1; for r in "${ORDER[@]}"; do mkdir -p "$S/$r/src"; done
mkdir -p "$S/femtic/.git";        printf '%s\n' "${REF[femtic]}" > "$S/femtic/.git/HEAD"
mkdir -p "$S/makeTetraMesh/.git/refs/heads"; printf 'ref: refs/heads/master\r\n' > "$S/makeTetraMesh/.git/HEAD"
                                  printf '%s\n' "${REF[makeTetraMesh]}" > "$S/makeTetraMesh/.git/refs/heads/master"
mkdir -p "$S/makeMtr/.git/refs/heads"; printf 'ref: refs/heads/main\n' > "$S/makeMtr/.git/HEAD"
printf '# pack-refs with: peeled fully-peeled sorted \n%s refs/heads/develop\n%s refs/heads/main\n%s refs/tags/v1\n^%s\n' \
  1111111111111111111111111111111111111111 "${REF[makeMtr]}" 2222222222222222222222222222222222222222 3333333333333333333333333333333333333333 \
  > "$S/makeMtr/.git/packed-refs"
mkdir -p "$S/TetGen2Femtic/.git"; printf 'ref: refs/heads/gone\n' > "$S/TetGen2Femtic/.git/HEAD"
: # makeDHexaMesh: plain git-free tree, no COMMIT_SHA.txt (the tree that printed "No such file" on p2-dmv-1)
mkdir -p "$S/mergeResultOfFEMTIC/.git"; printf '%s\r\n' "${REF[mergeResultOfFEMTIC]}" > "$S/mergeResultOfFEMTIC/COMMIT_SHA.txt"
mkdir -p "$S/tetgen/.git/refs/heads"; printf 'ref: refs/heads/master\n' > "$S/tetgen/.git/HEAD"
printf '%s\n' "${REF[tetgen]}" > "$S/tetgen/.git/refs/heads/master"
printf '%s refs/heads/master\n' "$OTHER" > "$S/tetgen/.git/packed-refs"
run01 "$T/g1.out" "$NOGIT" SRC="$S" PIN=1; chk rc "$?" 0
chk git_absent_line "$(cnt 'git=absent' "$T/g1.out")" 1
chk femtic_detached "$(cnt '^-- femtic @ 26c8606 (read from .git; no git on this node)$' "$T/g1.out")" 1
chk mtm_loose_ref_crlf "$(cnt '^-- makeTetraMesh @ 92a9a32 (read from .git; no git on this node)$' "$T/g1.out")" 1
chk makemtr_packed "$(cnt '^-- makeMtr @ df8e207 (read from .git; no git on this node)$' "$T/g1.out")" 1
chk tg2f_unknown "$(cnt '^-- TetGen2Femtic: version UNKNOWN (informational, not an error): no git on this node, and neither' "$T/g1.out")" 1
chk dhexa_unknown "$(cnt '^-- makeDHexaMesh: version UNKNOWN (informational, not an error): git-free tree without COMMIT_SHA.txt' "$T/g1.out")" 1
chk merge_fallback "$(cnt '^-- mergeResultOfFEMTIC @ 4fe54e1 (COMMIT_SHA.txt; no git on this node)$' "$T/g1.out")" 1
chk tetgen_loose_wins "$(cnt '^-- tetgen @ e05aca7 (read from .git; no git on this node)$' "$T/g1.out")" 1
chk warning "$(cnt '^WARNING: unknown source version for: TetGen2Femtic makeDHexaMesh (informational only' "$T/g1.out")" 1
chk no_such_file "$(cnt 'No such file' "$T/g1.out")" 0
chk no_error "$(cnt 'ERROR' "$T/g1.out")" 0
chk nothing_written "$(ls "$S"/*/COMMIT_SHA.txt | wc -l)" 1

echo "G2 no git, PIN=1, detached HEAD at another commit: expect exit 1 naming it, with the login-node hint"
printf '%s\n' "$OTHER" > "$S/femtic/.git/HEAD"
run01 "$T/g2.out" "$NOGIT" SRC="$S" PIN=1; chk rc "$?" 1
chk refused "$(cnt "femtic is at '$OTHER', pinned ${REF[femtic]}" "$T/g2.out")" 1
chk hint "$(cnt 'no git on this node: FETCH_ONLY=1 on the login node checks out the pinned commit' "$T/g2.out")" 1
chk no_such_file "$(cnt 'No such file' "$T/g2.out")" 0

echo "G3 same with PIN=0: expect exit 0, the other commit reported UNPINNED"
run01 "$T/g3.out" "$NOGIT" SRC="$S" PIN=0; chk rc "$?" 0
chk unpinned "$(cnt "^-- femtic @ $OTHER (read from .git; no git on this node)  \[UNPINNED" "$T/g3.out")" 1

echo "G4 git present, 7 real repositories (git init + commit), PIN=0: expect exit 0 and every COMMIT_SHA.txt = git rev-parse HEAD"
S=$T/src4
for r in "${ORDER[@]}"; do
  mkdir -p "$S/$r/src"; echo "// $r" > "$S/$r/src/main.cpp"
  git -C "$S/$r" -c init.defaultBranch=master init -q
  git -C "$S/$r" add -A; git -C "$S/$r" -c user.name=t -c user.email=t@t commit -q -m "$r"
done
run01 "$T/g4.out" "$PATH" SRC="$S" PIN=0; chk rc "$?" 0
n=0; for r in "${ORDER[@]}"; do [ "$(cat "$S/$r/COMMIT_SHA.txt" 2>/dev/null)" = "$(git -C "$S/$r" rev-parse HEAD)" ] && n=$((n+1)); done
chk commit_sha_recorded "$n" 7
chk no_such_file "$(cnt 'No such file' "$T/g4.out")" 0

echo "G5 the same real repositories on a node without git, COMMIT_SHA.txt deleted; makeMtr's refs packed by 'git pack-refs"
echo "   --all' (loose ref gone), femtic on a detached HEAD: expect exit 0, all 7 resolved from .git = git rev-parse HEAD"
git -C "$S/makeMtr" pack-refs --all; git -C "$S/femtic" checkout -q --detach
chk loose_ref_gone "$([ -e "$S/makeMtr/.git/refs/heads/master" ] && echo present || echo gone)" gone
chk femtic_detached "$(head -c 5 "$S/femtic/.git/HEAD")" "$(git -C "$S/femtic" rev-parse HEAD | head -c 5)"
rm -f "$S"/*/COMMIT_SHA.txt
run01 "$T/g5.out" "$NOGIT" SRC="$S" PIN=0; chk rc "$?" 0
n=0; for r in "${ORDER[@]}"; do [ "$(cnt "^-- $r @ $(git -C "$S/$r" rev-parse HEAD) (read from .git; no git on this node)" "$T/g5.out")" = 1 ] && n=$((n+1)); done
chk resolved_without_git "$n" 7
chk no_such_file "$(cnt 'No such file' "$T/g5.out")" 0

echo; echo "CHECKS: $npass passed, $nfail failed"
echo "OVERALL: $([ $fail = 0 ] && echo PASS || echo FAIL)"
if [ $fail != 0 ] && [ -n "${KEEP:-}" ]; then echo "kept $T for debugging"; else rm -rf "$T"; fi
[ $fail = 0 ]
