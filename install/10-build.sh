#!/bin/bash
# install/10-build.sh -- PHASE 2: compile everything from the fetched sources.
#
# Runs after install/00-fetch.sh. No network needed (sources already on eagle),
# so this works on a compute node. Builds, in order:
#   1. spack env  (bedrock/mochi/mofka/darshan-util deps + cmake) -> view
#   2. diaspora-stream-api  (C API + python) -> its install/
#   3. darshan runtime (non-MPI, Mofka connector) -> darshan/install
#   4. darshan-util (parser + mofka-reconstruct)
#   5. smoke workload
#
# Usage (repo root):  bash install/10-build.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
cd "$REPO_ROOT"

# ---- 1. spack env build ------------------------------------------------------
SPACK_DIR="$(layout_path spack_dir)"
[[ -d "$SPACK_DIR/share/spack" ]] || die "spack not fetched; run install/00-fetch.sh on a login node first"
# shellcheck disable=SC1091
source "$SPACK_DIR/share/spack/setup-env.sh"
ENV_NAME="$(cfg layout.spack_env_name)"
JOBS="$(cfg spack.build_jobs)"
say "spack install (env $ENV_NAME, -j$JOBS)"
spack -e "$ENV_NAME" install -j"$JOBS" || die "spack install failed"
MOFKA_SPACK_VIEW="$(spack location -e "$ENV_NAME")/.spack-env/view"
export MOFKA_SPACK_VIEW
say "spack view: $MOFKA_SPACK_VIEW"

# ---- env: point the demo env at our freshly built view + venv -----------------
export MONGOD="$(layout_path mongo_env_dir)/bin/mongod"
# shellcheck disable=SC1091
source "$REPO_ROOT/server/env.sh" --polaris
module unload darshan 2>/dev/null || true
export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:${PKG_CONFIG_PATH#/soft/perftools/darshan/darshan-3.4.4/lib/pkgconfig:}"

# ---- 2. diaspora-stream-api --------------------------------------------------
DIA="$REPO_ROOT/$(cfg project.diaspora_dir)"
if [[ -e "$DIA/install/include/diaspora/diaspora_c.h" ]]; then
    say "diaspora already installed -> skip"
else
    say "build diaspora-stream-api"
    ( cd "$DIA" \
      && cmake -S . -B _build -DENABLE_C_API=ON -DENABLE_PYTHON=ON \
            -DCMAKE_PREFIX_PATH="$MOFKA_SPACK_VIEW" \
            -DCMAKE_INSTALL_PREFIX="$PWD/install" \
      && cmake --build _build -j && cmake --install _build ) || die "diaspora build failed"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/server/env.sh" --polaris
    module unload darshan 2>/dev/null || true
    export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:${PKG_CONFIG_PATH#/soft/perftools/darshan/darshan-3.4.4/lib/pkgconfig:}"
fi

# ---- 3. darshan runtime (non-MPI) --------------------------------------------
say "build darshan runtime"
( cd "$REPO_ROOT" && ./build.sh ) || die "darshan build failed"
export DARSHAN_PREFIX="$REPO_ROOT/$(cfg layout.darshan_prefix)"
[[ -e "$(darshan_lib)" ]] || die "libdarshan.so missing after build"
say "darshan_lib=$(darshan_lib)"

# ---- 4. darshan-util ---------------------------------------------------------
say "build darshan-util"
( cd "$REPO_ROOT/$(cfg project.darshan_dir)/darshan-util"
  if [[ ! -f _build_util/Makefile ]]; then
      ( cd .. && ./prepare.sh )
      mkdir -p _build_util
      ( cd _build_util && ../configure --prefix="$PWD/../install" )
  fi
  ( cd _build_util && make -j"$JOBS" && make install ) ) || die "darshan-util build failed"

# ---- 5. smoke workload -------------------------------------------------------
say "build smoke workload"
"$CC" -O2 "$REPO_ROOT/workloads/mofka_forward_smoke.c" \
    -o "$REPO_ROOT/workloads/mofka_forward_smoke" || die "workload compile failed"

say "BUILD PHASE COMPLETE."
say "Run the demo:  bash job.sh    (or freeze exact versions: bash install/20-freeze.sh)"
