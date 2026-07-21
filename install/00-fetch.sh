#!/bin/bash
# install/00-fetch.sh -- PHASE 1 (LOGIN NODE): download everything to eagle.
#
# Polaris compute nodes have NO internet, so all network fetches happen here on a
# login node. Everything lands under the repo (which is on eagle) so the compute
# node build phase can proceed offline.
#
# Fetches:
#   - git submodules (darshan, diaspora-stream-api, flowcept)
#   - spack (pinned ref) + `spack fetch` all sources for the env (offline-buildable)
#   - the conda mongodb env (mongod) at a prefix on eagle
#   - python wheels for the consumer venv (downloaded, installed in build phase)
#
# Usage (login node, repo root):  bash install/00-fetch.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
require_login_node
cd "$REPO_ROOT"

# ---- 0. submodules -----------------------------------------------------------
say "submodules"
git submodule update --init --recursive

# ---- 1. spack: clone at the EXACT commit that wrote spack.lock (v6) -----------
SPACK_DIR="$(layout_path spack_dir)"
SPACK_URL="$(cfg spack.git_url)"
SPACK_COMMIT="$(cfg spack.git_commit)"
SPACK_REF="$(cfg spack.git_ref)"
if [[ ! -d "$SPACK_DIR/.git" ]]; then
    say "clone spack -> $SPACK_DIR (pin commit ${SPACK_COMMIT:0:12})"
    git clone "$SPACK_URL" "$SPACK_DIR" || die "spack clone failed"
    if [[ -n "$SPACK_COMMIT" ]]; then
        if ! git -C "$SPACK_DIR" checkout -q "$SPACK_COMMIT" 2>/dev/null; then
            echo "[install] WARN: commit $SPACK_COMMIT not found; falling back to $SPACK_REF"
            git -C "$SPACK_DIR" checkout -q "$SPACK_REF" || die "spack checkout failed"
        fi
    fi
else
    say "spack already cloned at $SPACK_DIR ($(git -C "$SPACK_DIR" rev-parse --short HEAD))"
fi
say "spack at $(git -C "$SPACK_DIR" rev-parse --short HEAD)"
# shellcheck disable=SC1091
source "$SPACK_DIR/share/spack/setup-env.sh"

ENV_NAME="$(cfg layout.spack_env_name)"
ENV_LOCK="$REPO_ROOT/$(cfg spack.env_lock)"
ENV_SPEC="$REPO_ROOT/$(cfg spack.env_spec)"
if ! spack env list 2>/dev/null | grep -qx "$ENV_NAME"; then
    if [[ -s "$ENV_LOCK" ]]; then
        say "create spack env '$ENV_NAME' from pinned lock"
        spack env create "$ENV_NAME" "$ENV_LOCK" || die "spack env create (lock) failed"
    else
        say "create spack env '$ENV_NAME' from spec"
        spack env create "$ENV_NAME" "$ENV_SPEC" || die "spack env create (spec) failed"
    fi
fi
say "spack fetch (download all sources for offline build)"
spack -e "$ENV_NAME" concretize -f || die "spack concretize failed"
spack -e "$ENV_NAME" fetch || echo "[install] WARN: spack fetch had misses (some pkgs fetch at build)"

# ---- 2. mongodb (conda env on eagle) -----------------------------------------
MONGO_ENV="$(layout_path mongo_env_dir)"
if [[ -x "$MONGO_ENV/bin/mongod" ]]; then
    say "mongod already present at $MONGO_ENV/bin/mongod"
elif command -v conda >/dev/null 2>&1; then
    say "conda create mongodb=$(cfg mongo.version) -> $MONGO_ENV"
    conda create -y -p "$MONGO_ENV" -c "$(cfg mongo.channel)" \
        "$(cfg mongo.package)=$(cfg mongo.version)" || die "conda mongodb create failed"
else
    die "conda not found; needed to create the mongod env (or install mongod to $MONGO_ENV manually)"
fi

# ---- 3. python venv + download wheels ----------------------------------------
# We create the venv here (login node) so pip can reach PyPI; the build phase just
# reuses it. Built on the spack view's python (matches the consumer runtime).
# shellcheck disable=SC1091
source "$REPO_ROOT/server/env.sh" --polaris 2>/dev/null || true
VENV="$(layout_path venv_dir)"
REQS="$REPO_ROOT/$(cfg python.requirements)"
if [[ ! -x "$VENV/bin/python" ]]; then
    say "create venv -> $VENV (on ${PY:-python3})"
    "${PY:-python3}" -m venv "$VENV" || die "venv create failed"
fi
say "pip install consumer deps + flowcept (editable)"
"$VENV/bin/python" -m pip install --upgrade pip >/dev/null
"$VENV/bin/python" -m pip install -r "$REQS" || die "pip install requirements failed"
"$VENV/bin/python" -m pip install -e "$REPO_ROOT/$(cfg python.flowcept_editable)" \
    || die "pip install -e flowcept failed"

say "FETCH PHASE COMPLETE. Next: on a COMPUTE node run  bash install/10-build.sh"
