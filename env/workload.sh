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

# pin the module compiler's libstdc++ ahead of the view's older gcc-runtime
cxx_runtime_pin

# DLIO (install/_dlio_venv) uses a pip mpi4py built against the MPICH ABI, which needs
# libmpi.so.12. cray-mpich ships that ABI soname only under its lib-abi-mpich subdir (the
# cray-mpich-abi module's dir); the normal lib/ has libmpi_gnu_123.so.12 instead, so a plain
# `import mpi4py.MPI` fails "libmpi.so.12: cannot open shared object file". Add the ABI dir
# (module-derived from MPICH_DIR, never hardcoded) so DLIO's mpi4py binds cray-mpich at
# runtime. Only affects the dlio venv; other workloads link cray-mpich via the cc wrapper.
if [[ "$ENV_PROFILE" == polaris && -n "${MPICH_DIR:-}" && -d "$MPICH_DIR/lib-abi-mpich" ]]; then
    env_prepend LD_LIBRARY_PATH "$MPICH_DIR/lib-abi-mpich"
fi

# Pick the libdarshan.so to LD_PRELOAD. An MPI workload MUST use the MPI-aware build
# (darshan/install-mpi, built by `DARSHAN_MPI=1 ./build.sh`): with the non-MPI build,
# Darshan never instruments MPI-IO (the MPIIO module never fires) and, on a real MPI
# program, only a handful of ranks finalize/write a native log -- which is exactly why
# the MPI overnight run produced 10 nprocs=1 POSIX/STDIO logs instead of a proper set.
# dlio is ALSO a real MPI app (mpi4py MPI.Init/Finalize): with the plain build the
# process is inert (no MPI symbols; dlio sets DARSHAN_DISABLE=1; NONMPI unset) so it
# produces NO log -> a vacuous overhead study. It must use install-mpi too. The dlio mpich
# pin in lib/run.sh:workload_env is REQUIRED alongside install-mpi -- install-mpi alone
# crashes dlio on the 8.1.28-vs-9.0.1 cray-mpich skew. For c/python-ml use the plain build.
# WL_TYPE drives the choice; an explicit DARSHAN_PREFIX override still wins.
darshan_lib() {
    local d
    if [[ -n "${DARSHAN_PREFIX_OVERRIDE:-}" ]]; then
        d="$DARSHAN_PREFIX_OVERRIDE/lib"
    elif [[ ( "${WL_TYPE:-}" == "mpi" || "${WL_TYPE:-}" == "dlio" ) && -e "$ENV_ROOT/darshan/install-mpi/lib/libdarshan.so" ]]; then
        d="$ENV_ROOT/darshan/install-mpi/lib"
    else
        d="$DARSHAN_PREFIX/lib"
    fi
    [[ -e "$d/libdarshan.so" ]] && { printf '%s\n' "$d/libdarshan.so"; return; }
    compgen -G "$d/libdarshan.so*" | sort | head -1
}

# create + echo today's DARSHAN_LOGPATH subdir (Darshan writes native logs here)
darshan_ensure_logdir() {
    local d="$DARSHAN_LOGPATH/$(date +%Y)/$(date +%-m)/$(date +%-d)"
    mkdir -p "$d" 2>/dev/null || true
    printf '%s\n' "$d"
}
