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

# Partition layout knobs (defaults reproduce the original single-memory-partition
# broker exactly). MOFKA_PARTITIONS=N adds N partitions round-robin across the
# servers present in the group (MOFKA_NRANKS, default 1) -- the parallelism knob
# for the throughput sweep. MOFKA_PART_TYPE=memory|default selects the manager;
# `default` is on-disk and REQUIRES a path (MOFKA_PART_PATH, one subdir per
# partition), passed via mofkactl's `--config.path` extra-arg mechanism.
MOFKA_PARTITIONS="${MOFKA_PARTITIONS:-1}"
MOFKA_NRANKS="${MOFKA_NRANKS:-1}"
MOFKA_PART_TYPE="${MOFKA_PART_TYPE:-memory}"
MOFKA_PART_PATH="${MOFKA_PART_PATH:-/tmp/mofka_parts_$$}"
mofkactl topic create darshan --groupfile mofka.json 2>/dev/null || true
# NOTE: do NOT swallow partition-add errors -- a silently-failed add leaves the
# topic with no target and every producer push errors (the "default arm" trap).
for _p in $(seq 0 $((MOFKA_PARTITIONS - 1))); do
    _extra=()
    if [[ "$MOFKA_PART_TYPE" == default ]]; then
        mkdir -p "$MOFKA_PART_PATH/$_p"
        _extra=(--config.path "$MOFKA_PART_PATH/$_p")
    fi
    mofkactl partition add darshan --rank $((_p % MOFKA_NRANKS)) \
        --type "$MOFKA_PART_TYPE" "${_extra[@]}" --groupfile mofka.json \
        || echo "  WARN: partition add #$_p (type=$MOFKA_PART_TYPE) failed"
done

echo "mofka up: $(grep -oE '[a-z0-9+;_]+://[0-9.]+:[0-9]+' "$SERVER_RUN_DIR/mofka.json" | head -1) | topic 'darshan' ($MOFKA_PARTITIONS x $MOFKA_PART_TYPE part, $MOFKA_NRANKS rank) | groupfile $SERVER_RUN_DIR/mofka.json (pid $(cat bedrock.pid))"
