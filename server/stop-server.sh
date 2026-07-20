#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/env.sh"
SERVER_RUN_DIR="${MOFKA_SERVER_DIR:-$HERE}"
cd "$SERVER_RUN_DIR" 2>/dev/null || { echo "stopped."; exit 0; }
[ -f bedrock.pid ] && kill "$(cat bedrock.pid)" 2>/dev/null
rm -f bedrock.pid
echo "stopped."
