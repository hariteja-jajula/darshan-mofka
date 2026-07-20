#!/bin/bash
# Environment entry point for the Darshan -> Mofka smoke tests.
# Usage:
#   source server/env.sh --polaris
#   source server/env.sh --lcrc

_ENV_SRC="${BASH_SOURCE[0]:-$0}"
SERVER_DIR="$(cd "$(dirname "$_ENV_SRC")" && pwd)"
ROOT="${INTERNSHIP_ROOT:-$(cd "$SERVER_DIR/.." && pwd)}"
export ROOT SERVER_DIR

case "${1:-}" in
    --polaris) DARSHAN_MOFKA_ENV=polaris ;;
    --lcrc) DARSHAN_MOFKA_ENV=lcrc ;;
    "") ;;
    *) echo "[env] unknown profile '${1:-}' (use --polaris or --lcrc)" >&2; return 1 ;;
esac
export DARSHAN_MOFKA_ENV

if [[ -n "${DARSHAN_MOFKA_ENV:-}" ]]; then
    _cluster_env="$SERVER_DIR/env_${DARSHAN_MOFKA_ENV}.sh"
    [[ -f "$_cluster_env" ]] || { echo "[env] missing $_cluster_env" >&2; return 1; }
    source "$_cluster_env"
elif [[ -f "$SERVER_DIR/env.local.sh" ]]; then
    source "$SERVER_DIR/env.local.sh"
else
    echo "[env] choose a profile: source server/env.sh --polaris" >&2
    return 1
fi
unset _cluster_env

: "${DARSHAN_LOGPATH:=$ROOT/darshan-logs}"
export DARSHAN_LOGPATH

darshan_ensure_logdir() {
    local d="$DARSHAN_LOGPATH/$(date +%Y)/$(date +%-m)/$(date +%-d)"
    mkdir -p "$d" 2>/dev/null || true
    printf '%s\n' "$d"
}

_prepend() {
    local var="$1" dir="$2"
    [[ -n "$dir" && -d "$dir" ]] || return 0
    case ":${!var:-}:" in
        *:"$dir":*) ;;
        *) export "$var=$dir${!var:+:${!var}}" ;;
    esac
}

if [[ -n "${MOFKA_SPACK_VIEW:-}" ]]; then
    _prepend PATH "$MOFKA_SPACK_VIEW/bin"
    _prepend LD_LIBRARY_PATH "$MOFKA_SPACK_VIEW/lib"
    _prepend LD_LIBRARY_PATH "$MOFKA_SPACK_VIEW/lib64"
fi
if [[ -n "${DIASPORA_C:-}" ]]; then
    _prepend LD_LIBRARY_PATH "$DIASPORA_C/lib"
    _prepend LD_LIBRARY_PATH "$DIASPORA_C/lib64"
fi
if [[ -n "${MOFKA_PYTHONPATH:-}" ]]; then
    _pythonpath=":${PYTHONPATH:-}:"
    _pythonpath="${_pythonpath//:$MOFKA_PYTHONPATH:/:}"
    _pythonpath="${_pythonpath#:}"
    _pythonpath="${_pythonpath%:}"
    export PYTHONPATH="$MOFKA_PYTHONPATH${_pythonpath:+:$_pythonpath}"
    unset _pythonpath
fi

if [[ -z "${PY:-}" && -n "${MOFKA_SPACK_VIEW:-}" && -x "$MOFKA_SPACK_VIEW/bin/python" ]]; then
    PY="$MOFKA_SPACK_VIEW/bin/python"
fi
: "${PY:=$(command -v python3 || command -v python || true)}"
export PY

mofkactl() { "$PY" -m mochi.mofka.mofkactl "$@"; }

darshan_lib() {
    local d="$DARSHAN_PREFIX/lib"
    if [[ -e "$d/libdarshan.so" ]]; then
        printf '%s\n' "$d/libdarshan.so"
    else
        compgen -G "$d/libdarshan.so*" | sort | head -1
    fi
}
