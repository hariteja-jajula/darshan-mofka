#!/bin/bash
# stop_server.sh -- stop the Mofka broker started by start_server.sh (kills the
# recorded pid). No env needed. Honors MOFKA_SERVER_DIR (same as start_server.sh).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_RUN_DIR="${MOFKA_SERVER_DIR:-$HERE}"
cd "$SERVER_RUN_DIR" 2>/dev/null || { echo "stopped."; exit 0; }
[ -f bedrock.pid ] && kill "$(cat bedrock.pid)" 2>/dev/null || true
rm -f bedrock.pid
echo "stopped."
