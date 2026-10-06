#!/bin/bash
# =============================================================================
# run.sh -- submit one run folder on Phoenix (login node):
#     bash /hpcfs/users/$USER/vulcan_femtic/kit/run.sh Run01            (--again: submit a run that already has a job)
#
# Layout under VF=/hpcfs/users/$USER/vulcan_femtic:
#   bin               link to a FEMTIC build (RUNBOOK S1); BIN, default $VF/bin, is passed to every job
#   kit/              this kit: exported on the PC by scripts/make_phoenix_kit.sh, copied by WinSCP; VERSION names it
#   shared/mesh_v2/   mesh.dat, resistivity_block_iter0.dat, uploaded once (also mesh_v3/)
#   runs/RunNN/       control.dat observe.dat station_map.csv run.env RUN.md, made on the PC by scripts/make_run.sh
#   runs/INDEX.md     one line per run: run, mesh, purpose, layout, job id(s), verdict
# run.env: nine KEY=VALUE lines, all required, "none" where a key does not apply:
#   MESH=v2|v3   JOB=gate|forward|t4|inversion   START_RHO=<ohm-m> (gate) | none   RANKS=<ranks per node>
#   THREADS=<threads per rank>   TIME=<sbatch --time>   PARTITION=icelake|highmem   ITER_STEP=<n> | none
#   ITER_MAX=<n> | none   (ITER_STEP and ITER_MAX: inversion only)
# Two optional keys (a missing key means none):
#   NIV=<n> | none     N_iv for the layout rule and the job (none: 4 x the MT stations of observe.dat, i.e. 480;
#                      840 if Run03 measured it). Passed as NIV=<n> in --export to 04, 05 and 06.
#   MAIL=<address> | none   none: no email (--mail-type=NONE); else --mail-type=END,FAIL --mail-user=<address>.
#                      The job scripts carry no #SBATCH mail lines, so nobody is emailed unless MAIL says so.
# What it does:
#   1. checks run.env, the run's control.dat and observe.dat, FEMTIC in $BIN, and $SHARED/mesh_$MESH/{mesh.dat,
#      resistivity_block_iter0.dat} (each must exist and be non-empty; FEMTIC's own reader checks the rest)
#   2. checks the memory layout rule (femtic_layout_check, on the run folder with the shared mesh files; 04 and 06
#      check it again in the job). Silent unless it refuses: it stops a layout whose ranks would not fit in the
#      node's memory, i.e. an out-of-memory kill. A refusal leaves the run folder untouched.
#   3. links the two mesh files into the run folder: mesh.dat -> ../../shared/mesh_$MESH/mesh.dat, and the same for
#      resistivity_block_iter0.dat (FEMTIC never writes iteration 0, so the shared copy is only read)
#   4. submits from the run folder with -J RunNN -p PARTITION --ntasks-per-node=RANKS --cpus-per-task=THREADS
#      --time=TIME (highmem: also --mem=1900G), the mail options and --export=ALL,KIT=$KIT,BIN=$BIN[,NIV=<n>]:
#        gate      06_forward_only.slurm with START_RHO (half-space accuracy gate)
#        forward   06_forward_only.slurm (one forward solve of resistivity_block_iter0.dat)
#        t4        04_inversion.slurm once; control.dat must say ITERATION 0 1 (make_run.sh writes it)
#        inversion 05_chain.sh: ceil((ITER_MAX - last model) / ITER_STEP) chained 04 jobs of ITER_STEP iterations
#   5. appends "job <id> submitted <date>" to RUN.md, writes the id(s) into the run's line of INDEX.md (adding the
#      line if INDEX.md has none) and prints the id(s)
# Refuses (exit 1, nothing submitted): an unknown run, a missing or bad run.env key, no FEMTIC in $BIN, a missing
# shared mesh file, a layout the memory rule refuses, a run whose RUN.md already lists a job (unless --again).
# Then: bash $VF/kit/status.sh RunNN.  Environment (defaults): VF, KIT (this script's folder), BIN ($VF/bin),
# SHARED ($VF/shared), RUNS ($VF/runs). GNU bash 4.4 (the Phoenix login node); no python.
# =============================================================================
set -o pipefail
KIT=${KIT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
VF=${VF:-/hpcfs/users/$USER/vulcan_femtic}
BIN=${BIN:-$VF/bin}
SHARED=${SHARED:-$VF/shared}
RUNS=${RUNS:-$VF/runs}
die() { echo "run.sh: REFUSED: $*" >&2; exit 1; }

RUN=""; AGAIN=0
for a in "$@"; do
  case "$a" in
    --again) AGAIN=1 ;;
    -*) die "unknown option '$a' (usage: bash $KIT/run.sh RunNN [--again])" ;;
    *) [ -z "$RUN" ] || die "one run at a time (got $RUN and $a)"; RUN=${a%/}; RUN=${RUN##*/} ;;
  esac
done
[ -n "$RUN" ] || die "usage: bash $KIT/run.sh RunNN [--again]"
RD=$RUNS/$RUN
[ -d "$RD" ] || die "unknown run $RUN: there is no folder $RD (WinSCP the folder scripts/make_run.sh made to $RUNS/)"
# shellcheck disable=SC1091
source "$KIT/femtic_lib.sh" 2>/dev/null || die "no kit at $KIT (femtic_lib.sh missing)"
[ "${FEMTIC_LIB_VERSION:-0}" -ge 5 ] || die "$KIT/femtic_lib.sh is version ${FEMTIC_LIB_VERSION:-unset}; run.sh needs FEMTIC_LIB_VERSION >= 5 (upload the current kit)"

# ---------------------------------------------------------------- run.env
[ -s "$RD/run.env" ] || die "$RD/run.env is missing or empty"
declare -A E=()
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%$'\r'}
  case "$line" in ''|'#'*) continue ;; esac
  [[ "$line" =~ ^([A-Z_]+)=([^[:space:]]+)$ ]] || die "run.env line '$line' is not KEY=VALUE"
  case "${BASH_REMATCH[1]}" in
    MESH|JOB|START_RHO|RANKS|THREADS|TIME|PARTITION|ITER_STEP|ITER_MAX|NIV|MAIL) E[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]} ;;
    *) die "run.env: unknown key ${BASH_REMATCH[1]} (keys: MESH JOB START_RHO RANKS THREADS TIME PARTITION ITER_STEP ITER_MAX, optional NIV MAIL)" ;;
  esac
done < "$RD/run.env"
for k in MESH JOB START_RHO RANKS THREADS TIME PARTITION ITER_STEP ITER_MAX; do
  [ -n "${E[$k]:-}" ] || die "run.env has no $k (all nine keys are needed; 'none' where one does not apply)"
done
MESH=${E[MESH]}; JOB=${E[JOB]}; START_RHO=${E[START_RHO]}; RANKS=${E[RANKS]}; THREADS=${E[THREADS]}
TIME=${E[TIME]}; PARTITION=${E[PARTITION]}; ITER_STEP=${E[ITER_STEP]}; ITER_MAX=${E[ITER_MAX]}
NIVV=${E[NIV]:-none}; MAIL=${E[MAIL]:-none}
posint() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
case "$MESH" in v2|v3) ;; *) die "run.env: MESH=$MESH (v2 or v3)" ;; esac
case "$JOB" in gate|forward|t4|inversion) ;; *) die "run.env: JOB=$JOB (gate, forward, t4 or inversion)" ;; esac
posint "$RANKS" && posint "$THREADS" || die "run.env: RANKS=$RANKS THREADS=$THREADS (whole numbers >= 1)"
[ $(( RANKS * THREADS )) -le 72 ] || die "run.env: RANKS x THREADS = $(( RANKS * THREADS )) cpus, a node has 72"
[[ "$TIME" =~ ^([0-9]+-)?[0-9]{1,2}:[0-9]{2}:[0-9]{2}$ ]] || die "run.env: TIME=$TIME (HH:MM:SS or D-HH:MM:SS)"
case "$PARTITION" in
  icelake) NODE_MB=254952; MEMOPT=() ;;              # the 04/06 headers' --mem=254952M (72 x 3541 MiB)
  highmem) NODE_MB=1945600; MEMOPT=(--mem=1900G) ;;  # 72 x 27126 MiB per node; 2.5 SU per cpu-hour
  *) die "run.env: PARTITION=$PARTITION (icelake or highmem)" ;;
esac
if [ "$JOB" = gate ]; then
  [[ "$START_RHO" =~ ^[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$ ]] && awk -v r="$START_RHO" 'BEGIN {exit !(r + 0 > 0)}' \
    || die "run.env: JOB=gate needs START_RHO=<ohm-m> > 0 (got $START_RHO)"
else
  [ "$START_RHO" = none ] || die "run.env: START_RHO=$START_RHO is for JOB=gate only; JOB=$JOB needs START_RHO=none"
fi
if [ "$JOB" = inversion ]; then
  posint "$ITER_STEP" && posint "$ITER_MAX" || die "run.env: JOB=inversion needs ITER_STEP and ITER_MAX (whole numbers)"
else
  [ "$ITER_STEP" = none ] && [ "$ITER_MAX" = none ] || die "run.env: ITER_STEP and ITER_MAX are for JOB=inversion only; JOB=$JOB needs none"
fi
# NIV: run.env decides, for the layout rule here and for the job (a NIV in the login shell is dropped)
if [ "$NIVV" = none ]; then unset NIV; else posint "$NIVV" || die "run.env: NIV=$NIVV (a whole number >= 1, or none)"; NIV=$NIVV; fi
if [ "$MAIL" = none ]; then MAILOPT=(--mail-type=NONE)
else [[ "$MAIL" =~ ^[^@,]+@[^@,]+$ ]] || die "run.env: MAIL=$MAIL (an email address, or none)"; MAILOPT=(--mail-type=END,FAIL --mail-user="$MAIL"); fi

# ---------------------------------------------------------------- earlier jobs, the run's own files, the shared mesh
PREV=$(sed -nE 's/^job ([0-9]+) submitted.*/\1/p' "$RD/RUN.md" 2>/dev/null | tr '\n' ' ')
[ -z "$PREV" ] || [ "$AGAIN" = 1 ] || die "$RUN already has job(s) ${PREV% } in RUN.md. See: bash $KIT/status.sh $RUN. To submit it again: bash $KIT/run.sh $RUN --again"
for f in control.dat observe.dat; do [ -s "$RD/$f" ] || die "$RD/$f is missing or empty"; done
grep -qE '^END([[:space:]]|$)' "$RD/control.dat" || die "$RD/control.dat has no END line"
if [ "$JOB" = t4 ]; then
  IT=$(femtic_ctl_get "$RD/control.dat" ITERATION | awk '{print $1, $2}')
  [ "$IT" = "0 1" ] || die "JOB=t4 needs ITERATION 0 1 in control.dat (it says '$IT')"
fi
[ -x "$BIN/femtic" ] && [ -s "$BIN/femtic_env.sh" ] \
  || die "no FEMTIC at $BIN (femtic or femtic_env.sh missing or not readable): RUNBOOK S1 links \$VF/bin to a FEMTIC build; or set BIN=<a femtic bin folder>"
SM=$SHARED/mesh_$MESH
for f in mesh.dat resistivity_block_iter0.dat; do
  [ -s "$SM/$f" ] || die "shared mesh file $SM/$f is missing or empty: WinSCP mesh/vulcan_$MESH/inversion/$f there (once)"
  [ ! -e "$RD/$f" ] || [ -L "$RD/$f" ] || die "$RD/$f is a file, not the link run.sh makes: delete it (the mesh comes from $SM)"
done

# ---------------------------------------------------------------- layout rule (silent unless it refuses), before any link
ERRF=$(mktemp 2>/dev/null) || ERRF=/tmp/run_sh_$$.err
if ! femtic_mem_model "$RD" "$SM" > /dev/null 2> "$ERRF"; then
  M=$(cat "$ERRF"); rm -f "$ERRF"; die "the memory model is incomplete: $M"
fi
rm -f "$ERRF"
LC=$(femtic_layout_check "$RANKS" "$FM_FWD_MB" "$FM_NONP_MB" "$NODE_MB" 2>&1) \
  || die "$LC. Use fewer ranks per node (RANKS in run.env; v2 3 x 24, v3 2 x 36 on icelake) or PARTITION=highmem"

# ---------------------------------------------------------------- links to the shared mesh
if [ "$(cd "$RUNS/.." && pwd -P)" = "$(cd "$SHARED/.." && pwd -P)" ]; then T=../../${SHARED##*/}/mesh_$MESH; else T=$SM; fi
for f in mesh.dat resistivity_block_iter0.dat; do
  ln -sfn "$T/$f" "$RD/$f" && [ -s "$RD/$f" ] || die "cannot link $RD/$f -> $T/$f"
done

# ---------------------------------------------------------------- submit
cd "$RD" || die "cannot cd to $RD"
SB=(-J "$RUN" -p "$PARTITION" --ntasks-per-node="$RANKS" --cpus-per-task="$THREADS" --time="$TIME" "${MEMOPT[@]}" "${MAILOPT[@]}")
EXP="ALL,KIT=$KIT,BIN=$BIN${NIV:+,NIV=$NIV}"
case "$JOB" in
  gate)    OUT=$(sbatch --parsable "${SB[@]}" --export="$EXP,START_RHO=$START_RHO" "$KIT/06_forward_only.slurm") ;;
  forward) OUT=$(sbatch --parsable "${SB[@]}" --export="$EXP" "$KIT/06_forward_only.slurm") ;;
  t4)      OUT=$(sbatch --parsable "${SB[@]}" --export="$EXP,WATCH_S=10" "$KIT/04_inversion.slurm") ;;
  inversion)
    LAST=$(femtic_last_iter "$RD"); LAST=${LAST:-0}
    K=$(( (ITER_MAX - LAST + ITER_STEP - 1) / ITER_STEP ))
    [ "$K" -ge 1 ] || die "model $LAST already reaches ITER_MAX=$ITER_MAX"
    OUT=$(KIT="$KIT" BIN="$BIN" SBATCH_EXTRA="${SB[*]}" SBATCH_EXPORT_EXTRA="${NIV:+NIV=$NIV}" \
          bash "$KIT/05_chain.sh" "$RD" "$K" "$ITER_STEP" "$ITER_MAX" 2>&1)
    echo "$OUT"
    OUT=$(sed -n 's/^submitted: *\([0-9 ]*\).*/\1/p' <<< "$OUT" | tail -1) ;;
esac
IDS=$(echo "$OUT" | awk '{for (i = 1; i <= NF; i++) {id = $i; sub(/;.*/, "", id); if (id !~ /^[0-9]+$/) exit 1; printf "%s%s", (n++ ? " " : ""), id}}') \
  && [ -n "$IDS" ] || die "submission failed: no job id (sbatch's message is above)${OUT:+; it printed: $OUT}"

# ---------------------------------------------------------------- record
NOW=$(date '+%F %T')
WHAT="JOB=$JOB"; [ "$JOB" = gate ] && WHAT="$WHAT START_RHO=$START_RHO"
for id in $IDS; do
  echo "job $id submitted $NOW (run.sh: $WHAT, ${RANKS}x$THREADS, --time=$TIME, -p $PARTITION, kit $(femtic_kit_version))" >> "$RD/RUN.md"
done
IDX=$RUNS/INDEX.md
[ -s "$IDX" ] || printf '# Runs\n\n| run | mesh | purpose | layout | job id(s) | verdict |\n|---|---|---|---|---|---|\n' > "$IDX"
if ! grep -q "^| $RUN |" "$IDX"; then
  P=$(sed -n 's/^- purpose: //p' "$RD/RUN.md" 2>/dev/null | head -1 | tr '|' '/')
  echo "| $RUN | $MESH | ${P:--} | ${RANKS}x$THREADS | - | - |" >> "$IDX"
fi
awk -v r="$RUN" -v ids="$IDS" 'BEGIN {FS = OFS = "|"}
     $2 == " " r " " { j = $6; gsub(/^ +| +$/, "", j); $6 = " " ((j == "-" || j == "") ? ids : j " " ids) " " } {print}' \
  "$IDX" > "$IDX.tmp" && mv -f "$IDX.tmp" "$IDX"
echo "$RUN: submitted job $IDS ($WHAT, mesh $MESH, ${RANKS}x$THREADS, --time=$TIME)"
echo "status: bash $KIT/status.sh $RUN"
