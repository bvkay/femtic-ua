#!/bin/bash
# =============================================================================
# status.sh -- where a run stands (Phoenix login node):   bash /hpcfs/users/$USER/vulcan_femtic/kit/status.sh Run01
# Prints, for the run folder $RUNS/RunNN (RUNS default /hpcfs/users/$USER/vulcan_femtic/runs):
#   jobs:     Slurm state, exit code and elapsed time of every job RUN.md lists (sacct; squeue if sacct is silent)
#   report:   the last T6 / GATE / RESULT lines of the newest logs/fwd0_report_<jobid>.txt (06: gate and forward)
#   outcome:  the last row of job_outcomes.tsv (04 and 06), and the last femtic.cnv row (t4 and inversion progress)
#   index:    the run's line in runs/INDEX.md
# Reads only; changes nothing. GNU bash 4.4; no python.
# =============================================================================
KIT=${KIT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
VF=${VF:-/hpcfs/users/$USER/vulcan_femtic}
RUNS=${RUNS:-$VF/runs}
RUN=${1%/}; RUN=${RUN##*/}
[ -n "$RUN" ] && [ -d "$RUNS/$RUN" ] || { echo "status.sh: unknown run '${1:-}' (no folder $RUNS/${RUN:-RunNN}); usage: bash $KIT/status.sh RunNN" >&2; exit 1; }
RD=$RUNS/$RUN
echo "== $RUN   ($RD)"
IDS=$(sed -nE 's/^job ([0-9]+) submitted.*/\1/p' "$RD/RUN.md" 2>/dev/null | paste -sd, -)
if [ -z "$IDS" ]; then
  echo "jobs:    none submitted yet (bash $KIT/run.sh $RUN)"
else
  S=$(sacct -X -n -P -j "$IDS" -o JobID,State,ExitCode,Elapsed 2>/dev/null | awk -F'|' 'NF >= 4 {printf "%s%s %s exit %s elapsed %s", (n++ ? "; " : ""), $1, $2, $3, $4}')
  [ -n "$S" ] || S=$(squeue -h -j "$IDS" -o '%i %T elapsed %M' 2>/dev/null | paste -sd';' -)
  echo "jobs:    ${S:-$IDS (no answer from sacct or squeue)}"
fi
R=$(ls -t "$RD"/logs/fwd0_report_*.txt 2>/dev/null | head -1)
if [ -n "$R" ]; then
  echo "report:  ${R#"$RD"/}"
  grep -E '^(T6|GATE|RESULT)' "$R" | tail -3 | sed 's/^/         /'
fi
O=$(awk -F'\t' '$1 != "job_id" && NF >= 9 {r = "job " $1 " (" $2 "): " $6 ", exit " $9} END {print r}' "$RD/job_outcomes.tsv" 2>/dev/null)
[ -n "$O" ] && echo "outcome: $O"
C=$(awk '$1 ~ /^[0-9]+$/ {r = $0} END {print r}' "$RD/femtic.cnv" 2>/dev/null)
[ -n "$C" ] && echo "cnv:     $(echo "$C" | awk '{print "iteration " $1 ", retrial " $2 ", misfit " $6 ", RMS " $7}')"
L=$(grep "^| $RUN |" "$RUNS/INDEX.md" 2>/dev/null)
echo "index:   ${L:-no line for $RUN in $RUNS/INDEX.md}"
