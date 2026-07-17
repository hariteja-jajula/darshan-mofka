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

# Keep paths user-independent by deriving from $HOME.
export DIASPORA_C="${DIASPORA_C:-$HOME/diaspora-c-install}"
export DARSHAN_PREFIX="${DARSHAN_PREFIX:-$ROOT/darshan/install}"
export MOFKA_PROTOCOL="${MOFKA_PROTOCOL:-verbs}"

# Ask Spack for the exact Mofka prefix when available. This provides bedrock,
# mofkactl, CMake package files, and the Python mochi.mofka package.
if command -v spack >/dev/null 2>&1; then
    _mofka_prefix="$(spack location -i mofka+python 2>/dev/null || true)"
    if [[ -n "$_mofka_prefix" && -d "$_mofka_prefix" ]]; then
        export MOFKA_SPACK_VIEW="${MOFKA_SPACK_VIEW:-$_mofka_prefix}"
        export MOFKA_PYTHONPATH="${MOFKA_PYTHONPATH:-$_mofka_prefix/lib/python3.14/site-packages}"
    fi
fi
