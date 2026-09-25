#!/bin/bash
# verify_v2.sh -- static + dry-run checks on the ported build files. Run INSIDE WSL. No compilation.
S=/mnt/c/Users/joint/AppData/Local/Temp/claude/D--BEN-FEMTIC-2026/4e858f54-ea4e-47a8-9815-7766aca9830d/scratchpad
P=$S/ported
fail=0
bad() { echo "  FAIL: $*"; fail=1; }

echo "make: $(make --version | head -1)"

echo "== 1. line endings: FAILS if any ported file contains a CR byte =="
for f in $(find "$P" -type f | sort); do
  n=$(tr -cd '\r' < "$f" | wc -c)
  printf "  %-48s CR-bytes=%s\n" "${f#$P/}" "$n"
  [ "$n" = 0 ] || bad "CR in ${f#$P/}"
done

echo "== 2. recipes: FAILS if a makefile has <3 TAB recipe lines or any space-indented recipe =="
for f in $(find "$P" -name 'Makefile*' | sort); do
  t=$(grep -c $'^\t' "$f")
  s=$(grep -cE '^ +(\$\(CXX\)|rm -f)' "$f")
  printf "  %-48s TAB-recipes=%s space-recipes=%s\n" "${f#$P/}" "$t" "$s"
  { [ "$t" -ge 3 ] && [ "$s" = 0 ]; } || bad "recipe indentation in ${f#$P/}"
done

echo "== 3. OBJS blocks: FAILS on any diff vs the CR-stripped reference =="
cmpobjs() {
  if diff <(tr -d '\r' < "$1" | sed -n '/^OBJS/,/^PROGRAM/p' | sed '$d') \
          <(sed -n '/^OBJS/,/^PROGRAM/p' "$2" | sed '$d') > /dev/null; then
    echo "  OK   ${2#$P/}"
  else
    bad "OBJS differs: ${2#$P/}"
  fi
}
cmpobjs "$S/femtic/src/Makefile_IntelMPI"   "$P/femtic/Makefile.gcc_openmpi_mkl"
cmpobjs "$S/femtic/src/Makefile_IntelMPI"   "$P/femtic/Makefile.intel_oneapi"
cmpobjs "$S/makeTetraMesh/src/Makefile"     "$P/makeTetraMesh/Makefile.gcc_mkl"
cmpobjs "$S/makeTetraMesh/src/Makefile"     "$P/makeTetraMesh/Makefile.intel_oneapi"
cmpobjs "$S/makeMtr/src/Makefile"           "$P/makeMtr/Makefile.gcc"
cmpobjs "$S/TetGen2Femtic/src/Makefile"     "$P/TetGen2Femtic/Makefile.gcc"
cmpobjs "$S/makeDHexaMesh/src/Makefile"     "$P/makeDHexaMesh/Makefile.gcc"
grep -q '^OBJS *= *mergeResult.o$' "$P/mergeResultOfFEMTIC/Makefile.gcc" && echo "  OK   mergeResultOfFEMTIC/Makefile.gcc (OBJS = mergeResult.o)" || bad "mergeResult OBJS"
echo "  every OBJS entry has a .cpp (FAILS otherwise):"
for mk in "$P"/*/Makefile*; do
  d=$S/$(basename "$(dirname "$mk")")/src
  for o in $(sed -n '/^OBJS/,/^PROGRAM/p' "$mk" | grep -o '[A-Za-z0-9_]*\.o'); do
    [ -f "$d/${o%.o}.cpp" ] || bad "no source for $o in $d"
  done
done

echo "== 4. make -n dry runs: FAILS if make errors, compile count != expected, or link line lacks the expected token =="
dry() {  # dir makefile expected_compiles expected_link_token [make args...]
  local d=$1 mk=$2 exp=$3 tok=$4; shift 4
  local out rc n link
  out=$(cd "$d" && make -n -f "$mk" "$@" 2>&1); rc=$?
  n=$(printf '%s\n' "$out" | grep -c ' -c ')
  link=$(printf '%s\n' "$out" | grep -- ' -o ' | grep -v ' -c ' | tail -1)
  printf "  %-38s %-22s rc=%s compiles=%s/%s\n" "$(basename "$mk")" "[$*]" "$rc" "$n" "$exp"
  printf "    first: %s\n" "$(printf '%s\n' "$out" | head -1 | cut -c1-200)"
  printf "    link : %s\n" "$(printf '%s\n' "$link" | sed 's/  */ /g' | cut -c1-200)"
  printf "    tail : ...%s\n" "$(printf '%s\n' "$link" | sed 's/  */ /g' | tail -c 230)"
  [ "$rc" = 0 ] || bad "make -n rc=$rc for $mk: $(printf '%s\n' "$out" | head -2)"
  [ "$n" = "$exp" ] || bad "compile count $n != $exp for $mk"
  [ -z "$tok" ] || printf '%s\n' "$link" | grep -q -- "$tok" || bad "link line lacks '$tok' for $mk"
}
dry "$S/femtic/src"        "$P/femtic/Makefile.gcc_openmpi_mkl"       59 '-lmkl_intel_ilp64 -lmkl_gnu_thread'   MKLROOT=/opt/dummy/mkl
dry "$S/femtic/src"        "$P/femtic/Makefile.intel_oneapi"          59 '-lmkl_intel_ilp64 -lmkl_intel_thread' MKLROOT=/opt/dummy/mkl
dry "$S/makeTetraMesh/src" "$P/makeTetraMesh/Makefile.gcc_mkl"        23 '-fopenmp'
dry "$S/makeTetraMesh/src" "$P/makeTetraMesh/Makefile.gcc_mkl"        23 '-lmkl_intel_lp64 -lmkl_gnu_thread'    WITH_MKL=1 MKLROOT=/opt/dummy/mkl
dry "$S/makeTetraMesh/src" "$P/makeTetraMesh/Makefile.intel_oneapi"   23 '-qmkl=parallel'
dry "$S/makeMtr/src"       "$P/makeMtr/Makefile.gcc"                   3 'g++'
dry "$S/TetGen2Femtic/src" "$P/TetGen2Femtic/Makefile.gcc"             3 'g++'
dry "$S/makeDHexaMesh/src" "$P/makeDHexaMesh/Makefile.gcc"            10 'g++'
dry "$S/mergeResultOfFEMTIC/src" "$P/mergeResultOfFEMTIC/Makefile.gcc" 1 'g++'
echo "  compiled-out check: FAILS if the dry run mentions a source that is NOT in OBJS"
out=$(cd "$S/femtic/src" && make -n -f "$P/femtic/Makefile.gcc_openmpi_mkl" MKLROOT=/x 2>&1)
for x in Forward2DSquareElementNodeBased Forward2DTriangleElementNodeBased InversionGaussNewtonDataSpace.cpp; do
  printf '%s\n' "$out" | grep -q "$x" && bad "dry run compiles excluded source $x"
done
echo "  (ok if no FAIL above)"

echo "== 5. MKLROOT guard: FAILS if unset MKLROOT does not stop make, or blocks 'make clean' =="
for mk in "$P/femtic/Makefile.gcc_openmpi_mkl" "$P/femtic/Makefile.intel_oneapi"; do
  out=$(cd "$S/femtic/src" && env -u MKLROOT make -n -f "$mk" 2>&1); rc=$?
  printf "  %-32s no MKLROOT: rc=%s msg=%s\n" "$(basename "$mk")" "$rc" "$(printf '%s\n' "$out" | head -1 | cut -c1-110)"
  { [ "$rc" != 0 ] && printf '%s\n' "$out" | grep -q 'MKLROOT is not set'; } || bad "MKLROOT guard missing in $mk"
  out=$(cd "$S/femtic/src" && env -u MKLROOT make -n -f "$mk" clean 2>&1); rc=$?
  printf "  %-32s clean w/o MKLROOT: rc=%s -> %s\n" "$(basename "$mk")" "$rc" "$(printf '%s\n' "$out" | head -1)"
  [ "$rc" = 0 ] || bad "make clean blocked by MKLROOT guard in $mk"
done
out=$(cd "$S/makeTetraMesh/src" && env -u MKLROOT make -n -f "$P/makeTetraMesh/Makefile.gcc_mkl" WITH_MKL=1 2>&1); rc=$?
printf "  %-32s WITH_MKL=1 no MKLROOT: rc=%s msg=%s\n" "Makefile.gcc_mkl" "$rc" "$(printf '%s\n' "$out" | head -1 | cut -c1-110)"
[ "$rc" != 0 ] || bad "WITH_MKL=1 without MKLROOT did not stop"

echo "== 6. tetgen upstream makefile (informational): does CRLF leak into the recipe? =="
cd "$S/tetgen"
printf "  as-is (CRLF) : "; make -n tetgen 2>&1 | tail -1 | cat -A | cut -c1-120
sed 's/\r$//' makefile > /tmp/tetgen_lf.mk
printf "  CR-stripped  : "; make -n -f /tmp/tetgen_lf.mk tetgen 2>&1 | tail -1 | cat -A | cut -c1-120
printf "  predicates   : "; make -n -f /tmp/tetgen_lf.mk tetgen 2>&1 | grep predicates | head -1

echo "== RESULT =="
if [ "$fail" = 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; fi
exit $fail
