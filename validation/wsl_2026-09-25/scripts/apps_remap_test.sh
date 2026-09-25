#!/bin/bash
# apps_remap_test.sh -- WSL test of femtic_apps_remap (femtic_lib.sh, added 2026-09-25) and of the femtic_env.sh that
# 01's section 4 writes. Phoenix's interactive (data-mover) nodes p2-dmv-* have no /apps, only /gpfs/apps, yet the
# modules set /apps/... paths there. The function must rewrite /apps/ -> /gpfs/apps/ in exported variables where a
# path starts, never touch /gpfs/apps/... (no /gpfs/gpfs/apps), leave unexported and non-path values alone, warn
# once, be idempotent, return 0 under set -eu, and do nothing where /apps exists or /gpfs/apps does not.
# The real paths /apps and /gpfs/apps are used, inside a private mount namespace (unshare -rm + chroot onto a tmpfs
# root); the real file system is never changed. Each case runs under 'env -i', so no WSL variable leaks in.
# Failure criterion: the harness FAILS if any observable below differs from the value each case states.
# Run in WSL:  bash apps_remap_test.sh      (PLAN=... to test another copy of the kit)
# BASH_UNDER_TEST=<bash binary> runs the probes (femtic_lib.sh, femtic_env.sh) with that bash (default: /bin/bash).
export BASH_UNDER_TEST=${BASH_UNDER_TEST:-/bin/bash}
export PLAN=${PLAN:-/mnt/d/BEN/FEMTIC_2026/hpc/phoenix_plan}
export T; T=$(mktemp -d); fail=0; npass=0; nfail=0
chk(){ if [ "$2" = "$3" ]; then echo "  PASS $1 ($2)"; npass=$((npass+1)); else echo "  FAIL $1: got '$2' want '$3'"; fail=1; nfail=$((nfail+1)); fi; }
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
# the probe: sets module-like variables, calls femtic_apps_remap twice, dumps the results
cat > "$T/probe.sh" <<'EOF'
set -eu
. "$PLAN/femtic_lib.sh"
export MKLROOT=/apps/icl/software/imkl/2023.1.0/mkl/2023.1.0
export LD_LIBRARY_PATH=/apps/icl/software/imkl/2023.1.0/mkl/2023.1.0/lib/intel64:/gpfs/apps/icl/software/GCCcore/12.3.0/lib64:/usr/lib64
export LIBRARY_PATH=/apps/icl/software/imkl/2023.1.0/mkl/2023.1.0/lib/intel64
export CPATH=/apps/icl/a/include:/apps/icl/b/include
export PATH=/apps/icl/x/bin:/usr/bin:/bin
export __LMOD_REF_COUNT_LD_LIBRARY_PATH="/apps/icl/a/lib:1;/gpfs/apps/icl/b/lib64:1"
export OPTS_BLANK="-x /apps/y"
export KEEP_GPFS=/gpfs/apps/icl/z KEEP_USR=/usr/apps/q KEEP_WORD=hello
UNEXPORTED=/apps/n
echo "bash=${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
femtic_apps_remap 2> "$T/warn1_$1"; echo "rc1=$?"
for v in MKLROOT LD_LIBRARY_PATH LIBRARY_PATH CPATH PATH __LMOD_REF_COUNT_LD_LIBRARY_PATH OPTS_BLANK KEEP_GPFS KEEP_USR KEEP_WORD UNEXPORTED; do
  echo "$v=${!v}"; done
femtic_apps_remap 2> "$T/warn2_$1"; echo "rc2=$?"
echo "after2 MKLROOT=$MKLROOT LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
echo "reached_end"
EOF
probe(){ env -i HOME=/tmp PATH=/usr/bin:/bin PLAN="$PLAN" T="$T" "$BASH_UNDER_TEST" "$T/probe.sh" "$1"; }
val(){ sed -n "s|^$2=||p" "$T/$1.out"; }
G=/gpfs/apps/icl/software/imkl/2023.1.0/mkl/2023.1.0

echo "R1 node without /apps, with /gpfs/apps (p2-dmv-like sandbox), under set -eu: expect 7 exported variables remapped at"
echo "   path starts only, /gpfs/apps entries untouched, unexported/non-path values untouched, one warning, rc 0"
sandbox gpfs_only /bin/bash -c "$(declare -f probe); probe r1" > "$T/r1.out" 2>&1
chk rc1 "$(val r1 rc1)" 0
chk bash_version "$(val r1 bash)" "$("$BASH_UNDER_TEST" -c 'echo ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}')"
chk MKLROOT "$(val r1 MKLROOT)" "$G"
chk LD_LIBRARY_PATH "$(val r1 LD_LIBRARY_PATH)" "$G/lib/intel64:/gpfs/apps/icl/software/GCCcore/12.3.0/lib64:/usr/lib64"
chk LIBRARY_PATH "$(val r1 LIBRARY_PATH)" "$G/lib/intel64"
chk CPATH "$(val r1 CPATH)" "/gpfs/apps/icl/a/include:/gpfs/apps/icl/b/include"
chk PATH "$(val r1 PATH)" "/gpfs/apps/icl/x/bin:/usr/bin:/bin"
chk lmod_refcount "$(val r1 __LMOD_REF_COUNT_LD_LIBRARY_PATH)" "/gpfs/apps/icl/a/lib:1;/gpfs/apps/icl/b/lib64:1"
chk blank_separated "$(val r1 OPTS_BLANK)" "-x /gpfs/apps/y"
chk keep_gpfs "$(val r1 KEEP_GPFS)" /gpfs/apps/icl/z
chk keep_usr_apps "$(val r1 KEEP_USR)" /usr/apps/q
chk keep_word "$(val r1 KEEP_WORD)" hello
chk keep_unexported "$(val r1 UNEXPORTED)" /apps/n
chk no_double_gpfs "$(grep -c 'gpfs/gpfs' "$T/r1.out")" 0
chk warning "$(cat "$T/warn1_r1")" "femtic_env.sh: /apps absent on $(hostname); remapped to /gpfs/apps (7 exported variables)"
chk idempotent_rc2 "$(val r1 rc2)" 0
chk idempotent_no_warning "$(wc -c < "$T/warn2_r1")" 0
chk idempotent_values "$(sed -n 's/^after2 //p' "$T/r1.out")" "MKLROOT=$G LD_LIBRARY_PATH=$G/lib/intel64:/gpfs/apps/icl/software/GCCcore/12.3.0/lib64:/usr/lib64"
chk reached_end "$(grep -c '^reached_end$' "$T/r1.out")" 1

echo "R2 node with /apps and /gpfs/apps (icelake/login-like sandbox), set -eu: expect nothing changed, no warning, rc 0"
sandbox both /bin/bash -c "$(declare -f probe); probe r2" > "$T/r2.out" 2>&1
chk rc1 "$(val r2 rc1)" 0; chk MKLROOT "$(val r2 MKLROOT)" /apps/icl/software/imkl/2023.1.0/mkl/2023.1.0
chk CPATH "$(val r2 CPATH)" "/apps/icl/a/include:/apps/icl/b/include"; chk no_warning "$(wc -c < "$T/warn1_r2")" 0
chk reached_end "$(grep -c '^reached_end$' "$T/r2.out")" 1

echo "R3 plain WSL (neither /apps nor /gpfs/apps): expect nothing changed, no warning, rc 0"
probe r3 > "$T/r3.out" 2>&1
chk rc1 "$(val r3 rc1)" 0; chk PATH "$(val r3 PATH)" "/apps/icl/x/bin:/usr/bin:/bin"; chk no_warning "$(wc -c < "$T/warn1_r3")" 0

echo "R4 the femtic_env.sh written by 01's section 4, sourced on the p2-dmv-like node with a mock 'module load' that sets"
echo "   MKLROOT=/apps/... and LD_LIBRARY_PATH: expect both on /gpfs/apps afterwards and exactly one warning line"
sed -n '/^install -m 644 "\$PLAN_DIR\/femtic_lib.sh"/,/^} > "\$BIN\/femtic_env.sh"/p' "$PLAN/01_build_femtic.sh" > "$T/sec4.sh"
# shellcheck disable=SC2034  # read by the sourced section-4 code
mkdir -p "$T/bin"; ( BIN=$T/bin TOOLCHAIN=foss MODS="foss/2023a imkl/2023.1.0" EB_MODULES=$T/no_eb PLAN_DIR=$PLAN; . "$T/sec4.sh" )
chk env_file_calls_remap "$(grep -c '^femtic_apps_remap' "$T/bin/femtic_env.sh")" 1
cat > "$T/r4.sh" <<'EOF'
module() { [ "$1" = load ] && export MKLROOT=/apps/icl/software/imkl/2023.1.0/mkl/2023.1.0 \
  LD_LIBRARY_PATH=/apps/icl/software/imkl/2023.1.0/mkl/2023.1.0/lib/intel64:/gpfs/apps/icl/software/GCCcore/12.3.0/lib64; return 0; }
. "$T/bin/femtic_env.sh"; echo "src_rc=$?"; echo "MKLROOT=$MKLROOT"; echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
EOF
sandbox gpfs_only /usr/bin/env -i HOME=/tmp PATH=/usr/bin:/bin T="$T" "$BASH_UNDER_TEST" "$T/r4.sh" > "$T/r4.out" 2>&1
chk source_rc "$(val r4 src_rc)" 0
chk MKLROOT "$(val r4 MKLROOT)" "$G"
chk LD_LIBRARY_PATH "$(val r4 LD_LIBRARY_PATH)" "$G/lib/intel64:/gpfs/apps/icl/software/GCCcore/12.3.0/lib64"
chk one_warning "$(grep -c '^femtic_env.sh: /apps absent on .*; remapped to /gpfs/apps' "$T/r4.out")" 1
chk wsl_root_untouched "$(ls -d /apps /gpfs/apps 2>/dev/null | wc -l)" 0

echo; echo "CHECKS: $npass passed, $nfail failed"
echo "OVERALL: $([ $fail = 0 ] && echo PASS || echo FAIL)"
if [ $fail != 0 ] && [ -n "${KEEP:-}" ]; then echo "kept $T for debugging"; else rm -rf "$T"; fi
[ $fail = 0 ]
