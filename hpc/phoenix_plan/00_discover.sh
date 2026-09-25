#!/bin/bash -l
# =============================================================================
# 00_discover.sh -- Phoenix (University of Adelaide) environment discovery for FEMTIC
#
# Run ONCE on the Phoenix LOGIN node, from a directory under /hpcfs:
#     bash -l 00_discover.sh
# Output: ./phoenix_discovery_<hostname>.txt  (also echoed to the terminal)
#
# Read-only: modules are loaded only inside sub-shells, and nothing is submitted.
# ("sbatch --test-only" validates a request and prints an estimated start time;
# it does not create a job.) Every command tolerates failure (|| true), so the
# script always runs to the end and records what is and is not available.
# The "KEY FINDINGS" block at the end is summarised in README_phoenix.md section 12; what is still
# unverified is listed at the end of section 10.
#
# RUN ONCE ALREADY: p2-log-2, 2026-09-25, from /hpcfs/users/a1690074/FEMTIC_2026. The output is kept in
# phoenix_plan/discovery/phoenix_discovery_p2-log-2_2026-09-25.txt. Re-run only to re-check after a
# Phoenix software or Slurm change, and compare with that file. Results of that run, in brief:
#   * Lmod 8.2.10; foss/2023a + imkl/2023.1.0 load together (MKLROOT=/apps/icl/software/imkl/2023.1.0/
#     mkl/2023.1.0); intel/2023a loads, with mpiicpc but no mpiicpx / mpiicx.
#   * icelake 93 x 72 cpu, 255,000 MiB, MaxMemPerCPU 3541, CPU=1.20; a100cpu MaxCPUsPerNode=36,
#     MaxMemPerCPU 7152 (a job gets <= 36 cpus / 257,472 MiB per node); highmem 7 x 72 cpu,
#     MaxMemPerCPU 27126, CPU=2.5; srun --mpi=list: pmi2, none, cray_shasta (no pmix).
#   * git 2.27, curl and internet on the login node; micromamba 2.9.0 already under /hpcfs.
# =============================================================================

OUT="$PWD/phoenix_discovery_$(hostname -s 2>/dev/null || hostname).txt"
exec > >(tee "$OUT") 2>&1

# 'module' is a shell function; make sure it exists even if started with plain 'bash'
if ! type module >/dev/null 2>&1; then
  for f in /etc/profile.d/lmod.sh /etc/profile.d/z00_lmod.sh /etc/profile.d/modules.sh /usr/share/lmod/lmod/init/bash; do
    if [ -f "$f" ]; then . "$f" >/dev/null 2>&1 && break; fi
  done
fi

section() { echo; echo "=================================================================="; echo "## $*"; echo "=================================================================="; }
run() { echo; echo "\$ $*"; "$@" 2>&1 || echo "   [exit $? -- failed or not available]"; }
KEY=()                              # one-line findings, printed at the end
key() { KEY+=("$*"); }

# -----------------------------------------------------------------------------
section "Host / OS"
run hostname
run date
grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release 2>&1 || true
echo "USER=$USER  HOME=$HOME  PWD=$PWD"
echo "TMPDIR on this (login) node: ${TMPDIR:-<unset>}   (in jobs, \$TMPDIR exists only with --gres=tmpfs:<N>G)"

# -----------------------------------------------------------------------------
section "Module system"
run module --version
echo "MODULEPATH=$MODULEPATH"
echo "LMOD_VERSION=${LMOD_VERSION:-<unset>}"
IS_LMOD=0
if [ -n "${LMOD_VERSION:-}" ] || module --version 2>&1 | grep -qi lmod; then IS_LMOD=1; fi
if [ "$IS_LMOD" = 1 ]; then key "module system: Lmod ${LMOD_VERSION:-?}"; else key "module system: NOT Lmod (unexpected: the 2026-09-25 census showed Lmod)"; fi

# -----------------------------------------------------------------------------
section "module avail foss imkl intel GCC OpenMPI impi (the toolchain question)"
echo "\$ module avail foss imkl intel GCC OpenMPI impi"
module avail foss imkl intel GCC OpenMPI impi 2>&1 || true
echo
echo "--- terse listing (one module per line) of the toolchain pieces ---"
TERSE=$(module -t avail 2>&1 | grep -iE '^(foss|gompi|iimpi|intel|intel-compilers|imkl|imkl-FFTW|GCC|GCCcore|OpenMPI|impi|UCX|PMIx|FlexiBLAS|EasyBuild)/' || true)
echo "$TERSE"
for m in foss/2023a imkl/2023.1.0 intel/2023a GCC/12.3.0 OpenMPI/4.1.5-GCC-12.3.0 impi/2021.9.0-intel-compilers-2023.1.0; do   # all listed on 2026-09-25
  if echo "$TERSE" | grep -qx "$m"; then key "module $m: listed"; else key "module $m: NOT listed under that exact name (see module avail above)"; fi
done
echo
echo "--- other modules of interest ---"
module -t avail 2>&1 | grep -iE '^(CMake|Anaconda3|Python|git|zlib)/' || true

# -----------------------------------------------------------------------------
section "module spider (Lmod)"
if [ "$IS_LMOD" = 1 ]; then
  echo "\$ module spider imkl"
  module spider imkl 2>&1 | head -60 || true
  for m in foss intel impi OpenMPI; do
    echo; echo "\$ module spider $m | head -30"
    module spider "$m" 2>&1 | head -30 || true
  done
  for m in imkl/2023.1.0 foss/2023a intel/2023a; do
    echo; echo "\$ module spider $m | head -25"
    module spider "$m" 2>&1 | head -25 || true
  done
else
  echo "Not Lmod: 'module spider' unavailable."
fi

# -----------------------------------------------------------------------------
section "Toolchain load tests (sub-shells; nothing persists)"
echo "--- A: module load foss/2023a imkl/2023.1.0   (TOOLCHAIN=foss in 01_build_femtic.sh) ---"
A=$( (
  module purge >/dev/null 2>&1
  module load foss/2023a imkl/2023.1.0 >/dev/null 2>&1 || exit 9
  echo "LOADED"
  module -t list 2>&1 | tr '\n' ' '; echo
  echo "MKLROOT=${MKLROOT:-<unset>}"
  ls -d "${MKLROOT:-/nonexistent}/lib/intel64" "${MKLROOT:-/nonexistent}/lib" 2>/dev/null | tr '\n' ' '; echo
  ls "${MKLROOT:-/nonexistent}/lib/intel64/libmkl_intel_ilp64.so" "${MKLROOT:-/nonexistent}/lib/intel64/libmkl_gnu_thread.so" 2>&1
  echo "mpicxx=$(command -v mpicxx)  g++=$(g++ -dumpfullversion 2>/dev/null)"
  mpicxx -showme 2>&1 | head -1
  ompi_info 2>/dev/null | grep -iE 'Open MPI:|slurm|pmix' | head -8
) 2>&1 )
echo "$A"
case "$A" in
  *LOADED*) key "foss/2023a + imkl/2023.1.0: loads OK; $(echo "$A" | grep -m1 '^MKLROOT=')" ;;
  *)        key "foss/2023a + imkl/2023.1.0: FAILED (it loaded on 2026-09-25: module retired? try another generation from 'module avail', or the EasyBuild fallback)" ;;
esac
# (The former test A2 loaded a toolchain-suffixed imkl variant; no such module exists on Phoenix
#  (2026-09-25 run printed nothing), so it was removed. imkl/2023.1.0 is the only imkl 2023.1.0 module.)
echo
echo "--- B: module load intel/2023a   (TOOLCHAIN=intel) ---"
B=$( (
  module purge >/dev/null 2>&1
  module load intel/2023a >/dev/null 2>&1 || exit 9
  echo "LOADED"
  module -t list 2>&1 | tr '\n' ' '; echo
  echo "MKLROOT=${MKLROOT:-<unset>}  I_MPI_ROOT=${I_MPI_ROOT:-<unset>}"
  for c in icpc icpx mpiicpc mpiicpx mpiicx; do printf '%-8s %s\n' "$c" "$(command -v "$c" || echo MISSING)"; done
  icpc --version 2>&1 | head -1
  icpx --version 2>&1 | head -1
  mpiicpc -show 2>&1 | head -1
  echo "I_MPI_ROOT/bin: $(cd "${I_MPI_ROOT:-/nonexistent}/bin" 2>/dev/null && echo mpi*)"
) 2>&1 )
echo "$B"
case "$B" in
  *LOADED*) key "intel/2023a: loads OK; mpiicpc=$(echo "$B" | awk '$1=="mpiicpc"{print $2}') mpiicpx=$(echo "$B" | awk '$1=="mpiicpx"{print $2}') (2026-09-25: mpiicpx MISSING; 01 uses 'mpiicpc -cxx=icpx')" ;;
  *)        key "intel/2023a: FAILED to load (it loaded on 2026-09-25)" ;;
esac

# -----------------------------------------------------------------------------
section "EasyBuild -- central easyconfig search (fallback route only)"
EBMOD=$(module -t avail EasyBuild 2>&1 | grep -E '^EasyBuild/' | tail -1)
echo "EasyBuild modules: $(module -t avail EasyBuild 2>&1 | grep -E '^EasyBuild/' | tr '\n' ' ')"
if [ -n "$EBMOD" ] && ( module load "$EBMOD" >/dev/null 2>&1 ); then
  module load "$EBMOD" >/dev/null 2>&1
  run eb --version
  echo "\$ eb --show-config | head -30"; eb --show-config 2>&1 | head -30 || true
  echo; echo "\$ eb -S imkl-2023";                eb -S imkl-2023 2>&1 | tail -30 || true
  echo; echo "\$ eb -S intel-2023";               eb -S intel-2023 2>&1 | tail -30 || true
  echo; echo "\$ eb -S foss-2023";                eb -S foss-2023 2>&1 | tail -30 || true
  echo; echo "\$ eb -S impi-2021.9";              eb -S impi-2021.9 2>&1 | tail -10 || true
  if eb -S 'imkl-2023.1.0' 2>&1 | grep -q 'imkl-2023.1.0.eb'; then
    key "$EBMOD: loads; imkl-2023.1.0.eb found by eb -S"
  else
    key "$EBMOD: loads; imkl-2023.1.0.eb NOT found by eb -S (read the output above)"
  fi
  module unload "$EBMOD" >/dev/null 2>&1 || true
else
  echo "   [no loadable EasyBuild module]"
  key "EasyBuild: no loadable module (${EBMOD:-none listed})"
fi
if [ -d "/hpcfs/users/$USER/easybuild" ]; then echo "(user EasyBuild prefix /hpcfs/users/$USER/easybuild exists)"; else echo "(no /hpcfs/users/$USER/easybuild yet)"; fi

# -----------------------------------------------------------------------------
section "SLURM associations, fair-share, QoS"
run sacctmgr -P show assoc user="$USER" format=account,partition,qos%40,fairshare,grptres%40,maxtres%40,maxwall
run sshare -U
run sacctmgr show qos format=name,maxwall,maxtrespu%30,maxtres%30,maxjobspu,priority
ACCS=$(sacctmgr -nP show assoc user="$USER" format=account 2>/dev/null | sort -u | tr '\n' ' ')
key "SLURM accounts for $USER: ${ACCS:-<none shown>}  (expected: physci; -A needed only if more than one)"

# -----------------------------------------------------------------------------
section "Quotas: /home and /hpcfs"
run rcquota
run df -h "/home/$USER" "/hpcfs/users/$USER"
echo "\$ command -v rcstat rcquota"; command -v rcstat rcquota 2>&1 || true

# -----------------------------------------------------------------------------
section "Partitions and memory per cpu (RAM is granted per cpu)"
run sinfo -p icelake,newicelake,a100cpu,highmem,interactive,dm -o '%P %a %l %D %c %m %G'
echo
echo "--- per-partition memory / billing settings (scontrol show partition) ---"
for p in icelake a100cpu highmem interactive; do
  scontrol show partition "$p" 2>&1 | grep -oE 'PartitionName=[^ ]+|DefMemPerCPU=[^ ]+|MaxMemPerCPU=[^ ]+|DefMemPerNode=[^ ]+|MaxMemPerNode=[^ ]+|MaxTime=[^ ]+|MaxCPUsPerNode=[^ ]+|TRESBillingWeights=[^ ]+|QoS=[^ ]+|OverSubscribe=[^ ]+' | tr '\n' ' '
  echo
done
echo
echo "\$ scontrol show config | grep -iE 'MemPerCPU|MemPerNode|SelectTypeParameters|TaskPlugin|MpiDefault|PriorityWeightTRES|AccountingStorageTRES|KillWait'"
scontrol show config 2>&1 | grep -iE 'MemPerCPU|MemPerNode|SelectTypeParameters|TaskPlugin|MpiDefault|PriorityWeightTRES|AccountingStorageTRES|KillWait' || true
for p in icelake a100cpu highmem; do
  key "$p memory/billing: $(scontrol show partition "$p" 2>/dev/null | grep -oE '(Def|Max)MemPer(CPU|Node)=[^ ]+|TRESBillingWeights=[^ ]+' | tr '\n' ' ')"
done
echo
echo "--- one icelake node ---"
N1=$(sinfo -p icelake -h -o '%N' 2>/dev/null | head -1)
if [ -n "$N1" ]; then
  scontrol show node "$(scontrol show hostnames "$N1" 2>/dev/null | head -1)" 2>&1 | grep -oE 'NodeName=[^ ]+|CPUTot=[^ ]+|RealMemory=[^ ]+|TmpDisk=[^ ]+|Gres=[^ ]+|AvailableFeatures=[^ ]+|Sockets=[^ ]+|CoresPerSocket=[^ ]+|ThreadsPerCore=[^ ]+' | tr '\n' ' '
  echo
fi
echo; echo "\$ srun --mpi=list"; srun --mpi=list 2>&1 || true
key "srun MPI plugins: $(srun --mpi=list 2>&1 | grep -oE 'pmix[^ ]*|pmi2|cray_shasta' | sort -u | tr '\n' ' ')"

# -----------------------------------------------------------------------------
section "Request validation with 'sbatch --test-only' (nothing is submitted)"
tst() {   # tst <label> <sbatch options...>
  local label=$1; shift
  local r
  r=$(sbatch --test-only "$@" --wrap=true 2>&1 | tail -1)
  echo "[$label] sbatch --test-only $* -> $r"
  case "$r" in
    *"to start at"*) key "request accepted : $label" ;;
    *)               key "request REJECTED : $label -> $r" ;;
  esac
}
tst "04 default: icelake 1 node 8x9 --mem=254952M (72 x 3541) tmpfs:200G 3 days" -p icelake -N 1 --ntasks-per-node=8 --cpus-per-task=9 --mem=254952M --gres=tmpfs:200G --time=3-00:00:00
tst "icelake 1 node --mem=250G (256000 MiB > 254952, expect REJECT)" -p icelake -N 1 --ntasks-per-node=8 --cpus-per-task=9 --mem=250G --time=1:00:00
tst "icelake 36 cpus --mem=254952M (over 36 x 3541, expect REJECT or cpus raised)" -p icelake -N 1 --ntasks-per-node=4 --cpus-per-task=9 --mem=254952M --time=1:00:00
# a100cpu has MaxCPUsPerNode=36, so this 72-cpu request must be REJECTED (it was on 2026-09-25: QOS policy).
# The kit does not use a100cpu (36 cpus, <= 257,472 MiB: icelake's RAM with half the cores); kept as a regression check.
tst "a100cpu 72 cpus --mem=514944M (MaxCPUsPerNode=36, expect REJECT)" -p a100cpu -N 1 --ntasks-per-node=8 --cpus-per-task=9 --mem=514944M --gres=tmpfs:200G --time=3-00:00:00
tst "04 alt: highmem 1 node 8x9 --mem=1900G 3 days" -p highmem -N 1 --ntasks-per-node=8 --cpus-per-task=9 --mem=1900G --time=3-00:00:00
tst "06 forward-only: icelake 1 node 8x9 --mem=254952M 2 h" -p icelake -N 1 --ntasks-per-node=8 --cpus-per-task=9 --mem=254952M --time=02:00:00
tst "03 mesh: icelake 1 task x 8 cpus --mem=27G 2 h" -p icelake -N 1 -n 1 -c 8 --mem=27G --time=02:00:00
tst "03 mesh: interactive 1 task x 8 cpus --mem=27G 2 h" -p interactive -N 1 -n 1 -c 8 --mem=27G --time=02:00:00
tst "icelake 2 nodes 8x9 --mem=254952M 3 days" -p icelake -N 2 --ntasks-per-node=8 --cpus-per-task=9 --mem=254952M --time=3-00:00:00

# -----------------------------------------------------------------------------
section "CPU (this is the LOGIN node p2-log-2: Xeon Platinum 8360Y, SMT on; icelake compute nodes: 72 cores, SMT off)"
lscpu 2>&1 | grep -E 'Model name|^CPU\(s\)|Thread\(s\) per core' || true
if lscpu 2>&1 | grep -qi avx512; then echo "login node has AVX-512"; else echo "login node: no AVX-512 flag"; fi
run nproc

# -----------------------------------------------------------------------------
section "Misc: git, curl, internet (for 01 FETCH_ONLY=1 and 02)"
echo "TMPDIR=${TMPDIR:-<unset>}"
run gcc --version
run git --version
run curl --version
key "git on login node: $(git --version 2>/dev/null || echo 'absent (01 then downloads GitHub archives with curl)')"
echo "\$ curl -sI --max-time 10 https://github.com"
curl -sI --max-time 10 https://github.com 2>&1 | head -1 || true
key "internet from login node: github HTTP $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://github.com 2>/dev/null || echo fail), micro.mamba.pm HTTP $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://micro.mamba.pm 2>/dev/null || echo fail), conda-forge HTTP $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://conda.anaconda.org/conda-forge/ 2>/dev/null || echo fail)"
run ulimit -s

# -----------------------------------------------------------------------------
section "Python route (02_env_femticpy.sh uses micromamba under /hpcfs)"
MMB="/hpcfs/users/$USER/micromamba/bin/micromamba"
if [ -x "$MMB" ]; then
  echo "micromamba: $("$MMB" --version 2>&1)   envs:"; "$MMB" env list 2>&1 | tail -n +1 || true
  key "micromamba present at $MMB (env femticpy: $("$MMB" env list 2>/dev/null | awk '{print $1}' | grep -qx femticpy && echo yes || echo not yet))"
else
  key "micromamba NOT installed at $MMB -- 02_env_femticpy.sh installs it"
fi
echo "(fallback only) Anaconda modules: $(module -t avail Anaconda3 2>&1 | grep -E '^Anaconda3/' | tr '\n' ' ')"

# -----------------------------------------------------------------------------
section "KEY FINDINGS (see README_phoenix.md, sections 10 and 12)"
for k in "${KEY[@]}"; do echo " * $k"; done
echo
echo "Discovery written to: $OUT"
exit 0
