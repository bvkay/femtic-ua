# shellcheck shell=bash
# =============================================================================
# femtic_lib.sh -- helpers shared by 01_build_femtic.sh (smoke/restart test), 03_mesh.slurm,
# 04_inversion.slurm, 05_chain.sh and 06_forward_only.slurm; femtic_env.sh also calls femtic_apps_remap.
# 01_build_femtic.sh installs it to $BIN and $BIN/femtic_env.sh sources it, so the restart logic
# that the smoke test exercises is the SAME code the 3-day chain runs.
# After editing this file on Phoenix, re-install it:   install -m 644 femtic_lib.sh "$BIN"/
# (01 SMOKE_ONLY=1, 03, 04, 05 and 06 all refuse to run with a copy older than FEMTIC_LIB_VERSION 4; version 3
# loses N_iv behind FEMTIC's DIV_NUM_RHS_FWD warning, see Versions below.)
# Versions: 2 = the copy installed on Phoenix on 2026-09-25 (commit fa58604, 18,193 B).
#           3 = 2026-09-28: femtic_pardiso_kb reads FEMTIC's %g numbers (1.23456e+06, 1.5e+08; version 2
#               turned them into 12345606 and 1508 KB); sensitivity-step memory model with both dense
#               N_eq x N_iv arrays (femtic_sens_mem_mb, femtic_mem_model) and the layout rule that 04/06
#               enforce (femtic_layout_check); femtic_block_uniform for the half-space gate in 06.
#           4 = 2026-09-28, later: femtic_niv_measured keeps counting across the two "Warning : Division number
#               of right-hand sides ..." lines FEMTIC writes when DIV_NUM_RHS_FWD > N_iv (Forward3D.cpp:183-186);
#               version 3 lost the count there and 04 printed "?".
#
# control.dat format (verified in femtic/src/AnalysisControl.cpp::inputControlData):
#   a keyword line (matched by prefix, "line.substr(0,N)") followed by its value(s),
#   read with "inFile >>" -- i.e. the value is on the NEXT line. Reading stops at END.
#   Defaults when a keyword is absent: NUM_THREADS 1, FWD_SOLVER 0 (in-core),
#   MEM_LIMIT 3000 (MB), ITERATION 0 0, INV_METHOD 0 (model space).
#   HOLD_FWD_MEM is a bare keyword with NO value line (use femtic_ctl_has, not femtic_ctl_get).
# =============================================================================
# shellcheck disable=SC2034  # read by the scripts that source this file
FEMTIC_LIB_VERSION=4

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

# femtic_pardiso_kb LOG... -> the largest "Total memory consumed by in-core forward solver for internal float
#   point arrays : <value> [KByte]" over the given logs, as a whole number of KB; prints nothing if no log has
#   the line. FEMTIC writes the double with the default ostream format (PARDISOSolver.cpp:218), i.e. %g with 6
#   significant digits: "216125" below 1e6 KB, then "1.23456e+06", "2.74856e+07", "2.5e+07", "1.5e+08". The
#   value is read as one token and converted by awk (strtod). Version 2 deleted every non-digit instead, which
#   turned 1.23456e+06 into 12345606 (10x high) and 1.5e+08 or 2.5e+07 into 1508 or 2507 (1e5 x low); it was
#   right only for a 6-digit mantissa at e+07. A token that is not a number is reported on stderr.
femtic_pardiso_kb() {
  local f files=()
  for f in "$@"; do [ -f "$f" ] && files+=("$f"); done
  [ "${#files[@]}" -gt 0 ] || return 0
  awk '/Total memory consumed by in-core forward solver/ {
         s = $0; sub(/^[^:]*:[[:space:]]*/, "", s); split(s, a, /[[:space:]]+/)
         if (a[1] ~ /^[0-9]+(\.[0-9]*)?([eE][-+]?[0-9]+)?$/) { v = a[1] + 0; if (!n || v > m) m = v; n++ }
         else printf "femtic_pardiso_kb: %s line %d: \"%s\" is not a number\n", FILENAME, FNR, a[1] > "/dev/stderr" }
       END { if (n) printf "%.0f\n", m }' "${files[@]}"
}

# femtic_pardiso_max_gb [DIR] -> largest in-core PARDISO memory over all ranks' logs DIR/femtic_*.log, in GiB
#   (KB / 1024^2, one decimal); prints nothing if no log has the line
femtic_pardiso_max_gb() {
  local kb
  kb=$(femtic_pardiso_kb "${1:-.}"/femtic_*.log)
  [ -n "$kb" ] && awk -v k="$kb" 'BEGIN {printf "%.1f\n", k / 1048576}'
}

# femtic_pardiso_log_gb LOG -> the same for one rank's log, two decimals; "-" if the log has no such line
femtic_pardiso_log_gb() {
  local kb
  kb=$(femtic_pardiso_kb "$1")
  if [ -n "$kb" ]; then awk -v k="$kb" 'BEGIN {printf "%.2f\n", k / 1048576}'; else echo "-"; fi
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
#   NONPARDISO_MB is each rank's own sensitivity-step arrays (the interpolator right-hand-side matrix and its
#   solution, field derivatives, sensitivity block; README section 6), which MEM_LIMIT does not cover.
#   MEM_LIMIT only steers FWD_SOLVER 1/2 (in-core or out-of-core PARDISO); with FEMTIC's default in-core solver
#   it changes nothing, so it cannot prevent an out-of-memory kill. femtic_layout_check does that job.
femtic_mem_limit_auto() {
  local r0=0
  [ "$3" = 1 ] && r0=$4
  echo $(( ($1 * 85 / 100 - r0) / $2 - $5 ))
}

# femtic_sens_mem_mb NEQ NIV M NDF -> MiB (rounded up) of the arrays one rank holds in the sensitivity step
#   besides PARDISO, per frequency (README section 6). Read in femtic/src at 26c8606:
#     2 x N_eq x N_iv x 16 B  the right-hand-side matrix of the interpolator vectors (ComplexSparseMatrix.cpp:535-536,
#                             allocated by Forward3D::initializeRhsVectors(N_iv)) AND its solution
#                             (Inversion.cpp:108). Both are live during the solve (Inversion.cpp:111); the RHS
#                             matrix shrinks to one column only after it (Forward3D.cpp:213). The PARDISO factors
#                             stay resident until after the last frequency.
#     2 x N_iv x M x 16 B     the field derivatives of both polarisations (Inversion.cpp:131)
#     Nd_f x M x 8 B          the frequency's sensitivity block (Inversion.cpp:169)
#   The three terms are added as if live at once. The strict peak (during the second polarisation's solve) is
#   the first term plus ONE derivative array, so this is about 1 GB high on Vulcan v3. Whether MKL's multi-RHS
#   solve adds workspace on top is not known: T4 (04 with ITERATION 0 1) measures the real peak.
#   N_eq = "Number of equation after degeneration"; N_iv = 4 per MT station (Ex, Ey, Hx, Hy; femtic_mem_model);
#   M = free parameters; Nd_f = real data per frequency (8 per MT station).
femtic_sens_mem_mb() {
  local a
  [ "$#" -eq 4 ] || { echo "femtic_sens_mem_mb: usage NEQ NIV M NDF" >&2; return 1; }
  for a in "$@"; do
    case "$a" in ''|*[!0-9]*) echo "femtic_sens_mem_mb: '$a' is not a whole number (NEQ NIV M NDF)" >&2; return 1 ;; esac
  done
  echo $(( (2 * 10#$1 * 10#$2 * 16 + 2 * 10#$2 * 10#$3 * 16 + 10#$4 * 10#$3 * 8 + 1048575) / 1048576 ))
}

# femtic_mesh_counts MESH -> "NODES ELEMENTS" of a FEMTIC tetra mesh.dat (line 1 TETRA, line 2 the node count,
#   one line per node, then the element count). Prints nothing for any other layout.
femtic_mesh_counts() {
  awk 'NR == 1 { if ($1 != "TETRA") exit; next }
       NR == 2 { v = $1 + 0; if (v < 1) exit; next }
       NR == v + 3 { if ($1 ~ /^[0-9]+$/) print v, $1 + 0; exit }' "$1" 2>/dev/null
}

# femtic_obs_counts OBSERVE -> "N_MT ND": impedance (MT) stations of a FEMTIC observe.dat and its number of real
#   impedance data (8 per station-frequency line of the MT block). Other blocks (e.g. the VTF block of dummy
#   stations that prep writes for OWNER_ELEMENT -1) are listed on stderr. Returns 1 without an MT block.
femtic_obs_counts() {
  awk '{sub(/\r$/, "")}
       $1 ~ /^[A-Z][A-Z_0-9]*$/ && $1 != "END" && NF >= 2 && $2 ~ /^[0-9]+$/ {
         blk = $1; if (blk == "MT") nmt = $2 + 0; else other = other " " blk " " $2; st = "sta"; next }
       $1 == "END" { blk = ""; next }
       blk == "MT" && st == "sta"  { st = "nf"; next }
       blk == "MT" && st == "nf"   { left = $1 + 0; nd += 8 * left; st = (left > 0 ? "data" : "sta"); next }
       blk == "MT" && st == "data" { if (--left == 0) st = "sta"; next }
       END { if (nmt == "") exit 1
             print nmt, nd + 0
             if (other != "") print "observe.dat blocks besides MT (stations):" other > "/dev/stderr" }' "$1"
}

# femtic_log_neq LOG... -> the largest "Number of equation after degeneration" in the given logs (N_eq)
femtic_log_neq() {
  local f files=()
  for f in "$@"; do [ -f "$f" ] && files+=("$f"); done
  [ "${#files[@]}" -gt 0 ] || return 0
  sed -nE 's/.*Number of equation after degeneration = ([0-9]+).*/\1/p' "${files[@]}" | sort -n | tail -1
}

# femtic_niv_measured LOG... -> N_iv as FEMTIC used it: the right-hand sides of one interpolator-vector solve,
#   i.e. the "# Solve phase is performed simultaneously for N right-hand sides" lines that follow "# Solve phase of
#   matrix solver for right-hand sides consisting of interpolator vectors." (Inversion.cpp:110), summed over the
#   DIV_NUM_RHS_FWD calls (Forward3D.cpp:195), largest over all solves. The block ends at the next line that starts
#   with "#" ("# Calculate derivatives of EM field."). Lines without "#" inside it are skipped: when DIV_NUM_RHS_FWD
#   exceeds N_iv, Forward3D.cpp:183-186 writes, between the two,
#     "Warning : Division number of right-hand sides ( D ) is greater than the total number of right-hand sides ( N )."
#     "          Thus, the division number is set the total number of right-hand sides."
#   and then N lines "... simultaneously for 1 right-hand sides". Prints nothing when no sensitivity step ran
#   (ITERATION 0 0 has none).
femtic_niv_measured() {
  local f files=()
  for f in "$@"; do [ -f "$f" ] && files+=("$f"); done
  [ "${#files[@]}" -gt 0 ] || return 0
  awk 'FNR == 1 { on = 0 }
       /^# Solve phase of matrix solver for right-hand sides consisting of interpolator vectors/ { on = 1; s = 0; next }
       on && /^# Solve phase is performed simultaneously for [0-9]+ right-hand sides/ { s += $8; if (s > m) m = s; next }
       on && /^#/ { on = 0 }
       END { if (m) print m }' "${files[@]}"
}

# femtic_fwd_mb_auto DIR [NEQ] -> "MiB SOURCE": one rank's memory in the forward phase (PARDISO factors, system
#   matrix, mesh), the first term of the layout rule. In order of preference:
#     DIR/logs/fwd_rank_mb   written by 06 after a forward-only run on Phoenix: max(peak summed node RSS / ranks per
#                            node, 1.25 x the largest PARDISO line of that run)
#     1.25 x the largest PARDISO line in DIR's femtic logs (femtic_*.log, fwd0_*/, logs/run_*/). On WSL the
#                            forward-only peak RSS was 1.17 / 1.21 / 1.22 x the PARDISO line for v1 / v2 / v3
#     NEQ x FEMTIC_FWD_MIB_PER_MEQ (default 11000 MiB per 10^6 equations) when NEQ is given. The WSL forward-only
#                            peak RSS per 10^6 N_eq was 10,832 / 9,718 / 9,211 MiB for v1 / v2 / v3 (19,328 /
#                            27,645 / 32,869 MiB at N_eq 1,784,220 / 2,844,872 / 3,568,555)
#     FEMTIC_FWD_MB_FALLBACK (default 33000): v3's WSL forward-only peak RSS, 32,869 MiB (v2: 27,645 MiB)
femtic_fwd_mb_auto() {
  local d=${1:-.} neq=${2:-} v kb
  if [ -s "$d/logs/fwd_rank_mb" ]; then
    v=$(awk 'NR == 1 && $1 ~ /^[0-9]+$/ {print $1 " measured_by_06_" $2}' "$d/logs/fwd_rank_mb")
    [ -n "$v" ] && { echo "$v"; return 0; }
  fi
  kb=$(femtic_pardiso_kb "$d"/femtic_*.log "$d"/fwd0_*/femtic_*.log "$d"/logs/run_*/femtic_*.log)
  if [ -n "$kb" ]; then
    awk -v k="$kb" 'BEGIN {x = k * 1.25 / 1024; n = int(x); if (n < x) n++; printf "%d 1.25_x_PARDISO_%.0f_MiB_in_logs\n", n, k / 1024}'
    return 0
  fi
  case "$neq" in
    ''|*[!0-9]*) ;;
    *) awk -v n="$neq" -v r="${FEMTIC_FWD_MIB_PER_MEQ:-11000}" 'BEGIN {x = n * r / 1e6; m = int(x); if (m < x) m++; printf "%d no_log_yet:_%d_MiB_per_1e6_equations_x_N_eq\n", m, r}'
       return 0 ;;
  esac
  echo "${FEMTIC_FWD_MB_FALLBACK:-33000} fallback_no_log_yet"
}

# femtic_mem_model DIR -> sets the variables of the layout rule (README section 6) and prints two summary lines:
#   FM_NMT FM_ND   MT stations and real data of DIR/observe.dat (femtic_obs_counts)
#   FM_NEQ   N_eq: knob NEQ if a number; else the largest logged value in DIR's femtic logs (femtic_*.log,
#            fwd0_*/, logs/run_*/); else nodes + elements of DIR/mesh.dat. For a tetrahedral mesh of a ball the
#            edge count is nodes + elements + (boundary faces / 2) - 1; on Vulcan v1-v3 nodes + elements is
#            2,557 above the logged N_eq (0.07-0.14 %).
#   FM_NIV   N_iv: knob NIV if a number; else 4 x FM_NMT. With OWNER_ELEMENT -1 prep adds a VTF block of 120 dummy
#            stations (no data) that carry Hx, Hy for the MT stations. By ObservedData.cpp:1029-1082 a station
#            without data at a frequency adds no right-hand side and the MT station's own Hx, Hy are not
#            requested, so N_iv stays 4 x 120 = 480 (not 480 + 3 x 120 = 840). That is a reading of the source,
#            not a measurement: T4 measures it (femtic_niv_measured); until then NIV=840 is the pessimistic case.
#   FM_M     free parameters (block types 0/3) of DIR/resistivity_block_iter0.dat (distortion parameters,
#            DISTORTION != 0, are not added)
#   FM_NDF   8 x FM_NMT
#   FM_NONP_MB  knob NONPARDISO_MB if a number, else femtic_sens_mem_mb FM_NEQ FM_NIV FM_M FM_NDF
#   FM_FWD_MB   knob FWD_MB if a number, else femtic_fwd_mb_auto DIR FM_NEQ
#   Returns 1 (message on stderr) if a quantity cannot be derived; the knob named in the message fixes it.
femtic_mem_model() {
  local d=${1:-.} vt
  FM_NMT=""; FM_ND=""; FM_NEQ=""; FM_NEQ_SRC=""; FM_NIV=""; FM_NIV_SRC=""; FM_M=""; FM_NDF=""
  FM_NONP_MB=""; FM_NONP_SRC=""; FM_FWD_MB=""; FM_FWD_SRC=""
  read -r FM_NMT FM_ND < <(femtic_obs_counts "$d/observe.dat")
  [ -n "$FM_NMT" ] && FM_NDF=$(( 8 * FM_NMT ))
  case "${NIV:-auto}" in
    auto) [ -n "$FM_NMT" ] && { FM_NIV=$(( 4 * FM_NMT )); FM_NIV_SRC="4 x $FM_NMT MT stations of observe.dat"; } ;;
    *[!0-9]*) echo "femtic_mem_model: NIV='$NIV' is not a whole number" >&2; return 1 ;;
    *) FM_NIV=$NIV; FM_NIV_SRC="NIV=$NIV (set)" ;;
  esac
  case "${NEQ:-auto}" in
    auto)
      FM_NEQ=$(femtic_log_neq "$d"/femtic_*.log "$d"/fwd0_*/femtic_*.log "$d"/logs/run_*/femtic_*.log)
      if [ -n "$FM_NEQ" ]; then
        FM_NEQ_SRC="largest 'Number of equation after degeneration' in the femtic logs of $d"
      else
        vt=$(femtic_mesh_counts "$d/mesh.dat")
        if [ -n "$vt" ]; then
          FM_NEQ=$(( ${vt% *} + ${vt#* } ))
          FM_NEQ_SRC="mesh.dat nodes + elements (${vt% *} + ${vt#* }; no femtic log yet)"
        fi
      fi ;;
    *[!0-9]*) echo "femtic_mem_model: NEQ='$NEQ' is not a whole number" >&2; return 1 ;;
    *) FM_NEQ=$NEQ; FM_NEQ_SRC="NEQ=$NEQ (set)" ;;
  esac
  [ -f "$d/resistivity_block_iter0.dat" ] && FM_M=$(femtic_block_stats "$d/resistivity_block_iter0.dat" | awk '$4 > 0 {print $4}')
  case "${NONPARDISO_MB:-auto}" in
    auto)
      if [ -z "$FM_NEQ" ] || [ -z "$FM_NIV" ] || [ -z "$FM_M" ] || [ -z "$FM_NDF" ]; then
        echo "femtic_mem_model: cannot derive NONPARDISO_MB from $d (N_eq '$FM_NEQ', N_iv '$FM_NIV', M '$FM_M', Nd_f '$FM_NDF'): set NONPARDISO_MB=<MiB>, or NEQ / NIV" >&2
        return 1
      fi
      FM_NONP_MB=$(femtic_sens_mem_mb "$FM_NEQ" "$FM_NIV" "$FM_M" "$FM_NDF") || return 1
      FM_NONP_SRC="2 x N_eq x N_iv x 16 B + 2 x N_iv x M x 16 B + Nd_f x M x 8 B" ;;
    *[!0-9]*) echo "femtic_mem_model: NONPARDISO_MB='$NONPARDISO_MB' is not a whole number of MiB" >&2; return 1 ;;
    *) FM_NONP_MB=$NONPARDISO_MB; FM_NONP_SRC="NONPARDISO_MB=$NONPARDISO_MB (set)" ;;
  esac
  case "${FWD_MB:-auto}" in
    auto) read -r FM_FWD_MB FM_FWD_SRC < <(femtic_fwd_mb_auto "$d" "$FM_NEQ") ;;
    *[!0-9]*) echo "femtic_mem_model: FWD_MB='$FWD_MB' is not a whole number of MiB" >&2; return 1 ;;
    *) FM_FWD_MB=$FWD_MB; FM_FWD_SRC="FWD_MB=$FWD_MB (set)" ;;
  esac
  echo "memory model: N_eq ${FM_NEQ:-?} (${FM_NEQ_SRC:-unknown}); N_iv ${FM_NIV:-?} (${FM_NIV_SRC:-unknown}); M ${FM_M:-?}; Nd_f ${FM_NDF:-?}; Nd ${FM_ND:-?}"
  echo "memory model: per rank, forward phase FWD_MB = $FM_FWD_MB MiB ($FM_FWD_SRC); sensitivity-step arrays NONPARDISO_MB = $FM_NONP_MB MiB ($FM_NONP_SRC)"
}

# femtic_layout_check RPN FWD_MB NONP_MB NODE_MB [SAFETY_PCT] [EXTRA_MB] -> the layout rule (README section 6):
#   RPN x (FWD_MB + NONP_MB) + EXTRA_MB <= SAFETY_PCT (default 95) % of NODE_MB, the job's --mem per node.
#   Every rank factorises the whole mesh and keeps its factors through the sensitivity step, so memory grows
#   with the ranks per node, and FEMTIC's in-core solver cannot shrink (MEM_LIMIT does not bind it).
#   Prints one line ending in OK or REFUSED with the largest rank count that fits; returns 1 if refused.
#   NONP_MB 0 checks the forward phase alone. EXTRA_MB: the rank-0 reserve under HOLD_FWD_MEM, sensitivity files
#   on a RAM-backed $TMPDIR.
femtic_layout_check() {
  local r=$1 fw=$2 np=$3 node=$4 pct=${5:-95} ex=${6:-0} a per need lim fit
  for a in "$r" "$fw" "$np" "$node" "$pct" "$ex"; do
    case "$a" in ''|*[!0-9]*) echo "femtic_layout_check: '$a' is not a whole number (RPN FWD_MB NONP_MB NODE_MB [PCT] [EXTRA_MB])" >&2; return 1 ;; esac
  done
  per=$(( fw + np )); need=$(( r * per + ex )); lim=$(( node * pct / 100 ))
  fit=0; [ "$per" -gt 0 ] && [ "$lim" -gt "$ex" ] && fit=$(( (lim - ex) / per ))
  if [ "$need" -le "$lim" ]; then
    echo "layout rule: $r ranks/node x ($fw forward + $np sensitivity-step MiB) + $ex extra = $need MiB <= $pct % of $node MiB (--mem) = $lim MiB: OK (up to $fit ranks/node fit)"
    return 0
  fi
  echo "layout rule: $r ranks/node x ($fw forward + $np sensitivity-step MiB) + $ex extra = $need MiB > $pct % of $node MiB (--mem) = $lim MiB: REFUSED (at most $fit ranks/node fit)"
  return 1
}

# femtic_block_uniform SRC DST RHO -> writes DST = SRC with every block of resistivity below 1e6 ohm-m set to RHO
#   (the air block, 1e9 ohm-m and fixed, is kept), for the half-space accuracy gate (06 START_RHO). Element lines
#   and the other block columns are copied unchanged. Prints "OK <blocks set> <blocks kept>"; prints "BAD
#   <reason>" and returns 1 on a malformed SRC or RHO.
femtic_block_uniform() {
  local src=$1 dst=$2 rho=$3 r
  case "$rho" in ''|*[!0-9.eE+-]*) echo "BAD RHO '$rho' is not a number"; return 1 ;; esac
  awk -v rho="$rho" 'BEGIN { exit !(rho + 0 > 0) }' || { echo "BAD RHO '$rho' is not a positive number"; return 1; }
  r=$(femtic_block_check "$src") || { echo "BAD $src: $r"; return 1; }
  awk -v rho="$rho" -v out="$dst" '{sub(/\r$/, "")}
       NR == 1 { ne = $1 + 0; print > out; next }
       NR <= ne + 1 || /^[[:space:]]*$/ { print > out; next }
       { if ($2 + 0 < 1e6) { $2 = sprintf("%.6e", rho); nset++ } else nkeep++; print > out }
       END { close(out); printf "OK %d %d\n", nset, nkeep }' "$src"
}

# femtic_launch_cmd NRANKS RANKS_PER_NODE THREADS EXE -> sets the array FEMTIC_LAUNCH (and the
#   launcher's environment) for the toolchain in FEMTIC_TOOLCHAIN; USE_SRUN=1 uses srun.
#   Phoenix (00_discover.sh, 2026-09-25): 'srun --mpi=list' gives pmi2, none, cray_shasta (no pmix) and
#   MpiDefault=none, so srun needs --mpi=pmi2; OpenMPI 4.1.5 was built --with-pmi and has the s1/s2
#   PMI components. mpirun (the default) uses OpenMPI's ess slurm component and needs none of this.
# shellcheck disable=SC2034  # FEMTIC_LAUNCH is read by the caller
femtic_launch_cmd() {
  local n=$1 rpn=$2 t=$3 exe=$4
  if [ "${USE_SRUN:-0}" = 1 ]; then
    # Slurm >= 22.05 no longer passes --cpus-per-task from sbatch to srun; SRUN_CPUS_PER_TASK does.
    export SRUN_CPUS_PER_TASK=$t
    [ "${FEMTIC_TOOLCHAIN:-foss}" = intel ] && export I_MPI_PMI_LIBRARY=${I_MPI_PMI_LIBRARY:-/usr/lib64/libpmi2.so}   # path VERIFY on Phoenix
    FEMTIC_LAUNCH=(srun --mpi="${SRUN_MPI:-pmi2}" --ntasks="$n" --ntasks-per-node="$rpn" --cpus-per-task="$t" --cpu-bind=cores "$exe")
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

# femtic_apps_remap -> for nodes WITHOUT /apps but WITH /gpfs/apps. Phoenix's interactive-partition
#   (data-mover) nodes p2-dmv-* are such nodes (verified 2026-09-25): 'module load foss/2023a imkl/2023.1.0'
#   still succeeds there but sets MKLROOT, LD_LIBRARY_PATH, ... to /apps/icl/... paths that do not exist, so
#   'ldd femtic' reports the MKL libraries "not found". There, every exported variable naming a path under
#   /apps/ is rewritten to /gpfs/apps/, and one warning line goes to stderr. "/apps/" is rewritten only where
#   a path starts (start of the value, or after ':' ';' ',' '=' or a blank), so /gpfs/apps/... entries stay
#   as they are and a second call changes nothing. PWD, OLDPWD and Lmod's encoded _ModuleTable* are skipped.
#   Where /apps exists (login node, icelake nodes) it does nothing. Called by femtic_env.sh after 'module
#   load'. Always returns 0.
femtic_apps_remap() {
  [ ! -d /apps ] && [ -d /gpfs/apps ] || return 0
  local _ar_v _ar_val _ar_new _ar_sep _ar_from _ar_to _ar_n=0
  for _ar_v in $(compgen -e); do
    case "$_ar_v" in PWD|OLDPWD|_ModuleTable*) continue ;; esac
    _ar_val=${!_ar_v}
    case "$_ar_val" in *"/apps/"*) ;; *) continue ;; esac
    _ar_new=$_ar_val
    case "$_ar_new" in /apps/*) _ar_new="/gpfs$_ar_new" ;; esac
    for _ar_sep in ':' ';' ',' '=' ' ' $'\t'; do
      _ar_from="$_ar_sep/apps/"; _ar_to="$_ar_sep/gpfs/apps/"
      _ar_new=${_ar_new//"$_ar_from"/$_ar_to}
    done
    if [ "$_ar_new" != "$_ar_val" ]; then
      export "$_ar_v=$_ar_new" 2>/dev/null && _ar_n=$((_ar_n + 1))
    fi
  done
  if [ "$_ar_n" -gt 0 ]; then
    echo "femtic_env.sh: /apps absent on $(hostname 2>/dev/null || uname -n); remapped to /gpfs/apps ($_ar_n exported variables)" >&2
  fi
  return 0
}
