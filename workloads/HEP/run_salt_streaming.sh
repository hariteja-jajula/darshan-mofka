#!/bin/bash
set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
HEP="$ROOT/workloads/HEP"

SIF="$HEP/salt-dev.sif"
DARSHAN_LIB="${DARSHAN_LIB_SO:-$ROOT/darshan/install/lib/libdarshan.so}"

mkdir -p \
    "$HEP/dummy_data" \
    "$HEP/darshan_logs" \
    "$HEP/logs"

# ---------------------------------------------------------------------------
# Required inputs from the EXISTING streaming harness.
# Do not create a separate Mofka configuration here.
# ---------------------------------------------------------------------------

: "${DARSHAN_MOFKA_GROUP_FILE:?DARSHAN_MOFKA_GROUP_FILE was not supplied by streaming harness}"

TOPIC="${DARSHAN_MOFKA_TOPIC:-darshan}"
ENABLE="${DARSHAN_MOFKA_ENABLE:-1}"
TIMING="${DARSHAN_MOFKA_TIMING:-1}"
FLUSH_MS="${DARSHAN_MOFKA_FLUSH_MS:-30000}"
MAX_BATCHES="${DARSHAN_MOFKA_MAX_BATCHES:-512}"
SENDER_THREADS="${DIASPORA_C_SENDER_THREADS:-1}"

if [ ! -f "$SIF" ]; then
    echo "ERROR: missing SALT image: $SIF" >&2
    exit 1
fi

if [ ! -f "$DARSHAN_LIB" ]; then
    echo "ERROR: missing custom Darshan: $DARSHAN_LIB" >&2
    exit 1
fi

if [ ! -r "$DARSHAN_MOFKA_GROUP_FILE" ]; then
    echo "ERROR: Mofka group file not readable: $DARSHAN_MOFKA_GROUP_FILE" >&2
    exit 1
fi

echo "=== HEP/SALT streaming workload ==="
echo "SIF=$SIF"
echo "DARSHAN_LIB=$DARSHAN_LIB"
echo "DARSHAN_MOFKA_GROUP_FILE=$DARSHAN_MOFKA_GROUP_FILE"
echo "DARSHAN_MOFKA_TOPIC=$TOPIC"


# ---------------------------------------------------------------------------
# Container library resolution for the custom Darshan preload.
#
# libdarshan.so pulls in two families of shared objects that do NOT exist
# inside the SALT image and are NOT covered by the -B "$ROOT" bind:
#
#   1. Spack-stack libs (libnlohmann_json_schema_validator.so.2, plus the
#      mofka/margo/mercury/thallium view) live under the *shared parent* of
#      $ROOT: a sibling tree holds the spack install and $ROOT/install/_spack
#      symlinks into it. They are already on LD_LIBRARY_PATH in /lus/... form
#      (env/workload.sh prepends MOFKA_SPACK_VIEW), but the underlying path is
#      not bind-mounted. Binding the shared parent (resolved /lus real path)
#      makes every /lus/... LD_LIBRARY_PATH entry reachable inside the image.
#
#   2. liblustreapi.so.1 is a hard DT_NEEDED of libdarshan.so itself. It is a
#      host system lib (/usr/lib64), present on the compute node but absent
#      from the Ubuntu-based image, and it drags a small chain (liblnetconfig,
#      libyaml-0, libnl-genl-3, libnl-3). Stage exactly those into a private
#      dir and bind it in; libkeyutils.so.1 already exists in the image.
# ---------------------------------------------------------------------------

# Resolved /lus real path of the shared parent that contains BOTH trees.
SHARED_PARENT="$(cd "$(dirname "$(readlink -f "$ROOT")")" && pwd)"

# Stage the host system-lib chains the image lacks (fresh each run).
# NOTE: do NOT use ldconfig here -- it lives in /sbin and is not on PATH in the
# compute-node shell launched under mpiexec; a $(ldconfig ...) miss returns 127
# and aborts under set -e. These are plain host system libs, so search fixed
# dirs directly.
#
# Two families of host libs are staged:
#   (a) liblustreapi.so.1 chain -- a hard DT_NEEDED of libdarshan.so itself.
#   (b) the cray-mpich leaf chain pulled in TRANSITIVELY when the connector
#       dlopen()s libmofka.so at runtime (the Mofka client driver). libmofka.so
#       -> libbedrock-client.so.0 -> libmpi_gnu_123.so.12 (cray-mpich) ->
#       libfabric/libpmi/libgfortran/... . Most of that chain self-resolves via
#       the libs' baked RPATH once /opt/cray is bind-mounted (below), but a
#       handful of leaves live in the host /usr/lib64 and are ABSENT from the
#       Ubuntu image: libgfortran/libquadmath/libatomic (cray-mpich fortran
#       runtime), libcxi (Slingshot), and libcurl + its OpenLDAP/SASL chain
#       (libldap_r/liblber/libsasl2, pulled by libpmi). Stage exactly those.
# libpmi.so.0/libpmi2.so.0 live under /opt/cray/pe/lib64 (bind-mounted), but are
# staged here too so the loader finds them without needing that dir on the path.
HOSTLIB="$HEP/_hostlib"
rm -rf "$HOSTLIB"; mkdir -p "$HOSTLIB"
for _l in liblustreapi.so.1 liblnetconfig.so.4 libyaml-0.so.2 \
          libnl-genl-3.so.200 libnl-3.so.200 \
          libgfortran.so.5 libquadmath.so.0 libatomic.so.1 \
          libcxi.so.1 libcurl.so.4 \
          libldap_r-2.4.so.2 liblber-2.4.so.2 libsasl2.so.3 \
          libpmi.so.0 libpmi2.so.0; do
    _src=""
    for _d in /usr/lib64 /lib64 /opt/cray/pe/lib64 \
              /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu; do
        if [ -e "$_d/$_l" ]; then _src="$_d/$_l"; break; fi
    done
    if [ -n "$_src" ]; then
        cp -aL "$_src" "$HOSTLIB/$_l" 2>/dev/null || true
    else
        echo "WARN: host lib not found on node: $_l" >&2
    fi
done

# LD_LIBRARY_PATH injected INTO the container:
#   * $HOSTLIB          -- the staged host system chains above.
#   * $MOFKA_SPACK_VIEW/lib -- holds libmofka.so (the driver the connector
#     dlopen()s). This opt-prefix lib dir is CLEAN: it has NO
#     libdiaspora-stream-api.so.0 and none of the risky shadowers
#     (libstdc++/libz/libgcc_s/libc/libm), so adding it does not disturb the
#     otherwise-RUNPATH-resolved chain -- libmofka + all its Mochi deps
#     self-resolve via baked RPATH, and libdiaspora-stream-api still comes from
#     the clean LOCAL install copy (verified: 0 not-found, no cray-mpich pulled
#     into diaspora).
#   * /opt/cray/pals/.../lib -- holds libpals.so.0 (pulled by cray-mpich).
# Deliberately NOT the spack ENV VIEW dir (.spack-env/view/lib): that copy of
# libdiaspora-stream-api.so.0 IS linked against cray-mpich and would shadow the
# clean local copy.
_PALS_LIB=""
for _d in /opt/cray/pals/default/lib /opt/cray/pals/*/lib; do
    if [ -e "$_d/libpals.so.0" ]; then _PALS_LIB="$_d"; break; fi
done
STACK_LD="$HOSTLIB"
[ -n "${MOFKA_SPACK_VIEW:-}" ] && STACK_LD="$STACK_LD:$MOFKA_SPACK_VIEW/lib"
[ -n "$_PALS_LIB" ] && STACK_LD="$STACK_LD:$_PALS_LIB"

BINDS=(
    -B "$ROOT:$ROOT"
    -B "$SHARED_PARENT:$SHARED_PARENT"
    -B /opt/cray:/opt/cray
    -B "$HEP/dummy_data:/workspace/dummy_data"
    -B "$HEP/darshan_logs:/workspace/darshan_logs"
    -B "$HEP/logs:/workspace/logs"
)

# Run from HEP so SALT retains the same working-directory behavior as
# the already-tested manual execution.
cd "$HEP"

# ---------------------------------------------------------------------------
# Polaris provides apptainer via a module; compute-node shells launched under
# mpiexec do not have it on PATH by default. Load it before any apptainer call
# (mirrors the original job.sh). Source lmod init in case the module function
# did not survive into this shell.
# ---------------------------------------------------------------------------
if ! command -v apptainer >/dev/null 2>&1; then
    if ! command -v module >/dev/null 2>&1; then
        # shellcheck disable=SC1090
        source "${MODULESHOME:-/opt/cray/pe/lmod/lmod}/init/bash" 2>/dev/null || true
    fi
    module use /soft/modulefiles 2>/dev/null || true
    module load spack-pe-base   2>/dev/null || true
    module load apptainer       2>/dev/null || true
fi
if ! command -v apptainer >/dev/null 2>&1; then
    echo "ERROR: apptainer not found after module load" >&2
    exit 1
fi
echo "apptainer=$(command -v apptainer)"

# ---------------------------------------------------------------------------
# Smoke validation: GPU + custom Darshan dependencies.
#
# IMPORTANT:
# LD_PRELOAD is explicitly removed from the host-side Apptainer launcher.
# The custom Darshan preload is supplied only to the contained SALT process.
# ---------------------------------------------------------------------------

echo "=== HEP smoke validation ==="

env -u LD_PRELOAD -u BASH_ENV -u ENV \
    APPTAINERENV_PREPEND_LD_LIBRARY_PATH="$STACK_LD" \
    apptainer exec \
        --nv \
        --fakeroot \
        "${BINDS[@]}" \
        "$SIF" \
        env PYTHONNOUSERSITE=1 \
        bash -c '
            python - <<'"'"'PY'"'"'
import torch

print("torch version:", torch.__version__)
print("torch CUDA build:", torch.version.cuda)
print("torch path:", torch.__file__)
print("cuda available:", torch.cuda.is_available())

if torch.cuda.is_available():
    print("GPU:", torch.cuda.get_device_name(0))
PY
        '

echo "=== custom Darshan dependencies inside container ==="

env -u LD_PRELOAD -u BASH_ENV -u ENV \
    apptainer exec \
        --nv \
        --fakeroot \
        "${BINDS[@]}" \
        --env "HEP_EXTRA_LD=$STACK_LD" \
        "$SIF" \
        bash --noprofile --norc -c "
            export LD_LIBRARY_PATH=\"\$HEP_EXTRA_LD:\${LD_LIBRARY_PATH:-}\"
            echo 'Darshan library: $DARSHAN_LIB'
            echo
            ldd '$DARSHAN_LIB'
        "

# ---------------------------------------------------------------------------
# Environment explicitly passed into SALT.
# ---------------------------------------------------------------------------

APPT_ENV=(
    --env "PYTHONNOUSERSITE=1"
    # Apptainer silently DROPS APPTAINERENV_PREPEND_LD_LIBRARY_PATH here, so the
    # extra stack dirs (staged host lustre chain + darshan lib) are passed as a
    # plain --env var and prepended to LD_LIBRARY_PATH INSIDE the container shell
    # below. (libnlohmann + the spack view resolve via the diaspora libs' baked
    # RUNPATH once SHARED_PARENT is bind-mounted; liblustreapi.so.1 has no RUNPATH
    # help and is found only via this LD_LIBRARY_PATH entry.)
    --env "HEP_EXTRA_LD=$STACK_LD"
    --env "DARSHAN_MOFKA_GROUP_FILE=$DARSHAN_MOFKA_GROUP_FILE"
    --env "DARSHAN_MOFKA_TOPIC=$TOPIC"
    --env "DARSHAN_MOFKA_ENABLE=$ENABLE"
    --env "DARSHAN_MOFKA_TIMING=$TIMING"
    --env "DARSHAN_MOFKA_FLUSH_MS=$FLUSH_MS"
    --env "DARSHAN_MOFKA_MAX_BATCHES=$MAX_BATCHES"
    --env "DIASPORA_C_SENDER_THREADS=$SENDER_THREADS"
)

# Baseline = no Darshan at all.
# Runtime-only + streaming = custom Darshan preload.
#
# CRITICAL: do NOT pass LD_PRELOAD as an --env here. Apptainer sets --env vars
# in the process environment BEFORE the container's /usr/bin/bash execs, so bash
# itself would be preloaded with libdarshan.so -> which DT_NEEDs liblustreapi.so.1
# -> not yet on LD_LIBRARY_PATH at exec time -> "bash: error while loading shared
# libraries: liblustreapi.so.1" and the rank dies with 127 before running a line.
# Instead pass the lib under a NON-magic name and turn it into LD_PRELOAD inside
# the shell, AFTER LD_LIBRARY_PATH is set (below).
if [ "${NO_DARSHAN:-0}" != 1 ]; then
    APPT_ENV+=(
        --env "HEP_DARSHAN_PRELOAD=$DARSHAN_LIB"
        --env "DARSHAN_LD_PRELOAD=$DARSHAN_LIB"
    )
fi

# Preserve these knobs only if the existing harness supplied them.
if [ -n "${DARSHAN_MOFKA_BATCH:-}" ]; then
    APPT_ENV+=(
        --env "DARSHAN_MOFKA_BATCH=$DARSHAN_MOFKA_BATCH"
    )
fi

if [ -n "${DARSHAN_MOFKA_VERBOSE:-}" ]; then
    APPT_ENV+=(
        --env "DARSHAN_MOFKA_VERBOSE=$DARSHAN_MOFKA_VERBOSE"
    )
fi

if [ -n "${DARSHAN_MOFKA_FINAL_SWEEP:-}" ]; then
    APPT_ENV+=(
        --env "DARSHAN_MOFKA_FINAL_SWEEP=$DARSHAN_MOFKA_FINAL_SWEEP"
    )
fi

echo "=== launching SALT/GN2 ==="

# Do not let a host LD_PRELOAD affect the Apptainer executable itself.
# Pass custom libdarshan.so only into the container.
env -u LD_PRELOAD -u BASH_ENV -u ENV \
    apptainer exec \
        --nv \
        --fakeroot \
        "${BINDS[@]}" \
        "${APPT_ENV[@]}" \
        "$SIF" \
        bash -c '
            # Order matters: set LD_LIBRARY_PATH BEFORE promoting the darshan lib
            # to LD_PRELOAD, so the preload chain (esp. liblustreapi.so.1) is
            # resolvable. LD_PRELOAD was deliberately NOT passed as --env (that
            # would preload bash itself before this runs). See APPT_ENV comment.
            export LD_LIBRARY_PATH="$HEP_EXTRA_LD:${LD_LIBRARY_PATH:-}"
            if [ -n "${HEP_DARSHAN_PRELOAD:-}" ]; then
                export LD_PRELOAD="$HEP_DARSHAN_PRELOAD"
            fi
            echo "inside container:"
            echo "  PYTHONNOUSERSITE=$PYTHONNOUSERSITE"
            echo "  LD_PRELOAD=${LD_PRELOAD:-<unset>}"
            echo "  DARSHAN_MOFKA_GROUP_FILE=$DARSHAN_MOFKA_GROUP_FILE"
            echo "  DARSHAN_MOFKA_TOPIC=$DARSHAN_MOFKA_TOPIC"

            exec salt fit --force \
                --config /workspace/salt/salt/configs/GN2/GN2.yaml \
                --trainer.devices=1 \
                --data.batch_size=64 \
                --data.num_workers=4 \
                --data.persistent_workers=true \
                --data.multiprocessing_context=spawn \
                --data.train_file=/workspace/dummy_data/train.h5 \
                --data.val_file=/workspace/dummy_data/val.h5 \
                --data.norm_dict=/workspace/dummy_data/norm_dict.yaml \
                --data.class_dict=/workspace/dummy_data/class_dict.yaml \
                --data.num_train=1000 \
                --data.num_val=200 \
                --trainer.max_epochs=2 \
                --name=GN2_streaming
        '