#!/bin/bash
# Launched by multinode-percore.pbs via mpiexec, ONE INSTANCE PER CORE. It sets
# up this node's HSN iface + the darshan/mofka env, then EXECs the io_mpi binary
# so this shell is REPLACED by the MPI rank -- exec keeps the PID mpiexec wired
# up, so MPI_Init still connects all ranks into one MPI_COMM_WORLD.
#
# This is the per-core analogue of client-node.sh (which runs the non-MPI
# io_test once per node).
set -uo pipefail
RUN_DIR="$1"
ROOT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$ROOT/server/env.sh"

HOST=$(hostname -s)
# pin this node's HSN iface for the client-side transport (same as client-node.sh)
CLI_IP=$(hostname -i 2>/dev/null | awk '{print $1}')
FI_IFACE=$(ip -4 -o addr show 2>/dev/null | awk -v ip="$CLI_IP" '$4 ~ ip"/" {print $2; exit}')
[[ -n "$FI_IFACE" ]] && export FI_TCP_IFACE="$FI_IFACE"

# MODE (3rd arg): mofka (default) = stream to broker; native = darshan, no streaming;
# none = no darshan at all (pure app baseline). Default keeps multinode-percore.pbs unchanged.
# 4th+ args (mofka only): batch_size, max_num_batches, flush_ms -- absent = adaptive default,
# so the 2/3-arg callers (multinode-percore.pbs) are unaffected.
MODE="${3:-mofka}"
# compute pad (7th arg) applies to ALL modes -> export before the none-mode exec below
PAD="${7:-}"; [[ -n "$PAD" && "$PAD" != "-" ]] && export IO_PAD_SEC="$PAD"
WORKDIR="$RUN_DIR/wl_${MODE}_$HOST"; mkdir -p "$WORKDIR"   # per-mode dir; all ranks on a host share it

# MODE=none: pure application, no darshan
if [[ "$MODE" == none ]]; then
    exec "$ROOT/workloads/io_mpi" "$WORKDIR"
fi

# darshan modes need the lib + a dated log dir; --without-mpi build needs NONMPI=1
# (else the constructor never fires, the producer is never made, sends early-return)
DARSHAN_LIB="$(darshan_lib)"
[[ -n "$DARSHAN_LIB" ]] || { echo "[cli-mpi $HOST] FAIL: no libdarshan under $DARSHAN_PREFIX/lib"; exit 1; }
darshan_ensure_logdir >/dev/null
export DARSHAN_ENABLE_NONMPI=1

# MODE=mofka: also stream -- wait for the broker, then enable the connector + timers
if [[ "$MODE" == mofka ]]; then
    for i in $(seq 1 120); do [[ -f "$RUN_DIR/SERVER_READY" ]] && break; sleep 1; done
    [[ -f "$RUN_DIR/SERVER_READY" ]] || { echo "[cli-mpi $HOST] FAIL: server never ready"; exit 1; }
    export DARSHAN_MOFKA_ENABLE=1
    export DARSHAN_MOFKA_GROUP_FILE="$RUN_DIR/mofka.json"
    export DARSHAN_MOFKA_TOPIC=darshan
    export DARSHAN_MOFKA_ENABLE_POSIX=1
    export DARSHAN_MOFKA_TIMING=1   # per-rank init/send/finalize -> clients.out (DARSHAN_MOFKA_VERBOSE stays off)
    # optional producer batch knobs (4th+ args). Absent -> connector default (adaptive).
    BATCH="${4:-}"
    if [[ -n "$BATCH" && "$BATCH" != "-" ]]; then
        export DARSHAN_MOFKA_BATCH="$BATCH"
        [[ -n "${5:-}" ]] && export DARSHAN_MOFKA_MAX_BATCHES="$5"
        [[ -n "${6:-}" ]] && export DARSHAN_MOFKA_FLUSH_MS="$6"
    fi
fi

export LD_PRELOAD="$DARSHAN_LIB"
exec "$ROOT/workloads/io_mpi" "$WORKDIR"
