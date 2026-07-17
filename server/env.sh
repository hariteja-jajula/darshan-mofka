#!/bin/bash
# Portable environment for the darshan -> mofka mini stack.
#
# This file contains NO machine-specific paths. Everything is either derived
# from this file's own location or read from variables. Put the per-machine
# values (where your spack view / diaspora-c / python live, which MPI to load)
# in an optional, uncommitted "env.local.sh" next to this file -- see
# env.local.sh.example for the full list. That is the ONLY file you edit when
# moving to a new cluster.
#
# Safe to source under `set -u`.

# --- repo layout: derived, never hardcoded ------------------------------------
_ENV_SRC="${BASH_SOURCE[0]:-$0}"
SERVER_DIR="$(cd "$(dirname "$_ENV_SRC")" && pwd)"
# env.sh lives in <root>/server, so the repo root is its parent. Overridable.
ROOT="${INTERNSHIP_ROOT:-$(cd "$SERVER_DIR/.." && pwd)}"
export ROOT SERVER_DIR

# Optional profile shorthand: source server/env.sh --lcrc
case "${1:-}" in
    --lcrc) DARSHAN_MOFKA_ENV=lcrc ;;
    --polaris) DARSHAN_MOFKA_ENV=polaris ;;
    "") ;;
    *) echo "[env] unknown profile '${1:-}' (use --lcrc or --polaris)" >&2; return 1 ;;
esac

# --- per-machine overrides ----------------------------------------------------
# Select a committed cluster profile with DARSHAN_MOFKA_ENV=lcrc, or keep using
# an uncommitted env.local.sh for one-off local overrides.
if [[ -n "${DARSHAN_MOFKA_ENV:-}" ]]; then
    _cluster_env="$SERVER_DIR/env_${DARSHAN_MOFKA_ENV}.sh"
    [[ -f "$_cluster_env" ]] || { echo "[env] missing $_cluster_env" >&2; return 1; }
    source "$_cluster_env"
elif [[ -f "$SERVER_DIR/env.local.sh" ]]; then
    source "$SERVER_DIR/env.local.sh"
fi

# --- software stack locations -------------------------------------------------
# env.local.sh may set these explicitly; otherwise AUTO-DISCOVER them in
# conventional spots (built into the workspace, or one/two levels up). On a
# standard layout env.local.sh then only carries the machine's `module load`s --
# no hardcoded paths.
_discover() {   # _discover MARKER cand...  -> abs path of first cand containing MARKER
    local m="$1"; shift; local d
    for d in "$@"; do [[ -e "$d/$m" ]] && { (cd "$d" && pwd); return; }; done
}
# spack view providing bin/bedrock, mofkactl, python
: "${MOFKA_SPACK_VIEW:=$(_discover bin/bedrock \
        "$ROOT/mofka-view" "$ROOT/../mofka-view" "$ROOT/../../mofka-view")}"
# diaspora-c install (headers + libdiaspora-c / libdiaspora-stream-api)
: "${DIASPORA_C:=$(_discover include/diaspora/diaspora_c.h \
        "$ROOT/diaspora-stream-api/install" \
        "$ROOT/../diaspora-c-install-fork" "$ROOT/../../diaspora-c-install-fork")}"
# darshan-runtime install (libdarshan.so); prefer the submodule build output
: "${DARSHAN_PREFIX:=$(_discover lib/libdarshan.so "$ROOT/darshan/install" "$ROOT/darshan-install")}"
: "${DARSHAN_PREFIX:=$ROOT/darshan/install}"   # default target if not built yet
: "${PYPREFIX:=}"
: "${MOFKA_PYTHONPATH:=}"
export MOFKA_SPACK_VIEW DIASPORA_C DARSHAN_PREFIX

# darshan native-log path. Matches build-darshan.sh's --with-log-path=$ROOT/darshan-logs.
# On exit darshan writes <logpath>/<YYYY>/<M>/<D>/<name>.darshan and does NOT create
# that dated subdir itself -- if it's missing you get "unable to create log file".
# darshan uses NON-zero-padded month/day (e.g. 2026/7/8), matching date +%-m/%-d.
: "${DARSHAN_LOGPATH:=$ROOT/darshan-logs}"
export DARSHAN_LOGPATH
# Create today's dated log dir (idempotent). Call right before launching a
# darshan-instrumented workload so the native log write succeeds. Echoes the dir.
darshan_ensure_logdir() {
    local d="$DARSHAN_LOGPATH/$(date +%Y)/$(date +%-m)/$(date +%-d)"
    mkdir -p "$d" 2>/dev/null || true
    printf '%s\n' "$d"
}

_prepend() { # _prepend VARNAME dir  (only if dir exists and is non-empty)
    local var="$1" dir="$2"
    [[ -n "$dir" && -d "$dir" ]] || return 0
    # indirect expansion (${!var}) instead of eval; var names are internal only
    export "$var=$dir:${!var:-}"
}

if [[ -n "$MOFKA_SPACK_VIEW" ]]; then
    _prepend PATH            "$MOFKA_SPACK_VIEW/bin"
    _prepend LD_LIBRARY_PATH "$MOFKA_SPACK_VIEW/lib"
    _prepend LD_LIBRARY_PATH "$MOFKA_SPACK_VIEW/lib64"
fi
if [[ -n "$DIASPORA_C" ]]; then
    _prepend LD_LIBRARY_PATH "$DIASPORA_C/lib"
    _prepend LD_LIBRARY_PATH "$DIASPORA_C/lib64"
fi
if [[ -n "$PYPREFIX" ]]; then
    _prepend PATH            "$PYPREFIX/bin"
    _prepend LD_LIBRARY_PATH "$PYPREFIX/lib"
fi
if [[ -n "$MOFKA_PYTHONPATH" ]]; then
    _clean_pythonpath=":${PYTHONPATH:-}:"
    _clean_pythonpath="${_clean_pythonpath//:$MOFKA_PYTHONPATH:/:}"
    _clean_pythonpath="${_clean_pythonpath#:}"
    _clean_pythonpath="${_clean_pythonpath%:}"
    export PYTHONPATH="$MOFKA_PYTHONPATH${_clean_pythonpath:+:$_clean_pythonpath}"
fi

# --- transport ----------------------------------------------------------------
export MOFKA_PROTOCOL="${MOFKA_PROTOCOL:-ofi+tcp}"

# --- python + mofkactl --------------------------------------------------------
# Prefer explicit $PY; else the discovered spack view's python; else PATH.
if [[ -z "${PY:-}" && -n "$MOFKA_SPACK_VIEW" && -x "$MOFKA_SPACK_VIEW/bin/python" ]]; then
    PY="$MOFKA_SPACK_VIEW/bin/python"
fi
: "${PY:=$(command -v python3 || command -v python || true)}"
export PY
mofkactl() { "$PY" -m mochi.mofka.mofkactl "$@"; }

# --- C / C++ compilers: resolve by looking -----------------------------------
# Precedence: an explicit CC/CXX -- or a `module load <compiler>` in
# env.local.sh, which exports them -- always wins. Otherwise discover a compiler
# on PATH, preferring a real gcc/g++ over the bare cc/c++ (on many clusters
# `cc` is an ancient system gcc while `gcc` is a modern module/spack build).
# Everything downstream (configure, run.sh, the PBS verify build) inherits these
# so the whole stack is built with ONE consistent toolchain on any machine.
_find_cc() { local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 && { command -v "$c"; return 0; }; done; return 1; }
: "${CC:=$(_find_cc gcc cc clang || true)}"
: "${CXX:=$(_find_cc g++ c++ clang++ || true)}"
export CC CXX
[[ -z "$CC"  ]] && echo "[env] warning: no C compiler found (set CC or 'module load gcc' in env.local.sh)"  >&2
[[ -z "$CXX" ]] && echo "[env] warning: no C++ compiler found (set CXX or 'module load gcc' in env.local.sh)" >&2

# --- MPI launcher (portable across Cray PALS / Open MPI / MPICH-Hydra) --------
# Resolve a launcher: honour $MPIEXEC, else find one on PATH.
: "${MPIEXEC:=$(command -v mpiexec || command -v mpirun || true)}"
export MPIEXEC

# mpi_per_node HOSTS N [--] cmd args...
#   Launch N processes, one per node, across the comma-separated HOSTS list,
#   emitting the correct placement flags for whichever launcher is present.
mpi_per_node() {
    local hosts="$1" n="$2"; shift 2
    [[ "${1:-}" == "--" ]] && shift
    if [[ -z "$MPIEXEC" ]]; then
        echo "[env] no MPI launcher found; set MPIEXEC in env.local.sh" >&2
        return 127
    fi
    local ver; ver="$("$MPIEXEC" --version 2>&1 | tr 'A-Z' 'a-z')"
    if [[ "$ver" == *"open mpi"* || "$ver" == *"open-mpi"* || "$ver" == *"openmpi"* \
          || "$ver" == *openrte* || "$ver" == *"(ompi)"* ]]; then
        # One rank per node: round-robin ranks across the hosts with `--map-by
        # node`, and `--oversubscribe` so Open MPI does not reject the launch over
        # its own slot bookkeeping (under a PBS allocation 4.1.x miscounts the
        # per-host slots from --host and errors with "not enough slots" / "more
        # procs than ppr can support"). We never truly oversubscribe -- n == #nodes,
        # one each. `--bind-to none` leaves the co-located broker's cores free.
        local hostspec="${hosts//,/:1,}:1"
        "$MPIEXEC" --host "$hostspec" -n "$n" --map-by node --bind-to none --oversubscribe -- "$@"
    elif [[ "$ver" == *"hydra"* || "$ver" == *"mpich"* ]]; then
        "$MPIEXEC" -hosts "$hosts" -n "$n" -ppn 1 -- "$@"
    else
        # Cray PALS and generic fallback.
        "$MPIEXEC" --hosts "$hosts" -n "$n" --ppn 1 -- "$@"
    fi
}

# darshan_lib: resolve the darshan shared object even if the unversioned
# libdarshan.so symlink was not created by the install.
darshan_lib() {
    local d="$DARSHAN_PREFIX/lib"
    if [[ -e "$d/libdarshan.so" ]]; then
        echo "$d/libdarshan.so"
    else
        ls "$d"/libdarshan.so* 2>/dev/null | sort | head -1
    fi
}
