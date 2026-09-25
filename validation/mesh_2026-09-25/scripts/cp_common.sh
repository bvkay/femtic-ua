# sourced helpers for chain proof runs
export PATH=/home/tara/femtic_wsl/bin:$PATH
SP=/mnt/c/Users/joint/AppData/Local/Temp/claude/D--BEN-FEMTIC-2026/4e858f54-ea4e-47a8-9815-7766aca9830d/scratchpad
step() { # step <name> <cmd...> ; appends name, rc, wall seconds, maxrss to logs/timings.tsv
  local name=$1; shift
  local t0=$(date +%s.%N)
  /usr/bin/time -f "%e s wall, %M KB maxrss" -o logs/$name.time "$@" > logs/$name.log 2>&1
  local rc=$?
  local t1=$(date +%s.%N)
  printf '%s\t%d\t%.2f\t%s\n' "$name" "$rc" "$(echo "$t1 - $t0" | bc -l)" "$(tail -1 logs/$name.time)" >> logs/timings.tsv
  return $rc
}
ele_attrs() { # ele_attrs <file.ele> : histogram of last column (region attribute)
  awk 'NR==1{next} /^#/{next} NF>0{c[$NF]++} END{for(k in c) printf "attr %s : %d elements\n", k, c[k]}' "$1" | sort
}
