#!/usr/bin/env bash
# =============================================================================
# 02_env_femticpy.sh -- create the "femticpy" Python environment on Phoenix with micromamba
#
# Run once on the LOGIN node or in an interactive-partition job (both have internet; compute nodes
# may not):     bash 02_env_femticpy.sh
#               PYVISTA=1 bash 02_env_femticpy.sh     # also install pyvista (pulls VTK, ~0.5-1 GB)
#               UPDATE=1  bash 02_env_femticpy.sh     # re-solve an existing env against the yml
#
# Same route as Ben's PRISM bootstrap (3D_Joint_Inversion_2026/benchmarks/phoenix/bootstrap_env.sh):
#   * micromamba static binary under /hpcfs/users/$USER/micromamba (MAMBA_ROOT_PREFIX); nothing under
#     /home (10 GB cap), no root, no 'conda init', no ~/.condarc edits. The PRISM env gjoint lives
#     under the same root; this script only adds the env femticpy.
#   * the env is created from environment_femticpy.yml, written next to this script if absent
#     (edit it and delete the env, or run UPDATE=1, to change packages). conda-forge only.
#   * idempotent: re-running skips what is installed and re-runs the self-test.
#
# State on Phoenix (00_discover.sh on p2-log-2, 2026-09-25): micromamba 2.9.0 is ALREADY at
# /hpcfs/users/a1690074/micromamba/bin/micromamba with the envs base and gjoint; femticpy does not exist.
# Code path on the first run there: step 2 finds $MM executable and skips the download (no curl);
# step 3 parses 'micromamba env list' (first column; the same parse gave "not yet" in 00_discover.sh
# against micromamba 2.9.0's table output), does not find femticpy and creates only that env from the
# yml; base and gjoint are not touched. Re-runs take the "env femticpy exists -- skipping create" branch.
# /hpcfs/users/a1690074 resolves to /scratchdata1/users/a1690074 (gpfs-2-1), so micromamba may print
# /scratchdata1/... paths; the location check in step 3 compares resolved paths for that reason.
# Deliberately no 'set -e' around the activation hooks (micromamba hooks + SIGPIPE abort under -e).
#
# In job scripts and interactive shells:
#     export MAMBA_ROOT_PREFIX=/hpcfs/users/$USER/micromamba
#     eval "$("$MAMBA_ROOT_PREFIX/bin/micromamba" shell hook -s bash)"
#     micromamba activate femticpy
#
# TEST (fails if): any of pandas, numpy, scipy, matplotlib, pyproj, shapely, rdp, tabulate fails to
# import; pandas major version < 2; or pyproj's WGS84 -> UTM zone 53S (EPSG:32753) transform, the
# Vulcan survey's zone, misses either check point: (135 E, 30 S), on the zone's central meridian,
# must give E = 500,000.0 m (+-0.01) and N = 6,681,214.6 m (+-0.5); Vulcan site A1 (136.9748 E,
# 29.8541 S; coordinates rounded to 4 decimals) must land within 10 m of the E 690,761.6 m,
# N 6,695,743.5 m listed in Vulcan/edi_inventory.md. It catches a wrong zone or hemisphere (zone 54S
# puts A1 at E 111,050 m); it cannot tell WGS84 from GDA94 (about 1-2 m apart), so it is not a datum check.
# =============================================================================
set -o pipefail

HPCFS="${HPCFS:-/hpcfs/users/$USER}"
export MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-$HPCFS/micromamba}"
MM="$MAMBA_ROOT_PREFIX/bin/micromamba"
ENV_NAME="${ENV_NAME:-femticpy}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YML="${YML:-$HERE/environment_femticpy.yml}"
FEMTICPY_SRC="${FEMTICPY_SRC:-$HPCFS/femticPy}"   # copy (WinSCP) or checkout of https://github.com/hseille/femticPy; no .git needed

echo "=== femticpy env: root=$MAMBA_ROOT_PREFIX env=$ENV_NAME yml=$YML host=$(hostname) job=${SLURM_JOB_ID:-none} ==="
case "$MAMBA_ROOT_PREFIX" in /home/*) echo "WARNING: MAMBA_ROOT_PREFIX is under /home (10 GB cap); use /hpcfs" ;; esac
if [ -n "${SLURM_JOB_ID:-}" ] && [ "${SLURM_JOB_PARTITION:-}" != interactive ]; then
  echo "WARNING: inside a ${SLURM_JOB_PARTITION:-?} job -- compute nodes may have no internet; use the login node or -p interactive"
fi

# 1) environment_femticpy.yml (written once; the file on disk wins afterwards)
if [ ! -f "$YML" ]; then
  cat > "$YML" <<'YAML'
# environment_femticpy.yml -- written by 02_env_femticpy.sh; used with: micromamba create -n femticpy -f <this file>
name: femticpy
channels:
  - conda-forge
dependencies:
  - python=3.12
  - numpy
  - scipy
  - pandas>=2
  - matplotlib
  - pyproj
  - shapely
  - rdp
  - jupyterlab
  - tabulate
  - pip
# optional (PYVISTA=1 installs it after the env is created): pyvista
YAML
  echo "wrote $YML"
else
  echo "using existing $YML (delete it to regenerate the default)"
fi

# 2) micromamba (static binary; no installer, no root)
if [ ! -x "$MM" ]; then
  echo "=== installing micromamba into $MAMBA_ROOT_PREFIX ==="
  mkdir -p "$MAMBA_ROOT_PREFIX/bin"
  curl -Ls https://micro.mamba.pm/api/micromamba/linux-64/latest | tar -xj -C "$MAMBA_ROOT_PREFIX" bin/micromamba \
    || { echo "micromamba download failed (no internet on this node? run on the login node or -p interactive)"; exit 3; }
fi
"$MM" --version || exit 3
eval "$("$MM" shell hook -s bash)" || { echo "micromamba shell hook failed"; exit 3; }

# 3) the env
if ! "$MM" env list | awk '{print $1}' | grep -qx "$ENV_NAME"; then
  echo "=== creating env $ENV_NAME from $YML ==="
  "$MM" create -y -n "$ENV_NAME" -f "$YML" || { echo "env create FAILED -- read the solver output above"; exit 4; }
elif [ "${UPDATE:-0}" = 1 ]; then
  echo "=== UPDATE=1: installing/updating the yml's packages into $ENV_NAME ==="
  "$MM" install -y -n "$ENV_NAME" -f "$YML" || { echo "env update FAILED"; exit 4; }
else
  echo "env $ENV_NAME exists -- skipping create (UPDATE=1 to re-solve against $YML)"
fi
if [ "${PYVISTA:-0}" = 1 ]; then
  "$MM" install -y -n "$ENV_NAME" -c conda-forge pyvista || echo "(pyvista install failed -- optional)"
fi
micromamba activate "$ENV_NAME" || { echo "activate $ENV_NAME failed"; exit 4; }
echo "python: $(command -v python)"
case "$(readlink -f "$(command -v python)")" in "$(readlink -f "$MAMBA_ROOT_PREFIX")"/*) ;; *) echo "WARNING: env python is not under $MAMBA_ROOT_PREFIX";; esac

# 4) self-test
python - <<'PY' || { echo "ENV TEST: FAIL"; exit 2; }
import pandas, numpy, scipy, matplotlib, pyproj, shapely, rdp, tabulate
assert int(pandas.__version__.split('.')[0]) >= 2, "pandas < 2"
t = pyproj.Transformer.from_crs("EPSG:4326", "EPSG:32753", always_xy=True)   # WGS84 -> WGS84 / UTM zone 53S
x0, y0 = t.transform(135.0, -30.0)          # central meridian of zone 53
assert abs(x0 - 500000.0) < 0.01 and abs(y0 - 6681214.6) < 0.5, ("central-meridian check", x0, y0)
x, y = t.transform(136.9748, -29.8541)      # Vulcan site A1 (edi_inventory.md: E 690761.6, N 6695743.5)
assert abs(x - 690761.6) < 10 and abs(y - 6695743.5) < 10, ("Vulcan A1 check", x, y)
print("pandas", pandas.__version__, "| numpy", numpy.__version__, "| scipy", scipy.__version__,
      "| matplotlib", matplotlib.__version__, "| pyproj", pyproj.__version__, "| shapely", shapely.__version__)
print("ENV TEST: PASS  (135E 30S -> %.2f E %.2f N; Vulcan A1 -> %.1f E %.1f N, UTM 53S)" % (x0, y0, x, y))
PY

# 5) femticPy is a plain package directory (src/femticPy.py, src/MTtools.py; no setup.py/pyproject),
#    so expose it through a .pth file rather than pip install. Works on a git-free copy.
if [ -d "$FEMTICPY_SRC/src" ]; then
  SITE=$(python -c 'import site; print(site.getsitepackages()[0])')
  echo "$FEMTICPY_SRC/src" > "$SITE/femticpy.pth"
  python -c 'import femticPy, MTtools; print("femticPy import OK")' || echo "(femticPy import failed -- check $FEMTICPY_SRC/src)"
else
  echo "-- no femticPy tree at $FEMTICPY_SRC: copy it there with WinSCP (or, on the login node,"
  echo "   git clone https://github.com/hseille/femticPy.git $FEMTICPY_SRC) and re-run"
fi

echo
echo "DONE. JupyterLab on the interactive partition (free; max 8 cpus per job):"
echo "   srun -p interactive -N 1 -n 1 -c 4 --mem=16G --time=08:00:00 --pty bash"
echo "   export MAMBA_ROOT_PREFIX=$MAMBA_ROOT_PREFIX; eval \"\$(\$MAMBA_ROOT_PREFIX/bin/micromamba shell hook -s bash)\""
echo "   micromamba activate $ENV_NAME && jupyter lab --no-browser --ip=\$(hostname) --port=8888"
echo "   then from your PC: ssh -L 8888:<node>:8888 a1690074@<phoenix login host>"
exit 0

# =============================================================================
# FALLBACK A (only if micromamba is refused): the Anaconda module. Anaconda3/2025.06-1 is the
# default in /gpfs/apps/icl/modules/all (module avail, 2026-09-25). Keep pkgs/envs on /hpcfs:
#
#   module load Anaconda3/2025.06-1
#   eval "$(conda shell.bash hook)"
#   mkdir -p /hpcfs/users/$USER/myconda/{pkgs,envs}
#   conda config --prepend pkgs_dirs /hpcfs/users/$USER/myconda/pkgs
#   conda config --prepend envs_dirs /hpcfs/users/$USER/myconda/envs
#   conda env create -n femticpy -f environment_femticpy.yml --override-channels -c conda-forge
#   # in jobs: module load Anaconda3/2025.06-1 && eval "$(conda shell.bash hook)" && conda activate femticpy
#
# FALLBACK B: EasyBuild Python + venv (module name verified in the 2026-09-25 census):
#
#   module load Python/3.11.3-GCCcore-12.3.0
#   python -m venv /hpcfs/users/$USER/local/venvs/femticpy
#   source /hpcfs/users/$USER/local/venvs/femticpy/bin/activate
#   pip install --upgrade pip
#   pip install "pandas>=2" numpy scipy matplotlib pyproj shapely rdp jupyterlab tabulate   # pyvista optional
#   (pyproj and shapely wheels bundle PROJ and GEOS, so no extra modules are needed.)
# =============================================================================
