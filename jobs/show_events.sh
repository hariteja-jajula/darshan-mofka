#!/bin/bash
# show_events.sh -- produce a small KNOWN workload under darshan->mofka and print
# the FULL JSON of each event, so you can see exactly what the connector sends.
#
# Writes under /tmp (a real fs) NOT /var/tmp/pbs (tmpfs) -- darshan EXCLUDES tmpfs,
# which is why the sweep to $SCRATCH looked nearly empty. Self-contained: starts
# and stops its own broker. Run on a compute node:  bash jobs/show_events.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/server/env.sh"
LIB="$(darshan_lib)"; darshan_ensure_logdir >/dev/null

pkill -u "$USER" -x bedrock 2>/dev/null || true; sleep 1
( cd "$ROOT/server" && ./start-server.sh ) || { echo "broker failed; see server/bedrock.log"; exit 1; }
GF="$ROOT/server/mofka.json"
trap '( cd "$ROOT/server" && ./stop-server.sh ) >/dev/null 2>&1; rm -rf "$WL"' EXIT

WL="/tmp/show_events_$$"; mkdir -p "$WL"
log="$(mktemp)"
env DARSHAN_ENABLE_NONMPI=1 DARSHAN_MOFKA_ENABLE=1 DARSHAN_MOFKA_ENABLE_POSIX=1 \
    DARSHAN_MOFKA_TIMING=1 DARSHAN_MOFKA_GROUP_FILE="$GF" DARSHAN_MOFKA_TOPIC=darshan \
    LD_PRELOAD="$LIB" "$ROOT/workloads/io_test" "$WL" > "$log" 2>&1

fired=$(grep -c 'timing\] send' "$log")
show=$(( fired < 25 ? fired : 25 ))
echo "io_test fired $fired connector send() calls (writing under /tmp -> instrumented)."
echo "showing the first $show events in full JSON (raise the last arg to dump_events.py to see more):"
echo "=========================================================================="
"$PY" "$ROOT/jobs/dump_events.py" "$GF" darshan "$show"
