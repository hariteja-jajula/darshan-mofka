#!/bin/bash
# install/setup.sh -- one-shot automated setup for the darshan-mofka demo.
#
# This is the AUTOMATED BACKUP to the manual steps in the top-level README
# ("Dependencies & Environments"). Prefer the README if you already have parts of
# the stack -- run `bash check-deps.sh` first to see what's missing.
#
# Does everything in one run:
#   1. submodules
#   2. spack: clone (pinned) -> env from server/spack/spack.yaml -> install
#   3. mongod: reuse an existing one, else conda-create
#   4. python venv (>=3.11) + FlowCept consumer deps
#   5. build diaspora-stream-api, the darshan runtime (Mofka connector),
#      darshan-util, and the C smoke workload
#
# Versions/names come from install/config.yaml (no hardcoded paths). Needs
# internet for the downloads, so run it where you have it (on Polaris: a login
# node; the spack build itself works on login or compute).
#
# Usage (repo root):  bash install/setup.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
cd "$REPO_ROOT"

SPACK_DIR="$(layout_path spack_dir)"
MONGO_ENV="$(layout_path mongo_env_dir)"
VENV="$(layout_path venv_dir)"

# ---- 0. preflight (fail fast on missing system deps) -------------------------
# env.sh resolves the profile (arg > $DARSHAN_MOFKA_PROFILE > config.yaml > host).
say "preflight"
# shellcheck disable=SC1091
source "$REPO_ROOT/server/env.sh" || die "could not source server/env.sh"
PROFILE="$DARSHAN_MOFKA_PROFILE"; ENV_ARG="--$PROFILE"
say "profile: $PROFILE"
if command -v module >/dev/null 2>&1 && ! command -v cc >/dev/null 2>&1; then
    module swap PrgEnv-nvidia PrgEnv-gnu >/dev/null 2>&1 || module load PrgEnv-gnu >/dev/null 2>&1 || true
fi
command -v cc >/dev/null 2>&1 || die "cc compiler wrapper not found; load a compiler/MPI PrgEnv first"

if [[ "$PROFILE" == polaris ]]; then
    missing=()
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        [[ -e "$path" ]] || missing+=("$path")
    done < <(spack_external_prefixes)
    ((${#missing[@]})) && die "missing external paths required by server/spack/spack.yaml: ${missing[*]}"
    say "compiler and spack externals present"
else
    command -v bedrock >/dev/null 2>&1 || die "bedrock not found after server/env.sh $ENV_ARG"
    [[ -n "${MOFKA_SPACK_VIEW:-}" && -d "$MOFKA_SPACK_VIEW" ]] || die "MOFKA_SPACK_VIEW not set after server/env.sh $ENV_ARG"
    say "compiler and LCRC Mofka stack present"
fi

# ---- 1. submodules -----------------------------------------------------------
say "submodules"
git submodule update --init --recursive

JOBS="$(cfg spack.build_jobs)"
if [[ "$PROFILE" == polaris ]]; then
    SPACK_URL="$(cfg spack.git_url)"; SPACK_COMMIT="$(cfg spack.git_commit)"; SPACK_REF="$(cfg spack.git_ref)"
    if [[ ! -d "$SPACK_DIR/.git" ]]; then
        say "clone spack -> $SPACK_DIR (pin ${SPACK_COMMIT:0:12})"
        git clone "$SPACK_URL" "$SPACK_DIR" || die "spack clone failed"
        if [[ -n "$SPACK_COMMIT" ]]; then
            git -C "$SPACK_DIR" checkout -q "$SPACK_COMMIT" 2>/dev/null \
                || git -C "$SPACK_DIR" checkout -q "$SPACK_REF" || die "spack checkout failed"
        fi
    fi
    say "spack at $(git -C "$SPACK_DIR" rev-parse --short HEAD)"
    # shellcheck disable=SC1091
    source "$SPACK_DIR/share/spack/setup-env.sh"

    MOFKA_DIR="$REPO_ROOT/$(cfg mofka.dir)"; MOFKA_URL="$(cfg mofka.git_url)"; MOFKA_REF="$(cfg mofka.git_ref)"
    [[ -d "$MOFKA_DIR/.git" ]] || { say "clone mofka ($MOFKA_REF)"; git clone --branch "$MOFKA_REF" "$MOFKA_URL" "$MOFKA_DIR" || die "mofka clone failed"; }

    ENV_NAME="$(cfg layout.spack_env_name)"; ENV_SPEC="$REPO_ROOT/$(cfg spack.env_spec)"
    if [[ -f "$SPACK_DIR/var/spack/environments/$ENV_NAME/spack.yaml" ]]; then
        say "spack env '$ENV_NAME' exists -> reuse"
    else
        say "create spack env '$ENV_NAME' from spec"
        spack env create "$ENV_NAME" "$ENV_SPEC" || die "spack env create failed"
    fi
    spack -e "$ENV_NAME" develop -p "$MOFKA_DIR" "mofka@$MOFKA_REF" 2>/dev/null || true

    say "spack concretize"
    spack -e "$ENV_NAME" concretize -f || die "spack concretize failed"

    say "spack install (-j$JOBS)"
    spack -e "$ENV_NAME" install -j"$JOBS" || die "spack install failed"
    MOFKA_SPACK_VIEW="$(spack location -e "$ENV_NAME")/.spack-env/view"
    export MOFKA_SPACK_VIEW
else
    say "using LCRC Mofka stack: $MOFKA_SPACK_VIEW"
fi
say "spack view: $MOFKA_SPACK_VIEW"

# ---- 3. mongod: reuse existing, else conda-create ----------------------------
_roots=(); _p="$REPO_ROOT"; for _ in 1 2 3 4; do _p="$(dirname "$_p")"; _roots+=("$_p"); done; _roots+=("$HOME")
find_existing_mongod() {
    local o; o="$(cfg mongo.mongod_path)"; [[ -n "$o" && -x "$o" ]] && { echo "$o"; return 0; }
    local r h; for r in "${_roots[@]}"; do [[ -d "$r" ]] || continue
        h="$(compgen -G "$r/miniconda3*/envs/*/bin/mongod" 2>/dev/null | head -1)"
        [[ -n "$h" && -x "$h" ]] && { echo "$h"; return 0; }; done
    h="$(command -v mongod 2>/dev/null || true)"; [[ -n "$h" ]] && { echo "$h"; return 0; }; return 1
}
find_conda() {
    local o; o="$(cfg mongo.conda_bin)"; [[ -n "$o" && -x "$o" ]] && { echo "$o"; return 0; }
    command -v conda 2>/dev/null && return 0
    local r h; for r in "${_roots[@]}"; do
        h="$(compgen -G "$r/miniconda3*/bin/conda" 2>/dev/null | head -1)"
        [[ -n "$h" && -x "$h" ]] && { echo "$h"; return 0; }; done; return 1
}
if [[ -x "$MONGO_ENV/bin/mongod" ]]; then
    say "mongod present: $MONGO_ENV/bin/mongod"
elif EXISTING="$(find_existing_mongod)"; then
    say "reuse mongod: $EXISTING"; mkdir -p "$MONGO_ENV/bin"; ln -sf "$EXISTING" "$MONGO_ENV/bin/mongod"
elif CONDA="$(find_conda)"; then
    say "conda create mongodb=$(cfg mongo.version) -> $MONGO_ENV"
    "$CONDA" create -y -p "$MONGO_ENV" -c "$(cfg mongo.channel)" "$(cfg mongo.package)=$(cfg mongo.version)" \
        || die "conda mongodb create failed"
else
    die "no mongod and no conda; set mongo.mongod_path or mongo.conda_bin in install/config.yaml"
fi

# ---- 4. python venv (>=3.11) + consumer deps ---------------------------------
# shellcheck disable=SC1091
source "$REPO_ROOT/server/env.sh" "$ENV_ARG" 2>/dev/null || true
REQS="$REPO_ROOT/$(cfg python.requirements)"
pick_python() {
    local c; for c in "${PY:-}" python3.14 python3.13 python3.12 python3.11 python3; do
        [[ -n "$c" ]] && command -v "$c" >/dev/null 2>&1 || continue
        "$c" -c 'import sys;sys.exit(0 if sys.version_info[:2]>=(3,11) else 1)' 2>/dev/null \
            && { command -v "$c"; return 0; }; done; return 1
}
VENV_PY="$(pick_python)" || die "no python >= 3.11 (try: module load cray-python)"
_ok=0; [[ -x "$VENV/bin/python" ]] && "$VENV/bin/python" -c 'import sys;sys.exit(0 if sys.version_info[:2]>=(3,11) else 1)' 2>/dev/null && _ok=1
if [[ "$_ok" != 1 ]]; then
    [[ -e "$VENV" ]] && { say "rebuild stale venv"; rm -rf "$VENV"; }
    say "create venv -> $VENV (on $VENV_PY)"; "$VENV_PY" -m venv "$VENV" || die "venv create failed"
fi
say "venv: $("$VENV/bin/python" -V 2>&1)"

# force real PyPI (Polaris site mirror can be stale) and ignore inherited pip.conf
PIPFLAGS=(--index-url "https://pypi.org/simple" --disable-pip-version-check)
export PIP_CONFIG_FILE=/dev/null
say "pip install consumer deps + flowcept"
"$VENV/bin/python" -m pip install "${PIPFLAGS[@]}" --upgrade pip || die "pip upgrade failed"
"$VENV/bin/python" -m pip install "${PIPFLAGS[@]}" -r "$REQS" || die "pip install requirements failed"
"$VENV/bin/python" -m pip install "${PIPFLAGS[@]}" -e "$REPO_ROOT/$(cfg python.flowcept_editable)" || die "pip install flowcept failed"

# ---- 5. build project source -------------------------------------------------
# refresh env so the freshly built view + venv are picked up
export MONGOD="$MONGO_ENV/bin/mongod"
# shellcheck disable=SC1091
source "$REPO_ROOT/server/env.sh" "$ENV_ARG"
module unload darshan 2>/dev/null || true
export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"

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
    source "$REPO_ROOT/server/env.sh" "$ENV_ARG"
    module unload darshan 2>/dev/null || true
    export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
fi

say "build darshan runtime"
( cd "$REPO_ROOT" && ./build.sh ) || die "darshan build failed"
export DARSHAN_PREFIX="$REPO_ROOT/$(cfg layout.darshan_prefix)"
[[ -e "$(darshan_lib)" ]] || die "libdarshan.so missing after build"
say "darshan_lib=$(darshan_lib)"

say "build darshan-util"
( cd "$REPO_ROOT/$(cfg project.darshan_dir)/darshan-util"
  if [[ ! -f _build_util/Makefile ]]; then
      ( cd .. && ./prepare.sh )
      mkdir -p _build_util
      ( cd _build_util && ../configure --prefix="$PWD/../install" )
  fi
  ( cd _build_util && make -j"$JOBS" && make install ) ) || die "darshan-util build failed"

say "build smoke workload"
"$CC" -O2 "$REPO_ROOT/workloads/c/mofka_forward_smoke.c" \
    -o "$REPO_ROOT/workloads/c/mofka_forward_smoke" || die "workload compile failed"

say "SETUP COMPLETE."
say "Run the demo (compute node):  bash job.sh"
