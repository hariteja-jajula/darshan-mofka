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
PROFILE="${DARSHAN_MOFKA_PROFILE:-${DARSHAN_MOFKA_ENV:-}}"
if [[ -z "$PROFILE" ]]; then
    if [[ -d /gpfs/fs1/soft/improv ]] || hostname 2>/dev/null | grep -qi 'ilogin\|improv'; then
        PROFILE=lcrc
    else
        PROFILE=polaris
    fi
fi
case "$PROFILE" in polaris|lcrc) ;; *) die "unknown profile '$PROFILE' (use polaris or lcrc)" ;; esac
ENV_ARG="--$PROFILE"

# ---- 0. preflight (fail fast on missing system deps) -------------------------
say "preflight"
say "profile: $PROFILE"
# shellcheck disable=SC1091
source "$REPO_ROOT/env/server.sh" "$ENV_ARG" || die "could not source env/server.sh $ENV_ARG"
# shellcheck disable=SC1091
source "$REPO_ROOT/env/workload.sh" "$ENV_ARG" || true
if command -v module >/dev/null 2>&1 && ! command -v cc >/dev/null 2>&1; then
    module swap PrgEnv-nvidia PrgEnv-gnu >/dev/null 2>&1 || module load PrgEnv-gnu >/dev/null 2>&1 || true
fi
command -v cc >/dev/null 2>&1 || die "cc compiler wrapper not found; load a compiler/MPI PrgEnv first"

# Seed the GNU bash 5.3 patch files into spack's source cache from ftp.gnu.org (the
# canonical, valid-cert host). ftpmirror.gnu.org redirects to mirrors that 404/502 or
# serve expired certs for these tiny patch files, which fails the bash build. Reads the
# (patch#, sha256) pairs straight from the concretized bash package.py so it tracks the
# pinned version; spack sha256-verifies each on use, so a corrupt download can't slip in.
# Idempotent: skips any patch already cached with the right sha. Never fatal (best effort).
_seed_gnu_bash_patches() {
    local bpkg cache py
    bpkg="$(find "$SPACK_DIR" -path "*spack_repo/builtin/packages/bash/package.py" 2>/dev/null | head -1)"
    [[ -f "$bpkg" ]] || return 0
    cache="$SPACK_DIR/var/spack/cache/_source-cache/archive"
    py="$(command -v python3 || echo python3)"
    "$py" - "$bpkg" <<'PYEOF' | while read -r num sha; do
import re,sys
txt=open(sys.argv[1]).read()
for m in re.finditer(r'\(\s*"5\.3"\s*,\s*"(\d+)"\s*,\s*"([0-9a-f]{64})"\s*\)', txt):
    print(m.group(1), m.group(2))
PYEOF
        [[ -z "$num" || -z "$sha" ]] && continue
        local sub="${sha:0:2}" dest
        dest="$cache/$sub/$sha"
        if [[ -f "$dest" ]] && [[ "$(sha256sum "$dest" | cut -d' ' -f1)" == "$sha" ]]; then continue; fi
        mkdir -p "$cache/$sub"
        if curl -sSfL --connect-timeout 15 -o "$dest.tmp" "https://ftp.gnu.org/gnu/bash/bash-5.3-patches/bash53-$num" 2>/dev/null \
           && [[ "$(sha256sum "$dest.tmp" | cut -d' ' -f1)" == "$sha" ]]; then
            mv "$dest.tmp" "$dest"; say "seeded bash53-$num"
        else
            rm -f "$dest.tmp"; say "WARN: could not seed bash53-$num (build may retry mirrors)"
        fi
    done
    return 0
}

if [[ "$PROFILE" == polaris ]]; then
    missing=()
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        [[ -e "$path" ]] || missing+=("$path")
    done < <(spack_external_prefixes)
    ((${#missing[@]})) && die "missing external paths required by server/spack/spack.yaml: ${missing[*]}"
    say "compiler and spack externals present"
else
    # LCRC: we build the Mofka stack from source into install/_spack if it isn't
    # already present, so no pre-existing stack is required.
    if command -v bedrock >/dev/null 2>&1 && [[ -n "${MOFKA_SPACK_VIEW:-}" && -d "${MOFKA_SPACK_VIEW:-}" ]]; then
        say "LCRC Mofka stack already present: $MOFKA_SPACK_VIEW"
    else
        say "LCRC Mofka stack absent -> will build it from source into $SPACK_DIR"
    fi
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
    # fetch via system curl (this login node's python-urllib fails cert verify to
    # some GNU mirrors; curl trusts them; spack still sha256-checks every source).
    # (LCRC branch already does this; Polaris needs it too.)
    spack config add "config:url_fetch_method:curl" 2>/dev/null || true
    # Pre-seed the flaky GNU bash 5.3 patches from the canonical ftp.gnu.org into the
    # source cache. ftpmirror.gnu.org redirects to mirrors that 404/502 or serve
    # expired certs for these small patch files; ftp.gnu.org is reliable. spack
    # sha256-verifies each, so a bad download can't slip through. Idempotent.
    _seed_gnu_bash_patches

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

    # Apply the Mofka connector patch to the develop checkout. spack.yaml's develop block
    # says "the connector patch is included", but the upstream checkout is vanilla -- nothing
    # applied it, so both features were silently missing from every built libmofka:
    #   (1) MOFKA_CLIENT_MODE=1 -> producer engines use THALLIUM_CLIENT_MODE (non-listening,
    #       shallow queues) so many Darshan producers per node can attach without exhausting
    #       the NIC fabric queues (the connect-storm fix, REQUIRED for the 4+1/partition runs).
    #   (2) MOFKA_NA_DOMAIN -> qualifies a domain-less protocol (verbs needs it on connect).
    # Both are inert unless their env var is set, so an unpatched build "works" for a single
    # producer on tcp -- which is why this gap went unnoticed. Apply idempotently to the
    # checkout src before concretize/install. (BX 2026-07-27)
    MOFKA_CONN_PATCH="$REPO_ROOT/server/spack/patches/mofka-producer-client-mode-and-na-domain.patch"
    if [[ -f "$MOFKA_CONN_PATCH" && -f "$MOFKA_DIR/src/MofkaDriver.cpp" ]]; then
        if grep -q "MOFKA_CLIENT_MODE" "$MOFKA_DIR/src/MofkaDriver.cpp"; then
            say "mofka connector patch already present -> skip"
        elif patch -p1 -d "$MOFKA_DIR" --dry-run < "$MOFKA_CONN_PATCH" >/dev/null 2>&1; then
            say "apply mofka connector patch (client-mode + na_domain)"
            patch -p1 -d "$MOFKA_DIR" < "$MOFKA_CONN_PATCH" || die "mofka connector patch failed"
        else
            say "WARN: mofka connector patch does not apply cleanly (upstream may have changed) -> continuing"
        fi
    fi

    # Polaris fix: the upstream mochi mercury package declares variant +hwloc (which we require)
    # but omits `depends_on('hwloc', when='+hwloc')`, so hwloc.pc never lands on mercury's build
    # PKG_CONFIG_PATH and its FindHWLOC.cmake (pkg_check_modules) fails "Could NOT find HWLOC" on
    # Polaris (no system hwloc dev headers / module). Patch the fetched mochi repo idempotently.
    # The mochi repo path is machine-specific (spack global package cache), so resolve it live.
    MOCHI_REPO="$(spack -e "$ENV_NAME" repo list 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="mochi"){print $NF; break}}')"
    MERC_PKG="$MOCHI_REPO/packages/mercury/package.py"
    HWLOC_PATCH="$REPO_ROOT/server/spack/patches/mercury-add-hwloc-depends.patch"
    if [[ -f "$MERC_PKG" && -f "$HWLOC_PATCH" ]]; then
        if grep -q "depends_on('hwloc', when='+hwloc')" "$MERC_PKG"; then
            say "mercury hwloc dep-edge patch already present -> skip"
        elif patch -p1 -d "$MOCHI_REPO" --dry-run < "$HWLOC_PATCH" >/dev/null 2>&1; then
            say "apply mercury hwloc dep-edge patch"
            patch -p1 -d "$MOCHI_REPO" < "$HWLOC_PATCH" || die "mercury hwloc patch failed"
        else
            say "WARN: mercury hwloc patch does not apply cleanly (upstream may have changed) -> continuing"
        fi
    fi

    say "spack concretize"
    spack -e "$ENV_NAME" concretize -f || die "spack concretize failed"

    say "spack install (-j$JOBS)"
    spack -e "$ENV_NAME" install -j"$JOBS" || die "spack install failed"
    MOFKA_SPACK_VIEW="$(spack location -e "$ENV_NAME")/.spack-env/view"
    export MOFKA_SPACK_VIEW
elif command -v bedrock >/dev/null 2>&1 && [[ -n "${MOFKA_SPACK_VIEW:-}" && -d "${MOFKA_SPACK_VIEW:-}" ]]; then
    say "using existing LCRC Mofka stack: $MOFKA_SPACK_VIEW"
else
    # LCRC from-scratch: build the native stack into install/_spack from the
    # committed spec (server/spack/spack-lcrc.yaml). Env name: flowcept-mofka-lcrc.
    SPACK_URL="$(cfg spack.git_url)"; SPACK_COMMIT="$(cfg spack.git_commit)"; SPACK_REF="$(cfg spack.git_ref)"
    if [[ ! -d "$SPACK_DIR/.git" ]]; then
        say "clone spack -> $SPACK_DIR (pin ${SPACK_COMMIT:0:12})"
        git clone "$SPACK_URL" "$SPACK_DIR" || die "spack clone failed"
        git -C "$SPACK_DIR" checkout -q "$SPACK_COMMIT" 2>/dev/null \
            || git -C "$SPACK_DIR" checkout -q "$SPACK_REF" || die "spack checkout failed"
    fi
    say "spack at $(git -C "$SPACK_DIR" rev-parse --short HEAD)"
    # shellcheck disable=SC1091
    source "$SPACK_DIR/share/spack/setup-env.sh"
    # fetch via system curl (this login node's python-urllib fails cert verify to
    # some GNU mirrors; curl trusts them; spack still sha256-checks every source).
    spack config add "config:url_fetch_method:curl" 2>/dev/null || true
    ENV_NAME=flowcept-mofka-lcrc
    if [[ ! -f "$SPACK_DIR/var/spack/environments/$ENV_NAME/spack.yaml" ]]; then
        # substitute the repo-local spack-repos path into the committed spec
        REPOS_DIR="$REPO_ROOT/install/spack-repos"; mkdir -p "$REPOS_DIR"
        SPEC_SRC="$REPO_ROOT/server/spack/spack-lcrc.yaml"; SPEC_GEN="$SPACK_DIR/spack-lcrc.gen.yaml"
        sed "s|__SPACK_REPOS__|$REPOS_DIR|g" "$SPEC_SRC" > "$SPEC_GEN"
        say "create spack env '$ENV_NAME' from spec"
        spack env create "$ENV_NAME" "$SPEC_GEN" || die "spack env create failed"
    fi
    say "spack concretize (lcrc)"
    spack -e "$ENV_NAME" concretize -f || die "spack concretize failed"
    say "spack install (-j$JOBS) -- this builds the full Mofka stack, takes a while"
    spack -e "$ENV_NAME" install -j"$JOBS" || die "spack install failed"
    MOFKA_SPACK_VIEW="$(spack location -e "$ENV_NAME")/.spack-env/view"
    export MOFKA_SPACK_VIEW
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
source "$REPO_ROOT/env/server.sh" "$ENV_ARG" 2>/dev/null || true
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
"$VENV/bin/python" -m pip install "${PIPFLAGS[@]}" -r "$REPO_ROOT/$(cfg python.requirements)" || die "pip install requirements failed"
"$VENV/bin/python" -m pip install "${PIPFLAGS[@]}" -e "$REPO_ROOT/$(cfg python.flowcept_editable)" || die "pip install flowcept failed"

# ---- 5. build project source -------------------------------------------------
# refresh env so the freshly built view + venv are picked up
export MONGOD="$MONGO_ENV/bin/mongod"
# shellcheck disable=SC1091
source "$REPO_ROOT/env/server.sh" "$ENV_ARG"
# shellcheck disable=SC1091
source "$REPO_ROOT/env/workload.sh" "$ENV_ARG"
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
    source "$REPO_ROOT/env/server.sh" "$ENV_ARG"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/env/workload.sh" "$ENV_ARG"
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
