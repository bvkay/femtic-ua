#!/bin/bash
# smokefix_run_all.sh -- verification of the 2026-09-25 smoke-test hardening of hpc/phoenix_plan (01_build_femtic.sh
# SMOKE_ONLY / git-free HEAD / MKL + make guards; femtic_lib.sh femtic_apps_remap). Run in WSL:
#     bash smokefix_run_all.sh [lint|old|new|bash44|mut|all]      (default all)
# Writes test_outputs/smokefix_*.out next to this directory. Each part states its failure criterion:
#   lint   FAILS if a kit script or new harness has a CR, fails 'bash -n' after CR strip, or shellcheck 0.11 reports any
#          warning-level finding for the kit (info-level findings of 01 and femtic_lib.sh are listed for comparison
#          with the pre-change baseline: one SC2012 note in each).
#   old    FAILS if libtest_v2 / chaintest_v2 / unit2_v2 / fetchtest_v2 do not end with OVERALL: PASS (48/89/12/14).
#   new    FAILS if smokeonly_test / gitfree_head_test / build_guards_test / apps_remap_test do not end with OVERALL: PASS.
#   bash44 the same four with BASH_UNDER_TEST = bash 4.4.12 (Debian 9; Phoenix runs RHEL 8.4, which ships bash 4.4), copied
#          from the LOCAL docker image debian:9 (never pulled); FAILS like 'new'.
#   mut    runs harnesses against deliberately broken copies of the kit (and the pre-change kit); FAILS if any
#          broken copy still gives OVERALL: PASS (i.e. the check that should catch it cannot fail).
KIT=${KIT:-/mnt/d/BEN/FEMTIC_2026/hpc/phoenix_plan}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); OUT=${OUT:-$HERE/../test_outputs}
ORIG=${ORIG:-/mnt/c/Users/joint/AppData/Local/Temp/claude/D--BEN-FEMTIC-2026/4e858f54-ea4e-47a8-9815-7766aca9830d/scratchpad/smokefix_orig}
SHELLCHECK=${SHELLCHECK:-/home/tara/miniforge3/pkgs/shellcheck-0.11.0-ha770c72_1/bin/shellcheck}
NEW=(smokeonly_test gitfree_head_test build_guards_test apps_remap_test)
what=${1:-all}; rcall=0
summ(){ tail -2 "$1" | tr '\n' ' '; echo; }

if [ "$what" = lint ] || [ "$what" = all ]; then
  o=$OUT/smokefix_lint.out; T=$(mktemp -d); bad=0
  {
    echo "== bash -n after CR strip, and CR count (failure: any CR or any syntax error)"
    for f in "$KIT"/*.sh "$KIT"/*.slurm "${NEW[@]/#/$HERE/}"; do
      case "$f" in *_test) f=$f.sh ;; esac
      cr=$(tr -cd '\r' < "$f" | wc -c); tr -d '\r' < "$f" > "$T/x.sh"
      if bash -n "$T/x.sh" 2> "$T/err"; then syn=ok; else syn="ERROR $(cat "$T/err")"; bad=1; fi
      [ "$cr" = 0 ] || bad=1
      printf '%-28s CR=%s  bash -n: %s\n' "${f##*/}" "$cr" "$syn"
    done
    f=$HERE/smokefix_run_all.sh; tr -d '\r' < "$f" > "$T/x.sh"; printf '%-28s CR=%s  bash -n: %s\n' "${f##*/}" "$(tr -cd '\r' < "$f" | wc -c)" "$(bash -n "$T/x.sh" 2>&1 && echo ok)"
    echo; "$SHELLCHECK" --version | sed -n 2p
    echo "== shellcheck -S warning -s bash -e SC1090,SC1091 on the kit (failure: any finding)"
    ( cd "$KIT" && "$SHELLCHECK" -S warning -s bash -e SC1090,SC1091 ./*.sh ./*.slurm ); r=$?; echo "warning-level exit: $r"; [ $r = 0 ] || bad=1
    echo "== shellcheck -S warning on the new harnesses (information only)"
    ( cd "$HERE" && "$SHELLCHECK" -S warning -s bash -e SC1090,SC1091 "${NEW[@]/%/.sh}" smokefix_run_all.sh ); echo "exit: $?"
    echo "== shellcheck info level, 01_build_femtic.sh and femtic_lib.sh (baseline before the change: SC2012 once in each file)"
    ( cd "$KIT" && "$SHELLCHECK" -S info -s bash -e SC1090,SC1091 -f gcc 01_build_femtic.sh femtic_lib.sh ); echo "exit: $?"
    echo; echo "OVERALL: $([ $bad = 0 ] && echo PASS || echo FAIL)"
  } > "$o" 2>&1
  echo "lint: $(summ "$o")"; grep -q 'OVERALL: PASS' "$o" || rcall=1; rm -rf "$T"
fi

if [ "$what" = old ] || [ "$what" = all ]; then
  for h in libtest_v2 chaintest_v2 unit2_v2 fetchtest_v2; do
    o=$OUT/smokefix_$h.out; PLAN=$KIT bash "$HERE/$h.sh" > "$o" 2>&1
    echo "$h: $(grep -E '^(CHECKS|OVERALL)' "$o" | tr '\n' ' ')"; grep -q '^OVERALL: PASS' "$o" || rcall=1
  done
fi

if [ "$what" = new ] || [ "$what" = all ]; then
  for h in "${NEW[@]}"; do
    o=$OUT/smokefix_$h.out; PLAN=$KIT bash "$HERE/$h.sh" > "$o" 2>&1
    echo "$h: $(summ "$o")"; grep -q '^OVERALL: PASS' "$o" || rcall=1
  done
fi

if [ "$what" = bash44 ] || [ "$what" = all ]; then
  B44=$(mktemp -d)
  if docker image inspect debian:9 >/dev/null 2>&1; then
    id=$(docker create debian:9 /bin/true) && docker cp -L "$id:/bin/bash" "$B44/bash" && \
      docker cp -L "$id:/lib/x86_64-linux-gnu/libtinfo.so.5" "$B44/libtinfo.so.5"; docker rm "$id" >/dev/null
    printf '#!/bin/bash\nexport LD_LIBRARY_PATH="%s${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\nexec "%s" "$@"\n' "$B44" "$B44/bash" > "$B44/bash44"
    chmod +x "$B44/bash44"; echo "bash44: $("$B44/bash44" --version | head -1)"
    for h in "${NEW[@]}"; do
      o=$OUT/smokefix_${h}_bash44.out
      { echo "BASH_UNDER_TEST=$B44/bash44 ($("$B44/bash44" --version | head -1))"; PLAN=$KIT BASH_UNDER_TEST=$B44/bash44 bash "$HERE/$h.sh"; } > "$o" 2>&1
      echo "$h (bash 4.4): $(summ "$o")"; grep -q '^OVERALL: PASS' "$o" || rcall=1
    done
  else
    echo "bash44: NOT RUN (docker image debian:9 not present locally; this script never pulls images)"; rcall=1
  fi
  rm -rf "$B44"
fi

if [ "$what" = mut ] || [ "$what" = all ]; then
  o=$OUT/smokefix_mutations.out; M=$(mktemp -d); caught=0; missed=0
  mutant(){  # mutant <id> <harness> <description> <file> <sed script> -> kit copy with one edit; the harness must FAIL
    local id=$1 h=$2 desc=$3 f=$4 sc=$5 d=$M/$1
    mkdir -p "$d"; cp "$KIT"/*.sh "$KIT"/*.slurm "$d"/
    sed -i "$sc" "$d/$f"
    if cmp -s "$KIT/$f" "$d/$f"; then echo "$id MUTATION NOT APPLIED ($desc)"; missed=$((missed+1)); return; fi
    PLAN=$d bash "$HERE/$h.sh" > "$M/$id.out" 2>&1
    if grep -q '^OVERALL: PASS' "$M/$id.out"; then echo "$id NOT CAUGHT by $h: $desc"; missed=$((missed+1))
    else echo "$id caught by $h ($(grep -c '  FAIL ' "$M/$id.out") failed checks: $(grep '  FAIL ' "$M/$id.out" | awk '{print $2}' | sort -u | tr -d : | tr '\n' ' ')): $desc"; caught=$((caught+1)); fi
  }
  {
    echo "Each line: a deliberately broken copy of the kit and the harness that must reject it (failure criterion: any"
    echo "'NOT CAUGHT' or 'NOT APPLIED')."
    mutant M1 smokeonly_test "T1 no longer fails on 'not found' (requirement D)" 01_build_femtic.sh "/^if echo \"\$LDD\" | grep -q 'not found'; then\$/,/^fi\$/d"
    mutant M2 smokeonly_test "femtic_env.sh no longer calls femtic_apps_remap" 01_build_femtic.sh '/^  echo "femtic_apps_remap /d'
    mutant M3 apps_remap_test "remap replaces every /apps/ substring (turns /gpfs/apps into /gpfs/gpfs/apps)" femtic_lib.sh 's|_ar_from="$_ar_sep/apps/"; _ar_to="$_ar_sep/gpfs/apps/"|_ar_from="/apps/"; _ar_to="/gpfs/apps/"|'
    mutant M4 build_guards_test "no make check after module load" 01_build_femtic.sh '/^command -v make >\/dev\/null || die "make not found/d'
    mutant M5 gitfree_head_test "git_head_nogit ignores .git/packed-refs" 01_build_femtic.sh 's/\[ -f "\$g\/packed-refs" \] && \[ -r "\$g\/packed-refs" \] || return 1/return 1/'
    mutant M6 build_guards_test "MKL guard back to exact unversioned names" 01_build_femtic.sh 's|for f in "$1"/lib/intel64/libmkl_core.so\* "$1"/lib/libmkl_core.so\*; do|for f in "$1"/lib/intel64/libmkl_core.so "$1"/lib/libmkl_core.so; do|'
    mutant M7 gitfree_head_test "unguarded COMMIT_SHA.txt read, as before the change" 01_build_femtic.sh 's|^    HEAD=$(sha_file "$d/COMMIT_SHA.txt"); DATE="git-free tree"$|    HEAD=$(tr -d " \\r\\n" < "$d/COMMIT_SHA.txt" 2>/dev/null); DATE="git-free tree"|'
    mutant M8 smokeonly_test "no unique stamp when another run used this second" 01_build_femtic.sh '/^compgen -G "\$SRC\/\*_\$STAMP\*" >\/dev\/null && STAMP=/d'
    mutant M9 build_guards_test "no /apps <-> /gpfs/apps fallback in the MKL guard" 01_build_femtic.sh 's|^    /apps/\*)      ALT_MKLROOT="/gpfs$MKLROOT" ;;$|    /apps/*)      ALT_MKLROOT="" ;;|'
    if [ -f "$ORIG/01_build_femtic.sh" ] && [ -f "$ORIG/femtic_lib.sh" ]; then
      for h in "${NEW[@]}"; do
        PLAN=$ORIG bash "$HERE/$h.sh" > "$M/orig_$h.out" 2>&1
        if grep -q '^OVERALL: PASS' "$M/orig_$h.out"; then echo "ORIG NOT CAUGHT by $h: the pre-change kit passes"; missed=$((missed+1))
        else echo "ORIG caught by $h ($(grep -c '  FAIL ' "$M/orig_$h.out") failed checks): the pre-change kit ($ORIG)"; caught=$((caught+1)); fi
      done
    else echo "ORIG: pre-change kit not found at $ORIG (not run)"; fi
    echo; echo "MUTANTS: $caught caught, $missed not caught"
    echo "OVERALL: $([ $missed = 0 ] && echo PASS || echo FAIL)"
  } > "$o" 2>&1
  echo "mutations: $(summ "$o")"; grep -q '^OVERALL: PASS' "$o" || rcall=1; rm -rf "$M"
fi
exit $rcall
