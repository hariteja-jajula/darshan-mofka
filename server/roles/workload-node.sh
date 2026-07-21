#!/bin/bash
# workload-node.sh -- the WORKLOAD role of the split-node darshan-mofka demo.
#
# Runs on N nodes (one instance per node, or per rank). It needs NONE of the
# server side: no broker, no mongod, no python venv. It only needs
#   - the Darshan runtime lib (built on eagle, shared)  -> LD_PRELOAD
#   - the spack view libs on LD_LIBRARY_PATH             -> source server/env.sh
#   - the shared broker group file                       -> $RUN_DIR/mofka.json
# all of which live on the shared (eagle) filesystem.
#
# It waits for the server node's READY marker, runs the given workload command
# under the Darshan->Mofka connector, and (optionally) signals DONE.
#
# Usage:
#   RUN_DIR=<shared eagle dir> [WORKLOAD_IS_MPI=0|1] [SIGNAL_DONE=1] \
#     server/roles/workload-node.sh <workload cmd> [args...]
#
# Env:
#   RUN_DIR         shared run dir on eagle (REQUIRED; same as server-node)
#   TOPIC           mofka topic (default: darshan; MUST match server)
#   WORKLOAD_IS_MPI 1 = real MPI job (do NOT set DARSHAN_ENABLE_NONMPI); default 0
#   SIGNAL_DONE     1 = touch $RUN_DIR/DONE after this workload (single-workload
#                   runs). For multi-workload orchestration, let the launcher do it.
#   READY_MAX       seconds to wait for server READY (default: 600)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source server/env.sh --polaris
module unload darshan 2>/dev/null || true
export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:${PKG_CONFIG_PATH#/soft/perftools/darshan/darshan-3.4.4/lib/pkgconfig:}"
export DARSHAN_LOGPATH="${DARSHAN_LOGPATH:-$ROOT/darshan-logs}"
darshan_ensure_logdir >/dev/null

: "${RUN_DIR:?set RUN_DIR to the shared (eagle) run dir the server node uses}"
TOPIC="${TOPIC:-darshan}"
WORKLOAD_IS_MPI="${WORKLOAD_IS_MPI:-0}"
SIGNAL_DONE="${SIGNAL_DONE:-0}"
READY_MAX="${READY_MAX:-600}"
GROUP="$RUN_DIR/mofka.json"

[[ $# -ge 1 ]] || { echo "usage: RUN_DIR=... $0 <workload cmd> [args...]"; exit 2; }

say() { printf '\n[workload-node %s] %s\n' "$(hostname -s)" "$*"; }

# --- wait for the server node to be READY -------------------------------------
say "waiting for server READY ($RUN_DIR/READY, timeout ${READY_MAX}s)"
waited=0
until [[ -f "$RUN_DIR/READY" ]]; do
    [[ -f "$RUN_DIR/FAILED" ]] && { echo "server reported FAILED; aborting"; exit 1; }
    sleep 2; waited=$((waited+2))
    [[ "$waited" -ge "$READY_MAX" ]] && { echo "timed out waiting for server READY"; exit 1; }
done
[[ -s "$GROUP" ]] || { echo "READY seen but no group file at $GROUP"; exit 1; }
say "server READY; group file present"

LIB="$(darshan_lib)"
[[ -e "$LIB" ]] || { echo "darshan lib not found ($LIB); build it first (darshan/build.sh)"; exit 1; }
say "LD_PRELOAD=$LIB"

# --- common connector env -----------------------------------------------------
COMMON_ENV=(
    DARSHAN_MOFKA_ENABLE=1
    DARSHAN_MOFKA_GROUP_FILE="$GROUP"
    DARSHAN_MOFKA_TOPIC="$TOPIC"
    DARSHAN_MOFKA_TIMING=1
    DARSHAN_MOFKA_FLUSH_MS=10000
    DARSHAN_LOGPATH="$DARSHAN_LOGPATH"
    LD_PRELOAD="$LIB"
)
# non-MPI workloads need DARSHAN_ENABLE_NONMPI; real MPI jobs must NOT set it.
[[ "$WORKLOAD_IS_MPI" = "1" ]] || COMMON_ENV+=(DARSHAN_ENABLE_NONMPI=1)

say "running workload: $*"
env "${COMMON_ENV[@]}" "$@"
rc=$?
say "workload exited rc=$rc"

if [[ "$SIGNAL_DONE" = "1" ]]; then
    touch "$RUN_DIR/DONE"
    say "DONE marker written -> $RUN_DIR/DONE"
fi
exit "$rc"
