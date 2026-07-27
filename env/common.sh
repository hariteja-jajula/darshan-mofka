#!/bin/bash
# env/common.sh -- shared base for the server and workload envs.
# Loads the compiler/MPI modules and provides env_prepend(). Sourced by
# env/server.sh and env/workload.sh (not directly). Needs ENV_PROFILE set.

# lmod bootstrap (some PBS shells start without `module`)
if ! command -v module >/dev/null 2>&1; then
    for _f in /etc/profile.d/z00_lmod.sh /etc/profile.d/lmod.sh; do
        [ -f "$_f" ] && { . "$_f"; break; }
    done
fi

# compiler + MPI via MODULES only (never absolute lib paths). ENV_MODULES may be
# set by the caller from config; else per-profile defaults.
: "${ENV_MODULES:=$([[ $ENV_PROFILE == polaris ]] && echo 'PrgEnv-gnu gcc-native/12.3' || echo 'gcc/13.2.0 openmpi/4.1.8')}"
# shellcheck disable=SC2086
command -v module >/dev/null 2>&1 && module load $ENV_MODULES 2>/dev/null || true

export CC="${CC:-$(command -v gcc || command -v cc || true)}"
export CXX="${CXX:-$(command -v g++ || command -v c++ || true)}"

env_prepend() {  # env_prepend VAR DIR  (dedups; no-op if DIR missing)
    local var="$1" dir="$2"
    [[ -n "$dir" && -d "$dir" ]] || return 0
    case ":${!var:-}:" in *:"$dir":*) ;; *) export "$var=$dir${!var:+:${!var}}" ;; esac
}

# cxx_runtime_pin -- put the module compiler's libstdc++ ahead of the Spack view's.
# On a compute node the view can place gcc-runtime-8.5's libstdc++ before gcc-13's, so
# pydiaspora (built against gcc-13) fails with "GLIBCXX_3.4.32 not found". The path is
# asked of the compiler ($CXX -print-file-name), never hardcoded. Call after the
# profile has activated its Spack env.
cxx_runtime_pin() {
    local lib; lib="$("${CXX:-g++}" -print-file-name=libstdc++.so.6 2>/dev/null)"
    [[ -e "$lib" ]] || return 0
    env_prepend LD_LIBRARY_PATH "$(dirname "$lib")"
    case ":${LD_PRELOAD:-}:" in *:"$lib":*) ;; *) export LD_PRELOAD="$lib${LD_PRELOAD:+:$LD_PRELOAD}" ;; esac
}

# mpi_launch -- build MPI_LAUNCH=(...) for the current profile.
#   mpi_launch <total_ranks> <ranks_per_node> [hostfile]
# Polaris uses the cray-mpich PALS launcher (mpiexec --ppn/--cpu-bind); LCRC uses
# OpenMPI (mpirun --map-by ppr:N:node + TCP --mca to dodge the verbs connect-storm).
# On Polaris `mpirun` is a symlink to PALS mpiexec, so the OpenMPI flags would ERROR
# there -- the profile split is mandatory, not cosmetic. PALS rejects --map-by/--mca and
# chokes on "slots=" hostfiles (parses the whole line as a hostname), so the hostfile
# passed here must be bare hostnames under polaris (see the writer in workloads/job.sh).
# --cpu-bind none is deliberate: this is an I/O benchmark whose ranks each run a
# Mercury/Margo progress thread for the connector; pinning rank+progress to one core
# serializes the very sends the overhead study measures.
mpi_launch() {
    local n="$1" ppn="$2" hf="${3:-}"
    if [[ "$ENV_PROFILE" == polaris ]]; then
        MPI_LAUNCH=(mpiexec -n "$n" --ppn "$ppn" --cpu-bind none)
    else
        MPI_LAUNCH=(mpirun -n "$n" --map-by ppr:"$ppn":node --mca pml ob1 --mca btl tcp,self)
    fi
    [[ -n "$hf" ]] && MPI_LAUNCH+=(--hostfile "$hf")
}
