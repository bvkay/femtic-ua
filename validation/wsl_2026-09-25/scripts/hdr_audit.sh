#!/bin/bash
# Heuristic: for each translation unit (cpp + the headers it directly includes), report symbols used
# whose canonical header is not included anywhere in that unit. Transitive includes through the
# project's own headers are followed one level (direct includes only), so some hits may be false
# positives; hits are worth a look because Intel headers pull in more std headers than libstdc++ 13.
dir="$1"
cd "$dir" || exit 1
check() { # file symbol-regex header-regex label
  local f="$1" sym="$2" hdr="$3" label="$4"
  local unit="$f"
  # add directly included local headers
  for h in $(grep -h -o -E '#include *"[^"]+"' "$f" | sed -E 's/#include *"([^"]+)"/\1/'); do [ -f "$h" ] && unit="$unit $h"; done
  if grep -q -E "$sym" $unit 2>/dev/null; then
    grep -q -E "$hdr" $unit 2>/dev/null || echo "  $f: uses $label but does not include matching header"
  fi
}
for f in *.cpp; do
  check "$f" '\b(memcpy|memset|strcpy|strlen|strcmp|strncmp|strcat|strchr|strstr)\s*\(' '#include *<(cstring|string\.h)>' 'memcpy/str*'
  check "$f" '\b(exit|atoi|atof|atol|strtod|strtol|malloc|free|abs|rand|srand|getenv|setenv|qsort)\s*\(' '#include *<(cstdlib|stdlib\.h)>' 'exit/atoi/malloc'
  check "$f" '\bstd::(sort|min|max|find|swap|reverse|fill|copy|unique|lower_bound|upper_bound|max_element|min_element|count|remove|stable_sort|binary_search|set_intersection|set_union)\s*\(' '#include *<algorithm>' 'std::sort/min/max/find'
  check "$f" '\b(INT_MAX|INT_MIN|LONG_MAX|LLONG_MAX|CHAR_BIT)\b' '#include *<(climits|limits\.h)>' 'INT_MAX'
  check "$f" '\b(DBL_MAX|DBL_MIN|DBL_EPSILON|FLT_MAX)\b' '#include *<(cfloat|float\.h)>' 'DBL_MAX'
  check "$f" '\b(sprintf|printf|fprintf|fopen|fclose|fscanf|sscanf|fgets|puts|snprintf|FILE)\b' '#include *<(cstdio|stdio\.h)>' 'stdio'
  check "$f" '\bstd::numeric_limits\b' '#include *<limits>' 'numeric_limits'
  check "$f" '\bassert\s*\(' '#include *<(cassert|assert\.h)>' 'assert'
  check "$f" '\bstd::(o|i)?stringstream\b' '#include *<sstream>' 'stringstream'
  check "$f" '\bstd::(setw|setprecision|setfill|fixed|scientific)\b' '#include *<(iomanip|ios)>' 'iomanip'
  check "$f" '\b(sqrt|fabs|pow|exp|log|log10|sin|cos|tan|atan2|floor|ceil|fmod|hypot|cbrt|isnan|isinf)\s*\(' '#include *<(cmath|math\.h)>' 'cmath'
  check "$f" '\bstd::(ifstream|ofstream|fstream)\b' '#include *<fstream>' 'fstream'
  check "$f" '\bstd::vector\b' '#include *<vector>' 'vector'
  check "$f" '\bstd::map\b' '#include *<map>' 'map'
  check "$f" '\bstd::set\b' '#include *<set>' 'set'
  check "$f" '\bstd::string\b' '#include *<string>' 'string'
  check "$f" '\bstd::complex\b' '#include *<complex>' 'complex'
  check "$f" '\bstd::pair\b|\bstd::make_pair\b' '#include *<(utility|map|set|vector|algorithm)>' 'pair'
  check "$f" '\bstd::(cout|cerr|endl)\b' '#include *<iostream>' 'iostream'
  check "$f" '\b(time|clock|difftime)\s*\(|\btime_t\b|\bclock_t\b' '#include *<(ctime|time\.h)>' 'ctime'
  check "$f" '\bsize_t\b' '#include *<(cstddef|stddef\.h|cstdlib|cstring|cstdio|vector|string|iostream)>' 'size_t'
done
