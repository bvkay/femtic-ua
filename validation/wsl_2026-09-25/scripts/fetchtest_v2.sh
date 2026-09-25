#!/bin/bash
# fetchtest_v2.sh -- test of 01_build_femtic.sh's source step (FETCH_ONLY=1 exits right after it), in WSL.
# New in v2 (2026-09-25): 01 must accept GitHub tarballs and git-free trees, record their commit, refuse a
# pin mismatch, and never fetch inside a non-interactive Slurm job. No network access is needed: every case
# below is satisfied (or refused) before any clone or download would start.
PLAN=${PLAN:-/mnt/d/BEN/FEMTIC_2026/hpc/phoenix_plan}
T=$(mktemp -d); fail=0; npass=0; nfail=0
chk(){ if [ "$2" = "$3" ]; then echo "  PASS $1 ($2)"; npass=$((npass+1)); else echo "  FAIL $1: got '$2' want '$3'"; fail=1; nfail=$((nfail+1)); fi; }
# pinned commits, copied by hand from 01_build_femtic.sh's REF table
declare -A REF=([femtic]=26c8606ea61717a9386f93fff47203391836829c [makeTetraMesh]=92a9a32e0683458f7908f75743a8e3777753d0a1
  [makeMtr]=df8e2071f908dfd9dc30333ec548a42dc2e5a5c1 [TetGen2Femtic]=ceb8bfb1493092ed7c6a1a52352307be356d31e3
  [makeDHexaMesh]=66afbfcaf8fea8c64ddcf686e52e553895559238 [mergeResultOfFEMTIC]=4fe54e1e6c0a55f636fc15a6b1d5bd646d739487
  [tetgen]=e05aca7df74e3f531bc35733ed87d36d437266c5)
mktar(){ # mktar <tarballs dir> <repo> -> <repo>-<sha>.tar.gz whose top dir is <repo>-<sha>/ like a GitHub archive
  local d=$T/stage/$2-${REF[$2]}; mkdir -p $d/src; echo "// $2" > $d/src/main.cpp
  tar -czf $1/$2-${REF[$2]}.tar.gz -C $T/stage $2-${REF[$2]}; rm -rf $T/stage; }
run01(){ env -u SLURM_JOB_ID -u SLURM_JOB_PARTITION "$@" bash $PLAN/01_build_femtic.sh > $T/out.txt 2>&1; echo $?; }

echo "F1 all 7 repos as GitHub tarballs, login node: expect exit 0, 7 trees unpacked, COMMIT_SHA.txt = pinned sha"
S=$T/src1; mkdir -p $S/tarballs; for r in "${!REF[@]}"; do mktar $S/tarballs $r; done
chk rc "$(run01 FETCH_ONLY=1 SRC=$S BIN=$T/bin1)" 0
chk trees "$(ls -d $S/*/src 2>/dev/null | wc -l)" 7
chk sha_femtic "$(cat $S/femtic/COMMIT_SHA.txt)" "${REF[femtic]}"
chk pinned_msg "$(grep -c -- '-- femtic @ 26c8606 (git-free tree)' $T/out.txt)" 1
echo "F2 rerun on the same tree: expect exit 0, no unpacking (idempotent)"
chk rc "$(run01 FETCH_ONLY=1 SRC=$S BIN=$T/bin1)" 0; chk no_unpack "$(grep -c 'unpacking' $T/out.txt)" 0
echo "F3 git-free tree without COMMIT_SHA.txt: expect exit 0 with a version-UNKNOWN warning naming the repo"
rm $S/makeMtr/COMMIT_SHA.txt
chk rc "$(run01 FETCH_ONLY=1 SRC=$S BIN=$T/bin1)" 0; chk unknown_warn "$(grep -c 'WARNING: unknown source version for: makeMtr' $T/out.txt)" 1
echo "F4 COMMIT_SHA.txt differs from the pin, PIN=1: expect exit 1 (refused)"
echo 0123456789abcdef0123456789abcdef01234567 > $S/makeMtr/COMMIT_SHA.txt
chk rc "$(run01 FETCH_ONLY=1 SRC=$S BIN=$T/bin1)" 1; chk refuse_msg "$(grep -c 'makeMtr is at' $T/out.txt)" 1
echo "F5 missing repo inside an icelake job, no tarball: expect exit 1 before any clone, with the login-node instruction"
S2=$T/src2; mkdir -p $S2
chk rc "$(run01 FETCH_ONLY=1 SRC=$S2 BIN=$T/bin2 SLURM_JOB_ID=42 SLURM_JOB_PARTITION=icelake)" 1
chk no_fetch_msg "$(grep -c 'Fetch first on the login node' $T/out.txt)" 1; chk nothing_cloned "$(ls $S2 | grep -vc -E '^(fetch_|tarballs$)')" 0
echo "F6 same, but the tarballs are present inside the icelake job: expect exit 0 (unpacking needs no internet)"
mkdir -p $S2/tarballs; for r in "${!REF[@]}"; do mktar $S2/tarballs $r; done
chk rc "$(run01 FETCH_ONLY=1 SRC=$S2 BIN=$T/bin2 SLURM_JOB_ID=42 SLURM_JOB_PARTITION=icelake)" 0
echo; echo "CHECKS: $npass passed, $nfail failed"
echo "OVERALL: $([ $fail = 0 ] && echo PASS || echo FAIL)"; rm -rf $T
[ $fail = 0 ]
