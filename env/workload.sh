#!/bin/bash
# env/workload.sh -- environment for the WORKLOAD node (runs Darshan-instrumented
# apps). Provides the compiler, DIASPORA_C (the runtime links it), DARSHAN_PREFIX
# (the LD_PRELOAD lib), and DARSHAN_LOGPATH. Does NOT need mongod or the venv.
# Usage:  source env/workload.sh [--lcrc|--polaris]
_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_d/_profile.sh" "$@"
. "$_d/common.sh"
. "$_d/$ENV_PROFILE.sh"

export DIASPORA_C="${DIASPORA_C:-$ENV_ROOT/diaspora-stream-api/install}"
export DARSHAN_PREFIX="${DARSHAN_PREFIX:-$ENV_ROOT/darshan/install}"
env_prepend LD_LIBRARY_PATH "$DIASPORA_C/lib64"
env_prepend LD_LIBRARY_PATH "$DIASPORA_C/lib"
env_prepend LD_LIBRARY_PATH "$MOFKA_SPACK_VIEW/lib64"
env_prepend LD_LIBRARY_PATH "$MOFKA_SPACK_VIEW/lib"
env_prepend PATH "$MOFKA_SPACK_VIEW/bin"
export DARSHAN_LOGPATH="${DARSHAN_LOGPATH:-$ENV_ROOT/darshan-logs}"

darshan_lib() {
    local d="$DARSHAN_PREFIX/lib"
    [[ -e "$d/libdarshan.so" ]] && { printf '%s\n' "$d/libdarshan.so"; return; }
    compgen -G "$d/libdarshan.so*" | sort | head -1
}

# create + echo today's DARSHAN_LOGPATH subdir (Darshan writes native logs here)
darshan_ensure_logdir() {
    local d="$DARSHAN_LOGPATH/$(date +%Y)/$(date +%-m)/$(date +%-d)"
    mkdir -p "$d" 2>/dev/null || true
    printf '%s\n' "$d"
}
