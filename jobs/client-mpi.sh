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

# every rank waits for the broker; polling the shared run dir is cheap
for i in $(seq 1 120); do [[ -f "$RUN_DIR/SERVER_READY" ]] && break; sleep 1; done
[[ -f "$RUN_DIR/SERVER_READY" ]] || { echo "[cli-mpi $HOST] FAIL: server never ready"; exit 1; }

export DARSHAN_MOFKA_ENABLE=1
export DARSHAN_MOFKA_GROUP_FILE="$RUN_DIR/mofka.json"
export DARSHAN_MOFKA_TOPIC=darshan
export DARSHAN_MOFKA_ENABLE_POSIX=1
# REQUIRED: this darshan is a --without-mpi build (see server/build-darshan.sh),
# so it does NOT hook MPI_Init. Every rank is instrumented as an independent
# process via the library constructor, which only fires when this is set. Without
# it darshan never initializes, the mofka producer is never created, and every
# connector_send early-returns -> zero events (with no error). io_mpi still uses
# MPI for launch/placement; darshan just can't stamp the MPI rank (rank stays -1).
export DARSHAN_ENABLE_NONMPI=1
# timing study: each rank prints init/finalize + one line per op to stderr, which
# the PBS captures in the run dir's clients.out (~59 lines/rank). Comment out to silence.
export DARSHAN_MOFKA_TIMING=1
# NOTE: DARSHAN_MOFKA_VERBOSE is intentionally OFF -- with hundreds of ranks its
# per-rank "producer connected" line would flood clients.out. Set it via
# `qsub -v ...` only when debugging a single small run.

WORKDIR="$RUN_DIR/wl_$HOST"; mkdir -p "$WORKDIR"   # idempotent; all ranks share it
DARSHAN_LIB="$(darshan_lib)"
[[ -n "$DARSHAN_LIB" ]] || { echo "[cli-mpi $HOST] FAIL: no libdarshan under $DARSHAN_PREFIX/lib"; exit 1; }
darshan_ensure_logdir >/dev/null

export LD_PRELOAD="$DARSHAN_LIB"
exec "$ROOT/workloads/io_mpi" "$WORKDIR"
