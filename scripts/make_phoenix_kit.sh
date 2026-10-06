#!/bin/bash
# =============================================================================
# make_phoenix_kit.sh -- export the Phoenix kit from the last commit (PC, Git Bash):
#     bash scripts/make_phoenix_kit.sh
# Writes export/kit/ (that fixed name, emptied and refilled every time) from 'git archive HEAD hpc/phoenix_plan',
# flattened: the scripts sit directly in export/kit/, plus tools/. Left out by export-ignore in .gitattributes:
# tests/, README_phoenix.md, RUNBOOK*, UPLOAD_LIST*, build logs, discovery/, __pycache__ (none of them is needed on
# Phoenix). It adds export/kit/VERSION, four lines: git short sha, commit date, branch, export date. Every job prints
# "KIT VERSION: <sha> (<commit date>)" from it, so a job log names the commit it ran.
# REFUSES (exit 1) when hpc/phoenix_plan has uncommitted or untracked changes: the kit is always a commit.
# Then copy export/kit to Phoenix with WinSCP, as printed at the end. No manifest, no md5.
# =============================================================================
set -o pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
cd "$REPO" || exit 1
git rev-parse --verify -q HEAD > /dev/null || { echo "make_phoenix_kit.sh: $REPO is not a git checkout with a commit" >&2; exit 1; }
DIRTY=$(git status --porcelain -- hpc/phoenix_plan)
if [ -n "$DIRTY" ]; then
  echo "make_phoenix_kit.sh: REFUSED: hpc/phoenix_plan has changes that are not committed:" >&2
  echo "$DIRTY" | sed 's/^/    /' >&2
  echo "Commit them (or undo them) and run this again: the kit must be a commit, so that its VERSION names it." >&2
  exit 1
fi
OUT=$REPO/export/kit
fail() { rm -rf "$OUT"; echo "make_phoenix_kit.sh: $* -- no kit written (export/kit removed)" >&2; exit 1; }
rm -rf "$OUT" && mkdir -p "$OUT" || fail "cannot empty $OUT"
git archive --format=tar HEAD hpc/phoenix_plan | tar -x --force-local -C "$OUT" --strip-components=2 \
  || fail "git archive of hpc/phoenix_plan failed"
# what export-ignore should have left out (if it is there, HEAD's .gitattributes lacks the lines)
LEFT=$(cd "$OUT" && ls -d tests README_phoenix.md RUNBOOK* UPLOAD_LIST* build_*.log discovery 2>/dev/null | tr '\n' ' ')
[ -z "$LEFT" ] || fail "export-ignore did not apply to: $LEFT(HEAD's .gitattributes)"
for f in femtic_lib.sh run.sh status.sh 04_inversion.slurm 06_forward_only.slurm tools/halfspace_eval.py; do
  [ -s "$OUT/$f" ] || fail "$f is not in HEAD's hpc/phoenix_plan"
done
# CR bytes counted with tr: Git Bash's grep drops a CR pattern in some contexts and then matches every file
CR=$(find "$OUT" -type f | while read -r f; do [ "$(tr -cd '\r' < "$f" | wc -c)" -eq 0 ] || printf '%s ' "${f#"$OUT"/}"; done)
[ -z "$CR" ] || fail "CRLF line endings in: $CR(Phoenix's bash cannot run them)"
{ git rev-parse --short HEAD
  git log -1 --format=%cd --date=format:'%Y-%m-%d %H:%M'
  git rev-parse --abbrev-ref HEAD
  date '+%Y-%m-%d %H:%M'; } > "$OUT/VERSION"
# the Windows form of the path (Git Bash's builtin 'pwd -W'; anaconda ships a cygpath that maps /d/... wrongly)
WOUT=$(cd "$OUT" && pwd -W 2>/dev/null) || WOUT=$OUT
echo "kit exported to $WOUT ($(find "$OUT" -type f | wc -l | tr -d ' ') files)"
paste -d' ' <(printf '%s\n' "  sha:" "  commit date:" "  branch:" "  exported:") "$OUT/VERSION"
echo "WinSCP: delete the folder /hpcfs/users/<your user>/vulcan_femtic/kit on Phoenix, then copy $WOUT into"
echo "        /hpcfs/users/<your user>/vulcan_femtic/ (so it becomes .../vulcan_femtic/kit)."
