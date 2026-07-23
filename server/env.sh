#!/bin/bash
# Environment entry point for the Darshan -> Mofka smoke tests.
# Usage:
#   source server/env.sh --polaris
#   source server/env.sh --lcrc

_ENV_SRC="${BASH_SOURCE[0]:-$0}"
SERVER_DIR="$(cd "$(dirname "$_ENV_SRC")" && pwd)"
ROOT="${INTERNSHIP_ROOT:-$(cd "$SERVER_DIR/.." && pwd)}"
export ROOT SERVER_DIR

# Resolve the cluster profile once, here, so every caller (job.sh, check-deps.sh,
# install/setup.sh) can just `source server/env.sh` and read $DARSHAN_MOFKA_PROFILE
# instead of re-implementing host detection. Precedence:
#   1. explicit --polaris/--lcrc arg   2. $DARSHAN_MOFKA_PROFILE / $DARSHAN_MOFKA_ENV
#   3. `cluster:` in install/config.yaml   4. host auto-detection (lcrc vs polaris)
darshan_mofka_resolve_profile() {
    case "${1:-}" in
        --polaris) printf polaris; return ;;
        --lcrc)    printf lcrc;    return ;;
        "") ;;
        *) echo "[env] unknown profile '${1:-}' (use --polaris or --lcrc)" >&2; return 1 ;;
    esac
    local p="${DARSHAN_MOFKA_PROFILE:-${DARSHAN_MOFKA_ENV:-}}"
    [[ -z "$p" && -f "$ROOT/install/config.yaml" ]] && \
        p="$(sed -n 's/^cluster:[[:space:]]*\([A-Za-z0-9_-]*\).*/\1/p' "$ROOT/install/config.yaml" | head -1)"
    if [[ -z "$p" ]]; then
        { [[ -d /gpfs/fs1/soft/improv ]] || hostname 2>/dev/null | grep -qi 'ilogin\|improv'; } \
            && p=lcrc || p=polaris
    fi
    printf '%s' "$p"
}
DARSHAN_MOFKA_ENV="$(darshan_mofka_resolve_profile "${1:-}")" || return 1
case "$DARSHAN_MOFKA_ENV" in polaris|lcrc) ;; *) echo "[env] bad profile '$DARSHAN_MOFKA_ENV'" >&2; return 1 ;; esac
# back-compat alias many callers read
export DARSHAN_MOFKA_ENV DARSHAN_MOFKA_PROFILE="$DARSHAN_MOFKA_ENV"

_cluster_env="$SERVER_DIR/env_${DARSHAN_MOFKA_ENV}.sh"
[[ -f "$_cluster_env" ]] || { echo "[env] missing $_cluster_env" >&2; return 1; }
source "$_cluster_env"
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
if [[ -n "${DARSHAN_MOFKA_CXX_RUNTIME_DIR:-}" && -d "$DARSHAN_MOFKA_CXX_RUNTIME_DIR" ]]; then
    _ldpath=":${LD_LIBRARY_PATH:-}:"
    _ldpath="${_ldpath//:$DARSHAN_MOFKA_CXX_RUNTIME_DIR:/:}"
    _ldpath="${_ldpath#:}"
    _ldpath="${_ldpath%:}"
    export LD_LIBRARY_PATH="$DARSHAN_MOFKA_CXX_RUNTIME_DIR${_ldpath:+:$_ldpath}"
    if [[ -e "$DARSHAN_MOFKA_CXX_RUNTIME_DIR/libstdc++.so.6" ]]; then
        _preload=":${LD_PRELOAD:-}:"
        _preload="${_preload//:$DARSHAN_MOFKA_CXX_RUNTIME_DIR\/libstdc++.so.6:/:}"
        _preload="${_preload#:}"
        _preload="${_preload%:}"
        export LD_PRELOAD="$DARSHAN_MOFKA_CXX_RUNTIME_DIR/libstdc++.so.6${_preload:+:$_preload}"
        unset _preload
    fi
    unset _ldpath
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
