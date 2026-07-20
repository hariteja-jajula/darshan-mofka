#!/bin/bash
# Polaris environment for Darshan -> Mofka smoke tests.
# Source through: source server/env.sh --polaris

_PROJECT_ROOT="$(cd "$ROOT/.." && pwd)"
_SPACK_OPT="$_PROJECT_ROOT/../mofka_tests/spack/opt/spack"
_SPACK_ENVS="$_PROJECT_ROOT/../mofka_tests/spack/var/spack/environments"
# Prefer the Polaris-native view (reproducible from server/spack/); fall back to the
# older Improv-transferred view. Override either by exporting MOFKA_SPACK_VIEW.
_VIEW="$_SPACK_ENVS/flowcept-mofka-polaris/.spack-env/view"
[[ -d "$_VIEW" ]] || _VIEW="$_SPACK_ENVS/flowcept-mofka/.spack-env/view"
_VENV="$_PROJECT_ROOT/../envs/flowcept-py314"

if command -v module >/dev/null 2>&1; then
    module swap PrgEnv-nvidia PrgEnv-gnu >/dev/null 2>&1 || module load PrgEnv-gnu >/dev/null 2>&1 || true
    module load gcc-native/13.2 >/dev/null 2>&1 || true
fi

_GCC13_LIB="$(compgen -G "$_SPACK_OPT/*/gcc-runtime-13.2.0*/lib" | head -1)"
_PYLIB="$(compgen -G "$_SPACK_OPT/*/python-3.14.5-*/lib" | head -1)"
_CMAKE_BIN="$(compgen -G "$_SPACK_OPT/*/cmake-*/bin/cmake" | head -1)"

export MOFKA_SPACK_VIEW="${MOFKA_SPACK_VIEW:-$_VIEW}"

if [[ -e "$ROOT/diaspora-stream-api/install/include/diaspora/diaspora_c.h" ]]; then
    DIASPORA_C="$ROOT/diaspora-stream-api/install"
else
    DIASPORA_C="${DIASPORA_C:-$_PROJECT_ROOT/../diaspora-c-install}"
fi
export DIASPORA_C

if [[ -z "${DARSHAN_PREFIX:-}" || ! -e "$DARSHAN_PREFIX/lib/libdarshan.so" ]]; then
    DARSHAN_PREFIX="$ROOT/darshan/install"
fi
export DARSHAN_PREFIX

export MOFKA_PROTOCOL=ofi+tcp
export BEDROCK_PROTOCOL=ofi+tcp
export OPENBLAS_NUM_THREADS="${OPENBLAS_NUM_THREADS:-1}"
export PYTHONSAFEPATH=1

[[ -d "$_VENV/bin" ]] && export PATH="$_VENV/bin:$PATH"
[[ -d "$_VIEW/bin" ]] && export PATH="$_VIEW/bin:$PATH"
[[ -n "$_CMAKE_BIN" ]] && export PATH="$(dirname "$_CMAKE_BIN"):$PATH"
[[ -d "$_VIEW/lib" ]] && export LD_LIBRARY_PATH="$_VIEW/lib:${LD_LIBRARY_PATH:-}"
[[ -d "$_VIEW/lib64" ]] && export LD_LIBRARY_PATH="$_VIEW/lib64:${LD_LIBRARY_PATH:-}"
[[ -n "$_PYLIB" && -d "$_PYLIB" ]] && export LD_LIBRARY_PATH="$_PYLIB:${LD_LIBRARY_PATH:-}"
[[ -n "$_GCC13_LIB" && -d "$_GCC13_LIB" ]] && export LD_LIBRARY_PATH="$_GCC13_LIB:${LD_LIBRARY_PATH:-}"

if command -v python3 >/dev/null 2>&1; then
    export PY="$(command -v python3)"
fi
if command -v cc >/dev/null 2>&1; then
    export CC="$(command -v cc)"
fi
if command -v CC >/dev/null 2>&1; then
    export CXX="$(command -v CC)"
fi

_python_site="$_VIEW/lib/python3.14/site-packages"
_diaspora_python_site="$DIASPORA_C/lib/python3.14/site-packages"
[[ -d "$_diaspora_python_site" ]] && _python_site="$_diaspora_python_site:$_python_site"
export MOFKA_PYTHONPATH="$_python_site"

unset _PROJECT_ROOT _SPACK_OPT _VIEW _VENV _GCC13_LIB _PYLIB _CMAKE_BIN _python_site _diaspora_python_site
