#!/bin/bash
# =============================================================================
# portability_test.sh -- checks the Phoenix kit against Phoenix's own interpreters. The login and compute nodes run
# RHEL 8.4 (discovery txt:12): GNU bash 4.4.19, gawk 4.2.1, and the system python3 3.6.8 (discovery txt:805).
# Nothing on the PC has those versions, so most checks are static:
#   B  bash: no feature newer than bash 4.4 (or gawk 4.2) in the kit's *.sh (femtic_lib.sh, 0*.sh, run.sh, status.sh),
#      0*.slurm and tests/*.sh.
#      bash 4.4 already has ${var@Q} (and @E @P @A @a), mapfile/readarray -d, 'local -', wait -n, namerefs, so
#      those are only listed. Newer: ${var@U/@u/@L/@K} (5.1), @k (5.2), EPOCHSECONDS, EPOCHREALTIME, BASH_ARGV0
#      (5.0), SRANDOM (5.1), wait -p (5.1) / -f (5.0), the bash 5 shopt options, and '&' in a ${var/pat/rep}
#      replacement (the matched text in 5.2, a literal '&' in 4.4). gawk: @namespace (5.0), mkbool() (5.2).
#   P  python (tools/*.py): ast.parse(feature_version=(3, 6)) catches walrus, positional-only parameters, match.
#      It does NOT catch the f-string '=' specifier (3.8), PEP 701 f-strings (3.12) or 'from __future__ import
#      annotations' (3.7) (probed on Python 3.13.5), so an AST walk adds those, plus library calls newer than 3.6
#      (math.prod, str.removeprefix, subprocess capture_output/text, dataclasses, builtin generics such as
#      list[int], dict | dict on literals, ...) and every text-mode open() without encoding= (Python 3.6 reads
#      and prints with the locale's encoding, ASCII under LANG=C; 3.7 switched to UTF-8, PEP 538/540).
#   R  run: tools/halfspace_eval.py on a small synthetic half-space whose station_map.csv has a non-ASCII site
#      name, with stdout forced to ASCII (PYTHONIOENCODING=ascii, as Python 3.6 under LANG=C) and, if one exists,
#      under every python3.6 / PYTHON_OLD on PATH (none on Ben's PC; oldest local conda env: 3.9.23).
#   bash portability_test.sh [PLAN_DIR]     env: WORK, PYTHON (>= 3.8, runs the checker), PYTHON_OLD
# Every check prints "fails if ..." first. Exit 0 only if all pass. This file is not scanned by B (it holds the
# patterns as data).
# =============================================================================
PLAN=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
PLAN=$(cd "$PLAN" && pwd) || exit 2
WORK=${WORK:-$(mktemp -d)}; mkdir -p "$WORK"; WORK=$(cd "$WORK" && pwd)
if [ -z "${PYTHON:-}" ]; then
  for p in python3 python; do
    if "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then PYTHON=$p; break; fi
  done
fi
echo "portability_test: PLAN=$PLAN  WORK=$WORK  checker ${PYTHON:-none} ($("${PYTHON:-false}" --version 2>&1))  bash $BASH_VERSION"
npass=0; nfail=0
crit() { echo; echo "CHECK $1: fails if $2"; }
ok()   { echo "  PASS $*"; npass=$((npass + 1)); }
bad()  { echo "  FAIL $*"; nfail=$((nfail + 1)); }
eq()   { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got '$2', want '$3'"; fi; }

# ---------------------------------------------------------------- B: bash > 4.4, gawk > 4.2
SELF=$(basename "${BASH_SOURCE[0]}")
FILES=(); for f in "$PLAN"/*.sh "$PLAN"/0*.slurm "$PLAN"/tests/*.sh; do
  [ -f "$f" ] && [ "$(basename "$f")" != "$SELF" ] && FILES+=("$f"); done
NEWER=(
  '\$\{[#!]?[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?@[UuLKk]\}=${var@U/@u/@L/@K} (bash 5.1), @k (5.2)'
  '\$\{?(EPOCHSECONDS|EPOCHREALTIME|BASH_ARGV0)([^A-Za-z0-9_]|$)=EPOCHSECONDS, EPOCHREALTIME, BASH_ARGV0 (bash 5.0)'
  '\$\{?SRANDOM([^A-Za-z0-9_]|$)=SRANDOM (bash 5.1)'
  '(^|[;&|({[:space:]])wait[[:space:]]+-[a-zA-Z]*[pf]=wait -p (bash 5.1) or wait -f (bash 5.0)'
  'shopt[[:space:]]+-[su].*(localvar_inherit|localvar_unset|assoc_expand_once|patsub_replacement|globskipdots|noexpand_translation|varredir_close|array_expand_once)=a bash 5 shopt option'
  '\$\{[^}]*/[^}]*&[^}]*\}=& in a ${var/pat/rep} replacement (bash 5.2 inserts the match; 4.4 a literal &)'
  '@namespace|mkbool\(=gawk 5 feature (Phoenix: gawk 4.2.1)'
)
INFO=(
  '\$\{[#!]?[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?@[QEPAa]\}=${var@Q/@E/@P/@A/@a} (bash 4.4: fine)'
  '(mapfile|readarray)[^#]*[[:space:]]-d=mapfile/readarray -d (bash 4.4: fine)'
)
code() { awk '!/^[[:space:]]*#/' "$1"; }   # full-line comments (and #SBATCH lines) are documentation
crit B1 "any of ${#FILES[@]} kit shell files uses a bash feature newer than 4.4 or a gawk feature newer than 4.2 (patterns above)"
nb=0
for f in "${FILES[@]}"; do
  bash -n "$f" 2>/dev/null || { bad "B1 bash -n $f"; }
  for e in "${NEWER[@]}"; do
    re=${e%%=*}; what=${e#*=}
    hits=$(code "$f" | grep -nE -- "$re")
    if [ -n "$hits" ]; then nb=$((nb + 1)); echo "  found $what in ${f#$PLAN/}:"; echo "$hits" | sed 's/^/      /' | head -3; fi
  done
done
eq "B1 newer-than-4.4 constructs" "$nb" 0
for e in "${INFO[@]}"; do
  n=$(for f in "${FILES[@]}"; do code "$f" | grep -cE -- "${e%%=*}"; done | awk '{s += $1} END {print s + 0}')
  echo "  info: ${e#*=}: $n line(s)"
done

# ---------------------------------------------------------------- P: python > 3.6
cat > "$WORK/py36check.py" <<'PYEOF'
import ast, re, sys
NEW_ATTR = {"prod": "3.8", "isqrt": "3.8", "dist": "3.8", "comb": "3.8", "perm": "3.8", "removeprefix": "3.9",
            "removesuffix": "3.9", "isascii": "3.7", "reconfigure": "3.7", "fromisoformat": "3.7", "time_ns": "3.7",
            "perf_counter_ns": "3.7", "monotonic_ns": "3.7", "fmean": "3.8", "geometric_mean": "3.8",
            "multimode": "3.8", "quantiles": "3.8", "correlation": "3.10", "covariance": "3.10",
            "cached_property": "3.8", "pairwise": "3.10", "BooleanOptionalAction": "3.9", "bit_count": "3.10",
            "is_relative_to": "3.9", "with_stem": "3.9", "nullcontext": "3.7"}
NEW_MOD = {"dataclasses": "3.7", "contextvars": "3.7", "zoneinfo": "3.9", "graphlib": "3.9", "tomllib": "3.11",
           "importlib.resources": "3.7", "importlib.metadata": "3.8"}
NEW_KW = {"capture_output": "3.7 (subprocess)", "text": "3.7 (subprocess)", "missing_ok": "3.8", "root_dir": "3.10"}
GENERIC = {"list", "dict", "set", "tuple", "type", "frozenset"}
out = []
for path in sys.argv[1:]:
    src = open(path, encoding="utf-8").read()
    def hit(node, what):
        out.append("%s:%d: %s" % (path, getattr(node, "lineno", 0), what))
    try:
        tree = ast.parse(src, feature_version=(3, 6))
    except SyntaxError as e:
        out.append("%s:%s: ast feature_version=(3, 6): %s" % (path, e.lineno, e.msg))
        continue
    for n in ast.walk(tree):
        if isinstance(n, ast.JoinedStr):
            seg = ast.get_source_segment(src, n) or ""
            m = re.match(r"(?i)[rbu]*f[rb]*('''|\"\"\"|'|\")", seg)
            q = m.group(1) if m else '"'
            body = seg[m.end():len(seg) - len(q)] if m else seg
            exprs = re.findall(r"\{([^{}]*)\}", body.replace("{{", "").replace("}}", ""))
            if any(re.search(r"(^|[^=!<>])=\s*(![rsa])?(:[^{}]*)?$", x) for x in exprs):
                hit(n, "f-string '=' specifier (3.8)")
            if len(q) == 1 and any(q in x or "\\" in x for x in exprs):
                hit(n, "f-string expression with its own quote or a backslash (3.12, PEP 701)")
        elif isinstance(n, ast.ImportFrom) and n.module == "__future__" and any(a.name == "annotations" for a in n.names):
            hit(n, "from __future__ import annotations (3.7)")
        elif isinstance(n, (ast.Import, ast.ImportFrom)):
            for name in ([a.name for a in n.names] if isinstance(n, ast.Import) else [n.module or ""]):
                for mod, v in NEW_MOD.items():
                    if name == mod or name.startswith(mod + "."):
                        hit(n, "module %s (%s)" % (mod, v))
        elif isinstance(n, ast.Attribute) and n.attr in NEW_ATTR:
            hit(n, ".%s (%s)" % (n.attr, NEW_ATTR[n.attr]))
        elif isinstance(n, ast.Call):
            if isinstance(n.func, ast.Name) and n.func.id == "breakpoint":
                hit(n, "breakpoint() (3.7)")
            for k in n.keywords:
                if k.arg in NEW_KW and not (k.arg == "text" and not isinstance(n.func, ast.Attribute)):
                    hit(n, "keyword %s= (%s)" % (k.arg, NEW_KW[k.arg]))
            if isinstance(n.func, ast.Name) and n.func.id == "open":
                mode = n.args[1] if len(n.args) > 1 else next((k.value for k in n.keywords if k.arg == "mode"), None)
                binary = isinstance(mode, ast.Constant) and "b" in str(mode.value)
                if not binary and not any(k.arg == "encoding" for k in n.keywords):
                    hit(n, "open() without encoding= (locale-dependent: ASCII under LANG=C on Python 3.6)")
        elif isinstance(n, (ast.BinOp, ast.AugAssign)) and isinstance(n.op, ast.BitOr):
            sides = [n.left, n.right] if isinstance(n, ast.BinOp) else [n.target, n.value]
            if any(isinstance(s, (ast.Dict, ast.DictComp)) or (isinstance(s, ast.Call) and isinstance(s.func, ast.Name)
                   and s.func.id == "dict") for s in sides):
                hit(n, "dict | dict (3.9)")
    anns = [n.annotation for n in ast.walk(tree) if isinstance(n, ast.arg) and n.annotation is not None]
    anns += [n.returns for n in ast.walk(tree) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.returns]
    anns += [n.annotation for n in ast.walk(tree) if isinstance(n, ast.AnnAssign)]
    for a in anns:
        for s in ast.walk(a):
            if isinstance(s, ast.Subscript) and isinstance(s.value, ast.Name) and s.value.id in GENERIC:
                hit(s, "builtin generic %s[...] in an annotation (3.9)" % s.value.id)
print("\n".join(out))
print("FINDINGS %d" % len(out))
PYEOF
PYFILES=("$PLAN"/tools/*.py)
crit P1 "a python file of the kit (${#PYFILES[@]}: ${PYFILES[*]##*/}) fails ast.parse(feature_version=(3, 6)), or uses an f-string '=' / PEP 701 f-string, a __future__ annotations import, a library call or builtin generic newer than 3.6, a literal dict union, or a text-mode open() without encoding="
if [ -z "${PYTHON:-}" ]; then bad "P1 no python >= 3.8 to run the checker"
else
  "$PYTHON" "$WORK/py36check.py" "${PYFILES[@]}" > "$WORK/P1.txt" 2>&1
  sed 's/^/    /' "$WORK/P1.txt"
  eq "P1 findings" "$(awk '$1 == "FINDINGS" {print $2}' "$WORK/P1.txt")" 0
fi

# ---------------------------------------------------------------- R: run the evaluator as Python 3.6 would
# 2 sites x 2 bands of a 100 ohm-m half-space (exp(-i omega t): Zxy = a(1 - i), Zyx = -Zxy; site 2 has Re(Zxy) 1 % high,
# so it is the worst site, +1.005 % rho_a and 0.285 deg, and its name is printed), observe.dat with
# the same pairs, and a station_map.csv (UTF-8) naming site 2 "Vulca<n-tilde>-2" (UTF-8 bytes 303 261).
R=$WORK/R1; mkdir -p "$R"
awk 'BEGIN { pi = atan2(0, -1); print "MT,"
  print "     StaID,        Freq[Hz],     Re(Zxx)_Cal,     Im(Zxx)_Cal,     Re(Zxy)_Cal,     Im(Zxy)_Cal,     Re(Zyx)_Cal,     Im(Zyx)_Cal,     Re(Zyy)_Cal,     Im(Zyy)_Cal,"
  split("10 0.1", F, " ")
  for (s = 1; s <= 2; s++) for (k = 1; k <= 2; k++) { f = F[k]; a = sqrt(2 * pi * f * 4e-7 * pi * 100) / sqrt(2)
    printf "%10d, %15.6e, %15.6e, %15.6e, %15.6e, %15.6e, %15.6e, %15.6e, %15.6e, %15.6e,\n", s, f, 0, 0, a * (s == 2 ? 1.01 : 1), -a, -a, a, 0, 0 } }' > "$R/result_0_iter0.csv"
printf 'MT 2\n1 1001 0 0 0\n2\n10 0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1\n0.1 0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1\n2 1002 0 1 1\n2\n10 0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1\n0.1 0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1\nEND\n' > "$R/observe.dat"
printf 'femtic_station_id,h_station_id,site_id,edi_file\n1,1001,A1,A1.edi\n2,1002,Vulca\303\261-2,V2.edi\n' > "$R/station_map.csv"
crit R1 "tools/halfspace_eval.py does not print 'RESULT: PASS' with exit 0 and the worst rho_a at '2 (Vulca?-2)' on a half-space within the limits when stdout is ASCII (PYTHONIOENCODING=ascii, i.e. Python 3.6 under LANG=C) and a site name is non-ASCII, or prints a Traceback"
PYS=("${PYTHON:-python3}")
for p in python3.6 ${PYTHON_OLD:-}; do command -v "$p" > /dev/null 2>&1 && PYS+=("$p"); done
for p in "${PYS[@]}"; do
  PYTHONIOENCODING=ascii "$p" "$PLAN/tools/halfspace_eval.py" 100 "$R" --station-map "$R/station_map.csv" > "$WORK/R1.out" 2>&1; rc=$?
  v=$("$p" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>&1)
  eq "R1 python $v exit" "$rc" 0
  eq "R1 python $v RESULT" "$(awk '$1 == "RESULT:" {print $2}' "$WORK/R1.out")" PASS
  eq "R1 python $v Traceback lines" "$(grep -c Traceback "$WORK/R1.out")" 0
  eq "R1 python $v worst rho_a names site 2" "$(grep -c '^LIMIT rho_a .* at site 2 (Vulca?-2), ' "$WORK/R1.out")" 1
done
grep -h "^LIMIT\|^COMPLETENESS" "$WORK/R1.out" | sed 's/^/    /'
command -v python3.6 > /dev/null 2>&1 || echo "  note: no python3.6 here; run 'bash tests/portability_test.sh' on p2-log-2 (python3 = 3.6.8) for the real interpreter"

echo; echo "SUMMARY: $npass passed, $nfail failed   (PLAN=$PLAN)"
[ "$nfail" = 0 ]
