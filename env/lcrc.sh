#!/bin/bash
# env/lcrc.sh -- LCRC/Improv profile. Locates the native Mofka/Bedrock spack
# stack (needed by BOTH server and workload) and a new-enough cmake.
# Sourced by env/server.sh and env/workload.sh after env/common.sh.
# Sets: MOFKA_SPACK_VIEW, MOFKA_PROTOCOL, cmake on PATH.

export MOFKA_PROTOCOL="${MOFKA_PROTOCOL:-verbs}"

# Native Mofka/Bedrock stack (spack env). Repo-local install/_spack first
# (built by build.sh on this branch), else the legacy ~/mofka_tests/spack.
for _sp in "$ENV_ROOT/install/_spack/share/spack/setup-env.sh" \
           "$HOME/mofka_tests/spack/share/spack/setup-env.sh"; do
    if [[ -f "$_sp" ]]; then
        . "$_sp"
        spack env activate "${ENV_SPACK_ENV:-flowcept-mofka}" 2>/dev/null || true
        break
    fi
done
if command -v spack >/dev/null 2>&1; then
    _pref="$(spack location -i mofka+python 2>/dev/null || true)"
    [[ -n "$_pref" && -d "$_pref" ]] && export MOFKA_SPACK_VIEW="${MOFKA_SPACK_VIEW:-$_pref}"
fi

# cmake 3.31 (diaspora needs >=3.31): prefer PATH, else from the spack tree.
if ! command -v cmake >/dev/null 2>&1 || \
   [[ "$(cmake --version 2>/dev/null | sed -n '1s/.* //p')" < "3.31" ]]; then
    _cm="$(compgen -G "$HOME/mofka_tests/spack/opt/spack/*/cmake-3.31*/bin/cmake" 2>/dev/null | head -1)"
    [[ -n "$_cm" ]] && env_prepend PATH "$(dirname "$_cm")"
fi

unset _sp _pref _cm
