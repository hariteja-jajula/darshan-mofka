#!/bin/bash
# start_server.sh -- bring up a fresh Mofka broker (bedrock) and create the topic
# the Darshan connector streams to. Writes a group file (mofka.json) the producer
# and consumer both read. Idempotent: stops any prior broker in the run dir first.
#
# Knobs come from server/server.config (protocol, topic, partitions, partition_type);
# any can be overridden by an env var of the same UPPERCASE name. MOFKA_SERVER_DIR sets
# where mofka.json/bedrock live (default: this dir).
# Usage:  bash server/start_server.sh [--lcrc|--polaris]
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../env/server.sh" "$@"
# shellcheck disable=SC1091
source "$HERE/../lib/run.sh"
load_run_config     # -> SRV_PROTOCOL / SRV_TOPIC / SRV_PARTITIONS / SRV_PART_TYPE

SERVER_RUN_DIR="${MOFKA_SERVER_DIR:-$HERE}"
mkdir -p "$SERVER_RUN_DIR"
[ "$HERE/bedrock-config.json" != "$SERVER_RUN_DIR/bedrock-config.json" ] \
    && cp "$HERE/bedrock-config.json" "$SERVER_RUN_DIR/bedrock-config.json"
cd "$SERVER_RUN_DIR"
[ -f bedrock.pid ] && kill "$(cat bedrock.pid)" 2>/dev/null || true
sleep 1
rm -f mofka.json bedrock.pid

echo "starting bedrock ($SRV_PROTOCOL) in $SERVER_RUN_DIR ..."
bedrock "$SRV_PROTOCOL" -c bedrock-config.json -v info > bedrock.log 2>&1 &
echo $! > bedrock.pid

for _ in $(seq 1 60); do [ -f mofka.json ] && break; sleep 0.5; done
[ -f mofka.json ] || { echo "mofka.json never appeared; see $SERVER_RUN_DIR/bedrock.log"; exit 1; }

broker_topic_partitions mofka.json    # creates SRV_TOPIC with SRV_PARTITIONS x SRV_PART_TYPE

echo "mofka up: $(grep -oE '[a-z0-9+;_]+://[0-9.]+:[0-9]+' mofka.json | head -1) | topic '$SRV_TOPIC' ($SRV_PARTITIONS x $SRV_PART_TYPE) | groupfile $SERVER_RUN_DIR/mofka.json (pid $(cat bedrock.pid))"
