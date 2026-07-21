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
# LOCATION-INDEPENDENT: works no matter where the repo is cloned. Order:
#   (a) already created in our env dir
#   (b) explicit config overrides (mongo.mongod_path / mongo.conda_bin)
#   (c) reuse an existing mongod found anywhere under the eagle account tree
#   (d) create fresh via any conda we can find
#   (e) clear guidance
MONGO_ENV="$(layout_path mongo_env_dir)"
# eagle account root = strip everything from /<user> onward is fragile; instead
# search a few ancestor levels of the repo for miniconda*/envs/*/bin/mongod.
_search_roots=()
_p="$REPO_ROOT"
for _ in 1 2 3 4; do _p="$(dirname "$_p")"; _search_roots+=("$_p"); done
_search_roots+=("$HOME")

find_existing_mongod() {
    local override; override="$(cfg mongo.mongod_path)"
    [[ -n "$override" && -x "$override" ]] && { echo "$override"; return 0; }
    local root hit
    for root in "${_search_roots[@]}"; do
        [[ -d "$root" ]] || continue
        hit="$(compgen -G "$root/miniconda3*/envs/*/bin/mongod" 2>/dev/null | head -1)"
        [[ -n "$hit" && -x "$hit" ]] && { echo "$hit"; return 0; }
    done
    hit="$(command -v mongod 2>/dev/null || true)"
    [[ -n "$hit" ]] && { echo "$hit"; return 0; }
    return 1
}
find_conda() {
    local override; override="$(cfg mongo.conda_bin)"
    [[ -n "$override" && -x "$override" ]] && { echo "$override"; return 0; }
    command -v conda 2>/dev/null && return 0
    local root hit
    for root in "${_search_roots[@]}"; do
        hit="$(compgen -G "$root/miniconda3*/bin/conda" 2>/dev/null | head -1)"
        [[ -n "$hit" && -x "$hit" ]] && { echo "$hit"; return 0; }
    done
    return 1
}

if [[ -x "$MONGO_ENV/bin/mongod" ]]; then
    say "mongod already present at $MONGO_ENV/bin/mongod"
elif EXISTING="$(find_existing_mongod)"; then
    say "reusing existing mongod: $EXISTING"
    mkdir -p "$MONGO_ENV/bin"
    ln -sf "$EXISTING" "$MONGO_ENV/bin/mongod"
    say "symlinked -> $MONGO_ENV/bin/mongod"
elif CONDA="$(find_conda)"; then
    say "conda create mongodb=$(cfg mongo.version) -> $MONGO_ENV  (via $CONDA)"
    "$CONDA" create -y -p "$MONGO_ENV" -c "$(cfg mongo.channel)" \
        "$(cfg mongo.package)=$(cfg mongo.version)" || die "conda mongodb create failed"
else
    die "no mongod found and no conda available. Options:
  - set mongo.mongod_path or mongo.conda_bin in install/config.yaml, or
  - conda create -p '$MONGO_ENV' -c conda-forge mongodb=$(cfg mongo.version), or
  - ln -s /path/to/mongod '$MONGO_ENV/bin/mongod'"
fi

# ---- 3. python venv + download wheels ----------------------------------------
# We create the venv here (login node) so pip can reach PyPI; the build phase just
# reuses it. During FETCH the spack view python may not be built yet, so $PY can
# fall back to the ancient system python3 (3.6) -- too old for pymongo 4.x. Pick a
# python >= 3.11 explicitly and fail clearly if none is available.
# shellcheck disable=SC1091
source "$REPO_ROOT/server/env.sh" --polaris 2>/dev/null || true
VENV="$(layout_path venv_dir)"
REQS="$REPO_ROOT/$(cfg python.requirements)"

pick_python() {
    local cand
    for cand in "$PY" python3.14 python3.13 python3.12 python3.11 python3; do
        [[ -n "$cand" ]] || continue
        command -v "$cand" >/dev/null 2>&1 || continue
        if "$cand" -c 'import sys; sys.exit(0 if sys.version_info[:2]>=(3,11) else 1)' 2>/dev/null; then
            command -v "$cand"; return 0
        fi
    done
    return 1
}
VENV_PY="$(pick_python)" || die "no python >= 3.11 found for the venv.
       The spack view python isn't built yet during fetch and the system
       python3 is too old. Load a newer python module (e.g. 'module load
       cray-python') on the login node and re-run install/00-fetch.sh."
say "venv python: $VENV_PY ($("$VENV_PY" -V 2>&1))"

if [[ ! -x "$VENV/bin/python" ]]; then
    say "create venv -> $VENV"
    "$VENV_PY" -m venv "$VENV" || die "venv create failed"
fi
say "pip install consumer deps + flowcept (editable)"
# Force the real PyPI index: Polaris may have a site pip.conf / stale mirror that
# only exposes old versions (seen: pymongo maxing at 4.1.1 instead of 4.17.0).
# Ignore any inherited index config for this venv.
PYPI="https://pypi.org/simple"
PIPFLAGS=(--index-url "$PYPI" --disable-pip-version-check)
# don't let a site/user pip.conf redirect us
export PIP_CONFIG_FILE=/dev/null

"$VENV/bin/python" -m pip install "${PIPFLAGS[@]}" --upgrade pip \
    || die "pip self-upgrade failed (check network / index $PYPI)"
# diagnose the index if the pinned pymongo isn't visible
if ! "$VENV/bin/python" -m pip index versions pymongo "${PIPFLAGS[@]}" 2>/dev/null \
        | grep -q '4\.17\.0'; then
    echo "[install] NOTE: pymongo 4.17.0 not seen from $PYPI; showing pip config:"
    "$VENV/bin/python" -m pip config list 2>/dev/null | sed 's/^/    /' || true
fi
"$VENV/bin/python" -m pip install "${PIPFLAGS[@]}" -r "$REQS" \
    || die "pip install requirements failed (index=$PYPI). If versions look stale,
       a site pip.conf or PIP_INDEX_URL is overriding PyPI; unset it and re-run."
"$VENV/bin/python" -m pip install "${PIPFLAGS[@]}" -e "$REPO_ROOT/$(cfg python.flowcept_editable)" \
    || die "pip install -e flowcept failed"

say "FETCH PHASE COMPLETE. Next: on a COMPUTE node run  bash install/10-build.sh"
