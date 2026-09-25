#!/bin/bash
# smokeonly_test.sh -- WSL test of 01_build_femtic.sh SMOKE_ONLY=1 (added 2026-09-25 after the smoke job on the
# data-mover node p2-dmv-1 failed in 0 s: no git there, and /apps absent so libmkl_core was not found).
#
# Set-up: a fake $BIN (fake femtic that honours ITERATION like FEMTIC's restart; fake mpirun; fake ldd that
# resolves the MKL libraries through LD_LIBRARY_PATH as the loader does, femtic having no RPATH for MKL) whose
# femtic_env.sh + femtic_lib.sh are installed by 01's OWN section-4 code (extracted below), with a mocked
# 'module' that sets MKLROOT and LD_LIBRARY_PATH like imkl/2023.1.0; the real FEMTIC example INV_MT_01/Tetra
# inputs; and a PATH with NO git, make or compiler (removed from a copy of /usr/bin) plus poison stubs (git,
# gcc, g++, cc, c++, make, mpicxx, mpiicpc, icpx) that record any call.
# K10-K12 run 01 in a private mount namespace (unshare -rm + chroot onto a tmpfs root) that has /gpfs/apps and
# no /apps, like p2-dmv-*, or both, like icelake; the real file system is never changed.
# Failure criterion: the harness FAILS if any observable below differs from the value each case states.
# Run in WSL:  bash smokeonly_test.sh      (PLAN=... to test another copy of the kit)
# BASH_UNDER_TEST=<bash binary> runs 01 (and femtic_env.sh / femtic_lib.sh inside it) with that bash (default: bash).
export BASH_UNDER_TEST=${BASH_UNDER_TEST:-bash}
export PLAN=${PLAN:-/mnt/d/BEN/FEMTIC_2026/hpc/phoenix_plan}
EXSRC=${EXSRC:-/mnt/d/BEN/FEMTIC_2026/validation/wsl_2026-09-25/femtic_example_INV_MT_01_Tetra}
[ -f "$EXSRC/resistivity_block_iter0.dat" ] || { echo "FEMTIC example not found at EXSRC=$EXSRC"; exit 2; }
export R; R=$(mktemp -d); fail=0; npass=0; nfail=0
chk(){ if [ "$2" = "$3" ]; then echo "  PASS $1 ($2)"; npass=$((npass+1)); else echo "  FAIL $1: got '$2' want '$3'"; fail=1; nfail=$((nfail+1)); fi; }
cnt(){ grep -c -- "$1" "$2" 2>/dev/null || true; }    # cnt <regex> <file> -> number of matching lines
lines(){ if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

# ---- PATH without git, make and compilers, plus poison stubs
SYS=$R/sysbin; POI=$R/poison; mkdir -p "$SYS" "$POI"
for f in /usr/bin/*; do
  case "${f##*/}" in
    git|git-*|gcc|gcc-*|g++|g++-*|cc|c++|cpp|cpp-*|*-linux-gnu-*|clang*|make|gmake|mpi*|ldd) ;;
    *) ln -s "$f" "$SYS/" ;;
  esac
done
for p in git gcc g++ cc c++ make mpicxx mpiicpc icpx; do
  printf '#!/bin/bash\necho "${0##*/} $*" >> "$MOCK_DIR/poison_calls"\nexit 127\n' > "$POI/$p"; chmod +x "$POI/$p"
done

# ---- fake $BIN
export B=$R/bin; mkdir -p "$B"
cat > "$B/femtic" <<'EOF'
#!/bin/bash
# fake femtic: runs iterations a..b of control.dat's ITERATION "a b", continuing from resistivity_block_iter<a>.dat
# like FEMTIC's restart. FAKE=badrestart ignores a (always starts from iteration 0).
read -r A Z < <(awk '$1=="ITERATION"{getline; print; exit}' control.dat)
[ "$FAKE" = badrestart ] && A=0
echo "$A $Z" >> "$MOCK_DIR/femtic_calls"
{ echo "#+++"; echo "# Forward calculation is performed for the frequencies/periods below."; echo "#   Freq#  Frequency[Hz]    Period[sec]"
  for i in 0 1 2 3; do echo "#  $i  $((i+1)).0  1.0"; done; echo "#++++++++++"; } > femtic_0.log
printf '%10s%10s%15s%15s%15s%15s%15s%15s\n' 'Iter#' 'Retrial#' Alpha Damp Roughness Misfit RMS ObjFunc > femtic.cnv
for it in $(seq "$A" "$Z"); do
  echo "# Start Forward Computation.  Iteration : $it,  Retrial : 0" >> femtic_0.log
  printf '%10d%10d%15e%15e%15e%15e%15e%15e\n' "$it" 0 3 0.5 1 $((1000 - 100 * it)) 1 1 >> femtic.cnv
  [ "$it" -gt "$A" ] && cp "resistivity_block_iter$((it - 1)).dat" "resistivity_block_iter$it.dat"
done
echo "# Reach maximum iteration number." >> femtic_0.log
EOF
cat > "$B/mpirun" <<'EOF'
#!/bin/bash
echo "$*" >> "$MOCK_DIR/mpirun_calls"
exec "${@: -1}"
EOF
cat > "$B/ldd" <<'EOF'
#!/bin/bash
# fake ldd of a foss/2023a + imkl 2023.1.0 femtic (as on p2-log-2, 2026-09-25): the three MKL libraries are
# resolved through LD_LIBRARY_PATH (no RPATH for MKL), libgomp and libmpi through the RPATH under /gpfs/apps
printf '\tlinux-vdso.so.1 (0x00007ffd00000000)\n'
IFS=: read -ra dirs <<< "${LD_LIBRARY_PATH:-}"
for lib in libmkl_intel_ilp64.so.2 libmkl_gnu_thread.so.2 libmkl_core.so.2; do
  hit=""; for d in "${dirs[@]}"; do [ -n "$d" ] && [ -e "$d/$lib" ] && { hit="$d/$lib"; break; }; done
  if [ -n "$hit" ]; then printf '\t%s => %s (0x1)\n' "$lib" "$hit"; else printf '\t%s => not found\n' "$lib"; fi
done
printf '\tlibgomp.so.1 => /gpfs/apps/icl/software/GCCcore/12.3.0/lib64/libgomp.so.1 (0x4)\n'
printf '\tlibmpi.so.40 => /gpfs/apps/icl/software/OpenMPI/4.1.5-GCC-12.3.0/lib/libmpi.so.40 (0x5)\n'
EOF
chmod +x "$B"/*
# femtic_env.sh + femtic_lib.sh installed by 01's own section-4 code (install ... through '} > "$BIN/femtic_env.sh"')
sed -n '/^install -m 644 "\$PLAN_DIR\/femtic_lib.sh"/,/^} > "\$BIN\/femtic_env.sh"/p' "$PLAN/01_build_femtic.sh" > "$R/sec4.sh"
chk sec4_extracted "$( [ "$(wc -l < "$R/sec4.sh")" -ge 8 ] && echo ok)" ok
# shellcheck disable=SC2034  # read by the sourced section-4 code
( BIN=$B TOOLCHAIN=foss MODS="foss/2023a imkl/2023.1.0" EB_MODULES=$R/no_easybuild PLAN_DIR=$PLAN; . "$R/sec4.sh" )
chk env_file_loads_modules "$(grep -c '^module load foss/2023a imkl/2023.1.0 ' "$B/femtic_env.sh")" 1
chk env_file_remaps "$(grep -c '^femtic_apps_remap' "$B/femtic_env.sh")" 1
# mock Lmod: 'module load' sets what imkl/2023.1.0 sets (MKLROOT + its lib/intel64 on LD_LIBRARY_PATH)
module() { echo "module $*" >> "$MOCK_DIR/module_calls"
  case "$1" in
    load) export MKLROOT="$MOCK_MKLROOT" LD_LIBRARY_PATH="$MOCK_MKLROOT/lib/intel64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;;
    list) echo "Currently Loaded Modules: (mock) foss/2023a imkl/2023.1.0" ;;
  esac; return 0; }
export -f module
MKLLIBS="libmkl_intel_ilp64.so.2 libmkl_gnu_thread.so.2 libmkl_core.so.2"
mkdir -p "$R/mkl/lib/intel64" "$R/mkl_nocore/lib/intel64"
for l in $MKLLIBS; do touch "$R/mkl/lib/intel64/$l"; done; touch "$R/mkl_nocore/lib/intel64/"{libmkl_intel_ilp64,libmkl_gnu_thread}.so.2

# ---- source tree: ONLY the example (no other repo, no .git, no COMMIT_SHA.txt), as a fresh compute node would need
export S=$R/src; mkdir -p "$S/femtic/examples/INV_MT_01/Tetra"
cp "$EXSRC"/{control.dat,mesh.dat,observe.dat,resistivity_block_iter0.dat} "$S/femtic/examples/INV_MT_01/Tetra/"
export RUNPATH=$B:$POI:$SYS
cat > "$R/run01.sh" <<'EOF'
#!/bin/bash
# run01.sh <out> [ENV=VAL ...] -> exit status of 01; the pipe through cat waits until 01's tee has finished
o=$1; shift
rm -f "$R/poison_calls" "$R/module_calls"
env -u SLURM_JOB_ID -u SLURM_JOB_PARTITION -u MKLROOT -u LD_LIBRARY_PATH PATH="$RUNPATH" MOCK_DIR="$R" \
    MOCK_MKLROOT="$R/mkl" SRC="$S" BIN="$B" "$@" "$BASH_UNDER_TEST" "$PLAN/01_build_femtic.sh" 2>&1 | cat > "$o"
exit "${PIPESTATUS[0]}"
EOF
run01(){ bash "$R/run01.sh" "$@"; }
sandbox(){  # sandbox <gpfs_only|both> <command...>: run the command as the private-namespace root, chrooted onto a
  # fresh tmpfs holding bind mounts of usr etc dev proc sys tmp mnt home run var plus an empty /gpfs/apps (and /apps if 'both')
  local lay=$1 nr rc; shift; nr=$(mktemp -d)
  unshare -rm bash -c 'nr=$1 lay=$2; shift 2
    mount -t tmpfs tmpfs "$nr" || exit 90
    for d in usr etc dev proc sys tmp mnt home run var; do mkdir -p "$nr/$d"; mount --rbind "/$d" "$nr/$d" || exit 91; done
    for l in bin lib lib64 sbin; do ln -s "usr/$l" "$nr/$l"; done
    mkdir -p "$nr/gpfs/apps"; [ "$lay" = both ] && mkdir -p "$nr/apps"
    exec chroot "$nr" "$@"' _ "$nr" "$lay" "$@"; rc=$?
  rmdir "$nr" 2>/dev/null; return $rc
}

echo "P0 preconditions: no /apps or /gpfs/apps in WSL; the restricted PATH has no real git/make/compiler, and git/g++/make"
echo "   resolve to the poison stubs; the namespace sandbox works"
chk no_apps_in_wsl "$(ls -d /apps /gpfs/apps 2>/dev/null | wc -l)" 0
chk no_real_git_make_cc "$(PATH=$SYS command -v git gcc g++ make cc | wc -l)" 0
chk poison_first "$(PATH=$RUNPATH command -v git g++ make | grep -c "^$POI/")" 3
chk sandbox "$(sandbox gpfs_only /bin/bash -c 'ls -d /apps /gpfs/apps 2>/dev/null')" /gpfs/apps
BIN_BEFORE=$(ls -l --time-style=+%s "$B" | md5sum); ENV_BEFORE=$(md5sum < "$B/femtic_env.sh")

echo "K1 SMOKE_ONLY=1 as the icelake batch job (SLURM_JOB_ID set, partition icelake), no git/make/compiler, MKLROOT unset"
echo "   before, SRC holding only the example: expect exit 0, T1/T2/T5 PASS, femtic_env.sh sourced, nothing built or rewritten"
run01 "$R/k1.out" SMOKE_ONLY=1 SLURM_JOB_ID=77 SLURM_JOB_PARTITION=icelake; chk rc "$?" 0
chk header_mode "$(cnt 'partition=icelake  SMOKE_ONLY=1$' "$R/k1.out")" 1
chk done_line "$(cnt 'SMOKE_ONLY DONE  T1=PASS  T2=PASS  T5=PASS' "$R/k1.out")" 1
chk t1_pass "$(cnt '^T1 (linkage): PASS$' "$R/k1.out")" 1
chk t1_saw_core "$(cnt "libmkl_core.so.2 => $R/mkl/lib/intel64/libmkl_core.so.2" "$R/k1.out")" 1
chk t2_t5_pass "$(cnt '^T2 (smoke run): PASS    T5 (restart equivalence): PASS' "$R/k1.out")" 1
chk env_sourced "$(cnt '^module load foss/2023a imkl/2023.1.0$' "$R/module_calls")" 1
chk poison_calls "$(lines "$R/poison_calls")" 0
chk section1_skipped "$(cnt '-- source policy' "$R/k1.out")" 0
chk no_remap_warning "$(cnt 'femtic_env.sh: /apps absent' "$R/k1.out")" 0
chk femtic_runs "$(tr '\n' ',' < "$R/femtic_calls")" "0 2,0 1,1 2,"
chk mpirun_calls "$(lines "$R/mpirun_calls")" 3
chk no_such_file "$(cnt 'No such file' "$R/k1.out")" 0
LOGF=$(ls "$S"/smoke_foss_*.log 2>/dev/null)
chk smoke_log "$(echo "$LOGF" | grep -c .)" 1
chk log_pairs_workdir "$([ -d "${LOGF%.log}/restart" ] && echo yes)" yes
chk log_has_result "$(cnt 'SMOKE_ONLY DONE' "$LOGF")" 1
# shellcheck disable=SC2010
chk no_build_or_fetch_log "$(ls "$S" | grep -cE '^(build|fetch)_')" 0
# shellcheck disable=SC2010
chk src_untouched "$(ls "$S" | grep -vcE '^(femtic|smoke_foss_[0-9_]+(\.log)?)$')" 0
chk bin_unchanged "$(ls -l --time-style=+%s "$B" | md5sum)" "$BIN_BEFORE"
chk env_file_unchanged "$(md5sum < "$B/femtic_env.sh")" "$ENV_BEFORE"
rm -f "$R/femtic_calls" "$R/mpirun_calls"

echo "K2 imkl's lib/intel64 lacks libmkl_core.so.2 (login-node-like: no Slurm; SMOKE_ONLY still runs T2/T5):"
echo "   expect exit 3, T1 FAIL naming 'libmkl_core.so.2 => not found', LD_LIBRARY_PATH and /apps diagnostics"
run01 "$R/k2.out" SMOKE_ONLY=1 MOCK_MKLROOT="$R/mkl_nocore"; chk rc "$?" 3
chk t1_unresolved "$(cnt '^T1 FAIL: unresolved libraries: .*libmkl_core.so.2 => not found' "$R/k2.out")" 1
chk t1_fail "$(cnt '^T1 (linkage): FAIL$' "$R/k2.out")" 1
chk diag_ldpath "$(cnt "^   LD_LIBRARY_PATH=$R/mkl_nocore/lib/intel64" "$R/k2.out")" 1
chk diag_prefixes "$(cnt '^   \$ ls -d /apps /gpfs/apps$' "$R/k2.out")" 1
chk smoke_ran_anyway "$(cnt '^T2 (smoke run): PASS' "$R/k2.out")" 1

echo "K3 femtic ignores the restart start iteration: expect exit 3, T2 PASS, T5 FAIL (restart leg did not start at iteration 1)"
run01 "$R/k3.out" SMOKE_ONLY=1 FAKE=badrestart; chk rc "$?" 3
chk t5_start_msg "$(cnt 'T5: restart leg did not start at iteration 1' "$R/k3.out")" 1
chk t2_pass_t5_fail "$(cnt '^T2 (smoke run): PASS    T5 (restart equivalence): FAIL' "$R/k3.out")" 1

echo "K4 no \$BIN/femtic: expect exit 1 with a clear message, before any run or work directory"
mv "$B/femtic" "$B/femtic.away"; nw=$(ls -d "$S"/smoke_foss_*/ | wc -l); rm -f "$R/mpirun_calls"
run01 "$R/k4.out" SMOKE_ONLY=1; chk rc "$?" 1; mv "$B/femtic.away" "$B/femtic"
chk msg "$(cnt "^ERROR: SMOKE_ONLY: $B/femtic not found or not executable -- build first" "$R/k4.out")" 1
chk no_mpirun "$(lines "$R/mpirun_calls")" 0; chk no_new_workdir "$(ls -d "$S"/smoke_foss_*/ | wc -l)" "$nw"

echo "K5 example directory missing (empty SRC): expect exit 1 naming the example path"
mkdir -p "$R/src_empty"; run01 "$R/k5.out" SMOKE_ONLY=1 SRC="$R/src_empty"; chk rc "$?" 1
chk msg "$(cnt "^ERROR: SMOKE_ONLY: FEMTIC example directory $R/src_empty/femtic/examples/INV_MT_01/Tetra not found" "$R/k5.out")" 1

echo "K6 \$BIN/femtic_env.sh missing: expect exit 1"
mv "$B/femtic_env.sh" "$B/femtic_env.sh.away"; run01 "$R/k6.out" SMOKE_ONLY=1; chk rc "$?" 1; mv "$B/femtic_env.sh.away" "$B/femtic_env.sh"
chk msg "$(cnt "^ERROR: SMOKE_ONLY: $B/femtic_env.sh not found" "$R/k6.out")" 1

echo "K7 TOOLCHAIN=intel against a foss femtic_env.sh: expect exit 1 (T1's criteria would be the wrong ones)"
run01 "$R/k7.out" SMOKE_ONLY=1 TOOLCHAIN=intel; chk rc "$?" 1
chk msg "$(cnt 'belongs to a TOOLCHAIN=foss build; rerun with TOOLCHAIN=foss' "$R/k7.out")" 1

echo "K8 SMOKE_ONLY=1 with FETCH_ONLY=1: expect exit 1"
run01 "$R/k8.out" SMOKE_ONLY=1 FETCH_ONLY=1; chk rc "$?" 1; chk msg "$(cnt 'exclude each other' "$R/k8.out")" 1

echo "K9 control: K1's job WITHOUT SMOKE_ONLY runs section 1: expect exit 1 (sources missing in a compute job) and a poison git call"
run01 "$R/k9.out" SLURM_JOB_ID=78 SLURM_JOB_PARTITION=icelake; chk rc "$?" 1
chk fetch_refused "$(cnt 'Fetch first on the login node' "$R/k9.out")" 1
chk poison_git_called "$(grep -c '^git ' "$R/poison_calls" 2>/dev/null)" 1

APPS_MKL=/apps/icl/software/imkl/2023.1.0/mkl/2023.1.0; GPFS_MKL=/gpfs/apps/icl/software/imkl/2023.1.0/mkl/2023.1.0
echo "K10 p2-dmv-like node (sandbox: /gpfs/apps only), module sets MKLROOT=$APPS_MKL (dangling), libraries under"
echo "    /gpfs/apps, interactive job: expect exit 0, one remap warning, MKLROOT and ldd on /gpfs/apps, T1/T2/T5 PASS"
sandbox gpfs_only /bin/bash -c "mkdir -p $GPFS_MKL/lib/intel64 && cd $GPFS_MKL/lib/intel64 && touch $MKLLIBS && \
  bash \"\$R/run01.sh\" \"\$R/k10.out\" SMOKE_ONLY=1 MOCK_MKLROOT=$APPS_MKL SLURM_JOB_ID=79 SLURM_JOB_PARTITION=interactive"
chk rc "$?" 0
chk remap_warning "$(cnt "^femtic_env.sh: /apps absent on $(hostname); remapped to /gpfs/apps" "$R/k10.out")" 1
chk mklroot_remapped "$(cnt "^MKLROOT=$GPFS_MKL " "$R/k10.out")" 1
chk ldd_core_gpfs "$(cnt "libmkl_core.so.2 => $GPFS_MKL/lib/intel64/libmkl_core.so.2" "$R/k10.out")" 1
chk done_line "$(cnt 'SMOKE_ONLY DONE  T1=PASS  T2=PASS  T5=PASS' "$R/k10.out")" 1
echo "K11 same node with the femtic_env.sh installed on 2026-09-25 (no femtic_apps_remap line): expect exit 3, T1 FAIL with"
echo "    3 libraries not found (as seen on p2-dmv-1), a NOTE to regenerate femtic_env.sh, and '/apps' absent in the diagnostics"
cp -a "$B" "$R/bin_old"; sed -i '/femtic_apps_remap/d' "$R/bin_old/femtic_env.sh"
sandbox gpfs_only /bin/bash -c "mkdir -p $GPFS_MKL/lib/intel64 && cd $GPFS_MKL/lib/intel64 && touch $MKLLIBS && \
  bash \"\$R/run01.sh\" \"\$R/k11.out\" SMOKE_ONLY=1 MOCK_MKLROOT=$APPS_MKL BIN=\"\$R/bin_old\""
chk rc "$?" 3
chk old_env_has_no_remap "$(grep -c femtic_apps_remap "$R/bin_old/femtic_env.sh")" 0
chk three_not_found "$(grep '^T1 FAIL: unresolved libraries' "$R/k11.out" | grep -o 'not found' | wc -l)" 3
chk note_regenerate "$(cnt '^NOTE: /apps is absent on .* predates the /apps -> /gpfs/apps remap' "$R/k11.out")" 1
chk diag_apps_absent "$(cnt "cannot access '/apps'" "$R/k11.out")" 1
echo "K12 icelake-like node (sandbox: /apps and /gpfs/apps, libraries under /apps): expect exit 0, no remap, MKLROOT on /apps"
sandbox both /bin/bash -c "mkdir -p $APPS_MKL/lib/intel64 && cd $APPS_MKL/lib/intel64 && touch $MKLLIBS && \
  bash \"\$R/run01.sh\" \"\$R/k12.out\" SMOKE_ONLY=1 MOCK_MKLROOT=$APPS_MKL SLURM_JOB_ID=80 SLURM_JOB_PARTITION=icelake"
chk rc "$?" 0
chk no_remap_warning "$(cnt 'femtic_env.sh: /apps absent' "$R/k12.out")" 0
chk mklroot_apps "$(cnt "^MKLROOT=$APPS_MKL " "$R/k12.out")" 1
chk done_line "$(cnt 'SMOKE_ONLY DONE  T1=PASS  T2=PASS  T5=PASS' "$R/k12.out")" 1
chk wsl_root_untouched "$(ls -d /apps /gpfs/apps 2>/dev/null | wc -l)" 0
echo "K13 another run used this second's stamp: stale smoke_foss_<stamp>/ dirs (restart/ holding an iteration-2 model) and"
echo "    .log files exist for the next 4 s: expect exit 0, T5 PASS, and a log + work dir with a _<pid> suffix, paired"
now=$(date +%s); for i in 0 1 2 3 4; do st=$(date -d "@$((now + i))" +%Y%m%d_%H%M%S)
  mkdir -p "$S/smoke_foss_$st/restart"; touch "$S/smoke_foss_$st/restart/resistivity_block_iter2.dat" "$S/smoke_foss_$st.log"; done
run01 "$R/k13.out" SMOKE_ONLY=1; chk rc "$?" 0
chk t5_pass "$(cnt '^T2 (smoke run): PASS    T5 (restart equivalence): PASS' "$R/k13.out")" 1
L13=$(sed -n 's/.*SMOKE_ONLY DONE .*log: //p' "$R/k13.out")
chk log_suffixed "$(basename "$L13" | grep -cE '^smoke_foss_[0-9]{8}_[0-9]{6}_[0-9]+\.log$')" 1
chk log_pairs_workdir "$([ -d "${L13%.log}/restart" ] && [ -s "$L13" ] && echo yes)" yes

echo; echo "CHECKS: $npass passed, $nfail failed"
echo "OVERALL: $([ $fail = 0 ] && echo PASS || echo FAIL)"
if [ $fail != 0 ] && [ -n "${KEEP:-}" ]; then echo "kept $R for debugging"; else rm -rf "$R"; fi
[ $fail = 0 ]
