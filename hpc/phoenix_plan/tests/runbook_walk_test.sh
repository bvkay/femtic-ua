#!/bin/bash
# =============================================================================
# runbook_walk_test.sh -- developer test (PC, Git Bash) of the student runbook hpc/phoenix_plan/RUNBOOK.md. It walks
# the student path in a sandbox, running the runbook's own commands, with the kit's fakes (the fake sbatch, sacct,
# mpirun and femtic of tests/run_sh_test.sh; nothing heavy runs):
#   PC       git clone the repository into WORK, copy the working tree's kit, scripts, runs/ and the runbook archive
#            (docs/dev/phoenix_runbook_2026-09-28) over it, commit there (never in the repository itself), then
#            scripts/make_phoenix_kit.sh (S2) and the runbook's make_run.sh lines
#   Phoenix  a fake VF: S1's command, export/kit copied to $VF/kit (S3), stand-in meshes in $VF/shared (S4), the run
#            folders copied to $VF/runs (R2), run.sh (R3; the fake sbatch runs the job script there and then),
#            status.sh (R4), F2's grep, and S5's mv lines on a separate tree with the old folders. S1's link
#            $VF/bin points at the fake femtic/bin, and run.sh and the jobs take BIN from it (no BIN is passed).
# Every check prints "fails if ...", then runs its failing case (a mutant RUNBOOK, a mutant kit, or the state before
# the step) and must see at least one assertion fail there, then runs the real case, where every assertion must pass.
#   bash runbook_walk_test.sh [REPO]      REPO default: the repository that holds this script
#   env: WORK=<dir> (default mktemp -d); MESH=<dir> (default /d/BEN/FEMTIC_2026/mesh: the real meshes whose paths,
#        sizes and F2 memory figures RUNBOOK.md quotes; read only, by wc and awk); PYTHON=<python 3>
# Windows MAX_PATH: the clone is made with core.longpaths=true, because a long WORK plus the deepest tracked path
# (validation/wsl_2026-09-25/..., 84 characters) passes 260 characters and git then stops with "Filename too long".
# Exit 0 only if every case passes.
# =============================================================================
REPO=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
REPO=$(cd "$REPO" && pwd) || exit 2
WORK=${WORK:-$(mktemp -d)}; mkdir -p "$WORK" || exit 2; WORK=$(cd "$WORK" && pwd)
MESH=${MESH:-/d/BEN/FEMTIC_2026/mesh}
if [ -z "${PYTHON:-}" ]; then
  for p in python3 python; do
    if [ "$("$p" -c 'import sys; print(sys.version_info[0])' 2>/dev/null)" = 3 ]; then PYTHON=$p; break; fi
  done
fi
RB=$REPO/hpc/phoenix_plan/RUNBOOK.md
echo "runbook_walk_test: REPO=$REPO  WORK=$WORK  MESH=$MESH  PYTHON=${PYTHON:-none}  bash $BASH_VERSION"
[ -f "$RB" ] || { echo "no $RB"; exit 2; }

# ---------------------------------------------------------------- reporting: cases (counted) and assertions
npass=0; nfail=0; NA=0; AF=0; IND="    "
crit() { echo; echo "CHECK $1: fails if $2"; }
ok()   { echo "  PASS $*"; npass=$((npass + 1)); }
bad()  { echo "  FAIL $*"; nfail=$((nfail + 1)); }
a_ok() { NA=$((NA + 1)); echo "$IND ok  $*"; }
a_no() { NA=$((NA + 1)); AF=$((AF + 1)); echo "$IND NO  $*"; }
eq()   { if [ "$2" = "$3" ]; then a_ok "$1 ($2)"; else a_no "$1: got '$2', want '$3'"; fi; }
has()  { if grep -qF -- "$3" "$2" 2>/dev/null; then a_ok "$1: '$3'"; else a_no "$1: '$3' not in $(basename "$2")"; fi; }
# failcase DESC FUNC ARGS: the failing case; FUNC must report >= 1 failed assertion. passcase DESC FUNC ARGS: none.
failcase() { local _case=$1; shift; AF=0; echo "  failing case: $_case"; IND="      "; "$@"; IND="    "
  if [ "$AF" -gt 0 ]; then ok "failing case caught ($AF assertion(s) failed): $_case"; else bad "failing case NOT caught: $_case"; fi; }
passcase() { local _case=$1; shift; AF=0; echo "  real case: $_case"; IND="      "; "$@"; IND="    "
  if [ "$AF" -eq 0 ]; then ok "$_case"; else bad "$_case ($AF assertion(s) failed)"; fi; }

# ---------------------------------------------------------------- the runbook's commands
# rbspan FILE TEXT: the first inline `code` span of FILE that contains TEXT
rbspan() { grep -o '`[^`]*`' "$1" | tr -d '`' | grep -F -- "$2" | head -1; }
# rbspanx FILE TEXT: the inline `code` span of FILE that is exactly TEXT (empty if there is none)
rbspanx() { grep -o '`[^`]*`' "$1" | tr -d '`' | grep -xF -- "$2" | head -1; }
# rbblock FILE TEXT: the first ```bash block of FILE that contains TEXT
rbblock() { awk -v want="$2" '/^```bash$/ {on = 1; b = ""; next} /^```$/ && on {on = 0; if (index(b, want)) {printf "%s", b; exit}} on {b = b $0 "\n"}' "$1"; }
# rbmakerun FILE: the make_run.sh lines of FILE's ```bash blocks
rbmakerun() { awk '/^```bash$/ {on = 1; next} /^```$/ {on = 0} on && /^bash scripts\/make_run\.sh Run[0-9]/' "$1"; }
# prb VFDIR RUN CMD [VAR=VALUE ...]: run a runbook command as on Phoenix, with $VF = VFDIR, Ben's femtic/bin = the
# fake BIN (S1 links $VF/bin to it) and RunNN = RUN. Sets RC, OUT (its output) and NSB (sbatch calls it made).
NP=0
prb() {
  local v=$1 r=$2 cmd=$3 n0; shift 3
  cmd=${cmd//'/hpcfs/users/a1690074/femtic/bin'/$BIN}; cmd=${cmd//RunNN/$r}
  NP=$((NP + 1)); OUT=$WORK/prb_$NP.out; n0=$(wc -l < "$WORK/sbatch_calls.txt")
  ( env -u BIN "PATH=$BIN:$PATH" WORK="$WORK" VF="$v" MSYS=winsymlinks:native WATCH_S=1 PYTHON="${PYTHON:-python3}" "$@" \
      timeout 300 bash -c "$cmd" > "$OUT" 2>&1 ); RC=$?
  NSB=$(( $(wc -l < "$WORK/sbatch_calls.txt") - n0 ))
}
# mutrb NAME SED: $WORK/RUNBOOK_NAME.md, a copy of RUNBOOK.md with one sed edit (stops the test if it changes nothing)
mutrb() { sed "$2" "$RB" > "$WORK/RUNBOOK_$1.md"; if cmp -s "$RB" "$WORK/RUNBOOK_$1.md"; then echo "harness: mutant $1 did not apply"; exit 2; fi; }

# ---------------------------------------------------------------- PC: the clone with the working tree committed
C=$WORK/clone; rm -rf "$C"
git clone -q -c core.longpaths=true "$REPO" "$C" || { echo "cannot clone $REPO"; exit 2; }
rm -rf "$C/hpc/phoenix_plan"; mkdir -p "$C/hpc/phoenix_plan"
( cd "$REPO/hpc/phoenix_plan" && tar -cf - --exclude=__pycache__ . ) | tar -xf - -C "$C/hpc/phoenix_plan"
cp "$REPO/scripts/make_phoenix_kit.sh" "$REPO/scripts/make_run.sh" "$C/scripts/" || exit 2
cp "$REPO/.gitattributes" "$REPO/.gitignore" "$C/" || exit 2
rm -rf "$C/runs"; cp -r "$REPO/runs" "$C/runs" || exit 2
A=docs/dev/phoenix_runbook_2026-09-28    # the archive RUNBOOK.md points to (only this folder of docs/dev)
rm -rf "${C:?}/$A"; mkdir -p "$C/docs/dev"; [ -d "$REPO/$A" ] && cp -r "$REPO/$A" "$C/$A"
gitc() { git -C "$C" -c user.name=walk-test -c user.email=walk-test@localhost "$@"; }

# ---------------------------------------------------------------- the kit's fakes (tests/run_sh_test.sh's block)
FAKES=$WORK/fakes.sh; PLAN=$C/hpc/phoenix_plan; BIN=$WORK/bin
sed -n '/^# -* fake bin/,/^chmod +x "\$BIN"\/\*$/p' "$REPO/hpc/phoenix_plan/tests/run_sh_test.sh" > "$FAKES"
for w in 'cat > "$BIN/sbatch"' 'cat > "$BIN/femtic"' 'cat > "$BIN/sacct"' 'chmod +x "$BIN"/*'; do
  grep -qF -- "$w" "$FAKES" || { echo "harness: no '$w' in the fake block of tests/run_sh_test.sh"; exit 2; }
done
# shellcheck disable=SC1090
. "$FAKES"; mkdir -p "$WORK/tmp"; : > "$WORK/sbatch_calls.txt"
# stand-ins for the shared meshes (S4): a 6,000-equation mesh and its 3-block model, as in tests/run_sh_test.sh
standin() {
  local m
  for m in v2 v3; do
    mkdir -p "$1/shared/mesh_$m"
    awk 'BEGIN { print "TETRA"; print "      1000"; for (i = 0; i < 1000; i++) printf "%10d 0 0 0\n", i; print "      5000" }' > "$1/shared/mesh_$m/mesh.dat"
    awk 'BEGIN { printf "%10d%10d\n", 10, 3; for (i = 0; i < 10; i++) printf "%10d%10d\n", i, 1 + i % 2
                 printf "%10d   %.6e   %.6e   %.6e   %.6e%10d\n", 0, 1e9, 1e-20, 1e20, 1, 1
                 for (k = 1; k < 3; k++) printf "%10d   %.6e   %.6e   %.6e   %.6e%10d\n", k, 20, 1e-20, 1e20, 1, 0 }' > "$1/shared/mesh_$m/resistivity_block_iter0.dat"
  done
}
# mkvf NAME CMD [standin]: $WORK/vf_NAME, a Phoenix tree after S1-S3 and R2 ($VF/bin linked to the fake BIN) whose kit has one edit (CMD, run inside
# the kit folder; stops the test if it changes nothing), with S4's stand-in meshes if the third argument is "standin"
mkvf() {
  local d=$WORK/vf_$1; rm -rf "$d"; mkdir -p "$d/shared/mesh_v2" "$d/shared/mesh_v3" "$d/runs"
  MSYS=winsymlinks:native ln -s "$BIN" "$d/bin"
  cp -r "$VF/kit" "$d/kit"; ( cd "$d/kit" && eval "$2" )
  if diff -rq "$VF/kit" "$d/kit" > /dev/null; then echo "harness: kit mutant $1 did not apply"; exit 2; fi
  cp -r "$C/runs/Run01" "$C/runs/Run02" "$C/runs/Run03" "$d/runs/"
  [ -d "$C/runs/Run04" ] && cp -r "$C/runs/Run04" "$d/runs/"
  [ "${3:-}" = standin ] && standin "$d"
}
VF=$WORK/vf; rm -rf "$VF"
# the kit mutants (each run inside a copy of the kit by mkvf)
m_mesh()    { sed -i 's/\[ -s "\$SM\/\$f" \] || die "shared mesh file/true || die "shared mesh file/' run.sh; }
m_key()     { sed -i 's/|| die "run.env has no \$k/|| : "run.env has no $k/' run.sh; }
m_threads() { sed -i 's/--cpus-per-task="\$THREADS"/--cpus-per-task=36/' run.sh; }
m_prev()    { sed -i 's/\[ -z "\$PREV" \] || \[ "\$AGAIN" = 1 \] || die/true || die/' run.sh; }
m_nover()   { rm -f VERSION; }
yn() { [ "$@" ] && echo yes || echo no; }

# ================================================================ PC: S2 and R1
crit C1 "scripts/make_phoenix_kit.sh (S2) exports from uncommitted changes, or on the committed clone does not exit 0 with export/kit holding run.sh, status.sh, 04, 06, femtic_lib.sh and a VERSION whose line 1 is the clone's HEAD sha, or the file count and size differ from S2's 'about 0.2 MB, <n> files'"
c_export() {
  local n b
  ( cd "$C" && bash scripts/make_phoenix_kit.sh > "$WORK/export.out" 2>&1 ); RC=$?
  eq "exit" "$RC" 0
  eq "VERSION line 1 = clone HEAD" "$(sed -n 1p "$C/export/kit/VERSION" 2>/dev/null)" "$(git -C "$C" rev-parse --short HEAD)"
  local f
  for f in run.sh status.sh 04_inversion.slurm 06_forward_only.slurm femtic_lib.sh; do eq "kit has $f" "$(yn -s "$C/export/kit/$f")" yes; done
  n=$(sed -n 's/^kit exported to .* (\([0-9]*\) files)$/\1/p' "$WORK/export.out")
  has "S2 states the file count" "$RB" "about 0.2 MB, ${n:-?} files"
  b=$(find "$C/export/kit" -type f -exec cat {} + 2>/dev/null | wc -c)
  eq "kit size in MB (one decimal)" "$(awk -v b="$b" 'BEGIN {printf "%.1f", b / 1e6}')" 0.2
}
echo probe > "$C/hpc/phoenix_plan/walk_probe.txt"
failcase "the overlaid working tree before the commit, plus an untracked file in hpc/phoenix_plan" c_export
rm -f "$C/hpc/phoenix_plan/walk_probe.txt"
gitc add -A > /dev/null && gitc commit -q -m "runbook_walk_test: working tree" > /dev/null || { echo "commit in the clone failed"; exit 2; }
HEADS=$(git -C "$C" rev-parse --short HEAD)
passcase "export of the committed clone (HEAD $HEADS)" c_export

crit C2 "a make_run.sh line of RUNBOOK.md's code blocks is refused (run from the repository root, as R1 says), or the run.env it writes lacks the line's --mesh, --job, --layout, --time and --start-rho, or there are not 3 such lines (Run04, Run05, Run06)"
c_makerun() {   # c_makerun RUNBOOK RUNSDIR
  local f=$1 rd=$2 line n=0 rc r mesh job lay tm rho
  mkdir -p "$rd"
  while IFS= read -r line; do
    n=$((n + 1))
    ( cd "$C" && RUNS="$rd" bash -c "$line" > "$WORK/mr_$n.out" 2>&1 < /dev/null ); rc=$?
    eval "set -- $line"; shift 2; r=$1; shift; mesh=""; job=""; lay=""; tm=""; rho=none
    while [ $# -ge 2 ]; do case "$1" in --mesh) mesh=$2 ;; --job) job=$2 ;; --layout) lay=$2 ;; --time) tm=$2 ;; --start-rho) rho=$2 ;; esac; shift 2; done
    eq "$r exit" "$rc" 0
    eq "$r run.env" "$(grep -v '^#' "$rd/$r/run.env" 2>/dev/null | tr '\n' ' ')" "MESH=$mesh JOB=$job START_RHO=$rho RANKS=${lay%x*} THREADS=${lay#*x} TIME=$tm PARTITION=icelake ITER_STEP=none ITER_MAX=none NIV=none MAIL=none "
  done < <(rbmakerun "$f")
  eq "make_run.sh lines" "$n" 3
}
mutrb layout 's/--layout 2x36 --time 04:00:00 --purpose "Half-space gate at 100/--layout 2x37 --time 04:00:00 --purpose "Half-space gate at 100/'
failcase "RUNBOOK with Run04's layout 2x37 (74 cpus)" c_makerun "$WORK/RUNBOOK_layout.md" "$WORK/runs_mutant"
passcase "RUNBOOK.md, into the clone's runs/" c_makerun "$RB" "$C/runs"

# ================================================================ Phoenix: S1, S3, R2
crit C3 "RUNBOOK S1's command exits 0 when Ben's femtic/bin has no femtic, or with femtic does not make \$VF/shared/mesh_v2, mesh_v3, runs and the link \$VF/bin through which \$VF/bin/femtic is found"
c_s1() {
  local d
  prb "$1" Run01 "$(rbspan "$RB" 'ln -s /hpcfs/users/a1690074/femtic/bin $VF/bin')"
  eq "exit" "$RC" 0
  for d in shared/mesh_v2 shared/mesh_v3 runs; do eq "made $d" "$(yn -d "$1/$d")" yes; done
  eq "\$VF/bin/femtic through the link" "$(yn -L "$1/bin" -a -x "$1/bin/femtic")" yes
}
mv "$BIN/femtic" "$BIN/femtic.off"
failcase "femtic/bin without femtic" c_s1 "$WORK/vf_nobin"
mv "$BIN/femtic.off" "$BIN/femtic"
passcase "the fake femtic/bin" c_s1 "$VF"

cp -r "$C/export/kit" "$VF/kit"    # S3: the WinSCP copy of export/kit into $VF/
crit C4 "RUNBOOK S3's 'cat \$VF/kit/VERSION' does not print, on line 1, the sha that make_phoenix_kit.sh printed and the clone's HEAD"
c_s3() {
  prb "$1" Run01 "$(rbspanx "$RB" 'cat $VF/kit/VERSION')"
  eq "exit" "$RC" 0
  eq "line 1 = clone HEAD" "$(head -1 "$OUT")" "$HEADS"
  eq "line 1 = the sha S2 printed" "$(head -1 "$OUT")" "$(sed -n 's/^  sha: //p' "$WORK/export.out")"
}
mkvf nover m_nover standin
failcase "a kit copied without VERSION" c_s3 "$WORK/vf_nover"
passcase "export/kit copied to \$VF/kit" c_s3 "$VF"
cp -r "$C/runs/Run01" "$C/runs/Run02" "$C/runs/Run03" "$C/runs/Run04" "$VF/runs/"    # R2: WinSCP of the run folders

# ================================================================ Phoenix: R3 refusals, S4
R3CMD=$(rbspanx "$RB" 'bash $VF/kit/run.sh RunNN'); R4CMD=$(rbspanx "$RB" 'bash $VF/kit/status.sh RunNN')
echo; echo "runbook commands: S1 '$(rbspan "$RB" 'ln -s /hpcfs/users/a1690074/femtic/bin $VF/bin')'  R3 '$R3CMD'  R4 '$R4CMD'"
crit C5 "run.sh Run01 (R3) before S4 (\$VF/shared/mesh_v2 empty) reaches sbatch, links a mesh.dat, or does not name the missing shared file"
c_nomesh() {
  prb "$1" Run01 "$R3CMD"
  eq "exit" "$RC" 1; has "message" "$OUT" "shared mesh file $1/shared/mesh_v2/mesh.dat is missing or empty"; eq "sbatch calls" "$NSB" 0
  eq "no mesh.dat in Run01" "$( { [ -e "$1/runs/Run01/mesh.dat" ] || [ -L "$1/runs/Run01/mesh.dat" ]; } && echo made || echo none)" none
}
mkvf mesh m_mesh
failcase "kit whose run.sh lacks the shared-mesh check" c_nomesh "$WORK/vf_mesh"
passcase "the exported kit, S4 not done" c_nomesh "$VF"

standin "$VF"    # S4: the WinSCP upload of the two meshes, as small stand-ins
crit C6 "run.sh Run01 (R3) with a run.env that has no TIME line reaches sbatch, or does not say 'run.env has no TIME'"
c_nokey() {
  cp "$1/runs/Run01/run.env" "$WORK/run.env.keep"; sed -i '/^TIME=/d' "$1/runs/Run01/run.env"
  prb "$1" Run01 "$R3CMD"
  cp "$WORK/run.env.keep" "$1/runs/Run01/run.env"
  eq "exit" "$RC" 1; has "message" "$OUT" "run.env has no TIME"; eq "sbatch calls" "$NSB" 0
}
mkvf key m_key standin
failcase "kit whose run.sh lacks the nine-keys check" c_nokey "$WORK/vf_key"
passcase "the exported kit" c_nokey "$VF"

# ================================================================ Phoenix: R3 submit, R4 status, R3 again
crit C7 "status.sh Run01 (R4) does not show a jobs line 'COMPLETED exit 0:0', the report's 'GATE (half-space, START_RHO=100): PASS' and Run01's INDEX.md line with a job id"
c_status() {
  prb "$1" Run01 "$R4CMD"
  eq "exit" "$RC" 0
  eq "jobs line" "$(grep -cE '^jobs: +[0-9]+ COMPLETED exit 0:0' "$OUT")" 1
  has "gate line" "$OUT" "GATE (half-space, START_RHO=100): PASS"
  eq "index line with a job id" "$(grep -cE '^index: +\| Run01 \| v2 \| .* \| 3x24 \| [0-9]+ \|' "$OUT")" 1
}
failcase "Run01 before it is submitted" c_status "$VF"

crit C8 "run.sh Run01 (R3) does not reach the fake sbatch exactly once with RUNBOOK F1's layout for Run01 (3x24, 2 h, 100 ohm-m, no mail, S1's \$VF/bin: -J Run01 -p icelake --ntasks-per-node=3 --cpus-per-task=24 --time=02:00:00 --mail-type=NONE ... BIN=\$VF/bin,START_RHO=100 .../06_forward_only.slurm), does not print 2 lines, or the job (run by the fake sbatch) leaves no 'KIT VERSION: <clone HEAD> (' in the first 5 lines of slurm-Run01-<jobid>.out, no logs/ and no job line in RUN.md (what R5 copies back)"
W01='--parsable -J Run01 -p icelake --ntasks-per-node=3 --cpus-per-task=24 --time=02:00:00 --mail-type=NONE --export=ALL,KIT=%s/kit,BIN=%s/bin,START_RHO=100 %s/kit/06_forward_only.slurm'
W02='--parsable -J Run02 -p icelake --ntasks-per-node=3 --cpus-per-task=24 --time=02:00:00 --mail-type=NONE --export=ALL,KIT=%s/kit,BIN=%s/bin,START_RHO=3 %s/kit/06_forward_only.slurm'
W03='--parsable -J Run03 -p icelake --ntasks-per-node=3 --cpus-per-task=24 --time=12:00:00 --mail-type=NONE --export=ALL,KIT=%s/kit,BIN=%s/bin,WATCH_S=10 %s/kit/04_inversion.slurm'
W04='--parsable -J Run04 -p icelake --ntasks-per-node=2 --cpus-per-task=36 --time=04:00:00 --mail-type=NONE --export=ALL,KIT=%s/kit,BIN=%s/bin,START_RHO=100 %s/kit/06_forward_only.slurm'
c_submit() {   # c_submit VFDIR RUN WANT_FORMAT [MOCK]
  local w; w=$(printf -- "$3" "$1" "$1" "$1")
  prb "$1" "$2" "$R3CMD" MOCK_SBATCH_RUN="${4:-0}"
  eq "$2 exit" "$RC" 0; eq "$2 sbatch calls" "$NSB" 1; eq "$2 sbatch arguments" "$(tail -1 "$WORK/sbatch_calls.txt")" "$w"
  eq "$2 prints 2 lines" "$(wc -l < "$OUT" | tr -d ' ')" 2
  JID=$(sed -n "s/^$2: submitted job \([0-9]*\).*/\1/p" "$OUT")
}
c_run01() {
  local so
  c_submit "$1" Run01 "$W01" 1; so=$1/runs/Run01/slurm-Run01-$JID.out
  eq "KIT VERSION in the first 5 lines of slurm-Run01-$JID.out" "$(head -5 "$so" 2>/dev/null | grep -c "KIT VERSION: $HEADS (")" 1
  eq "logs/ with the gate report" "$(yn -s "$1/runs/Run01/logs/fwd0_report_$JID.txt")" yes
  has "RUN.md job line" "$1/runs/Run01/RUN.md" "job $JID submitted"
}
mkvf threads m_threads standin
failcase "kit whose run.sh passes --cpus-per-task=36" c_run01 "$WORK/vf_threads"
failcase "kit copied without VERSION" c_run01 "$WORK/vf_nover"
passcase "the exported kit" c_run01 "$VF"
J01=$JID
crit C7 "(continued) as above, now after Run01's job $J01"
passcase "Run01 after its job" c_status "$VF"

crit C9 "run.sh Run01 (R3) a second time, without --again, reaches sbatch or does not say 'Run01 already has job(s)'"
c_again() { prb "$1" Run01 "$R3CMD"; eq "exit" "$RC" 1; has "message" "$OUT" "Run01 already has job(s)"; eq "sbatch calls" "$NSB" 0; }
mkvf prev m_prev standin; prb "$WORK/vf_prev" Run01 "$R3CMD"
failcase "kit whose run.sh lacks the earlier-job check (Run01 submitted once)" c_again "$WORK/vf_prev"
passcase "the exported kit (Run01 submitted once)" c_again "$VF"

crit C10 "run.sh (R3) does not submit Run02 (3x24, 2 h, 3 ohm-m, 06), Run03 (3x24, 12 h, 04 with WATCH_S=10) and Run04 (the runbook's v3 gate line: 2x36, 04:00:00, 100 ohm-m, 06) with exactly these flags, or RUNBOOK F1 and F2 no longer state '3x24, 2 h' and '3x24, 12 h'"
c_first() {
  has "F1 layout" "$RB" "3x24, 2 h"; has "F2 layout" "$RB" "3x24, 12 h"
  c_submit "$1" Run02 "$W02"; c_submit "$1" Run03 "$W03" 1; c_submit "$1" Run04 "$W04"
}
failcase "kit whose run.sh passes --cpus-per-task=36" c_first "$WORK/vf_threads"
passcase "the exported kit" c_first "$VF"

# ================================================================ F2's grep, S5's mv lines, S4's sizes
crit C11 "a pattern of RUNBOOK F2's grep is not the start of a line that 04_inversion.slurm prints (echo \"<pattern>...), or the grep, run on Run03's job output (the fake sbatch ran 04), shows no OUTCOME, N_iv or 'predicted per rank' line"
c_grep() {   # c_grep RUNBOOK
  local g p
  g=$(rbspan "$1" "grep -E '^OUTCOME"); [ -n "$g" ] || g=$(rbspan "$1" "grep -E '")
  eq "F2 grep found" "$(yn -n "$g")" yes
  while IFS= read -r p; do
    eq "04 prints '$p'" "$(yn "$(grep -cF "echo \"$p" "$VF/kit/04_inversion.slurm")" -ge 1)" yes
  done < <(echo "$g" | sed -n "s/.*grep -E '\([^']*\)'.*/\1/p" | tr '|' '\n' | sed 's/^\^//')
  prb "$VF" Run03 "$g"
  for p in OUTCOME N_iv 'predicted per rank'; do eq "Run03 output: '^$p' lines" "$(yn "$(grep -c "^$p" "$OUT")" -ge 1)" yes; done
}
mutrb grep "s/grep -E '^OUTCOME|/grep -E '^Outcome|/"
failcase "RUNBOOK whose grep asks for '^Outcome'" c_grep "$WORK/RUNBOOK_grep.md"
passcase "RUNBOOK.md on Run03" c_grep "$RB"

crit C12 "RUNBOOK S5's mv lines, run after S1 on a tree with the old folders \$VF/inputs/vulcan_v2 and vulcan_v3, leave a file behind or put one in the wrong mesh folder"
c_legacy() {   # c_legacy RUNBOOK
  local L=$WORK/legacy m f b
  rm -rf "$L"; mkdir -p "$L/shared/mesh_v2" "$L/shared/mesh_v3"
  for m in v2 v3; do mkdir -p "$L/inputs/vulcan_$m"; for f in mesh.dat resistivity_block_iter0.dat; do echo "$m $f" > "$L/inputs/vulcan_$m/$f"; done; done
  b=$(rbblock "$1" 'mv -n'); eq "S5 block found" "$(yn -n "$b")" yes
  prb "$L" Run01 "$b"
  for m in v2 v3; do for f in mesh.dat resistivity_block_iter0.dat; do
    eq "shared/mesh_$m/$f" "$(cat "$L/shared/mesh_$m/$f" 2>/dev/null)" "$m $f"
    eq "inputs/vulcan_$m/$f gone" "$(yn ! -e "$L/inputs/vulcan_$m/$f")" yes
  done; done
}
mutrb legacy 's#\$VF/inputs/vulcan_v3/resistivity_block_iter0.dat \$VF/shared/mesh_v3/#$VF/inputs/vulcan_v3/resistivity_block_iter0.dat $VF/shared/mesh_v2/#'
failcase "RUNBOOK whose v3 line moves into mesh_v2" c_legacy "$WORK/RUNBOOK_legacy.md"
passcase "RUNBOOK.md" c_legacy "$RB"

crit C13 "a byte count in RUNBOOK S4's 'Fails if' line differs from the real file under MESH ($MESH/vulcan_v{2,3}/inversion), or the MB figures (per mesh in the copy table, and the total in S4) are not the real sizes rounded"
c_sizes() {   # c_sizes RUNBOOK
  local line m f s c t tot=0
  line=$(grep '^Fails if: a size differs' "$1")
  for m in v2 v3; do
    t=0
    for f in mesh.dat resistivity_block_iter0.dat; do
      s=$(wc -c < "$MESH/vulcan_$m/inversion/$f" 2>/dev/null | tr -d ' '); s=${s:-0}; t=$((t + s))
      c=$(echo "$s" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')
      eq "$m $f: S4 quotes $c" "$(echo "$line" | grep -oF -- "$c" | head -1)" "$c"
    done
    tot=$((tot + t))
    has "copy table: mesh $m" "$1" "| $(awk -v t="$t" 'BEGIN {printf "%.0f", t / 1e6}') MB |"
  done
  has "S4 total" "$1" "($(awk -v t="$tot" 'BEGIN {printf "%.0f", t / 1e6}') MB, once)"
}
mutrb sizes 's/255,727,272/255,727,273/'
failcase "RUNBOOK with one digit of v2's mesh.dat size changed" c_sizes "$WORK/RUNBOOK_sizes.md"
passcase "RUNBOOK.md against $MESH" c_sizes "$RB"

# ================================================================ every path the runbook names, after the walk
crit C14 "a file or folder that RUNBOOK.md names does not exist after the walk (\$VF/... in the fake Phoenix tree, Ben's /hpcfs/users/a1690074/femtic/bin in the fake BIN, D:\BEN\FEMTIC_2026\mesh\... under MESH, every other PC path in the clone), or fewer than 25 paths were checked. Not checked: names with a <placeholder> (destinations the student creates) and S5's old folders (C12)"
# rbpaths RUNBOOK: the tokens that name a path: $VF/..., /hpcfs/..., /d/..., D:\..., and repo-relative scripts/ runs/
# export/ hpc/ mesh/ docs/ (with / or \)
rbpaths() {
  tr -s ' \t`"(),;|' '\n' < "$1" | sed "s/^'//; s/[.:']*\$//" \
    | grep -E '^(\$VF|/hpcfs/|/d/|D:[\/]|(scripts|runs|export|hpc|mesh|docs)[\/])' | sort -u
}
# mappath TOKEN -> the sandbox path, or SKIP
mappath() {
  local t; t=$(printf '%s' "$1" | tr '\\' '/'); t=${t//RunNN/Run01}
  case "$t" in
    *'<'*|*'>'*|'$VF/inputs/'*|'$VF/inversion/'*) echo SKIP ;;
    '$VF'*) echo "$VF${t#\$VF}" ;;
    '/hpcfs/users/$USER/vulcan_femtic'*) echo "$VF${t#/hpcfs/users/\$USER/vulcan_femtic}" ;;
    '/hpcfs/users/a1690074/femtic/bin'*) echo "$BIN${t#/hpcfs/users/a1690074/femtic/bin}" ;;
    D:/BEN/FEMTIC_2026/mesh/*) echo "$MESH/${t#D:/BEN/FEMTIC_2026/mesh/}" ;;
    D:/BEN/FEMTIC_2026*) echo "$C${t#D:/BEN/FEMTIC_2026}" ;;
    /d/BEN/FEMTIC_2026*) echo "$C${t#/d/BEN/FEMTIC_2026}" ;;
    *) echo "$C/$t" ;;
  esac
}
# exists PATH: PATH (a glob is expanded) names an existing file or folder. Not compgen -G: it returns any
# pattern that ends in "/" as a match, whether or not it exists.
exists() { local IFS=$'\n' x; for x in $1; do [ -e "$x" ] && return 0; done; return 1; }
c_paths() {   # c_paths RUNBOOK
  local t p n=0 s=0
  while IFS= read -r t; do
    p=$(mappath "$t")
    if [ "$p" = SKIP ]; then s=$((s + 1)); echo "$IND --  $t (not checked)"; continue; fi
    n=$((n + 1))
    if exists "${p%/}"; then a_ok "$t"; else a_no "$t: no $p"; fi
  done < <(rbpaths "$1")
  eq "paths checked (>= 25)" "$(yn "$n" -ge 25)" yes
}
mutrb paths1 's#\$VF/kit/status.sh#$VF/kit/state.sh#'
failcase "RUNBOOK naming \$VF/kit/state.sh" c_paths "$WORK/RUNBOOK_paths1.md"
mutrb paths2 's#\$VF/shared/mesh_v2/#$VF/shared/v2/#'
failcase "RUNBOOK naming \$VF/shared/v2/ (a folder, written with its trailing slash)" c_paths "$WORK/RUNBOOK_paths2.md"
passcase "RUNBOOK.md" c_paths "$RB"

# ================================================================ F2's memory figures against the real meshes
crit C15 "RUNBOOK F2's 'N forward + N sensitivity-step = N MiB' figures for v2 and v3 differ from what the kit's layout rule computes for the PC's runs/Run03 with the real mesh.dat and resistivity_block_iter0.dat under MESH (femtic_mem_model: no log yet, so 11,000 MiB per 10^6 equations, and N_iv = 4 x the MT stations), i.e. from the line 04 prints in Run03 (v2) or Run06 (v3)"
f2fig() {   # f2fig MESHDIR -> the figure 04's 'predicted per rank (layout rule):' line would show
  ( . "$VF/kit/femtic_lib.sh"; unset NIV NEQ FWD_MB NONPARDISO_MB
    femtic_mem_model "$C/runs/Run03" "$1" > /dev/null 2>&1 && echo "$FM_FWD_MB forward + $FM_NONP_MB sensitivity-step = $(( FM_FWD_MB + FM_NONP_MB )) MiB" )
}
F2V2=$(f2fig "$MESH/vulcan_v2/inversion"); F2V3=$(f2fig "$MESH/vulcan_v3/inversion")
c_f2mem() {   # c_f2mem RUNBOOK
  eq "v2 figure computed" "$(yn -n "$F2V2")" yes; eq "v3 figure computed" "$(yn -n "$F2V3")" yes
  has "F2 quotes v2's '$F2V2'" "$1" "predicted per rank (layout rule): ${F2V2:-?}"
  has "F2 quotes v3's '$F2V3'" "$1" "${F2V3:-?}"
}
mutrb f2 's/= 74469 MiB/= 70754 MiB/'
failcase "RUNBOOK quoting v2's 70,754 MiB (the README's WSL-based figure)" c_f2mem "$WORK/RUNBOOK_f2.md"
passcase "RUNBOOK.md against $MESH" c_f2mem "$RB"

echo; echo "SUMMARY: $npass passed, $nfail failed (cases; $NA assertions)   (REPO=$REPO, clone HEAD $HEADS)"
[ "$nfail" = 0 ]
