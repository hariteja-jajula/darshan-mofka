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

# Use the Python from the active Spack environment. A stale PY from a previous
# shell can point at a different Python ABI, which will not see the cpython-314
# pydiaspora_stream_api extension built below.
if command -v python3 >/dev/null 2>&1; then
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
export MOFKA_PROTOCOL=verbs
export CC="${CC:-$(command -v gcc || true)}"
export CXX="${CXX:-$(command -v g++ || true)}"

# Ask Spack for the exact Mofka prefix when available. This provides bedrock,
# mofkactl, CMake package files, and the Python mochi.mofka package.
if command -v spack >/dev/null 2>&1; then
    _mofka_prefix="$(spack location -i mofka+python 2>/dev/null || true)"
    if [[ -n "$_mofka_prefix" && -d "$_mofka_prefix" ]]; then
        export MOFKA_SPACK_VIEW="${MOFKA_SPACK_VIEW:-$_mofka_prefix}"
        _python_site="$_mofka_prefix/lib/python3.14/site-packages"
        _diaspora_python_site="$DIASPORA_C/lib/python3.14/site-packages"
        [[ -d "$_diaspora_python_site" ]] && _python_site="$_diaspora_python_site:$_python_site"
        export MOFKA_PYTHONPATH="$_python_site"
    fi
fi
