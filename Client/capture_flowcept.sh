#!/bin/bash
# capture_flowcept.sh -- "scale mode" consumer: FlowCept drains the darshan Mofka
# topic into MongoDB (instead of capture.py -> flat JSONL). This is the scalable
# / persistent alternative to Client/capture.py. See the repo README and
# docs/RUNBOOK.md for how this fits the full pipeline.
#
# It does NOT start the broker -- run server/start_server.sh first (same as the
# capture.py path). It DOES start a local mongod (FlowCept's sink) and the
# FlowCept consumer, waits for you to run the workload, then graceful-stops the
# consumer (flushing its buffer) so every event lands before teardown.
#
# Flow:
#   1. server/start_server.sh        (broker + darshan topic + mofka.json)
#   2. Client/capture_flowcept.sh &  (mongod + FlowCept consumer; this script)
#   3. run the Darshan-instrumented workload while FlowCept drains the topic
#   4. touch "$SHUTDOWN_FLAG"         (tells this script to flush + stop)
#   5. Client/export_jsonl.py ...     (mongo -> events.jsonl for the reconstructor)
#
# Usage:
#   source env/server.sh
#   MONGO_DB=darshan_stream Client/capture_flowcept.sh
# Env knobs (all optional):
#   TOPIC          mofka topic to consume         (default: darshan; MUST match producer)
#   MONGO_DB       mongo db to ingest into        (default: darshan_stream)
#   MONGO_PORT     mongod port                    (default: 27017)
#   RUN_DIR        where to write run artifacts   (default: $ROOT/server/_flowcept_run)
#   SHUTDOWN_FLAG  file whose creation stops us   (default: $RUN_DIR/SHUTDOWN)
#   MONGOD         path to mongod binary          (default: `command -v mongod`)
set -uo pipefail

# ROOT: honor caller, else ENV_ROOT (from env/server.sh), else derive from Client/.
ROOT="${ROOT:-${ENV_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
TOPIC="${TOPIC:-darshan}"
MONGO_DB="${MONGO_DB:-darshan_stream}"
MONGO_PORT="${MONGO_PORT:-27017}"
RUN_DIR="${RUN_DIR:-$ROOT/server/_flowcept_run}"
SHUTDOWN_FLAG="${SHUTDOWN_FLAG:-$RUN_DIR/SHUTDOWN}"
MOFKA_GROUP="${MOFKA_GROUP:-$ROOT/server/mofka.json}"
SETTINGS_TEMPLATE="${SETTINGS_TEMPLATE:-$ROOT/Client/flowcept_settings.template.yaml}"
MONGOD="${MONGOD:-$(command -v mongod || true)}"
PY="${PY:-python3}"

mkdir -p "$RUN_DIR"
rm -f "$SHUTDOWN_FLAG"

echo "=== [flowcept-capture] topic=$TOPIC db=$MONGO_DB run_dir=$RUN_DIR ==="

# --- preflight -------------------------------------------------------------
# MPMD: broker section may write mofka.json concurrently; poll instead of hard-fail.
for _i in $(seq 1 "${MOFKA_GROUP_WAIT_S:-120}"); do [[ -s "$MOFKA_GROUP" ]] && break; sleep 1; done
[[ -s "$MOFKA_GROUP" ]] || { echo "[fc] FAIL: no mofka group file at $MOFKA_GROUP after ${MOFKA_GROUP_WAIT_S:-120}s"; exit 1; }
[[ -n "$MONGOD" && -x "$MONGOD" ]] || { echo "[fc] FAIL: mongod not found on PATH; load MongoDB or set MONGOD=/path/to/mongod"; exit 1; }
"$PY" -c "import flowcept.cli" 2>/dev/null || { echo "[fc] FAIL: flowcept.cli not importable -- did you 'git submodule update --init --recursive' and pip-install deps/flowcept?"; exit 1; }
"$PY" -c "import pymongo" 2>/dev/null || { echo "[fc] FAIL: pymongo not importable"; exit 1; }

CONSUMER_PID=""; MONGOD_PID=""
cleanup() {
    echo "[fc] cleanup"
    [[ -n "$CONSUMER_PID" ]] && kill -TERM "$CONSUMER_PID" 2>/dev/null || true
    [[ -n "$MONGOD_PID"   ]] && kill -TERM "$MONGOD_PID"   2>/dev/null || true
    sleep 2
    [[ -n "$MONGOD_PID"   ]] && kill -KILL "$MONGOD_PID"   2>/dev/null || true
}
trap cleanup EXIT INT TERM

# --- mongod: the LEAD starts one shared mongod; FOLLOWERS attach to it -------
# For a sharded parallel drain, N consumers share ONE mongod: FlowCept upserts on the unique
# task_id index, so overlapping/duplicate events collapse and reconstruct reads one collection
# (simpler + safer than one mongod per shard). Only FC_ROLE=lead owns the mongod lifecycle.
FC_ROLE="${FC_ROLE:-lead}"
MONGO_LOG="$RUN_DIR/mongod.log"
if [ "$FC_ROLE" = lead ]; then
    MONGO_DBPATH="${MONGO_DBPATH:-${TMPDIR:-/tmp}/dm_mongo_$$}"; mkdir -p "$MONGO_DBPATH"
    echo "=== [fc] mongod (port $MONGO_PORT, dbpath $MONGO_DBPATH) ==="
    "$MONGOD" --dbpath "$MONGO_DBPATH" --logpath "$MONGO_LOG" \
              --port "$MONGO_PORT" --bind_ip 127.0.0.1 --nounixsocket \
              ${MONGO_CACHE_GB:+--wiredTigerCacheSizeGB "$MONGO_CACHE_GB"} &
    MONGOD_PID=$!
else
    echo "=== [fc] follower: attaching to shared mongod on port $MONGO_PORT ==="
fi
for i in $(seq 1 60); do (echo > "/dev/tcp/127.0.0.1/$MONGO_PORT") 2>/dev/null && { echo "[fc] mongod ready ${i}s"; break; }; sleep 1; done
(echo > "/dev/tcp/127.0.0.1/$MONGO_PORT") 2>/dev/null || { echo "[fc] FAIL: mongod not up on $MONGO_PORT"; [ "$FC_ROLE" = lead ] && tail -30 "$MONGO_LOG"; exit 1; }

# --- render flowcept settings from the template ----------------------------
FLOWCEPT_SETTINGS="$RUN_DIR/flowcept_settings.yaml"
sed -e "s|__MOFKA_GROUP__|$MOFKA_GROUP|g" \
    -e "s|__MONGO_DB__|$MONGO_DB|g" \
    -e "s|__TOPIC__|$TOPIC|g" \
    -e "s|__ENV_ID__|$(hostname -s)-$$|g" \
    -e "s|__MQ_BUF__|${MQ_BUFFER_SIZE:-50}|g" \
    -e "s|__MQ_FLUSH__|${MQ_FLUSH_SECS:-5}|g" \
    -e "s|__DB_BUF__|${DB_BUFFER_SIZE:-50}|g" \
    -e "s|__DB_FLUSH__|${DB_FLUSH_SECS:-5}|g" \
    -e "s|__TARGETS__|${MOFKA_TARGETS:-}|g" \
    -e "s|__MONGO_PORT__|${MONGO_PORT:-27017}|g" \
    "$SETTINGS_TEMPLATE" > "$FLOWCEPT_SETTINGS"
export FLOWCEPT_SETTINGS_PATH="$FLOWCEPT_SETTINGS"
# The FlowCept consumer (configs.py) reads the mongo SINK port from $MONGO_PORT; export it so each
# shard's consumer writes to the shared mongod on this port (all shards share one mongod).
export MONGO_PORT MONGO_HOST="127.0.0.1"
echo "[fc] FLOWCEPT_SETTINGS_PATH=$FLOWCEPT_SETTINGS_PATH"
grep -E "type:|channel:|group_file:|enabled:|db:" "$FLOWCEPT_SETTINGS" | sed 's/^/    /'

# --- launch the FlowCept consumer (this is the whole "consumer") -----------
# NOTE: invoke via `python3 -m flowcept.cli`, NOT the bin/flowcept console script
# (not reliably +x under stdbuf).
CONSUMER_LOG="$RUN_DIR/consumer.log"
echo "=== [fc] flowcept consumer (start-consumption-services) ==="
stdbuf -oL -eL "$PY" -m flowcept.cli --start-consumption-services > "$CONSUMER_LOG" 2>&1 &
CONSUMER_PID=$!
sleep 12
kill -0 "$CONSUMER_PID" 2>/dev/null || { echo "[fc] FAIL: consumer died on startup"; sed 's/^/    /' "$CONSUMER_LOG"; exit 1; }
echo "[fc] consumer alive PID=$CONSUMER_PID"
[[ -n "${FLAGDIR:-}" ]] && touch "$FLAGDIR/CONSUMER_READY"  # MPMD: signal readiness

# --- ready: idle until the workload has run and SHUTDOWN is signalled -------
echo "===================================================================="
echo "[fc] READY. Now (in another shell): run the darshan workload, then:"
echo "     touch $SHUTDOWN_FLAG"
echo "     to flush + stop and land all events in mongo db '$MONGO_DB'."
echo "===================================================================="
while [[ ! -f "$SHUTDOWN_FLAG" ]]; do
    [[ -n "$MONGOD_PID" ]] && { kill -0 "$MONGOD_PID" 2>/dev/null || { echo "[fc] mongod died"; tail -20 "$MONGO_LOG" | sed 's/^/    /'; break; }; }
    kill -0 "$CONSUMER_PID" 2>/dev/null || { echo "[fc] consumer died"; tail -20 "$CONSUMER_LOG" | sed 's/^/    /'; break; }
    sleep 5
done

# --- graceful stop so DocumentInserter flushes its buffer to mongo ----------
echo "=== [fc] graceful stop (flush) ==="
( timeout "${STOP_TIMEOUT:-600}" "$PY" -m flowcept.cli --stop-consumption-services 2>&1 ) | sed 's/^/    /' || echo "    (stop nonzero; cleanup will SIGTERM)"
for i in $(seq 1 30); do kill -0 "$CONSUMER_PID" 2>/dev/null || { echo "[fc] consumer exited cleanly"; break; }; sleep 1; done

# A follower has now flushed its shard into the shared mongod; the lead owns the
# verdict/export/teardown, so the follower is done.
if [ "$FC_ROLE" != lead ]; then
    echo "[fc] follower drained its shard + stopped; exiting (lead keeps the shared mongod up)"
    exit 0
fi

# --- ingest verdict --------------------------------------------------------
echo "=== [fc] mongo ingest verdict (db=$MONGO_DB) ==="
"$PY" - "$MONGO_DB" "$MONGO_PORT" <<'PY' 2>&1 | sed 's/^/    /'
import sys
from pymongo import MongoClient
db_name, port = sys.argv[1], int(sys.argv[2])
db = MongoClient("127.0.0.1", port).get_database(db_name)
tasks = db["tasks"]
total = tasks.count_documents({})
darshan = tasks.count_documents({"schema": {"$in": ["darshan_runtime", "darshan_runtime_agg"]}})
mods = {m: tasks.count_documents({"module": m}) for m in tasks.distinct("module") if m}
print(f"tasks total={total}  darshan={darshan}  modules={mods}")
print("INGEST: PASS" if darshan else "INGEST: FAIL -- 0 darshan docs (check topic match + consumer.log flush lines)")
PY

echo "[fc] mongod still UP on port $MONGO_PORT (db=$MONGO_DB) for export_jsonl.py."
echo "[fc] Export now, before this script exits and tears mongod down:"
echo "     $PY $ROOT/Client/export_jsonl.py 127.0.0.1 $MONGO_DB > events.jsonl"
echo "[fc] Press Ctrl-C (or let the parent kill this) when export is done."
# MPMD: mongod dies when this section ends, so export here before exit (trap tears down mongod).
if [ "${EXPORT_ON_STOP:-0}" = 1 ]; then
    echo "=== [fc] export events -> ${EXPORT_OUT:-events.jsonl} ==="
    "$PY" "$ROOT/Client/export_jsonl.py" 127.0.0.1 "$MONGO_DB" --mongo-port "$MONGO_PORT" > "${EXPORT_OUT:-$RUN_DIR/events.jsonl}" 2> "${EXPORT_OUT:-$RUN_DIR/events.jsonl}.count" || echo "[fc] export nonzero"
    [ -n "${ALL_DONE_FLAG:-}" ] && touch "$ALL_DONE_FLAG"
    exit 0
fi
# keep mongod alive for the export step; exit on signal via the trap
while kill -0 "$MONGOD_PID" 2>/dev/null; do sleep 5; done
