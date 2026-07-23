#!/bin/bash
# start_server.sh -- bring up a fresh Mofka broker (bedrock) and create the topic
# the Darshan connector streams to. Writes a group file (mofka.json) the producer
# and consumer both read. Idempotent: stops any prior broker in the run dir first.
#
# Config knobs (env vars; sensible per-profile defaults, no YAML parser needed):
#   MOFKA_PROTOCOL        fabric transport (default: profile's -- verbs on LCRC)
#   MOFKA_TOPIC           topic to create              (default: darshan)
#   MOFKA_PARTITION_TYPE  partition backend            (default: memory)
#   MOFKA_SERVER_DIR      where mofka.json/bedrock live (default: this dir)
# Usage:  bash server/start_server.sh [--lcrc|--polaris]
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../env/server.sh" "$@"

MOFKA_TOPIC="${MOFKA_TOPIC:-darshan}"
MOFKA_PARTITION_TYPE="${MOFKA_PARTITION_TYPE:-memory}"
SERVER_RUN_DIR="${MOFKA_SERVER_DIR:-$HERE}"
mkdir -p "$SERVER_RUN_DIR"
[ "$HERE/bedrock-config.json" != "$SERVER_RUN_DIR/bedrock-config.json" ] \
    && cp "$HERE/bedrock-config.json" "$SERVER_RUN_DIR/bedrock-config.json"
cd "$SERVER_RUN_DIR"
[ -f bedrock.pid ] && kill "$(cat bedrock.pid)" 2>/dev/null || true
sleep 1
rm -f mofka.json bedrock.pid

echo "starting bedrock ($MOFKA_PROTOCOL) in $SERVER_RUN_DIR ..."
bedrock "$MOFKA_PROTOCOL" -c bedrock-config.json -v info > bedrock.log 2>&1 &
echo $! > bedrock.pid

for _ in $(seq 1 60); do [ -f mofka.json ] && break; sleep 0.5; done
[ -f mofka.json ] || { echo "mofka.json never appeared; see $SERVER_RUN_DIR/bedrock.log"; exit 1; }

mofkactl topic create "$MOFKA_TOPIC" --groupfile mofka.json 2>/dev/null || true
mofkactl partition add "$MOFKA_TOPIC" --rank 0 --type "$MOFKA_PARTITION_TYPE" --groupfile mofka.json 2>/dev/null || true

echo "mofka up: $(grep -oE '[a-z0-9+;_]+://[0-9.]+:[0-9]+' mofka.json | head -1) | topic '$MOFKA_TOPIC' | groupfile $SERVER_RUN_DIR/mofka.json (pid $(cat bedrock.pid))"
