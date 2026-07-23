#!/bin/bash
# env/polaris.sh -- ALCF Polaris profile. Sourced by env/server.sh and
# env/workload.sh AFTER env/common.sh. Sets MOFKA_SPACK_VIEW, MOFKA_PYTHONPATH,
# MOFKA_PROTOCOL_DEFAULT/BEDROCK_PROTOCOL, cmake on PATH, and libfabric via its module.

# Profile default transport, used when server.config says protocol: auto.
export MOFKA_PROTOCOL_DEFAULT="${MOFKA_PROTOCOL_DEFAULT:-ofi+tcp}"
export BEDROCK_PROTOCOL="${BEDROCK_PROTOCOL:-ofi+tcp}"
export OPENBLAS_NUM_THREADS="${OPENBLAS_NUM_THREADS:-1}"

# Native stack: repo-local install/_spack first, else legacy transferred view.
_envs="$ENV_ROOT/install/_spack/var/spack/environments"
if [[ -f "$ENV_ROOT/install/_spack/share/spack/setup-env.sh" ]]; then
    . "$ENV_ROOT/install/_spack/share/spack/setup-env.sh"
    spack env activate "${ENV_SPACK_ENV:-flowcept-mofka-polaris}" 2>/dev/null || true
    command -v spack >/dev/null 2>&1 && \
        export MOFKA_SPACK_VIEW="${MOFKA_SPACK_VIEW:-$(spack location -i mofka+python 2>/dev/null || true)}"
fi
if [[ -z "${MOFKA_SPACK_VIEW:-}" ]]; then
    _legacy="$(cd "$ENV_ROOT/.." && pwd)/../mofka_tests/spack/var/spack/environments"
    for _n in flowcept-mofka-polaris flowcept-mofka; do
        [[ -d "$_legacy/$_n/.spack-env/view" ]] && { export MOFKA_SPACK_VIEW="$_legacy/$_n/.spack-env/view"; break; }
    done
fi

# libfabric via module (NEVER a hardcoded /opt/cray path); its lib dir is added
# to LD_LIBRARY_PATH by env/common's env_prepend using the module-provided prefix.
command -v module >/dev/null 2>&1 && module load libfabric 2>/dev/null || true
env_prepend LD_LIBRARY_PATH "${CRAY_LIBFABRIC_PREFIX:+$CRAY_LIBFABRIC_PREFIX/lib64}"

# cmake from the view if PATH lacks a new-enough one.
if ! command -v cmake >/dev/null 2>&1; then
    [[ -d "$MOFKA_SPACK_VIEW/bin" ]] && env_prepend PATH "$MOFKA_SPACK_VIEW/bin"
fi

unset _envs _legacy _n
