#!/bin/bash
# install/20-freeze.sh -- PHASE 3: snapshot the EXACT built versions for shipping.
#
# Run after a good build (env sourced). Writes pinned artifacts under install/lock/
# so the build is reproducible to the same versions. Nothing here hardcodes paths:
# it records versions + package names only.
#
# Produces:
#   install/lock/spack.lock         exact spack concretization (copied from env)
#   install/lock/requirements.lock  exact pip freeze of the consumer venv
#   install/lock/mongo.lock.yml     exact conda env export (mongod)
#   install/lock/versions.txt       human summary (toolchain + key component versions)
#
# Usage (compute node, env sourced):  bash install/20-freeze.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
cd "$REPO_ROOT"
LOCK="$INSTALL_DIR/lock"; mkdir -p "$LOCK"

# ---- spack.lock (exact concretization) ---------------------------------------
SPACK_DIR="$(layout_path spack_dir)"
ENV_NAME="$(cfg layout.spack_env_name)"
if [[ -d "$SPACK_DIR/share/spack" ]]; then
    # shellcheck disable=SC1091
    source "$SPACK_DIR/share/spack/setup-env.sh"
    ENV_ROOT="$(spack location -e "$ENV_NAME" 2>/dev/null || true)"
    if [[ -s "$ENV_ROOT/spack.lock" ]]; then
        say "freeze spack.lock"
        cp -v "$ENV_ROOT/spack.lock" "$LOCK/spack.lock"
    fi
fi

# ---- pip freeze (exact consumer deps) ----------------------------------------
VENV="$(layout_path venv_dir)"
PYBIN="$VENV/bin/python"; [[ -x "$PYBIN" ]] || PYBIN="${PY:-python3}"
say "freeze pip requirements"
"$PYBIN" -m pip freeze > "$LOCK/requirements.lock" 2>/dev/null || echo "(pip freeze failed)" > "$LOCK/requirements.lock"

# ---- conda mongo env export --------------------------------------------------
MONGO_ENV="$(layout_path mongo_env_dir)"
if command -v conda >/dev/null 2>&1 && [[ -d "$MONGO_ENV/conda-meta" ]]; then
    say "freeze mongo conda env"
    conda env export -p "$MONGO_ENV" --no-builds > "$LOCK/mongo.lock.yml" 2>/dev/null || true
fi

# ---- human-readable version summary ------------------------------------------
say "write versions.txt"
{
    echo "# frozen $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(hostname -s)"
    echo "## toolchain"
    echo "cc:      $("${CC:-cc}" --version 2>&1 | head -1)"
    echo "cmake:   $(command -v cmake) $(cmake --version 2>&1 | head -1)"
    echo "python:  $("${PY:-python3}" -V 2>&1)"
    echo "mongod:  $("$MONGO_ENV/bin/mongod" --version 2>&1 | head -1)"
    echo "## spack components (view)"
    if [[ -n "${ENV_NAME:-}" ]]; then
        spack -e "$ENV_NAME" find --no-groups 2>/dev/null \
            | grep -iE 'mofka|bedrock|margo|mercury|thallium|warabi|yokan|flock|darshan|diaspora' || true
    fi
    echo "## darshan submodule"
    echo "darshan: $(git -C "$REPO_ROOT/$(cfg project.darshan_dir)" rev-parse --short HEAD 2>/dev/null)"
} > "$LOCK/versions.txt"

say "FREEZE COMPLETE -> $LOCK"
ls -la "$LOCK"
echo
echo "Commit install/lock/ to pin this build. config.yaml keeps names+versions;"
echo "the lock/ files are the exact concretization for byte-for-byte reproduction."
