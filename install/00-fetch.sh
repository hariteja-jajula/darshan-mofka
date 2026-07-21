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

# ---- 1b. mofka source checkout (spack builds it via `develop`) ----------------
# server/spack/spack.yaml has `develop: mofka path: ../../../mofka`; that path is
# a placeholder. Clone mofka here and point spack's develop at our clone.
MOFKA_DIR="$REPO_ROOT/$(cfg mofka.dir)"
MOFKA_URL="$(cfg mofka.git_url)"; MOFKA_REF="$(cfg mofka.git_ref)"
if [[ ! -d "$MOFKA_DIR/.git" ]]; then
    say "clone mofka ($MOFKA_REF) -> $MOFKA_DIR"
    git clone --branch "$MOFKA_REF" "$MOFKA_URL" "$MOFKA_DIR" || die "mofka clone failed"
else
    say "mofka already cloned at $MOFKA_DIR"
fi

# ---- 1c. create env from spack.yaml (carries repos: + develop:), not the lock --
# The lock alone omits the git package repos (mochi/diaspora), so `mofka` is
# unknown. Create from the yaml spec; register the repos; point develop at our
# mofka clone; then concretize + fetch for an offline build.
ENV_NAME="$(cfg layout.spack_env_name)"
ENV_SPEC="$REPO_ROOT/$(cfg spack.env_spec)"
# idempotent: check the env dir directly (spack env list formatting is unreliable)
ENV_DIR="$SPACK_DIR/var/spack/environments/$ENV_NAME"
if [[ -f "$ENV_DIR/spack.yaml" ]]; then
    say "spack env '$ENV_NAME' already exists -> reuse"
else
    say "create spack env '$ENV_NAME' from spec (repos + develop)"
    spack env create "$ENV_NAME" "$ENV_SPEC" || die "spack env create (spec) failed"
fi
say "point spack develop at the mofka clone"
spack -e "$ENV_NAME" develop -p "$MOFKA_DIR" "mofka@$MOFKA_REF" 2>/dev/null || true

say "spack concretize"
spack -e "$ENV_NAME" concretize -f || die "spack concretize failed"

# Build a LOCAL MIRROR on eagle so the compute-node build is truly offline.
# `spack fetch` only caches into spack's own stage; a mirror is the portable,
# offline-complete source bundle. Misses (e.g. a flaky GNU patch mirror) are
# warned, not fatal -- rerun the fetch on a login node if the build later needs one.
MIRROR="$SPACK_DIR/_mirror"
say "populate spack mirror -> $MIRROR (offline source bundle)"
spack -e "$ENV_NAME" mirror create -d "$MIRROR" --all 2>&1 | tail -5 \
    || echo "[install] WARN: mirror create had misses (see above)"
spack mirror add local-eagle "$MIRROR" 2>/dev/null || true
say "also warming spack's stage cache"
spack -e "$ENV_NAME" fetch 2>/dev/null || echo "[install] WARN: spack fetch had misses (mirror should still cover the build)"

# ---- 2. mongodb (conda env on eagle) -----------------------------------------
# Order: (a) our own env dir; (b) an EXISTING working mongod on eagle (reuse it,
# no new download); (c) create via conda (login node); (d) clear guidance.
MONGO_ENV="$(layout_path mongo_env_dir)"
find_conda() {
    command -v conda 2>/dev/null && return 0
    for c in "$_PROJECT_ROOT/../miniconda3_polaris/bin/conda" \
             "$_PROJECT_ROOT/../miniconda3/bin/conda" \
             "$HOME/miniconda3/bin/conda"; do
        [[ -x "$c" ]] && { echo "$c"; return 0; }
    done
    return 1
}
# _PROJECT_ROOT is set by env.sh; if not sourced yet, derive it.
_PROJECT_ROOT="${_PROJECT_ROOT:-$(cd "$REPO_ROOT/.." && pwd)}"

if [[ -x "$MONGO_ENV/bin/mongod" ]]; then
    say "mongod already present at $MONGO_ENV/bin/mongod"
else
    # (b) reuse an existing working mongod on eagle (same list env_polaris.sh uses)
    EXISTING=""
    for m in "$_PROJECT_ROOT/../miniconda3_polaris/envs/cll-mongo/bin/mongod" \
             "$_PROJECT_ROOT/../miniconda3/envs/flowcept-mongo/bin/mongod"; do
        [[ -x "$m" ]] && { EXISTING="$m"; break; }
    done
    if [[ -n "$EXISTING" ]]; then
        say "reusing existing mongod on eagle: $EXISTING"
        mkdir -p "$MONGO_ENV/bin"
        ln -sf "$EXISTING" "$MONGO_ENV/bin/mongod"
        say "symlinked -> $MONGO_ENV/bin/mongod (env_polaris.sh will resolve it)"
    elif CONDA="$(find_conda)"; then
        say "conda create mongodb=$(cfg mongo.version) -> $MONGO_ENV  (via $CONDA)"
        "$CONDA" create -y -p "$MONGO_ENV" -c "$(cfg mongo.channel)" \
            "$(cfg mongo.package)=$(cfg mongo.version)" || die "conda mongodb create failed"
    else
        die "no mongod found and no conda available. Either:
  - install conda and re-run, or
  - create the env manually:  conda create -p '$MONGO_ENV' -c conda-forge mongodb=$(cfg mongo.version)
  - or symlink an existing mongod:  ln -s /path/to/mongod '$MONGO_ENV/bin/mongod'"
    fi
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
