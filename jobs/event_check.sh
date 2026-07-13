#!/bin/bash
# event_check.sh -- do read/write ops emit mofka events, or only open/close?
# Single-process io_test is deterministic: 3 files x [1 open + 10 write + 5 read
# + 1 close] = 51 POSIX ops. We run it under darshan->mofka with timing on and
# count how many connector send() calls actually fired.
#   51 => every op emits an event (expected firehose)
#    6 => only open+close emit (reads/writes are NOT firing) <-- what the sweep showed
# Requires a broker already up (cd server && ./start-server.sh).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/server/env.sh"
LIB="$(darshan_lib)"
darshan_ensure_logdir >/dev/null
pkill -u "$USER" -x bedrock 2>/dev/null || true; sleep 1
( cd "$ROOT/server" && ./start-server.sh ) || { echo "broker failed; see server/bedrock.log"; exit 1; }
GF="$ROOT/server/mofka.json"
trap '( cd "$ROOT/server" && ./stop-server.sh ) >/dev/null 2>&1' EXIT

o="$(mktemp)"
env DARSHAN_ENABLE_NONMPI=1 DARSHAN_MOFKA_ENABLE=1 DARSHAN_MOFKA_ENABLE_POSIX=1 \
    DARSHAN_MOFKA_TIMING=1 DARSHAN_MOFKA_VERBOSE=1 \
    DARSHAN_MOFKA_GROUP_FILE="$GF" DARSHAN_MOFKA_TOPIC=darshan \
    LD_PRELOAD="$LIB" "$ROOT/workloads/io_test" /tmp > "$o" 2>&1

echo "io_test performs 51 POSIX ops (3 files x [1 open + 10 write + 5 read + 1 close])."
echo "connector send() calls that fired: $(grep -c 'timing\] send' "$o")"
echo "  -> 51 means every op emits; 6 means only open+close emit"
echo
echo "--- io_test summary + any connector messages ---"
grep -E 'io_test done|producer connected|push failed|driver_create' "$o" || true
echo "(full log: $o)"
