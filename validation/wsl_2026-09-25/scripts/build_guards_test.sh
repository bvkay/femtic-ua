#!/bin/bash
# build_guards_test.sh -- WSL test of the two build-path guards in 01_build_femtic.sh section 2 (added 2026-09-25):
#   * make must exist after 'module load' (icelake compute nodes have none: "make: command not found");
#   * libmkl_core.so* (versioned names included) must exist in lib/intel64/ or lib/ of MKLROOT, else of the same
#     path with /apps <-> /gpfs/apps swapped (then MKLROOT is switched, with a warning), else the script stops
#     after printing hostname, ls -ld of MKLROOT and its lib dirs, ls -d /apps /gpfs/apps and df -h.
# Set-up: 7 git-free source trees with COMMIT_SHA.txt = the pinned commit (section 1 passes without git or network),
# a mocked 'module' whose 'load' sets MKLROOT=$MOCK_MKLROOT, g++/mpicxx stubs, and PORTED pointing at an EMPTY
# directory, so a run that gets past both guards stops at the first build step with
# "missing .../femtic/Makefile.gcc_openmpi_mkl": that line is the observable for "the guards let it through".
# B5-B7 run inside a private mount namespace (unshare -rm + chroot onto a tmpfs root) that has /gpfs/apps and/or
# /apps; the real file system is never changed.
# Failure criterion: the harness FAILS if any observable below differs from the value each case states.
# Run in WSL:  bash build_guards_test.sh      (PLAN=... to test another copy of the kit)
# BASH_UNDER_TEST=<bash binary> runs 01 (and femtic_env.sh / femtic_lib.sh inside it) with that bash (default: bash).
export BASH_UNDER_TEST=${BASH_UNDER_TEST:-bash}
export PLAN=${PLAN:-/mnt/d/BEN/FEMTIC_2026/hpc/phoenix_plan}
export T; T=$(mktemp -d); fail=0; npass=0; nfail=0
chk(){ if [ "$2" = "$3" ]; then echo "  PASS $1 ($2)"; npass=$((npass+1)); else echo "  FAIL $1: got '$2' want '$3'"; fail=1; nfail=$((nfail+1)); fi; }
cnt(){ grep -c -- "$1" "$2" 2>/dev/null || true; }
declare -A REF=([femtic]=26c8606ea61717a9386f93fff47203391836829c [makeTetraMesh]=92a9a32e0683458f7908f75743a8e3777753d0a1
  [makeMtr]=df8e2071f908dfd9dc30333ec548a42dc2e5a5c1 [TetGen2Femtic]=ceb8bfb1493092ed7c6a1a52352307be356d31e3
  [makeDHexaMesh]=66afbfcaf8fea8c64ddcf686e52e553895559238 [mergeResultOfFEMTIC]=4fe54e1e6c0a55f636fc15a6b1d5bd646d739487
  [tetgen]=e05aca7df74e3f531bc35733ed87d36d437266c5)
export S=$T/src; for r in "${!REF[@]}"; do mkdir -p "$S/$r/src"; echo "${REF[$r]}" > "$S/$r/COMMIT_SHA.txt"; done
STUB=$T/stubs; mkdir -p "$STUB" "$T/noported"
printf '#!/bin/bash\ncase "$1" in -dumpversion) echo 12;; -dumpfullversion) echo 12.3.0;; *) exit 1;; esac\n' > "$STUB/g++"
printf '#!/bin/bash\necho "g++ (stub mpicxx)"\n' > "$STUB/mpicxx"; chmod +x "$STUB"/*
NOMAKE=$T/nomake; mkdir -p "$NOMAKE"
for f in /usr/bin/*; do case "${f##*/}" in make|gmake) ;; *) ln -s "$f" "$NOMAKE/" ;; esac; done
module() { case "$1" in load) export MKLROOT="$MOCK_MKLROOT" ;; list) echo "Currently Loaded Modules: (mock)" ;; esac; return 0; }
export -f module
export WITHMAKE=$STUB:$PATH WITHOUTMAKE=$STUB:$NOMAKE
cat > "$T/run01.sh" <<'EOF'
#!/bin/bash
# run01.sh <out> <PATH> [ENV=VAL ...] -> exit status of the 01 build path (TOOLCHAIN=foss)
o=$1 p=$2; shift 2
env -u SLURM_JOB_ID -u SLURM_JOB_PARTITION -u MKLROOT PATH="$p" SRC="$S" BIN="$T/bin" PORTED="$T/noported" \
    TOOLCHAIN=foss "$@" "$BASH_UNDER_TEST" "$PLAN/01_build_femtic.sh" 2>&1 | cat > "$o"
exit "${PIPESTATUS[0]}"
EOF
run01(){ bash "$T/run01.sh" "$@"; }
sandbox(){  # sandbox <gpfs_only|both> <command...> (see smokeonly_test.sh)
  local lay=$1 nr rc; shift; nr=$(mktemp -d)
  unshare -rm bash -c 'nr=$1 lay=$2; shift 2
    mount -t tmpfs tmpfs "$nr" || exit 90
    for d in usr etc dev proc sys tmp mnt home run var; do mkdir -p "$nr/$d"; mount --rbind "/$d" "$nr/$d" || exit 91; done
    for l in bin lib lib64 sbin; do ln -s "usr/$l" "$nr/$l"; done
    mkdir -p "$nr/gpfs/apps"; [ "$lay" = both ] && mkdir -p "$nr/apps"
    exec chroot "$nr" "$@"' _ "$nr" "$lay" "$@"; rc=$?
  rmdir "$nr" 2>/dev/null; return $rc
}
MKMSG='missing .*/noported/femtic/Makefile.gcc_openmpi_mkl'

echo "P0 preconditions: make is on the normal PATH and absent from the no-make PATH; no /apps or /gpfs/apps in WSL"
chk make_normal "$(PATH=$WITHMAKE command -v make | wc -l)" 1
chk make_absent "$(PATH=$WITHOUTMAKE command -v make | wc -l)" 0
chk no_apps_in_wsl "$(ls -d /apps /gpfs/apps 2>/dev/null | wc -l)" 0

echo "B1 SMOKE=1 build inside an icelake job with no make on PATH (valid MKL): expect exit 1 with the make message,"
echo "   before the MKL check, the build and T2"
mkdir -p "$T/mklA/lib/intel64"; touch "$T/mklA/lib/intel64/libmkl_core.so.2"
run01 "$T/b1.out" "$WITHOUTMAKE" SMOKE=1 SLURM_JOB_ID=91 SLURM_JOB_PARTITION=icelake MOCK_MKLROOT="$T/mklA"; chk rc "$?" 1
chk make_msg "$(cnt '^ERROR: make not found: build on the login node (compute nodes have no make); for the smoke test use SMOKE_ONLY=1$' "$T/b1.out")" 1
chk no_mkl_check_output "$(cnt 'libmkl_core' "$T/b1.out")" 0
chk no_build "$(cnt '===============' "$T/b1.out")" 0
chk no_t2 "$(cnt 'T2 (smoke run)' "$T/b1.out")" 0
chk bin_empty "$(ls "$T/bin" | wc -l)" 0

echo "B2 make present, MKLROOT has ONLY lib/intel64/libmkl_core.so.2 (versioned name): expect the guards to pass"
run01 "$T/b2.out" "$WITHMAKE" MOCK_MKLROOT="$T/mklA"; chk rc "$?" 1
chk reached_build "$(cnt "$MKMSG" "$T/b2.out")" 1; chk no_mkl_error "$(cnt 'no libmkl_core' "$T/b2.out")" 0

echo "B3 MKLROOT has ONLY lib/libmkl_core.so (imkl 2024+ layout): expect the guards to pass"
mkdir -p "$T/mklB/lib"; touch "$T/mklB/lib/libmkl_core.so"
run01 "$T/b3.out" "$WITHMAKE" MOCK_MKLROOT="$T/mklB"; chk rc "$?" 1
chk reached_build "$(cnt "$MKMSG" "$T/b3.out")" 1; chk no_mkl_error "$(cnt 'no libmkl_core' "$T/b3.out")" 0

echo "B4 MKLROOT (outside /apps) with lib/intel64 but no libmkl_core: expect exit 1 after the diagnostics"
mkdir -p "$T/mklC/lib/intel64"; touch "$T/mklC/lib/intel64/libmkl_gnu_thread.so.2"
run01 "$T/b4.out" "$WITHMAKE" MOCK_MKLROOT="$T/mklC"; chk rc "$?" 1
chk die_msg "$(cnt "^ERROR: no libmkl_core.so\* under MKLROOT=$T/mklC on $(hostname) -- see the diagnostics above" "$T/b4.out")" 1
chk diag_head "$(cnt '^-- MKL diagnostics: no libmkl_core.so\* in lib/intel64/ or lib/ of MKLROOT$' "$T/b4.out")" 1
chk diag_hostname "$(grep -cx "$(hostname)" "$T/b4.out")" 1
chk diag_ls_ld "$(cnt "^d.* $T/mklC/lib/intel64$" "$T/b4.out")" 1
chk diag_apps "$(cnt "ls: cannot access '/apps'" "$T/b4.out")" 1
chk diag_df "$(cnt '^   \$ df -h ' "$T/b4.out")" 1
chk not_built "$(cnt "$MKMSG" "$T/b4.out")" 0

APPS_MKL=/apps/icl/software/imkl/2023.1.0/mkl/2023.1.0; GPFS_MKL=/gpfs/apps/icl/software/imkl/2023.1.0/mkl/2023.1.0
echo "B5 p2-dmv-like node (sandbox: /gpfs/apps only), MKLROOT=$APPS_MKL, library under /gpfs/apps:"
echo "   expect a warning, MKLROOT switched to $GPFS_MKL, the guards pass"
sandbox gpfs_only /bin/bash -c "mkdir -p $GPFS_MKL/lib/intel64 && touch $GPFS_MKL/lib/intel64/libmkl_core.so.2 && \
  bash \"\$T/run01.sh\" \"\$T/b5.out\" \"\$WITHMAKE\" MOCK_MKLROOT=$APPS_MKL"
chk rc "$?" 1
chk swap_warning "$(cnt "^WARNING: no libmkl_core.so\* under MKLROOT=$APPS_MKL on .*, but under $GPFS_MKL: using MKLROOT=$GPFS_MKL.$" "$T/b5.out")" 1
chk reached_build "$(cnt "$MKMSG" "$T/b5.out")" 1
echo "B6 the reverse (sandbox: /apps and /gpfs/apps): MKLROOT=$GPFS_MKL empty, library under /apps: expect MKLROOT=$APPS_MKL"
sandbox both /bin/bash -c "mkdir -p $APPS_MKL/lib $GPFS_MKL/lib/intel64 && touch $APPS_MKL/lib/libmkl_core.so && \
  bash \"\$T/run01.sh\" \"\$T/b6.out\" \"\$WITHMAKE\" MOCK_MKLROOT=$GPFS_MKL"
chk rc "$?" 1
chk swap_warning "$(cnt "but under $APPS_MKL: using MKLROOT=$APPS_MKL.$" "$T/b6.out")" 1
chk reached_build "$(cnt "$MKMSG" "$T/b6.out")" 1
echo "B7 sandbox /gpfs/apps only, library in neither tree: expect exit 1 naming both paths, diagnostics show /apps absent"
sandbox gpfs_only /bin/bash -c "mkdir -p $GPFS_MKL/lib/intel64 && bash \"\$T/run01.sh\" \"\$T/b7.out\" \"\$WITHMAKE\" MOCK_MKLROOT=$APPS_MKL"
chk rc "$?" 1
chk die_msg "$(cnt "^ERROR: no libmkl_core.so\* under MKLROOT=$APPS_MKL (nor under $GPFS_MKL) on " "$T/b7.out")" 1
chk diag_apps_absent "$(cnt "ls: cannot access '/apps'" "$T/b7.out")" 1
chk diag_gpfs_present "$(grep -cx '/gpfs/apps' "$T/b7.out")" 1
chk wsl_root_untouched "$(ls -d /apps /gpfs/apps 2>/dev/null | wc -l)" 0

echo; echo "CHECKS: $npass passed, $nfail failed"
echo "OVERALL: $([ $fail = 0 ] && echo PASS || echo FAIL)"
if [ $fail != 0 ] && [ -n "${KEEP:-}" ]; then echo "kept $T for debugging"; else rm -rf "$T"; fi
[ $fail = 0 ]
