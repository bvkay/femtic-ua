#!/bin/bash
# =============================================================================
# pc_scripts_test.sh -- developer test (PC, Git Bash) of the two PC-side scripts of the student workflow:
#   scripts/make_phoenix_kit.sh  K: refuses a dirty hpc/phoenix_plan; exports exactly HEAD's kit files minus the
#                                   export-ignore ones, byte for byte, plus a 4-line VERSION naming HEAD
#   scripts/make_run.sh          M: refusals; the run folder's files, run.env, RUN.md and INDEX.md line; --niv, --mail
#   both, then the kit's run.sh  E: the exported kit accepts a made run folder and the repo's own runs/Run01-03 and
#                                   submits them (fake sbatch) with the flags each run intends
# It never commits in the repository it tests: it clones it (git clone -q) into WORK, copies the working-tree versions
# of hpc/phoenix_plan, scripts/make_*.sh, .gitattributes and .gitignore over the clone, and commits there.
#   bash pc_scripts_test.sh [REPO]      REPO default: the repository that holds this script
#   env: WORK=<dir> (default mktemp -d)
# Every check prints its failure criterion ("fails if ...") first; refusals come before the passing cases.
# Exit 0 only if every check passes.
# =============================================================================
REPO=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
REPO=$(cd "$REPO" && pwd) || exit 2
WORK=${WORK:-$(mktemp -d)}; mkdir -p "$WORK" || exit 2; WORK=$(cd "$WORK" && pwd)
echo "pc_scripts_test: REPO=$REPO  WORK=$WORK  bash $BASH_VERSION  $(git --version)"
npass=0; nfail=0
crit() { echo; echo "CHECK $1: fails if $2"; }
ok()   { echo "  PASS $*"; npass=$((npass + 1)); }
bad()  { echo "  FAIL $*"; nfail=$((nfail + 1)); }
eq()   { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got '$2', want '$3'"; fi; }
has()  { if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1: '$3' found"; else bad "$1: '$3' not in $2"; fi; }
hasnt(){ if grep -qF -- "$3" "$2" 2>/dev/null; then bad "$1: '$3' present in $2"; else ok "$1: no '$3'"; fi; }

# ---------------------------------------------------------------- the clone, with the working tree's kit committed
C=$WORK/clone; rm -rf "$C"
git clone -q -c core.longpaths=true "$REPO" "$C" || { echo "cannot clone $REPO"; exit 2; }   # longpaths: Windows MAX_PATH
rm -rf "$C/hpc/phoenix_plan"; mkdir -p "$C/hpc/phoenix_plan"
( cd "$REPO/hpc/phoenix_plan" && tar -cf - --exclude=__pycache__ . ) | tar -xf - -C "$C/hpc/phoenix_plan"
cp "$REPO/scripts/make_phoenix_kit.sh" "$REPO/scripts/make_run.sh" "$C/scripts/"
cp "$REPO/.gitattributes" "$REPO/.gitignore" "$C/"
[ -d "$REPO/runs" ] && { rm -rf "$C/runs"; cp -r "$REPO/runs" "$C/runs"; }
gitc() { git -C "$C" -c user.name=kit-test -c user.email=kit-test@localhost "$@"; }
gitc add -A >/dev/null && gitc commit -q -m "pc_scripts_test: working tree" >/dev/null || { echo "commit in the clone failed"; exit 2; }
HEADS=$(git -C "$C" rev-parse --short HEAD); BRANCH=$(git -C "$C" rev-parse --abbrev-ref HEAD)
echo "clone HEAD $HEADS on $BRANCH"
mk() { NK=$((NK + 1)); OUT=$WORK/kit_$NK.out; ( bash "$C/scripts/make_phoenix_kit.sh" > "$OUT" 2>&1 ); RC=$?; }
NK=0; KO=$C/export/kit

# ================================================================ K: make_phoenix_kit.sh
crit K1 "make_phoenix_kit.sh exports while hpc/phoenix_plan has a modified tracked file or an untracked file (must exit 1, say REFUSED and leave export/kit as it was)"
mkdir -p "$KO"; echo old > "$KO/marker"
echo "# local edit" >> "$C/hpc/phoenix_plan/run.sh"; mk
eq "K1 modified: exit" "$RC" 1; has "K1 modified: message" "$OUT" "REFUSED: hpc/phoenix_plan has changes that are not committed"
has "K1 modified: names the file" "$OUT" "hpc/phoenix_plan/run.sh"
eq "K1 modified: export/kit untouched" "$(ls "$KO")" marker
git -C "$C" checkout -q -- hpc/phoenix_plan/run.sh
echo x > "$C/hpc/phoenix_plan/new_untracked.sh"; mk
eq "K1 untracked: exit" "$RC" 1; has "K1 untracked: names the file" "$OUT" "?? hpc/phoenix_plan/new_untracked.sh"
eq "K1 untracked: export/kit untouched" "$(ls "$KO")" marker
rm -f "$C/hpc/phoenix_plan/new_untracked.sh"
crit K2 "with HEAD's .gitattributes lacking the export-ignore lines the kit is exported (tests/, README_phoenix.md, RUNBOOK etc. would go to Phoenix): must exit 1"
cp "$C/.gitattributes" "$WORK/gitattributes.keep"; grep -v export-ignore "$WORK/gitattributes.keep" > "$C/.gitattributes"
gitc commit -q -am "no export-ignore" >/dev/null; mk
eq "K2 exit" "$RC" 1; has "K2 message" "$OUT" "export-ignore did not apply to"
eq "K2 nothing left to upload" "$([ -e "$KO" ] && echo present || echo absent)" absent
cp "$WORK/gitattributes.keep" "$C/.gitattributes"; gitc commit -q -am "export-ignore back" >/dev/null
crit K2b "a kit file committed with CRLF line endings (marked -text, so git keeps the CR bytes) is exported (Phoenix's bash would fail on it): must exit 1 naming the file"
printf '#!/bin/bash\r\necho crlf\r\n' > "$C/hpc/phoenix_plan/crlf_probe.sh"; echo "hpc/phoenix_plan/crlf_probe.sh -text" >> "$C/.gitattributes"
gitc add -A >/dev/null; gitc commit -q -m "crlf probe" >/dev/null; mk
eq "K2b exit" "$RC" 1; has "K2b message" "$OUT" "CRLF line endings in: crlf_probe.sh"
eq "K2b nothing left to upload" "$([ -e "$KO" ] && echo present || echo absent)" absent
git -C "$C" rm -q hpc/phoenix_plan/crlf_probe.sh; cp "$WORK/gitattributes.keep" "$C/.gitattributes"; gitc commit -q -am "crlf probe removed" >/dev/null
HEADS=$(git -C "$C" rev-parse --short HEAD)
crit K3 "on a clean commit the export fails, keeps a stale file, differs from HEAD's hpc/phoenix_plan minus the export-ignore paths (file list, or any byte of any file), has CR bytes, lacks the WinSCP line, or VERSION is not: short sha of HEAD, its commit date, the branch, an export date"
mkdir -p "$KO"; echo stale > "$KO/stale_file"; mk
eq "K3 exit" "$RC" 0
eq "K3 stale file gone" "$([ -e "$KO/stale_file" ] && echo present || echo absent)" absent
git -C "$C" ls-tree -r --name-only HEAD hpc/phoenix_plan | sed 's|^hpc/phoenix_plan/||' \
  | grep -vE '^(tests/|README_phoenix\.md$|RUNBOOK|UPLOAD_LIST|build_.*\.log$|discovery/)' | sort > "$WORK/want_files.txt"
( cd "$KO" && find . -type f ! -name VERSION | sed 's|^\./||' | sort ) > "$WORK/got_files.txt"
eq "K3 file list = HEAD minus export-ignore ($(wc -l < "$WORK/want_files.txt" | tr -d ' ') files)" "$(diff "$WORK/want_files.txt" "$WORK/got_files.txt" | grep -c '^[<>]')" 0
nd=0; while read -r f; do git -C "$C" show "HEAD:hpc/phoenix_plan/$f" | cmp -s - "$KO/$f" || { nd=$((nd + 1)); echo "  differs: $f"; }; done < "$WORK/got_files.txt"
eq "K3 files differing from HEAD" "$nd" 0
for f in run.sh status.sh femtic_lib.sh 04_inversion.slurm 05_chain.sh 06_forward_only.slurm tools/halfspace_eval.py; do
  eq "K3 has $f" "$([ -s "$KO/$f" ] && echo yes || echo no)" yes
done
eq "K3 CR bytes in the kit (tr count)" "$(find "$KO" -type f -exec cat {} + | tr -cd '\r' | wc -c | tr -d ' ')" 0
eq "K3 VERSION lines" "$(wc -l < "$KO/VERSION" | tr -d ' ')" 4
eq "K3 VERSION sha" "$(sed -n 1p "$KO/VERSION")" "$HEADS"
eq "K3 VERSION commit date" "$(sed -n 2p "$KO/VERSION")" "$(git -C "$C" log -1 --format=%cd --date=format:'%Y-%m-%d %H:%M')"
eq "K3 VERSION branch" "$(sed -n 3p "$KO/VERSION")" "$BRANCH"
eq "K3 VERSION export date is a date" "$(sed -n 4p "$KO/VERSION" | grep -cE '^20[0-9]{2}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$')" 1
has "K3 WinSCP line" "$OUT" "WinSCP: delete the folder /hpcfs/users/<your user>/vulcan_femtic/kit on Phoenix, then copy"
hasnt "K3 no md5 anywhere in the output" "$OUT" "md5"
. "$KO/femtic_lib.sh"
eq "K3 femtic_kit_banner of the export" "$(femtic_kit_banner "$KO")" "KIT VERSION: $HEADS ($(sed -n 2p "$KO/VERSION"))"

# ================================================================ M: make_run.sh
MR=$WORK/runs; rm -rf "$MR"
DATA=mesh/vulcan_v2_rot/inversion
mr() { NM=$((NM + 1)); OUT=$WORK/mr_$NM.out; ( cd "$C" && RUNS="$MR" bash scripts/make_run.sh "$@" > "$OUT" 2>&1 ); RC=$?; }
NM=0
G=(--mesh v2 --data "$DATA" --job gate --start-rho 100 --layout 3x24 --time 02:00:00 --purpose "gate test | 100 ohm-m")
crit M1 "make_run.sh accepts a bad run name, a gate without --start-rho, a missing --purpose, a 9x9 layout, or a --data folder without station_map.csv (each: exit 1 and no folder)"
mr run1 "${G[@]}"; eq "M1 name: exit" "$RC" 1; has "M1 name" "$OUT" "Run01, Run02"
mr Run01 --mesh v2 --data "$DATA" --job gate --layout 3x24 --time 02:00:00 --purpose p; eq "M1 no --start-rho: exit" "$RC" 1; has "M1 no --start-rho" "$OUT" "--job gate needs --start-rho"
mr Run01 --mesh v2 --data "$DATA" --job gate --start-rho 100 --layout 3x24 --time 02:00:00; eq "M1 no --purpose: exit" "$RC" 1; has "M1 no --purpose" "$OUT" "--purpose"
mr Run01 --mesh v2 --data "$DATA" --job gate --start-rho 100 --layout 9x9 --time 02:00:00 --purpose p; eq "M1 9x9: exit" "$RC" 1; has "M1 9x9" "$OUT" "81 cpus"
mkdir -p "$WORK/nosmap"; cp "$C/$DATA/control.dat" "$C/$DATA/observe.dat" "$WORK/nosmap/"
mr Run01 --mesh v2 --data "$WORK/nosmap" --job gate --start-rho 100 --layout 3x24 --time 02:00:00 --purpose p
eq "M1 no station_map.csv: exit" "$RC" 1; has "M1 no station_map.csv" "$OUT" "station_map.csv is missing or empty"
eq "M1 no run folder made" "$([ -e "$MR/Run01" ] && echo made || echo none)" none
crit M2 "a gate run folder is not made, its three data files differ from --data's, run.env is not the nine expected lines plus NIV=none and MAIL=none, RUN.md / INDEX.md miss the purpose, the data source or the half-space note, or RUN.md records the PC's git state (a '- kit:' line or the HEAD sha $HEADS: the job log's KIT VERSION line is the record)"
mr Run01 "${G[@]}"
eq "M2 exit" "$RC" 0
for f in control.dat observe.dat station_map.csv; do eq "M2 $f = --data's" "$(cmp -s "$C/$DATA/$f" "$MR/Run01/$f" && echo same || echo differs)" same; done
eq "M2 run.env" "$(grep -v '^#' "$MR/Run01/run.env" | tr '\n' ' ')" "MESH=v2 JOB=gate START_RHO=100 RANKS=3 THREADS=24 TIME=02:00:00 PARTITION=icelake ITER_STEP=none ITER_MAX=none NIV=none MAIL=none "
has "M2 RUN.md purpose" "$MR/Run01/RUN.md" "- purpose: gate test | 100 ohm-m"
has "M2 RUN.md data" "$MR/Run01/RUN.md" "- data: $DATA (control.dat, observe.dat, station_map.csv copied from there)"
hasnt "M2 RUN.md: no kit line" "$MR/Run01/RUN.md" "- kit:"
hasnt "M2 RUN.md: no PC git sha" "$MR/Run01/RUN.md" "$HEADS"
has "M2 RUN.md note" "$MR/Run01/RUN.md" "The data values in observe.dat do not matter, only its sites and frequencies."
has "M2 RUN.md jobs heading" "$MR/Run01/RUN.md" "## Jobs"
has "M2 INDEX.md line ('|' in the purpose replaced)" "$MR/INDEX.md" "| Run01 | v2 | gate test / 100 ohm-m | 3x24 | - | - |"
crit M3 "make_run.sh reuses an existing run name (must exit 1 and leave Run01 as it was)"
S1=$(cat "$MR/Run01/run.env" "$MR/Run01/RUN.md" | cksum)
mr Run01 --mesh v3 --data "$DATA" --job forward --layout 2x36 --time 04:00:00 --purpose other
eq "M3 exit" "$RC" 1; has "M3 message" "$OUT" "exists already"
eq "M3 Run01 unchanged" "$(cat "$MR/Run01/run.env" "$MR/Run01/RUN.md" | cksum)" "$S1"
eq "M3 INDEX.md lines for Run01" "$(grep -c '^| Run01 |' "$MR/INDEX.md")" 1
crit M4 "a t4 run's control.dat is not --data's with exactly the ITERATION value changed to '0 1'"
mr Run03 --mesh v2 --data "$DATA" --job t4 --layout 3x24 --time 12:00:00 --purpose "T4 test"
eq "M4 exit" "$RC" 0
eq "M4 ITERATION" "$(femtic_ctl_get "$MR/Run03/control.dat" ITERATION)" "0 1"
eq "M4 lines changed" "$(diff "$C/$DATA/control.dat" "$MR/Run03/control.dat" | grep -c '^>')" 1
eq "M4 source ITERATION (control)" "$(femtic_ctl_get "$C/$DATA/control.dat" ITERATION)" "0 10"
crit M5 "make_run.sh accepts --niv 0 or --mail nobody (each: exit 1, no folder), or with --niv 840 --mail a.student@example.edu does not write NIV=840 and MAIL=a.student@example.edu into run.env and NIV=840 into RUN.md's layout line"
mr Run05 --mesh v2 --data "$DATA" --job t4 --layout 3x24 --time 12:00:00 --purpose p --niv 0
eq "M5 --niv 0: exit" "$RC" 1; has "M5 --niv 0" "$OUT" "--niv N, a whole number >= 1"
mr Run05 --mesh v2 --data "$DATA" --job t4 --layout 3x24 --time 12:00:00 --purpose p --mail nobody
eq "M5 --mail nobody: exit" "$RC" 1; has "M5 --mail nobody" "$OUT" "--mail ADDRESS, an email address"
eq "M5 no run folder made" "$([ -e "$MR/Run05" ] && echo made || echo none)" none
mr Run05 --mesh v2 --data "$DATA" --job t4 --layout 3x24 --time 12:00:00 --purpose "T4 with N_iv 840" --niv 840 --mail a.student@example.edu
eq "M5 exit" "$RC" 0
eq "M5 run.env NIV and MAIL" "$(grep -E '^(NIV|MAIL)=' "$MR/Run05/run.env" | tr '\n' ' ')" "NIV=840 MAIL=a.student@example.edu "
has "M5 RUN.md layout line" "$MR/Run05/RUN.md" "- layout: 3 ranks x 24 threads per node, --time=12:00:00, partition icelake, NIV=840"

# ================================================================ E: exported kit + run folders -> run.sh -> sbatch
VF=$WORK/vf; rm -rf "$VF"; mkdir -p "$VF/shared/mesh_v2" "$VF/runs" "$VF/bin" "$WORK/fbin"
cp -r "$KO" "$VF/kit"
printf '#!/bin/bash\nexit 0\n' > "$VF/bin/femtic"; chmod +x "$VF/bin/femtic"; echo "# stand-in" > "$VF/bin/femtic_env.sh"   # S1's $VF/bin
awk 'BEGIN { print "TETRA"; print "      1000"; for (i = 0; i < 1000; i++) printf "%10d 0 0 0\n", i; print "      5000" }' > "$VF/shared/mesh_v2/mesh.dat"
awk 'BEGIN { printf "%10d%10d\n", 2, 2; print "0 0"; print "1 1"; print "0 1e9 1e-20 1e20 1 1"; print "1 20 1e-20 1e20 1 0" }' > "$VF/shared/mesh_v2/resistivity_block_iter0.dat"
printf '#!/bin/bash\necho "$*" >> "%s/sbatch_calls.txt"\necho $(( 8000 + $(wc -l < "%s/sbatch_calls.txt") ))\n' "$WORK" "$WORK" > "$WORK/fbin/sbatch"
chmod +x "$WORK/fbin/sbatch"; : > "$WORK/sbatch_calls.txt"
rs() { NE=$((NE + 1)); OUT=$WORK/rs_$NE.out; ( env "PATH=$WORK/fbin:$PATH" VF="$VF" MSYS=winsymlinks:native bash "$VF/kit/run.sh" "$@" > "$OUT" 2>&1 ); RC=$?; }
NE=0
crit E1 "the exported kit's run.sh refuses the gate folder make_run.sh made, or does not submit it with its own run.env's layout and START_RHO"
cp -r "$MR/Run01" "$VF/runs/"; rs Run01
eq "E1 exit" "$RC" 0
eq "E1 sbatch arguments" "$(tail -1 "$WORK/sbatch_calls.txt")" "--parsable -J Run01 -p icelake --ntasks-per-node=3 --cpus-per-task=24 --time=02:00:00 --mail-type=NONE --export=ALL,KIT=$VF/kit,BIN=$VF/bin,START_RHO=100 $VF/kit/06_forward_only.slurm"
crit E3 "the exported kit's run.sh does not submit the --niv 840 --mail run make_run.sh made (M5) with --mail-type=END,FAIL --mail-user=a.student@example.edu and NIV=840 in --export"
cp -r "$MR/Run05" "$VF/runs/"; rs Run05
eq "E3 exit" "$RC" 0
eq "E3 sbatch arguments" "$(tail -1 "$WORK/sbatch_calls.txt")" "--parsable -J Run05 -p icelake --ntasks-per-node=3 --cpus-per-task=24 --time=12:00:00 --mail-type=END,FAIL --mail-user=a.student@example.edu --export=ALL,KIT=$VF/kit,BIN=$VF/bin,NIV=840,WATCH_S=10 $VF/kit/04_inversion.slurm"
crit E2 "the repo's runs/Run01-03 (Ben's first gate and T4 runs) are not accepted by the exported kit's run.sh, or are not submitted as: Run01 v2 gate 100 ohm-m and Run02 v2 gate 3 ohm-m (06, 3 x 24, 02:00:00), Run03 v2 T4 (04, 3 x 24, 12:00:00, WATCH_S=10)"
if [ -d "$C/runs/Run01" ] && [ -d "$C/runs/Run02" ] && [ -d "$C/runs/Run03" ]; then
  rm -rf "$VF/runs"; mkdir -p "$VF/runs"; cp -r "$C/runs/Run01" "$C/runs/Run02" "$C/runs/Run03" "$VF/runs/"
  for r in 01 02 03; do
    rs "Run$r"; eq "E2 Run$r exit" "$RC" 0
    case $r in
      01) want="--export=ALL,KIT=$VF/kit,BIN=$VF/bin,START_RHO=100 $VF/kit/06_forward_only.slurm"; t=02:00:00 ;;
      02) want="--export=ALL,KIT=$VF/kit,BIN=$VF/bin,START_RHO=3 $VF/kit/06_forward_only.slurm"; t=02:00:00 ;;
      03) want="--export=ALL,KIT=$VF/kit,BIN=$VF/bin,WATCH_S=10 $VF/kit/04_inversion.slurm"; t=12:00:00 ;;
    esac
    eq "E2 Run$r sbatch arguments" "$(tail -1 "$WORK/sbatch_calls.txt")" "--parsable -J Run$r -p icelake --ntasks-per-node=3 --cpus-per-task=24 --time=$t --mail-type=NONE $want"
    eq "E2 Run$r data = mesh/vulcan_v2_rot/inversion" "$(for f in observe.dat station_map.csv; do cmp -s "$C/$DATA/$f" "$VF/runs/Run$r/$f" || echo "$f differs"; done)" ""
  done
  eq "E2 Run03 ITERATION" "$(femtic_ctl_get "$VF/runs/Run03/control.dat" ITERATION)" "0 1"
  for r in 01 02; do has "E2 Run$r RUN.md half-space note" "$C/runs/Run$r/RUN.md" "do not matter, only its sites and frequencies"; done
  for r in 01 02 03; do hasnt "E2 Run$r RUN.md: no PC git state" "$C/runs/Run$r/RUN.md" "- kit:"; done
else
  bad "E2 runs/Run01, Run02 and Run03 are not all in $REPO/runs"
fi

echo; echo "SUMMARY: $npass passed, $nfail failed   (REPO=$REPO)"
[ "$nfail" = 0 ]
