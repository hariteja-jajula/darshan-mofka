#!/bin/bash
# install/00-fetch.sh -- PHASE 1 (LOGIN NODE): download everything to eagle so the
# offline compute-node build (install/10-build.sh) can proceed. Usage: bash install/00-fetch.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
require_login_node
cd "$REPO_ROOT"

SPACK_DIR="$(layout_path spack_dir)"
MONGO_ENV="$(layout_path mongo_env_dir)"
VENV="$(layout_path venv_dir)"

say "preflight"
if [[ -d "$SPACK_DIR/.git" ]]; then
    say "spack repo present: $SPACK_DIR"
elif command -v spack >/dev/null 2>&1; then
    say "system spack present: $(command -v spack)"
    confirm_install "repo-local pinned spack" "this build uses the pinned Spack commit in install/config.yaml"
else
    confirm_install "spack" "the installer will clone the pinned Spack into $SPACK_DIR"
fi

if command -v module >/dev/null 2>&1; then
    say "environment modules available"
    if ! command -v cc >/dev/null 2>&1; then
        confirm_install "compiler/MPI modules" "the installer will try: module swap PrgEnv-nvidia PrgEnv-gnu; module load gcc-native/13.2"
        module swap PrgEnv-nvidia PrgEnv-gnu >/dev/null 2>&1 || module load PrgEnv-gnu >/dev/null 2>&1 || true
        module load gcc-native/13.2 >/dev/null 2>&1 || true
    fi
else
    say "environment modules not available; continuing if required compilers/MPI are already on PATH"
fi
command -v cc >/dev/null 2>&1 || die "cc compiler wrapper not found; load compiler/MPI modules before running install/00-fetch.sh"

# Externals are declared in server/spack/spack.yaml (single source of truth);
# check every external prefix exists so the offline spack build won't fail later.
missing=()
while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    [[ -e "$path" ]] || missing+=("$path")
done < <(spack_external_prefixes)
if ((${#missing[@]})); then
    die "missing external paths required by server/spack/spack.yaml: ${missing[*]}"
fi
say "compiler and spack externals present"

if [[ -x "$MONGO_ENV/bin/mongod" || -n "$(command -v mongod 2>/dev/null || true)" ]]; then
    say "mongod present"
else
    confirm_install "mongod" "the installer will reuse an existing conda or create $MONGO_ENV"
fi

if [[ -x "$VENV/bin/python" ]]; then
    say "python venv present: $VENV"
elif PY311="$(have_python_311)"; then
    say "python >= 3.11 present: $PY311"
    confirm_install "FlowCept python venv" "the installer will create $VENV and install server/requirements.txt"
else
    die "no python >= 3.11 found; load a Python module before running install/00-fetch.sh"
fi

say "submodules"
git submodule update --init --recursive

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

MIRROR="$SPACK_DIR/_mirror"
say "spack mirror -> $MIRROR (offline source bundle)"
spack -e "$ENV_NAME" mirror create -d "$MIRROR" --all 2>&1 | tail -5 || echo "[install] WARN: mirror misses"
spack mirror add local-eagle "$MIRROR" 2>/dev/null || true
spack -e "$ENV_NAME" fetch 2>/dev/null || echo "[install] WARN: fetch misses (mirror should cover build)"

# --- mongod: reuse existing on eagle, else conda-create; location-independent ---
MONGO_ENV="$(layout_path mongo_env_dir)"
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

# --- python venv (>=3.11) + consumer deps from real PyPI -----------------------
# shellcheck disable=SC1091
source "$REPO_ROOT/server/env.sh" --polaris 2>/dev/null || true
VENV="$(layout_path venv_dir)"; REQS="$REPO_ROOT/$(cfg python.requirements)"
pick_python() {
    local c; for c in "$PY" python3.14 python3.13 python3.12 python3.11 python3; do
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

say "FETCH PHASE COMPLETE. Next (COMPUTE node): bash install/10-build.sh"
