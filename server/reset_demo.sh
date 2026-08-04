#!/bin/bash
# reset_demo.sh -- clean slate before a manual demo. Kills any leftover broker/consumer/
# mongod on THIS login node and clears stale run state, so start_server.sh -> consumer ->
# producer starts fresh. Run this once before the demo. Safe: only touches demo state.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "=== killing leftover broker / consumer / mongod (this login node) ==="
pkill -9 -f 'bedrock '        2>/dev/null || true
pkill -9 -f flowcept          2>/dev/null || true
pkill -9 -f 'start_server.sh' 2>/dev/null || true
pkill -9 -f mongod            2>/dev/null || true
sleep 1
echo "=== clearing stale group file + consumer run dir ==="
rm -f  "$ROOT/server/mofka.json" "$ROOT/server/bedrock.log"
rm -rf "$ROOT/server/_flowcept_run"
echo "=== done. now (same login node):"
echo "  T1: bash server/start_server.sh"
echo "  T2: source env/server.sh && MOFKA_GROUP=\$PWD/server/mofka.json TOPIC=darshan MONGO_PORT=27099 bash Client/capture_flowcept.sh"
echo "  T3: bash server/run_producer.sh io_bench"
echo "  T2 (to finish): touch server/_flowcept_run/SHUTDOWN   # flush -> mongo, prints INGEST: PASS"
