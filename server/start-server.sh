#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/env.sh"

cd "$HERE"
[ -f bedrock.pid ] && kill "$(cat bedrock.pid)" 2>/dev/null
sleep 1
rm -f mofka.json bedrock.pid

echo "starting bedrock ($MOFKA_PROTOCOL) in $HERE ..."
bedrock "$MOFKA_PROTOCOL" -c bedrock-config.json -v info > bedrock.log 2>&1 &
echo $! > bedrock.pid

for i in $(seq 1 60); do [ -f mofka.json ] && break; sleep 0.5; done
[ -f mofka.json ] || { echo "mofka.json never appeared; see bedrock.log"; exit 1; }

mofkactl topic create darshan --groupfile mofka.json 2>/dev/null || true
mofkactl partition add darshan --rank 0 --type memory --groupfile mofka.json 2>/dev/null || true

echo "mofka up: $(grep -oE 'ofi\+tcp://[0-9.]+:[0-9]+' "$HERE/mofka.json") | topic 'darshan' | groupfile $HERE/mofka.json (pid $(cat bedrock.pid))"
