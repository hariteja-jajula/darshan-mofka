#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/env.sh"

SERVER_RUN_DIR="${MOFKA_SERVER_DIR:-$HERE}"
mkdir -p "$SERVER_RUN_DIR"
if [ "$HERE/bedrock-config.json" != "$SERVER_RUN_DIR/bedrock-config.json" ]; then
    cp "$HERE/bedrock-config.json" "$SERVER_RUN_DIR/bedrock-config.json"
fi
cd "$SERVER_RUN_DIR"
if [ -f bedrock.pid ]; then kill "$(cat bedrock.pid)" 2>/dev/null || true; fi
sleep 1
rm -f mofka.json bedrock.pid

echo "starting bedrock ($MOFKA_PROTOCOL) in $SERVER_RUN_DIR ..."
bedrock "$MOFKA_PROTOCOL" -c bedrock-config.json -v info > bedrock.log 2>&1 &
echo $! > bedrock.pid

for i in $(seq 1 60); do [ -f mofka.json ] && break; sleep 0.5; done
[ -f mofka.json ] || { echo "mofka.json never appeared; see bedrock.log"; exit 1; }

mofkactl topic create darshan --groupfile mofka.json 2>/dev/null || true
mofkactl partition add darshan --rank 0 --type memory --groupfile mofka.json 2>/dev/null || true

echo "mofka up: $(grep -oE '[a-z0-9+;_]+://[0-9.]+:[0-9]+' "$SERVER_RUN_DIR/mofka.json" | head -1) | topic 'darshan' | groupfile $SERVER_RUN_DIR/mofka.json (pid $(cat bedrock.pid))"
