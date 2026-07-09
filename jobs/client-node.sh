#!/bin/bash
# Runs on EACH client node. Waits for the server's mofka.json, then runs the
# io_test workload under darshan so every POSIX event streams across the HSN to
# the mofka server on node 0.
set -uo pipefail
RUN_DIR="$1"
# ROOT is passed by multinode.pbs; fall back to deriving it from script location.
ROOT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$ROOT/server/env.sh"

HOST=$(hostname -s)
# pin the same HSN iface for the client-side transport
CLI_IP=$(hostname -i 2>/dev/null | awk '{print $1}')
FI_IFACE=$(ip -4 -o addr show 2>/dev/null | awk -v ip="$CLI_IP" '$4 ~ ip"/" {print $2; exit}')
[[ -n "$FI_IFACE" ]] && export FI_TCP_IFACE="$FI_IFACE"

for i in $(seq 1 120); do [[ -f "$RUN_DIR/SERVER_READY" ]] && break; sleep 1; done
[[ -f "$RUN_DIR/SERVER_READY" ]] || { echo "[cli $HOST] FAIL: server never ready"; exit 1; }

export DARSHAN_MOFKA_ENABLE=1
export DARSHAN_MOFKA_GROUP_FILE="$RUN_DIR/mofka.json"
export DARSHAN_MOFKA_TOPIC=darshan
export DARSHAN_MOFKA_ENABLE_POSIX=1
export DARSHAN_MOFKA_VERBOSE=1
export DARSHAN_ENABLE_NONMPI=1

WORKDIR="$RUN_DIR/wl_$HOST"; mkdir -p "$WORKDIR"
echo "[cli $HOST] ip=$CLI_IP iface=${FI_IFACE:-?} -> dialing $(grep -oE 'ofi\+tcp://[0-9.]+:[0-9]+' "$RUN_DIR/mofka.json")"
DARSHAN_LIB="$(darshan_lib)"
[[ -n "$DARSHAN_LIB" ]] || { echo "[cli $HOST] FAIL: no libdarshan under $DARSHAN_PREFIX/lib"; exit 1; }
darshan_ensure_logdir >/dev/null   # pre-create the dated darshan-log dir (no warning)
LD_PRELOAD="$DARSHAN_LIB" "$ROOT/workloads/io_test" "$WORKDIR"
echo "[cli $HOST] workload exit=$?"
