#!/bin/bash
# LCRC/Improv environment for the Darshan -> Mofka smoke tests.
# Source through env.sh:
#   DARSHAN_MOFKA_ENV=lcrc source server/env.sh

if ! command -v module >/dev/null 2>&1; then
    for _f in /etc/profile.d/z00_lmod.sh /etc/profile.d/lmod.sh; do
        [ -f "$_f" ] && { source "$_f"; break; }
    done
fi

module load gcc/13.2.0 openmpi/4.1.8

# Existing LCRC setup uses this Spack environment for Mofka/Bedrock.
if [[ -f "$HOME/mofka_tests/spack/share/spack/setup-env.sh" ]]; then
    source "$HOME/mofka_tests/spack/share/spack/setup-env.sh"
    spack env activate flowcept-mofka
fi
_CMAKE_BIN="$(compgen -G "$HOME/mofka_tests/spack/opt/spack/*/cmake-3.31*/bin/cmake" 2>/dev/null | head -1)"
[[ -n "$_CMAKE_BIN" ]] && export PATH="$(dirname "$_CMAKE_BIN"):$PATH"

_VENV="$ROOT/install/_venv"
if [[ -x "$_VENV/bin/python3" ]]; then
    export PATH="$_VENV/bin:$PATH"
    export PY="$_VENV/bin/python3"
elif command -v python3 >/dev/null 2>&1; then
    export PY="$(command -v python3)"
fi

# Prefer the repo-local install built by the README; fall back to the old home install.
# This intentionally overrides a stale DIASPORA_C from a previous source command.
if [[ -e "$ROOT/diaspora-stream-api/install/include/diaspora/diaspora_c.h" ]]; then
    DIASPORA_C="$ROOT/diaspora-stream-api/install"
else
    DIASPORA_C="${DIASPORA_C:-$HOME/diaspora-c-install}"
fi
export DIASPORA_C
if [[ -z "${DARSHAN_PREFIX:-}" || ! -e "$DARSHAN_PREFIX/lib/libdarshan.so" ]]; then
    DARSHAN_PREFIX="$ROOT/darshan/install"
fi
export DARSHAN_PREFIX
if [[ -z "${MONGOD:-}" || ! -x "${MONGOD:-}" ]]; then
    if [[ -x "$ROOT/server/_mongo_env/bin/mongod" ]]; then
        MONGOD="$ROOT/server/_mongo_env/bin/mongod"
    else
        MONGOD="$(command -v mongod 2>/dev/null || true)"
    fi
fi
export MONGOD

export MOFKA_PROTOCOL=verbs
export CC="${CC:-$(command -v gcc || true)}"
export CXX="${CXX:-$(command -v g++ || true)}"

# Ask Spack for the exact Mofka prefix when available. This provides bedrock,
# mofkactl, CMake package files, and the Python mochi.mofka package.
if command -v spack >/dev/null 2>&1; then
    _mofka_prefix="$(spack location -i mofka+python 2>/dev/null || true)"
    if [[ -n "$_mofka_prefix" && -d "$_mofka_prefix" ]]; then
        export MOFKA_SPACK_VIEW="${MOFKA_SPACK_VIEW:-$_mofka_prefix}"
        [[ -d "$MOFKA_SPACK_VIEW/bin" ]] && export PATH="$MOFKA_SPACK_VIEW/bin:$PATH"
        _python_site="$_mofka_prefix/lib/python3.14/site-packages"
        _diaspora_python_site="$DIASPORA_C/lib/python3.14/site-packages"
        [[ -d "$_diaspora_python_site" ]] && _python_site="$_diaspora_python_site:$_python_site"
        export MOFKA_PYTHONPATH="$_python_site"
    fi
fi

_GXX_LIB="$(g++ -print-file-name=libstdc++.so.6 2>/dev/null || true)"
[[ -n "$_GXX_LIB" && -e "$_GXX_LIB" ]] && export DARSHAN_MOFKA_CXX_RUNTIME_DIR="$(dirname "$_GXX_LIB")"
unset _GXX_LIB _CMAKE_BIN _VENV _mofka_prefix _python_site _diaspora_python_site
