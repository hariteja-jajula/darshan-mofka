#!/usr/bin/env bash
# build_view.sh — reproducible build of the Mofka/Mochi Spack view from the pinned spec.
# Wraps server/spack/README.md into one runnable script. Produces a `view` symlink here.
#
# ~30-90 min on a Polaris login node (-j4; higher trips the login fork cap). On a compute
# node you may raise SPACK_JOBS. Requires network (clones spack + 3 package repos + mofka).
#
#   bash build_view.sh                 # full build from spack.lock
#   SPACK_JOBS=8 bash build_view.sh    # on a compute node
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_NAME="flowcept-mofka-polaris"
SPACK_JOBS="${SPACK_JOBS:-4}"
MOFKA_SRC="${MOFKA_SRC:-$HERE/../../mofka}"     # develop.mofka.path target (relative in spack.yaml)

source /etc/profile 2>/dev/null || true
module swap PrgEnv-nvidia PrgEnv-gnu 2>/dev/null || true

# 1. spack (reuse a clone if SPACK_ROOT is set + valid)
if [ -z "${SPACK_ROOT:-}" ] || [ ! -f "$SPACK_ROOT/share/spack/setup-env.sh" ]; then
  SPACK_ROOT="$HERE/spack"
  [ -d "$SPACK_ROOT" ] || { echo "[view] cloning spack"; git clone --depth=1 https://github.com/spack/spack.git "$SPACK_ROOT"; }
fi
. "$SPACK_ROOT/share/spack/setup-env.sh"
echo "[view] spack $(spack --version)"

# 2. mofka source checkout (develop spec — the connector patch rides this)
if [ ! -d "$MOFKA_SRC/.git" ]; then
  echo "[view] cloning mofka source -> $MOFKA_SRC"
  git clone https://github.com/mochi-hpc/mofka.git "$MOFKA_SRC" || {
    echo "[view] WARN: mofka clone failed; edit spack.yaml develop.mofka.path manually"; }
fi

# 3. create + activate the env from the pinned spec, build
if ! spack env list 2>/dev/null | grep -q "$ENV_NAME"; then
  echo "[view] creating env $ENV_NAME from spack.yaml (spack.lock pins exact versions)"
  spack env create "$ENV_NAME" "$HERE/spack.yaml"
fi
spack env activate "$ENV_NAME"
echo "[view] spack install -j$SPACK_JOBS (this is the long step)"
spack install -j"$SPACK_JOBS" || { echo "[view] FAIL: spack install"; exit 1; }

# 4. expose a stable ./view symlink for env.sh / setup.sh to point at
VIEW="$(spack location --env "$ENV_NAME")/.spack-env/view"
ln -sfn "$VIEW" "$HERE/view"
[ -e "$HERE/view/bin/bedrock" ] && echo "[view] OK -> $HERE/view (bedrock present)" \
  || { echo "[view] FAIL: no bedrock in view"; exit 1; }
