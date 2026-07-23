#!/bin/bash
# lib/run.sh -- shared run core. Reads workloads/workload.config + server/server.config
# (via lib/config.sh) and turns them into env, so job.sh and the study/* scripts don't
# hand-copy the DARSHAN_MOFKA_* block, the topic name, or the partition-add loop.
#
# Source it, then:
#   load_run_config                  populate WL_*/SRV_* (an env var of the same NAME wins)
#   connector_env <group>            -> CONNECTOR_ENV=(DARSHAN_MOFKA_...)   producer knobs
#   workload_env                     -> WORKLOAD_ENV=(EPOCHS.. | ML_..)     per-workload knobs
#   broker_topic_partitions <group> [nranks]   create the topic + SRV_PARTITIONS partitions
#   workload_tag / next_run_dir <base>         results-dir naming helpers

_RUN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_RUN_LIB_DIR/config.sh"
REPO_ROOT="${REPO:-$(dirname "$_RUN_LIB_DIR")}"
WORKLOAD_CONFIG="${WORKLOAD_CONFIG:-$REPO_ROOT/workloads/workload.config}"
SERVER_CONFIG="${SERVER_CONFIG:-$REPO_ROOT/server/server.config}"

# read key from a config file, but let an env var of the given NAME override it
_cfg_env() { local name="$1" file="$2" key="$3" def="$4" v="${!name:-}"; [ -n "$v" ] && printf '%s\n' "$v" || cfg_get "$file" "$key" "$def"; }

load_run_config() {
    WL_TYPE=$(_cfg_env WORKLOAD "$WORKLOAD_CONFIG" workload c)
    WL_EVENTS=$(_cfg_env EVENTS "$WORKLOAD_CONFIG" events 8)
    WL_CHECKPOINTS=$(_cfg_env CHECKPOINTS "$WORKLOAD_CONFIG" checkpoints 2)
    C_BATCH=$(_cfg_env DARSHAN_MOFKA_BATCH "$WORKLOAD_CONFIG" connector.batch 0)
    C_MAX_BATCHES=$(_cfg_env DARSHAN_MOFKA_MAX_BATCHES "$WORKLOAD_CONFIG" connector.max_batches 64)
    C_TIMING=$(_cfg_env DARSHAN_MOFKA_TIMING "$WORKLOAD_CONFIG" connector.timing 1)
    C_FLUSH_MS=$(_cfg_env DARSHAN_MOFKA_FLUSH_MS "$WORKLOAD_CONFIG" connector.flush_ms 5000)
    SRV_TOPIC=$(_cfg_env MOFKA_TOPIC "$SERVER_CONFIG" topic darshan)
    SRV_PARTITIONS=$(_cfg_env PARTITIONS "$SERVER_CONFIG" partitions 1)
    SRV_PART_TYPE=$(_cfg_env MOFKA_PARTITION_TYPE "$SERVER_CONFIG" partition_type memory)
    SRV_MONGO_DB=$(_cfg_env MONGO_DB "$SERVER_CONFIG" mongo.db darshan_stream)
    SRV_MONGO_PORT=$(_cfg_env MONGO_PORT "$SERVER_CONFIG" mongo.port 27017)
    local prot; prot=$(_cfg_env MOFKA_PROTOCOL "$SERVER_CONFIG" protocol auto)   # 'auto' -> profile default
    [ "$prot" = auto ] && prot="${MOFKA_PROTOCOL_DEFAULT:-tcp}"
    SRV_PROTOCOL="$prot"
}

# uppercased workload tag for results-dir names (c -> C, python-ml -> PYTHONML)
workload_tag() { load_run_config; printf '%s\n' "$WL_TYPE" | tr -d '-' | tr '[:lower:]' '[:upper:]'; }

# echo <base>/RUN<n> for the next unused rep (results/README.md convention)
next_run_dir() { local base="$1" n=1; while [ -e "$base/RUN$n" ]; do n=$((n+1)); done; printf '%s\n' "$base/RUN$n"; }

# CONNECTOR_ENV=(...) -- the producer's DARSHAN_MOFKA_* knobs, from config
connector_env() {
    local group="$1"; load_run_config
    CONNECTOR_ENV=(
        DARSHAN_MOFKA_ENABLE=1
        DARSHAN_MOFKA_GROUP_FILE="$group"
        DARSHAN_MOFKA_TOPIC="$SRV_TOPIC"
        DARSHAN_MOFKA_BATCH="$C_BATCH"
        DARSHAN_MOFKA_MAX_BATCHES="$C_MAX_BATCHES"
        DARSHAN_MOFKA_TIMING="$C_TIMING"
        DARSHAN_MOFKA_FLUSH_MS="$C_FLUSH_MS"
    )
}

# WORKLOAD_ENV=(...) -- map generic events/checkpoints onto the selected workload's knobs
workload_env() {
    load_run_config
    local every=$(( WL_CHECKPOINTS > 0 ? WL_EVENTS / WL_CHECKPOINTS : WL_EVENTS ))
    [ "$every" -lt 1 ] && every=1
    case "$WL_TYPE" in
        c)         WORKLOAD_ENV=(EPOCHS="$WL_EVENTS" CHECKPOINT_EVERY="$every") ;;
        python-ml) WORKLOAD_ENV=(ML_EPOCHS="$WL_EVENTS" ML_CHECKPOINTS="$WL_CHECKPOINTS") ;;
        *)         WORKLOAD_ENV=() ;;
    esac
}

# create the topic and SRV_PARTITIONS partitions (round-robin across ranks if multi-rank)
broker_topic_partitions() {
    local group="$1" nranks="${2:-1}"; load_run_config
    mofkactl topic create "$SRV_TOPIC" --groupfile "$group" 2>/dev/null || true
    local p
    for p in $(seq 0 $(( SRV_PARTITIONS - 1 ))); do
        mofkactl partition add "$SRV_TOPIC" --rank $(( p % nranks )) \
            --type "$SRV_PART_TYPE" --groupfile "$group" 2>/dev/null \
            || echo "  WARN: partition add ($SRV_TOPIC rank $(( p % nranks )) $SRV_PART_TYPE) failed"
    done
}
