# shellcheck shell=bash
# =============================================================================
# femtic_lib.sh -- helpers shared by 01_build_femtic.sh (smoke/restart test), 03_mesh.slurm,
# 04_inversion.slurm, 05_chain.sh and 06_forward_only.slurm.
# 01_build_femtic.sh installs it to $BIN and $BIN/femtic_env.sh sources it, so the restart logic
# that the smoke test exercises is the SAME code the 3-day chain runs.
# After editing this file on Phoenix, re-install it:   install -m 644 femtic_lib.sh "$BIN"/
# (03/04/05/06 refuse to run with a copy older than FEMTIC_LIB_VERSION 2.)
#
# control.dat format (verified in femtic/src/AnalysisControl.cpp::inputControlData):
#   a keyword line (matched by prefix, "line.substr(0,N)") followed by its value(s),
#   read with "inFile >>" -- i.e. the value is on the NEXT line. Reading stops at END.
#   Defaults when a keyword is absent: NUM_THREADS 1, FWD_SOLVER 0 (in-core),
#   MEM_LIMIT 3000 (MB), ITERATION 0 0, INV_METHOD 0 (model space).
#   HOLD_FWD_MEM is a bare keyword with NO value line (use femtic_ctl_has, not femtic_ctl_get).
# =============================================================================
# shellcheck disable=SC2034  # read by the scripts that source this file
FEMTIC_LIB_VERSION=2

# femtic_ctl_get FILE KEY  -> prints the (first) value line after KEY, empty if absent
femtic_ctl_get() {
  awk -v k="$2" '{sub(/\r$/,"")} $1==k {if ((getline v) > 0) {sub(/\r$/,"",v); print v}; exit}' "$1"
}

# femtic_ctl_has FILE KEY -> exit 0 if a line before END starts with KEY (bare keywords such as
# HOLD_FWD_MEM, which FEMTIC matches by prefix and which take no value line)
femtic_ctl_has() {
  awk -v k="$2" '{sub(/\r$/,"")} /^END([[:space:]]|$)/ {exit} index($0, k) == 1 {f = 1; exit} END {exit !f}' "$1"
}

# femtic_ctl_set FILE KEY "VALUE"  -> replaces the value line after KEY, or inserts
# "KEY\nVALUE" before END when KEY is absent. Single-line values only
# (NUM_THREADS, FWD_SOLVER, MEM_LIMIT, ITERATION, SENSE_MAT_DIRECTORY).
femtic_ctl_set() {
  local f=$1 k=$2 v=$3
  sed -i 's/\r$//' "$f"                                  # CRLF from Windows-made control.dat
  if grep -qE "^${k}([[:space:]]|\$)" "$f"; then
    sed -i -E "/^${k}([[:space:]]|\$)/{n;s|.*|${v}|}" "$f"
  elif grep -qE '^END([[:space:]]|$)' "$f"; then
    sed -i -E "/^END([[:space:]]|\$)/i ${k}\n${v}" "$f"
  else
    echo "femtic_ctl_set: no END line in $f" >&2; return 1
  fi
  [ "$(femtic_ctl_get "$f" "$k")" = "$v" ] || { echo "femtic_ctl_set: $k not set to '$v' in $f" >&2; return 1; }
}

# femtic_last_iter [DIR] -> highest N for which DIR/resistivity_block_iter<N>.dat exists
# (exact-name match: ignores *.bak, *.dat.gz, *.corrupt_<jobid> etc.). Existence only; see
# femtic_restart_pick for the integrity-checked choice.
femtic_last_iter() {
  ( cd "${1:-.}" 2>/dev/null && ls -1 2>/dev/null | sed -nE 's/^resistivity_block_iter([0-9]+)\.dat$/\1/p' | sort -n | tail -1 )
}

# femtic_nfreq [LOG] -> number of distinct frequencies FEMTIC listed in femtic_0.log
femtic_nfreq() {
  awk '/Forward calculation is performed for the frequencies/ {f=1; getline; next}
       f && /^#\+\+\+/ {print n+0; found=1; exit}
       f {n++}
       END {if (!found && f) print n+0}' "${1:-femtic_0.log}" 2>/dev/null
}

# femtic_cnv_row ITER [CNV] -> last (accepted) row of femtic.cnv for iteration ITER
#   columns: Iter# Retrial# Alpha Damp Roughness Misfit RMS ObjFunc
femtic_cnv_row() {
  awk -v it="$1" '$1==it {row=$0} END {if (row!="") print row}' "${2:-femtic.cnv}" 2>/dev/null
}

# femtic_block_stats FILE -> "NELEM NBLK NBLK_COUNTED NFREE NFIXED"
#   resistivity_block_iter<N>.dat: line 1 "nElem nBlk"; nElem lines "elemID blockID";
#   nBlk lines "blkID rho rhoMin rhoMax weight type"; type 0/3 = free, 1/2 = fixed
#   (ResistivityBlockIsotropic.h enum ResistivityBlockTypes).
femtic_block_stats() {
  awk 'NR==1 {ne=$1; nb=$2; next}
       NR>ne+1 && NF>=6 {c++; if ($6==0 || $6==3) fr++; else fx++}
       END {print ne+0, nb+0, c+0, fr+0, fx+0}' "$1"
}

# femtic_block_check FILE [REF] -> prints "OK <nElem> <nBlk>" and returns 0 if FILE is a complete
#   resistivity_block file: numeric header "nElem nBlk"; exactly nElem element lines (>= 2 fields);
#   exactly nBlk block lines, each with >= 6 fields that are all numbers; nothing else except blank
#   lines. With REF (normally resistivity_block_iter0.dat) the header must also equal REF's header:
#   element and block counts never change during an inversion. Otherwise prints "BAD <reason>" and
#   returns 1. Catches a file cut short by a kill while rank 0 was writing it (outputResistivityBlock
#   writes it line by line with fprintf and closes it at the end), and a NaN/inf model.
femtic_block_check() {
  local f=$1 ref=${2:-} rne="" rnb=""
  [ -s "$f" ] || { echo "BAD missing or empty: $f"; return 1; }
  if [ -n "$ref" ] && [ "$ref" != "$f" ] && [ -s "$ref" ]; then
    read -r rne rnb < <(head -1 "$ref" | tr -d '\r')
  fi
  awk -v rne="$rne" -v rnb="$rnb" '
    {sub(/\r$/, "")}
    NR == 1 { ne = $1; nb = $2
              if (ne !~ /^[0-9]+$/ || nb !~ /^[0-9]+$/ || ne + 0 < 1 || nb + 0 < 1) {msg = "header \"" $0 "\" is not <nElem> <nBlk>"; exit}
              if (rne != "" && (ne + 0 != rne + 0 || nb + 0 != rnb + 0)) {msg = "header " ne " " nb " differs from the reference " rne " " rnb; exit}
              next }
    /^[[:space:]]*$/ {next}
    { n++
      if (n <= ne + 0) { if (NF < 2) {msg = "element line " NR " has " NF " field(s)"; exit}; nel++ }
      else { if (NF < 6) {msg = "block line " NR " has " NF " field(s) (cut short?)"; exit}
             for (i = 2; i <= NF; i++) if ($i !~ /^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/) {msg = "block line " NR " field " i " \"" $i "\" is not a number"; exit}
             nbl++ } }
    END { if (msg == "" && nel != ne + 0) msg = nel + 0 " element lines, header says " ne
          if (msg == "" && nbl != nb + 0) msg = nbl + 0 " block lines, header says " nb
          if (msg != "") {print "BAD " msg; exit 1}
          print "OK", ne + 0, nb + 0 }' "$f"
}

# femtic_dist_check FILE [REF] -> "OK <nSta>" / "BAD <reason>" for distortion_iter<N>.dat: a count
#   line, then exactly that many station lines of >= 4 numeric fields (ObservedData::
#   outputDistortionParams: 6 fields for the distortion matrix and gains+rotations, 4 for gains only).
#   With REF (distortion_iter0.dat) the count must match REF's.
femtic_dist_check() {
  local f=$1 ref=${2:-} rn=""
  [ -s "$f" ] || { echo "BAD missing or empty: $f"; return 1; }
  if [ -n "$ref" ] && [ "$ref" != "$f" ] && [ -s "$ref" ]; then
    rn=$(head -1 "$ref" | tr -d '\r' | awk '{print $1}')
  fi
  awk -v rn="$rn" '
    {sub(/\r$/, "")}
    NR == 1 { ns = $1
              if (ns !~ /^[0-9]+$/) {msg = "count line \"" $0 "\" is not an integer"; exit}
              if (rn != "" && ns + 0 != rn + 0) {msg = "station count " ns " differs from the reference " rn; exit}
              next }
    /^[[:space:]]*$/ {next}
    { n++
      if (NF < 4) {msg = "line " NR " has " NF " field(s) (cut short?)"; exit}
      for (i = 1; i <= NF; i++) if ($i !~ /^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/) {msg = "line " NR " field " i " \"" $i "\" is not a number"; exit} }
    END { if (msg == "" && n + 0 != ns + 0) msg = n + 0 " station lines, header says " ns
          if (msg != "") {print "BAD " msg; exit 1}
          print "OK", ns + 0 }' "$f"
}

# femtic_iter_ok DIR N [DIST] -> returns 0 if iteration N can be restarted from: its
#   resistivity_block file passes femtic_block_check against iteration 0 and, when DIST != 0,
#   distortion_iter<N>.dat passes femtic_dist_check against distortion_iter0.dat.
#   On failure prints the reason on stdout.
femtic_iter_ok() {
  local d=$1 n=$2 dist=${3:-0} r
  r=$(femtic_block_check "$d/resistivity_block_iter$n.dat" "$d/resistivity_block_iter0.dat") \
    || { echo "resistivity_block_iter$n.dat: $r"; return 1; }
  if [ "$dist" != 0 ]; then
    r=$(femtic_dist_check "$d/distortion_iter$n.dat" "$d/distortion_iter0.dat") \
      || { echo "distortion_iter$n.dat: $r (DISTORTION=$dist)"; return 1; }
  fi
  return 0
}

# femtic_restart_pick [DIR] [DIST] [QUARANTINE] -> prints the iteration N to restart from.
#   N = femtic_last_iter DIR, used if femtic_iter_ok passes. Otherwise it falls back ONCE to N-1:
#   FEMTIC writes resistivity_block_iterN.dat and then distortion_iterN.dat, so a job killed while
#   rank 0 was writing leaves N incomplete and N-1 intact. A second rejection means something else
#   is wrong: returns 1 and prints nothing on stdout. Diagnostics go to stderr.
#   QUARANTINE=1 (04 at job start) renames the rejected iteration-N files to *.corrupt_<jobid>, so
#   femtic_last_iter and later jobs skip them. Iteration 0 is never renamed.
femtic_restart_pick() {
  local d=${1:-.} dist=${2:-0} q=${3:-0} n why f
  n=$(femtic_last_iter "$d")
  [ -n "$n" ] || { echo "femtic_restart_pick: no resistivity_block_iter<N>.dat in $d" >&2; return 1; }
  if why=$(femtic_iter_ok "$d" "$n" "$dist"); then echo "$n"; return 0; fi
  echo "femtic_restart_pick: iteration $n rejected -- $why" >&2
  [ "$n" -gt 0 ] || { echo "femtic_restart_pick: no earlier iteration to fall back to" >&2; return 1; }
  if ! why=$(femtic_iter_ok "$d" $(( n - 1 )) "$dist"); then
    echo "femtic_restart_pick: fallback iteration $(( n - 1 )) also rejected -- $why" >&2; return 1
  fi
  if [ "$q" = 1 ]; then
    for f in "$d/resistivity_block_iter$n.dat" "$d/distortion_iter$n.dat"; do
      [ -e "$f" ] && mv -f "$f" "$f.corrupt_${SLURM_JOB_ID:-$$}" && echo "femtic_restart_pick: renamed $f -> $f.corrupt_${SLURM_JOB_ID:-$$}" >&2
    done
  fi
  echo "femtic_restart_pick: restarting from iteration $(( n - 1 )) instead of $n" >&2
  echo $(( n - 1 ))
}

# femtic_time_left_s -> seconds of wall time left in this Slurm job (empty if unknown)
femtic_time_left_s() {
  local L d=0 h=0 m=0 s=0
  L=$(squeue -h -j "${SLURM_JOB_ID:-0}" -o %L 2>/dev/null | head -1)
  case "$L" in
    ""|UNLIMITED|NOT_SET|INVALID) return 0 ;;
  esac
  if [[ $L == *-* ]]; then d=${L%%-*}; L=${L#*-}; fi
  IFS=: read -r -a p <<< "$L"
  case ${#p[@]} in
    3) h=${p[0]}; m=${p[1]}; s=${p[2]} ;;
    2) m=${p[0]}; s=${p[1]} ;;
    1) s=${p[0]} ;;
  esac
  echo $(( 10#$d*86400 + 10#$h*3600 + 10#$m*60 + 10#$s ))
}

# femtic_pardiso_max_gb [DIR] -> largest "in-core forward solver" memory over all ranks' logs (GB)
femtic_pardiso_max_gb() {
  cat "${1:-.}"/femtic_*.log 2>/dev/null |
    awk -F: '/Total memory consumed by in-core forward solver/ {gsub(/[^0-9]/,"",$2); if ($2+0>m) m=$2+0}
             END {if (m>0) printf "%.1f\n", m/1024/1024}'
}

# femtic_fwd_times LOG -> "freq_hz seconds" for each frequency of the FIRST forward computation in
#   LOG (one rank's femtic_<rank>.log). Seconds = FEMTIC's elapsed stamp "( N sec )" on the
#   frequency's "Calculate response functions" line minus the stamp at the previous such line (or
#   the last stamp before "Start Forward Computation"). With ITERATION 0 0 (06) this is the pure
#   forward time; when sensitivities are computed it also contains the previous frequency's
#   sensitivity step. Resolution 1 s.
femtic_fwd_times() {
  awk '{ if (match($0, /\( *[0-9]+ sec *\)/)) { s = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); t = s + 0 } }
       /^# Start Forward Computation\./ { if (started) exit; started = 1; t0 = t; next }
       started && /^# Start forward calculation\. Frequency :/ { f = $7 }
       started && /^# Calculate response functions\./ { print f, t - t0; t0 = t }
       started && /^# Release memory of coefficient matrix and sparse solver\./ { exit }' "$1" 2>/dev/null
}

# femtic_mem_limit_auto NODE_MB RANKS_PER_NODE HOLD(0|1) RANK0_RESERVE_MB NONPARDISO_MB
#   -> MEM_LIMIT (MB per rank) = (0.85 x NODE_MB - [RANK0_RESERVE_MB only if HOLD]) / R - NONPARDISO_MB.
#   Without HOLD_FWD_MEM FEMTIC frees the forward matrices and PARDISO factors before rank 0's dense
#   model update, so the two phases do not overlap and the rank-0 reserve is not subtracted.
#   NONPARDISO_MB is each rank's own sensitivity-step arrays (interpolator solutions, field
#   derivatives, sensitivity block; README section 5), which MEM_LIMIT does not cover.
femtic_mem_limit_auto() {
  local r0=0
  [ "$3" = 1 ] && r0=$4
  echo $(( ($1 * 85 / 100 - r0) / $2 - $5 ))
}

# femtic_launch_cmd NRANKS RANKS_PER_NODE THREADS EXE -> sets the array FEMTIC_LAUNCH (and the
#   launcher's environment) for the toolchain in FEMTIC_TOOLCHAIN; USE_SRUN=1 uses srun.
# shellcheck disable=SC2034  # FEMTIC_LAUNCH is read by the caller
femtic_launch_cmd() {
  local n=$1 rpn=$2 t=$3 exe=$4
  if [ "${USE_SRUN:-0}" = 1 ]; then
    # Slurm >= 22.05 no longer passes --cpus-per-task from sbatch to srun; SRUN_CPUS_PER_TASK does.
    export SRUN_CPUS_PER_TASK=$t
    [ "${FEMTIC_TOOLCHAIN:-foss}" = intel ] && export I_MPI_PMI_LIBRARY=${I_MPI_PMI_LIBRARY:-/usr/lib64/libpmi2.so}   # path VERIFY on Phoenix
    FEMTIC_LAUNCH=(srun --mpi="${SRUN_MPI:-pmix}" --ntasks="$n" --ntasks-per-node="$rpn" --cpus-per-task="$t" --cpu-bind=cores "$exe")
  elif [ "${FEMTIC_TOOLCHAIN:-foss}" = intel ]; then
    # Intel MPI: one pinning domain of OMP_NUM_THREADS cores per rank
    export I_MPI_PIN_DOMAIN=omp I_MPI_DEBUG=${I_MPI_DEBUG:-4}
    FEMTIC_LAUNCH=(mpirun -np "$n" -ppn "$rpn" "$exe")
  else
    # OpenMPI 4.1: rpn ranks per node, each bound to t consecutive cores (man page spells it "PE=n")
    FEMTIC_LAUNCH=(mpirun -np "$n" --map-by "ppr:${rpn}:node:PE=${t}" --bind-to core --report-bindings "$exe")
  fi
}

# femtic_wait_pid PID -> waits for a background child and returns its exit code. A trapped signal
#   (the USR1 trap) makes 'wait' return early (status > 128) while the child still runs; this loops
#   until the child has really ended.
femtic_wait_pid() {
  local rc
  while :; do
    wait "$1"; rc=$?
    kill -0 "$1" 2>/dev/null || return "$rc"
  done
}

# femtic_stop PID REASON [STOPFILE] -> appends "REASON epoch" to STOPFILE (default $FEMTIC_STOPFILE),
#   sends TERM to the launcher (mpirun/srun forward it to every rank), waits up to
#   FEMTIC_STOP_GRACE_S (120) s, then sends KILL. Run it from a process that is NOT the launcher's
#   parent (the parent must stay in 'wait' to reap it; an unreaped child still answers kill -0).
femtic_stop() {
  local pid=$1 why=$2 sf=${3:-${FEMTIC_STOPFILE:-}} i=0
  [ -n "$sf" ] && echo "$why $(date +%s)" >> "$sf"
  echo "[$(date '+%F %T')] femtic_stop: $why -> TERM to pid $pid" >&2
  kill -TERM "$pid" 2>/dev/null || return 0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "${FEMTIC_STOP_GRACE_S:-120}" ]; do sleep 1; i=$(( i + 1 )); done
  if kill -0 "$pid" 2>/dev/null; then
    echo "[$(date '+%F %T')] femtic_stop: pid $pid still running after ${i} s -> KILL" >&2
    kill -KILL "$pid" 2>/dev/null
  fi
  return 0
}

# femtic_watch PID DEADLINE [LOG] -> run in the background next to a femtic launch. Every
#   FEMTIC_WATCH_S (60) s it:
#   * records the peak summed RSS (KiB) of the node's femtic processes in FEMTIC_RSS_FILE (if set);
#   * logs safe points: FEMTIC writes "# Start Inversion.  Iteration : N" only AFTER it has written
#     and closed resistivity_block_iterN.dat and distortion_iterN.dat (AnalysisControl::run), so at
#     that moment no model file is open. Each safe point is appended to FEMTIC_SAFEPOINTS
#     (job, iteration, epoch s, seconds since the previous safe point);
#   * safe-point stop: at a safe point, if the time left before DEADLINE is less than 1.1 x the last
#     safe-point interval (this job's, else the last one recorded by an earlier job), the next model
#     cannot be written in time, so femtic is stopped NOW. Nothing is lost that a restart from N would
#     not redo anyway: the restart repeats the forward solve of model N;
#   * deadline stop: at DEADLINE (epoch s; empty = none), whatever femtic is doing. The integrity
#     check in femtic_restart_pick catches a model file cut by this.
#   FEMTIC itself has no stop file and no signal handler, so a stop from outside is all there is.
femtic_watch() {
  local pid=$1 deadline=$2 log=${3:-femtic_0.log} spf=${FEMTIC_SAFEPOINTS:-/dev/null}
  local now left="" n sn="" st="" iv dur peak=0 rss nap sp=""
  trap '[ -n "$sp" ] && kill "$sp" 2>/dev/null; exit 0' TERM
  dur=$(awk -F'\t' '$4 ~ /^[0-9]+$/ && $4 > 0 {d = $4} END {print d}' "$spf" 2>/dev/null)
  while kill -0 "$pid" 2>/dev/null; do
    now=$(date +%s)
    if [ -n "${FEMTIC_RSS_FILE:-}" ]; then
      rss=$(ps -C femtic -o rss= 2>/dev/null | awk '{s += $1} END {print s + 0}')
      if [ "${rss:-0}" -gt "$peak" ]; then peak=$rss; echo "$peak" > "$FEMTIC_RSS_FILE"; fi
    fi
    if [ -n "$deadline" ]; then
      left=$(( deadline - now ))
      if [ "$left" -le 0 ]; then femtic_stop "$pid" deadline; return 0; fi
    fi
    n=$(awk '/^# Start Inversion\. +Iteration :/ {n = $NF} END {print n}' "$log" 2>/dev/null)
    if [ -n "$n" ] && [ "$n" != "$sn" ]; then
      iv=""
      [ -n "$st" ] && iv=$(( now - st )) && dur=$iv
      printf '%s\t%s\t%s\t%s\n' "${SLURM_JOB_ID:-0}" "$n" "$now" "$iv" >> "$spf"
      sn=$n; st=$now
      if [ -n "$deadline" ] && [ -n "$dur" ] && [ "$left" -lt $(( dur * 11 / 10 )) ]; then
        echo "[$(date '+%F %T')] femtic_watch: safe point after model $n; ${left} s left < 1.1 x ${dur} s per iteration" >&2
        femtic_stop "$pid" "safe_point_iter$n"; return 0
      fi
    fi
    nap=${FEMTIC_WATCH_S:-60}
    if [ -n "$deadline" ] && [ "$left" -lt "$nap" ]; then nap=$left; fi
    sleep "$nap" & sp=$!
    wait "$sp"; sp=""
  done
  return 0
}

# femtic_outcome_row FILE COL... -> appends one tab-separated row to FILE, header written once:
#   job_id script host start end outcome iter_start iter_end exit detail
femtic_outcome_row() {
  local f=$1; shift
  [ -s "$f" ] || printf 'job_id\tscript\thost\tstart\tend\toutcome\titer_start\titer_end\texit\tdetail\n' > "$f"
  ( IFS=$'\t'; printf '%s\n' "$*" ) >> "$f"
}
