#!/bin/bash
# server-node.sh -- the SERVER role of the split-node darshan-mofka demo.
#
# Runs on ONE node. Brings up the whole ingest side and publishes the coordination
# artifacts to a shared (eagle) run dir that the workload nodes read:
#     Mofka broker (bedrock)  -> writes mofka.json (routable HSN address)
#     mongod                  -> FlowCept's sink
#     FlowCept consumer       -> drains the darshan topic into MongoDB
# then writes a READY marker and idles until it sees a DONE marker (workload side
# signals completion), at which point it flushes + exports MongoDB -> JSONL and
# tears everything down.
#
# The server<->workload coupling is ENTIRELY through $RUN_DIR on the shared FS:
#   $RUN_DIR/mofka.json   the broker group file (address); workloads LD_PRELOAD
#                         darshan with DARSHAN_MOFKA_GROUP_FILE=$RUN_DIR/mofka.json
#   $RUN_DIR/READY        created when broker+mongo+consumer are all up
#   $RUN_DIR/DONE         created by the workload side when all workloads finished
#   $RUN_DIR/events.jsonl the exported result
#
# Env:
#   RUN_DIR     shared run dir on eagle (REQUIRED; must be visible to all nodes)
#   MONGO_DB    mongo db name                       (default: darshan_stream)
#   MONGO_PORT  mongod port                         (default: 27017)
#   TOPIC       mofka topic                         (default: darshan)
#   MONGOD      mongod binary (else env.sh resolves it)
#   IDLE_MAX    seconds to wait for DONE before giving up (default: 1800)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source server/env.sh --polaris
module unload darshan 2>/dev/null || true
export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:${PKG_CONFIG_PATH#/soft/perftools/darshan/darshan-3.4.4/lib/pkgconfig:}"

: "${RUN_DIR:?set RUN_DIR to a shared (eagle) run dir visible to all nodes}"
MONGO_DB="${MONGO_DB:-darshan_stream}"
MONGO_PORT="${MONGO_PORT:-27017}"
TOPIC="${TOPIC:-darshan}"
IDLE_MAX="${IDLE_MAX:-1800}"
mkdir -p "$RUN_DIR"

say() { printf '\n[server-node] %s\n' "$*"; }
die() { printf '\n[server-node] FATAL: %s\n' "$*" >&2; touch "$RUN_DIR/FAILED"; exit 1; }

MONGOD="${MONGOD:-$(command -v mongod || true)}"
[[ -x "$MONGOD" ]] || die "mongod not found; create it via server/mongo-environment.yml or set MONGOD (see env_polaris.sh resolver)"
say "mongod: $MONGOD"

# --- fresh broker into the SHARED run dir (so mofka.json lands on eagle) --------
say "starting Mofka broker (group file -> $RUN_DIR/mofka.json)"
rm -f "$RUN_DIR/READY" "$RUN_DIR/DONE" "$RUN_DIR/FAILED"
export MOFKA_SERVER_DIR="$RUN_DIR"          # start-server.sh writes mofka.json here
bash server/stop-server.sh >/dev/null 2>&1 || true
sleep 2
bash server/start-server.sh || die "start-server.sh failed"
GROUP="$RUN_DIR/mofka.json"
[[ -s "$GROUP" ]] || die "no mofka.json at $GROUP after start-server.sh"

cleanup() {
    say "cleanup (stop consumer + broker)"
    [[ -n "${FC:-}" ]] && kill "$FC" 2>/dev/null || true
    bash server/stop-server.sh >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- FlowCept consumer (drains topic -> mongo) ---------------------------------
say "starting FlowCept consumer"
RUN_DIR="$RUN_DIR" MONGO_DB="$MONGO_DB" MONGO_PORT="$MONGO_PORT" MONGOD="$MONGOD" \
TOPIC="$TOPIC" MOFKA_GROUP="$GROUP" \
bash server/capture_flowcept.sh > "$RUN_DIR/flowcept_capture.out" 2>&1 &
FC=$!
until grep -q 'consumer alive' "$RUN_DIR/flowcept_capture.out"; do
    kill -0 "$FC" 2>/dev/null || { cat "$RUN_DIR/flowcept_capture.out"; die "consumer failed to start"; }
    sleep 1
done
say "consumer alive (pid $FC)"

# --- signal READY: workloads may now run --------------------------------------
touch "$RUN_DIR/READY"
say "READY marker written -> $RUN_DIR/READY  (workload nodes may start)"

# --- idle until the workload side signals DONE --------------------------------
say "waiting for workload completion ($RUN_DIR/DONE, timeout ${IDLE_MAX}s)"
waited=0
until [[ -f "$RUN_DIR/DONE" ]]; do
    kill -0 "$FC" 2>/dev/null || die "consumer died before workloads finished (see flowcept_capture.out)"
    sleep 5; waited=$((waited+5))
    [[ "$waited" -ge "$IDLE_MAX" ]] && die "timed out waiting for $RUN_DIR/DONE"
done
say "DONE seen; flushing + exporting"

# --- flush + export mongo -> JSONL --------------------------------------------
touch "$RUN_DIR/SHUTDOWN"
until grep -q 'Export now' "$RUN_DIR/flowcept_capture.out"; do
    kill -0 "$FC" 2>/dev/null || { tail -40 "$RUN_DIR/flowcept_capture.out"; die "consumer died before export"; }
    sleep 1
done
EVENTS="$RUN_DIR/events.jsonl"
"$PY" server/export_jsonl.py 127.0.0.1 "$MONGO_DB" --mongo-port "$MONGO_PORT" \
    > "$EVENTS" 2> "$RUN_DIR/export.count"
say "exported $(wc -l < "$EVENTS") events -> $EVENTS"
cat "$RUN_DIR/export.count" || true
grep -E 'INGEST:|tasks total=' "$RUN_DIR/flowcept_capture.out" || true
touch "$RUN_DIR/EXPORTED"
say "server role complete"
