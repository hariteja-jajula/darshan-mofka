#!/bin/bash
# env/server.sh -- environment for the SERVER node (Mofka broker + FlowCept
# consumer + mongod). Provides the venv python (PY), MOFKA_PYTHONPATH
# (mochi.mofka + pydiaspora), and MONGOD. Does NOT need the compiler toolchain
# for building workloads. Usage:  source env/server.sh [--lcrc|--polaris]
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

# mongod (FlowCept sink): explicit $MONGOD, else repo-local (Database/, then the
# legacy server/_mongo_env), else PATH. Database/get_mongod.sh populates Database/.
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
