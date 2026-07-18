#!/bin/bash
# Polaris environment for the Darshan -> Mofka smoke tests.
# Source through env.sh:
#   source server/env.sh --polaris

_EAGLE="${EAGLE:-/eagle/radix-io/hjajula}"
_SPACK_OPT="$_EAGLE/mofka_tests/spack/opt/spack"
_VIEW="$_EAGLE/mofka_tests/spack/var/spack/environments/flowcept-mofka/.spack-env/view"
_VENV="${FLOWCEPT_VENV:-$_EAGLE/envs/flowcept-py314}"

# Polaris stack is consumed through the regenerated Spack view directly. Avoid
# live `spack env activate`; the transferred Spack tree has historically been
# fragile on login nodes.
_GCC13_LIB="$(find "$_SPACK_OPT" -maxdepth 3 -type d -path '*gcc-runtime-13.2.0*/lib' 2>/dev/null | head -1)"
_PYLIB="$(find "$_SPACK_OPT" -maxdepth 3 -type d -path '*/python-3.14.5-*/lib' 2>/dev/null | head -1)"

export MOFKA_SPACK_VIEW="${MOFKA_SPACK_VIEW:-$_VIEW}"

# Prefer the repo-local install built by the README; fall back to the old install.
if [[ -e "$ROOT/diaspora-stream-api/install/include/diaspora/diaspora_c.h" ]]; then
    DIASPORA_C="$ROOT/diaspora-stream-api/install"
else
    DIASPORA_C="${DIASPORA_C:-$_EAGLE/diaspora-c-install}"
fi
export DIASPORA_C
export DARSHAN_PREFIX="${DARSHAN_PREFIX:-$ROOT/darshan/install}"
export MOFKA_PROTOCOL=ofi+tcp
export BEDROCK_PROTOCOL=ofi+tcp
export OPENBLAS_NUM_THREADS="${OPENBLAS_NUM_THREADS:-1}"
export PYTHONSAFEPATH=1

[[ -d "$_VENV/bin" ]] && export PATH="$_VENV/bin:$PATH"
[[ -d "$_VIEW/bin" ]] && export PATH="$_VIEW/bin:$PATH"
_CMAKE_BIN="$(find "$_SPACK_OPT" -maxdepth 4 -type f -path '*/cmake-*/bin/cmake' 2>/dev/null | head -1)"
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
elif command -v c++ >/dev/null 2>&1; then
    export CXX="$(command -v c++)"
fi

_python_site="$_VIEW/lib/python3.14/site-packages"
_diaspora_python_site="$DIASPORA_C/lib/python3.14/site-packages"
[[ -d "$_diaspora_python_site" ]] && _python_site="$_diaspora_python_site:$_python_site"
export MOFKA_PYTHONPATH="$_python_site"
