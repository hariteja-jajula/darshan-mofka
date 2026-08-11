#!/bin/bash
# start_server.sh -- MANUAL step 1: start the Mofka broker (bedrock) + create the darshan
# topic + partitions. Leaves server/mofka.json (the group file the consumer + producer need).
# Run this FIRST, in its own terminal, and leave it running.
#
#   cd <repo> && bash server/start_server.sh          # ofi+tcp on the login node
#   PROTOCOL=ofi+cxi bash server/start_server.sh       # on a compute node with CXI
#
# Knobs (env): PROTOCOL (default ofi+tcp), TOPIC (darshan), PARTITIONS (1), PART_TYPE (memory).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source env/server.sh >/dev/null 2>&1 || { echo "could not source env/server.sh"; exit 1; }

PROTOCOL="${PROTOCOL:-ofi+tcp}"
TOPIC="${TOPIC:-darshan}"
PARTITIONS="${PARTITIONS:-1}"
PART_TYPE="${PART_TYPE:-memory}"
SRV="$ROOT/server"
GROUP="$SRV/mofka.json"
CFG="$SRV/bedrock-config.json"

echo "=== killing any old broker ==="
pkill -f 'bedrock ' 2>/dev/null || true; sleep 1
rm -f "$GROUP" "$SRV/bedrock.log"

echo "=== starting bedrock broker (protocol=$PROTOCOL) ==="
# bedrock writes mofka.json RELATIVE to its cwd (flock "file":"mofka.json"), so we MUST
# launch it from inside server/. cxi needs the VNI-collapse shim; tcp runs bare.
cd "$SRV"
if [[ "$PROTOCOL" == *cxi* ]]; then
    bash -c "$(cxi_collapse) exec bedrock \"\$@\"" bedrock "$PROTOCOL" -c "$CFG" -v info > "$SRV/bedrock.log" 2>&1 &
else
    bedrock "$PROTOCOL" -c "$CFG" -v info > "$SRV/bedrock.log" 2>&1 &
fi
BROKER_PID=$!
cd "$ROOT"
echo "broker pid=$BROKER_PID  log=$SRV/bedrock.log"

echo "=== waiting for group file $GROUP ==="
for i in $(seq 1 60); do [ -f "$GROUP" ] && break; sleep 1; done
[ -f "$GROUP" ] || { echo "BROKER FAILED to produce mofka.json; tail bedrock.log:"; tail -20 "$SRV/bedrock.log"; exit 1; }
echo "broker up: $(grep -oE '[a-z0-9+;_]+://[0-9.]+:[0-9]+' "$GROUP" | head -1)"

echo "=== creating topic '$TOPIC' + $PARTITIONS partition(s) ($PART_TYPE) ==="
# Serializer: default (parse+dump round-trip) unless the raw-json handoff is enabled, in which
# case the topic advertises the "raw" serializer in the master DB -- both the connector producer
# and the FlowCept consumer read this back, so the choice propagates to both ends automatically.
TOPIC_SER_OPT=()
if [ -n "${DARSHAN_MOFKA_RAW_JSON:-}" ] && [ "${DARSHAN_MOFKA_RAW_JSON}" != 0 ]; then
    TOPIC_SER_OPT=( -s raw )
    echo "  (raw-json handoff: creating topic with serializer 'raw')"
fi
mofkactl topic create "$TOPIC" "${TOPIC_SER_OPT[@]}" --groupfile "$GROUP" 2>/dev/null || echo "  (topic may already exist)"
for p in $(seq 0 $(( PARTITIONS - 1 ))); do
    mofkactl partition add "$TOPIC" --rank 0 --type "$PART_TYPE" --groupfile "$GROUP" 2>/dev/null \
        || echo "  WARN: partition add $p failed"
done
echo "=== topic ready. group file: $GROUP ==="
mofkactl topic list --groupfile "$GROUP" 2>/dev/null || true

echo
echo "SERVER READY. Leave this terminal running."
echo "  next: (terminal 2) bash Client/capture_flowcept.sh"
echo "  then: (terminal 3) bash server/run_producer.sh <workload>"
echo "Press Ctrl-C here to stop the broker when done."
trap 'echo; echo "stopping broker $BROKER_PID"; kill "$BROKER_PID" 2>/dev/null; pkill -f "bedrock " 2>/dev/null || true' EXIT
wait "$BROKER_PID"
