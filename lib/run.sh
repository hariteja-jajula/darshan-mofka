#!/bin/bash
# lib/run.sh -- the shared run core. Reads workloads/workload.config + server/server.config
# (via lib/config.sh) and turns them into env, so job.sh and every study/* script stop
# hand-copying the DARSHAN_MOFKA_* block and the topic name.
#
# Source it, then:
#   load_run_config                 # populate WL_* / SRV_* globals (env of same NAME wins)
#   connector_env <group>           # -> CONNECTOR_ENV=(DARSHAN_MOFKA_...=...)   producer knobs
#   workload_env                    # -> WORKLOAD_ENV=(EPOCHS=.. CHECKPOINT_EVERY=.. | ML_...)
#   run_workload <group> <logdir> <out_prefix>   # run c|python-ml under the connector
#   broker_topic_partitions <group> # create the topic + N partitions of the chosen type
#   resolve_protocol / mofka_topic  # echo the resolved value (for the study .pbs)

_RUN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_RUN_LIB_DIR/config.sh"
REPO_ROOT="${REPO:-$(dirname "$_RUN_LIB_DIR")}"
WORKLOAD_CONFIG="${WORKLOAD_CONFIG:-$REPO_ROOT/workloads/workload.config}"
SERVER_CONFIG="${SERVER_CONFIG:-$REPO_ROOT/server/server.config}"

# read key from a config file, but let an env var of the given NAME override it
_cfg_env() { local name="$1" file="$2" key="$3" def="$4"; local v="${!name:-}"; [ -n "$v" ] && printf '%s\n' "$v" || cfg_get "$file" "$key" "$def"; }

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
    # protocol: MOFKA_PROTOCOL env wins; else config; 'auto' -> profile default
    local prot; prot=$(_cfg_env MOFKA_PROTOCOL "$SERVER_CONFIG" protocol auto)
    [ "$prot" = auto ] && prot="${MOFKA_PROTOCOL_DEFAULT:-tcp}"
    SRV_PROTOCOL="$prot"
}

resolve_protocol() { load_run_config; printf '%s\n' "$SRV_PROTOCOL"; }
mofka_topic()      { load_run_config; printf '%s\n' "$SRV_TOPIC"; }

# uppercased workload tag for results-dir names (c -> C, python-ml -> PYTHONML)
workload_tag() { load_run_config; printf '%s\n' "$WL_TYPE" | tr -d '-' | tr '[:lower:]' '[:upper:]'; }

# echo <base>/RUN<n> for the next unused rep (matches results/README.md convention)
next_run_dir() { local base="$1" n=1; while [ -e "$base/RUN$n" ]; do n=$((n+1)); done; printf '%s\n' "$base/RUN$n"; }

# CONNECTOR_ENV=(...) -- the single definition of the producer's DARSHAN_MOFKA_* knobs
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

# run c|python-ml on THIS node under the connector; writes <out_prefix>.out/.err
run_workload() {
    local group="$1" logdir="$2" out="$3"
    load_run_config; connector_env "$group"; workload_env
    local dlib; dlib="$(darshan_lib)"
    local cmd=()
    case "$WL_TYPE" in
        c)         [ -x "$REPO_ROOT/workloads/c/mofka_forward_smoke" ] || \
                       "$CC" -O2 "$REPO_ROOT/workloads/c/mofka_forward_smoke.c" -o "$REPO_ROOT/workloads/c/mofka_forward_smoke"
                   cmd=("$REPO_ROOT/workloads/c/mofka_forward_smoke" "$logdir/data") ;;
        python-ml) cmd=("$PY" "$REPO_ROOT/workloads/python-ml/train.py" "$logdir/data") ;;
        *)         echo "run_workload: unsupported workload '$WL_TYPE'"; return 2 ;;
    esac
    env DARSHAN_ENABLE_NONMPI=1 DARSHAN_LOGPATH="$logdir" LD_PRELOAD="$dlib" \
        "${CONNECTOR_ENV[@]}" "${WORKLOAD_ENV[@]}" \
        "${cmd[@]}" > "${out}.out" 2> "${out}.err"
}

# create the topic and SRV_PARTITIONS partitions (round-robin across ranks if multi-rank)
broker_topic_partitions() {
    local group="$1"; load_run_config
    local nranks="${2:-1}"
    mofkactl topic create "$SRV_TOPIC" --groupfile "$group" 2>/dev/null || true
    local p
    for p in $(seq 0 $(( SRV_PARTITIONS - 1 ))); do
        mofkactl partition add "$SRV_TOPIC" --rank $(( p % nranks )) \
            --type "$SRV_PART_TYPE" --groupfile "$group" 2>/dev/null \
            || echo "  WARN: partition add ($SRV_TOPIC rank $(( p % nranks )) $SRV_PART_TYPE) failed"
    done
}
