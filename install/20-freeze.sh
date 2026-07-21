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
# Usage:  bash install/20-freeze.sh
# (sources server/env.sh itself so it records the PROJECT tools, not strays.)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
cd "$REPO_ROOT"
LOCK="$INSTALL_DIR/lock"; mkdir -p "$LOCK"

# Source the project env so $CC/$PY/cmake/MONGOD are the PROJECT ones. Without
# this, freeze records strays (e.g. ~/.local/bin/cmake, system python 3.6) and
# an empty pip freeze -- exactly the wrong thing to pin.
# shellcheck disable=SC1091
source "$REPO_ROOT/server/env.sh" --polaris || die "could not source server/env.sh"
# provenance guard: refuse to freeze stray tools
case "${PY:-}" in
    *"/.local/"*|/usr/bin/python*|/bin/python*|"")
        die "PY is stray/unset ($PY); source env in a clean shell before freezing";;
esac
"$PY" -c 'import sys; assert sys.version_info[:2]==(3,14), sys.version' 2>/dev/null \
    || die "PY is not the project python 3.14 ($($PY -V 2>&1)); env not set up correctly"

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
# Prefer the installer's venv; else the sourced project $PY (must be 3.14).
VENV="$(layout_path venv_dir)"
PYBIN="$VENV/bin/python"; [[ -x "$PYBIN" ]] || PYBIN="$PY"
say "freeze pip requirements (from $PYBIN)"
if ! "$PYBIN" -m pip freeze > "$LOCK/requirements.lock" 2>/dev/null \
     || [[ ! -s "$LOCK/requirements.lock" ]]; then
    echo "[install] WARN: pip freeze empty/failed from $PYBIN"
fi

# ---- conda mongo env export (resilient: find conda like 00-fetch does) --------
MONGO_ENV="$(layout_path mongo_env_dir)"
_PROJECT_ROOT="${_PROJECT_ROOT:-$(cd "$REPO_ROOT/.." && pwd)}"
_CONDA="$(command -v conda 2>/dev/null || true)"
for c in "$_PROJECT_ROOT/../miniconda3_polaris/bin/conda" \
         "$_PROJECT_ROOT/../miniconda3/bin/conda" "$HOME/miniconda3/bin/conda"; do
    [[ -z "$_CONDA" && -x "$c" ]] && _CONDA="$c"
done
# the mongo env may be a real conda env, or a symlink to one elsewhere on eagle.
_REAL_MONGO_ENV="$MONGO_ENV"
[[ -L "$MONGO_ENV/bin/mongod" ]] && \
    _REAL_MONGO_ENV="$(cd "$(dirname "$(readlink -f "$MONGO_ENV/bin/mongod")")/.." && pwd)"
if [[ -n "$_CONDA" && -d "$_REAL_MONGO_ENV/conda-meta" ]]; then
    say "freeze mongo conda env (from $_REAL_MONGO_ENV)"
    "$_CONDA" env export -p "$_REAL_MONGO_ENV" --no-builds > "$LOCK/mongo.lock.yml" 2>/dev/null \
        || echo "[install] WARN: conda env export failed"
else
    # no conda introspection possible; pin version from config as the spec.
    say "no conda export; writing mongo version pin from config"
    printf '# mongod pinned via server/mongo-environment.yml\nmongodb: %s\n' \
        "$(cfg mongo.version)" > "$LOCK/mongo.lock.yml"
fi

# ---- human-readable version summary ------------------------------------------
say "write versions.txt"
{
    echo "# frozen $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(hostname -s)"
    echo "## toolchain"
    # Cray 'cc' is a wrapper; its --version needs the full PE module env. Record the
    # wrapper path + the craype version from the path (stable, reproducible).
    _craype_ver="$(printf '%s\n' "${CC:-cc}" | sed -n 's|.*/craype/\([^/]*\)/.*|\1|p')"
    echo "cc:      ${CC:-cc}${_craype_ver:+  (craype $_craype_ver)}"
    echo "cmake:   $(command -v cmake) $(cmake --version 2>&1 | head -1)"
    echo "python:  $("${PY:-python3}" -V 2>&1)"
    echo "mongod:  $("$MONGO_ENV/bin/mongod" --version 2>&1 | head -1)"
    echo "## spack components (view, with versions)"
    # Pull name@version straight from the concretized lock (authoritative, no spack
    # invocation quirks). Covers the key mochi/mofka/darshan/diaspora components.
    if [[ -s "$LOCK/spack.lock" ]]; then
        "${PY:-python3}" - "$LOCK/spack.lock" <<'PY' 2>/dev/null || true
import json, sys, re
d = json.load(open(sys.argv[1]))
want = re.compile(r'mofka|bedrock|margo|mercury|thallium|warabi|yokan|flock|darshan|diaspora', re.I)
seen = set()
for s in d.get("concrete_specs", {}).values():
    n, v = s.get("name",""), s.get("version","")
    if n and want.search(n):
        seen.add(f"{n}@{v}")
for spec in sorted(seen):
    print(f"  {spec}")
PY
    fi
    echo "## darshan submodule"
    echo "darshan: $(git -C "$REPO_ROOT/$(cfg project.darshan_dir)" rev-parse --short HEAD 2>/dev/null)"
} > "$LOCK/versions.txt"

say "FREEZE COMPLETE -> $LOCK"
ls -la "$LOCK"
echo
echo "Commit install/lock/ to pin this build. config.yaml keeps names+versions;"
echo "the lock/ files are the exact concretization for byte-for-byte reproduction."
