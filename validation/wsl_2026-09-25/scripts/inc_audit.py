import os, re, sys
# Recursive include-closure audit: for each .cpp, collect all system headers reachable through the
# project's own headers (any depth), then report symbol families used whose canonical header is absent
# from that closure. Still heuristic (libstdc++ transitive includes not modelled), but far less noisy
# than a one-level check.
root = sys.argv[1]
files = {f: open(os.path.join(root, f), encoding='latin-1').read() for f in os.listdir(root) if f.endswith(('.cpp', '.h', '.cxx'))}
loc_re = re.compile(r'#include\s*"([^"]+)"')
sys_re = re.compile(r'#include\s*<([^>]+)>')
def closure(f, seen=None):
    seen = seen if seen is not None else set()
    if f in seen or f not in files: return seen
    seen.add(f)
    for h in loc_re.findall(files[f]):
        closure(h, seen)
    return seen
checks = [
 (r'\b(memcpy|memset|strcpy|strlen|strcmp|strncmp|strcat|strchr|strstr)\s*\(', {'cstring','string.h'}, 'memcpy/str*'),
 (r'\b(exit|atoi|atof|atol|strtod|strtol|malloc|free|rand|srand|getenv|setenv|qsort)\s*\(', {'cstdlib','stdlib.h'}, 'exit/atoi/malloc'),
 (r'\bstd::(sort|min|max|find|swap|reverse|fill|copy|unique|lower_bound|upper_bound|max_element|min_element|count|remove|stable_sort|binary_search)\s*\(', {'algorithm'}, 'std::sort/min/max'),
 (r'\b(INT_MAX|INT_MIN|LONG_MAX|LLONG_MAX)\b', {'climits','limits.h'}, 'INT_MAX'),
 (r'\b(DBL_MAX|DBL_MIN|DBL_EPSILON|FLT_MAX)\b', {'cfloat','float.h'}, 'DBL_MAX'),
 (r'\b(sprintf|printf|fprintf|fopen|fclose|fscanf|sscanf|fgets|snprintf)\s*\(', {'cstdio','stdio.h'}, 'stdio'),
 (r'\bstd::numeric_limits\b', {'limits'}, 'numeric_limits'),
 (r'\bassert\s*\(', {'cassert','assert.h'}, 'assert'),
 (r'\bstd::(o|i)?stringstream\b', {'sstream'}, 'stringstream'),
 (r'\bstd::(setw|setprecision|setfill)\b', {'iomanip'}, 'iomanip'),
 (r'(?<![\w:.])(sqrt|fabs|pow|exp|log|log10|sin|cos|tan|atan2|floor|ceil|fmod|hypot)\s*\(', {'cmath','math.h','complex'}, 'cmath'),
 (r'\bstd::(ifstream|ofstream|fstream)\b', {'fstream'}, 'fstream'),
 (r'\bstd::vector\b', {'vector'}, 'vector'),
 (r'\bstd::map\b', {'map'}, 'map'),
 (r'\bstd::set\b', {'set'}, 'set'),
 (r'\bstd::string\b', {'string','iostream','fstream','sstream'}, 'string'),
 (r'\bstd::complex\b', {'complex'}, 'complex'),
 (r'\bstd::(cout|cerr|endl)\b', {'iostream'}, 'iostream'),
 (r'\b(time|clock|difftime)\s*\(|\btime_t\b', {'ctime','time.h'}, 'ctime'),
]
strip = re.compile(r'//.*?$|/\*.*?\*/', re.S | re.M)
n = 0
for f in sorted(files):
    if not f.endswith(('.cpp', '.cxx')): continue
    cl = closure(f)
    sysh = set()
    for g in cl:
        sysh.update(sys_re.findall(files[g]))
        sysh.update(h for h in loc_re.findall(files[g]) if h not in files)
    if 'complex' in sysh: sysh.add('sstream')
    code = strip.sub('', files[f])
    for pat, hdrs, label in checks:
        if re.search(pat, code) and not (sysh & hdrs):
            print(f'  {f}: uses {label}; closure lacks {sorted(hdrs)}  (sys headers seen: {len(sysh)})'); n += 1
print(f'  -> {n} hits in {root}')
