#!/bin/bash

_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_d/_profile.sh" "$@"
. "$_d/common.sh"
. "$_d/$ENV_PROFILE.sh"

# venv python (has flowcept/pymongo); layers on the spack view already on LD path
_venv="$ENV_ROOT/install/_venv/bin/python3"
export PY="${PY:-$([[ -x $_venv ]] && echo "$_venv" || command -v python3)}"
env_prepend PATH "$ENV_ROOT/install/_venv/bin"

# PYTHONPATH for mochi.mofka (view) + pydiaspora (repo). Prepend view then
# diaspora so diaspora ends up first (matches the validated order).
env_prepend PYTHONPATH "$MOFKA_SPACK_VIEW/lib/python3.14/site-packages"
env_prepend PYTHONPATH "$ENV_ROOT/diaspora-stream-api/install/lib/python3.14/site-packages"
env_prepend PATH "$MOFKA_SPACK_VIEW/bin"
env_prepend LD_LIBRARY_PATH "$MOFKA_SPACK_VIEW/lib64"
env_prepend LD_LIBRARY_PATH "$MOFKA_SPACK_VIEW/lib"
env_prepend LD_LIBRARY_PATH "$ENV_ROOT/darshan/darshan-util/install/lib"

# raw-json handoff (DARSHAN_MOFKA_RAW_JSON): the spack-view libdiaspora-stream-api.so
# has no RawSerializer, so bedrock/mofkactl fall back to dlopen("libraw.so") and die.
# Only when the raw knob is on, prepend the repo fork's C install/lib (SONAME-identical
# superset that adds the "raw" serializer) so the C++ side resolves it. Gated so every
# non-raw run keeps the view copy => byte-identical to production.
if [ -n "${DARSHAN_MOFKA_RAW_JSON:-}" ] && [ "${DARSHAN_MOFKA_RAW_JSON}" != 0 ]; then
    env_prepend LD_LIBRARY_PATH "$ENV_ROOT/diaspora-stream-api/install/lib"
fi

# mongod (FlowCept sink)
if [[ -z "${MONGOD:-}" || ! -x "${MONGOD:-}" ]]; then
    for _m in "$ENV_ROOT/Database/_mongo_env/bin/mongod" \
              "$ENV_ROOT/server/_mongo_env/bin/mongod" \
              "$(command -v mongod 2>/dev/null)"; do
        [[ -n "$_m" && -x "$_m" ]] && { MONGOD="$_m"; break; }
    done
fi
export MONGOD
unset _m

mofkactl() { "$PY" -m mochi.mofka.mofkactl "$@"; }

# pin the module compiler's libstdc++ ahead of the view's older gcc-runtime
cxx_runtime_pin
unset _venv
