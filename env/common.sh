#!/bin/bash
# env/common.sh -- shared base for the server and workload envs.
# Loads the compiler/MPI modules and provides env_prepend(). Sourced by
# env/server.sh and env/workload.sh (not directly). Needs ENV_PROFILE set.
#
# NOTE: no libstdc++/LD_PRELOAD "pin" is needed. Verified on LCRC: `module load
# gcc/13.2.0` + `spack env activate` put a gcc-13 libstdc++ (GLIBCXX_3.4.32) on
# LD_LIBRARY_PATH via the spack view, and mochi.mofka + libdarshan.so resolve
# correctly with modules alone. The old DARSHAN_MOFKA_CXX_RUNTIME_DIR / LD_PRELOAD
# dance (and the "re-source after building diaspora" step) are therefore dropped.

# lmod bootstrap (some PBS shells start without `module`)
if ! command -v module >/dev/null 2>&1; then
    for _f in /etc/profile.d/z00_lmod.sh /etc/profile.d/lmod.sh; do
        [ -f "$_f" ] && { . "$_f"; break; }
    done
fi

# compiler + MPI via MODULES only (never absolute lib paths). ENV_MODULES may be
# set by the caller from config; else per-profile defaults.
: "${ENV_MODULES:=$([[ $ENV_PROFILE == polaris ]] && echo 'PrgEnv-gnu gcc-native/13.2' || echo 'gcc/13.2.0 openmpi/4.1.8')}"
# shellcheck disable=SC2086
command -v module >/dev/null 2>&1 && module load $ENV_MODULES 2>/dev/null || true

export CC="${CC:-$(command -v gcc || command -v cc || true)}"
export CXX="${CXX:-$(command -v g++ || command -v c++ || true)}"

env_prepend() {  # env_prepend VAR DIR  (dedups; no-op if DIR missing)
    local var="$1" dir="$2"
    [[ -n "$dir" && -d "$dir" ]] || return 0
    case ":${!var:-}:" in *:"$dir":*) ;; *) export "$var=$dir${!var:+:${!var}}" ;; esac
}
