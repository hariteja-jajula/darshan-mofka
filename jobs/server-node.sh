#!/bin/bash
# Runs on the SERVICE node (node 0). Starts bedrock bound to the HSN iface so
# client nodes can dial it, creates the topic+partition, writes mofka.json into
# the shared run dir, then idles until SHUTDOWN appears.
set -uo pipefail
RUN_DIR="$1"
# ROOT is passed by multinode.pbs so we don't depend on env-forwarding or on
# knowing an absolute path. Fall back to deriving it from this script's location.
ROOT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONFIG="${3:-$ROOT/server/bedrock-config.json}"   # 3rd arg: per-run bedrock config (e.g. rpc_thread sweep)
source "$ROOT/server/env.sh"

SVC_HOST=$(hostname -s)
SVC_IP=$(hostname -i 2>/dev/null | awk '{print $1}')
FI_IFACE=$(ip -4 -o addr show 2>/dev/null | awk -v ip="$SVC_IP" '$4 ~ ip"/" {print $2; exit}')
[[ -n "$FI_IFACE" ]] && export FI_TCP_IFACE="$FI_IFACE"
echo "[svc] host=$SVC_HOST ip=$SVC_IP iface=${FI_IFACE:-?} proto=$MOFKA_PROTOCOL"

cd "$RUN_DIR"
rm -f mofka.json SHUTDOWN
# Launch the broker UNPINNED. It is a mostly-idle, in-memory, single-process
# service: quiet -> ~0 CPU, and the OS schedules it wherever there is slack, so
# it only ever uses what it needs. Co-location already avoids dedicating a whole
# node to it; pinning to a fixed core set would just constrain the broker without
# reserving anything, so we keep the overhead minimal and don't pin.
echo "[svc] launching bedrock (unpinned)"
bedrock "$MOFKA_PROTOCOL" -c "$CONFIG" \
        -v info > "$RUN_DIR/bedrock.log" 2>&1 &
BEDROCK_PID=$!

for i in $(seq 1 60); do [[ -f mofka.json ]] && break; sleep 0.5; done
[[ -f mofka.json ]] || { echo "[svc] FAIL: no mofka.json"; tail -30 bedrock.log; exit 1; }
echo "[svc] mofka.json:"; sed 's/^/    /' mofka.json

mofkactl topic create darshan --groupfile mofka.json 2>/dev/null || true
mofkactl partition add darshan --rank 0 --type memory --groupfile mofka.json 2>/dev/null || true
echo "[svc] topic 'darshan' ready; signalling clients"
touch "$RUN_DIR/SERVER_READY"

echo "[svc] idling until SHUTDOWN"
for i in $(seq 1 600); do [[ -f "$RUN_DIR/SHUTDOWN" ]] && break; sleep 1; done
echo "[svc] SHUTDOWN seen; stopping bedrock"
kill "$BEDROCK_PID" 2>/dev/null
echo "[svc] done"
