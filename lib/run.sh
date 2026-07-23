#!/bin/bash
# lib/run.sh -- shared run core. Reads workloads/workload.config (what + where) and
# server/server.config (how it streams: broker, connector, Darshan env, sink) via
# lib/config.sh, and turns them into env + launch helpers so workloads/job.sh is the
# only runner and nothing hand-copies the DARSHAN_MOFKA_* block or the launch dance.
#
# Source it, then use: load_run_config, connector_env <group>, darshan_env,
# workload_env, start_broker <dir> [nranks], broker_topic_partitions <group> [nranks],
# start_consumer <run_dir> <group>, stop_consumer_verdict <run_dir> <out>,
# workload_tag, next_run_dir <base>. An env var of a key's UPPERCASE name overrides it.

_RUN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_RUN_LIB_DIR/config.sh"
REPO_ROOT="${REPO:-$(dirname "$_RUN_LIB_DIR")}"
WORKLOAD_CONFIG="${WORKLOAD_CONFIG:-$REPO_ROOT/workloads/workload.config}"
SERVER_CONFIG="${SERVER_CONFIG:-$REPO_ROOT/server/server.config}"

# read key from a config file, but let an env var of the given NAME override it.
# NB: the indirect expansion must be on its own `local` line (see the bash gotcha where
# `local name=$1 v=${!name}` expands ${!name} before name is assigned).
_cfg_env() {
    local name="$1" file="$2" key="$3" def="$4"
    local v="${!name:-}"
    [ -n "$v" ] && printf '%s\n' "$v" || cfg_get "$file" "$key" "$def"
}

load_run_config() {
    # --- workload.config: what to run + where ---
    WL_TYPE=$(_cfg_env WORKLOAD "$WORKLOAD_CONFIG" workload c)
    WL_EVENTS=$(_cfg_env EVENTS "$WORKLOAD_CONFIG" events 8)
    WL_CHECKPOINTS=$(_cfg_env CHECKPOINTS "$WORKLOAD_CONFIG" checkpoints 2)
    WL_REPS=$(_cfg_env REPS "$WORKLOAD_CONFIG" reps 1)
    WL_NODES=$(_cfg_env NODES "$WORKLOAD_CONFIG" topology.nodes 1)
    WL_TASKS=$(_cfg_env TASKS "$WORKLOAD_CONFIG" topology.tasks 1)
    WL_PLACEMENT=$(_cfg_env PLACEMENT "$WORKLOAD_CONFIG" topology.placement colocated)
    WL_BROKERS=$(_cfg_env BROKERS "$WORKLOAD_CONFIG" topology.brokers 1)
    CFG_ACCOUNT=$(_cfg_env PBS_ACCOUNT "$WORKLOAD_CONFIG" pbs.account "")
    CFG_QUEUE=$(_cfg_env QUEUE "$WORKLOAD_CONFIG" pbs.queue debug)
    CFG_WALLTIME=$(_cfg_env WALLTIME "$WORKLOAD_CONFIG" pbs.walltime 00:30:00)
    CFG_NCPUS=$(_cfg_env NCPUS "$WORKLOAD_CONFIG" pbs.ncpus 32)
    # --- server.config: broker + connector + darshan env + sink ---
    SRV_TOPIC=$(_cfg_env MOFKA_TOPIC "$SERVER_CONFIG" topic darshan)
    SRV_PARTITIONS=$(_cfg_env PARTITIONS "$SERVER_CONFIG" partitions 1)
    SRV_PART_TYPE=$(_cfg_env MOFKA_PARTITION_TYPE "$SERVER_CONFIG" partition_type memory)
    SRV_PROTOCOL=$(_cfg_env MOFKA_PROTOCOL "$SERVER_CONFIG" protocol auto)
    [ "$SRV_PROTOCOL" = auto ] && SRV_PROTOCOL="${MOFKA_PROTOCOL_DEFAULT:-tcp}"   # profile default
    C_ENABLE=$(_cfg_env DARSHAN_MOFKA_ENABLE "$SERVER_CONFIG" connector.enable 1)
    C_BATCH=$(_cfg_env DARSHAN_MOFKA_BATCH "$SERVER_CONFIG" connector.batch 0)
    C_MAX_BATCHES=$(_cfg_env DARSHAN_MOFKA_MAX_BATCHES "$SERVER_CONFIG" connector.max_batches 64)
    C_FLUSH_MS=$(_cfg_env DARSHAN_MOFKA_FLUSH_MS "$SERVER_CONFIG" connector.flush_ms 5000)
    C_TIMING=$(_cfg_env DARSHAN_MOFKA_TIMING "$SERVER_CONFIG" connector.timing 1)
    D_NONMPI=$(_cfg_env DARSHAN_ENABLE_NONMPI "$SERVER_CONFIG" darshan.enable_nonmpi 1)
    D_MODMEM=$(_cfg_env DARSHAN_MODMEM "$SERVER_CONFIG" darshan.modmem "")
    D_MOD_ENABLE=$(_cfg_env DARSHAN_MOD_ENABLE "$SERVER_CONFIG" darshan.mod_enable "")
    D_MOD_DISABLE=$(_cfg_env DARSHAN_MOD_DISABLE "$SERVER_CONFIG" darshan.mod_disable "")
    D_INTERNAL_TIMING=$(_cfg_env DARSHAN_INTERNAL_TIMING "$SERVER_CONFIG" darshan.internal_timing "")
    SRV_MONGO_DB=$(_cfg_env MONGO_DB "$SERVER_CONFIG" mongo.db darshan_stream)
    SRV_MONGO_PORT=$(_cfg_env MONGO_PORT "$SERVER_CONFIG" mongo.port 27017)
    SRV_MONGO_CACHE_GB=$(_cfg_env MONGO_CACHE_GB "$SERVER_CONFIG" mongo.cache_gb "")
    SRV_MONGO_DBPATH=$(_cfg_env MONGO_DBPATH "$SERVER_CONFIG" mongo.dbpath "")
    CONS_MQ_BUF=$(_cfg_env MQ_BUFFER_SIZE "$SERVER_CONFIG" consumer.mq_buffer_size 50)
    CONS_MQ_FLUSH=$(_cfg_env MQ_FLUSH_SECS "$SERVER_CONFIG" consumer.mq_flush_secs 5)
    CONS_DB_BUF=$(_cfg_env DB_BUFFER_SIZE "$SERVER_CONFIG" consumer.db_buffer_size 50)
    CONS_DB_FLUSH=$(_cfg_env DB_FLUSH_SECS "$SERVER_CONFIG" consumer.db_flush_secs 5)
    BRK_RPC_THREADS=$(_cfg_env RPC_THREAD_COUNT "$SERVER_CONFIG" broker.rpc_thread_count 4)
    BRK_PROGRESS=$(_cfg_env USE_PROGRESS_THREAD "$SERVER_CONFIG" broker.use_progress_thread true)
    BRK_MASTER_DB=$(_cfg_env MASTER_DB "$SERVER_CONFIG" broker.master_db map)
    BRK_MASTER_DB_PATH=$(_cfg_env MASTER_DB_PATH "$SERVER_CONFIG" broker.master_db_path "")
    PART_PATH=$(_cfg_env PARTITION_PATH "$SERVER_CONFIG" partition_opts.path "")
    PART_ABTIO=$(_cfg_env PARTITION_ABT_IO "$SERVER_CONFIG" partition_opts.abt_io io_controller)
    PART_SYNC=$(_cfg_env PARTITION_SYNC "$SERVER_CONFIG" partition_opts.sync true)
}

# uppercased workload tag for results-dir names (c -> C, python-ml -> PYTHONML)
workload_tag() { load_run_config; printf '%s\n' "$WL_TYPE" | tr -d '-' | tr '[:lower:]' '[:upper:]'; }
# echo <base>/RUN<n> for the next unused rep (results/README.md convention)
next_run_dir() { local base="$1" n=1; while [ -e "$base/RUN$n" ]; do n=$((n+1)); done; printf '%s\n' "$base/RUN$n"; }
# descriptive results dir name derived from the topology knobs
results_dir_name() {
    load_run_config
    printf '%s_%sNODE_%sPROC_%sBroker-%s\n' "$(workload_tag)" "$WL_NODES" "$WL_TASKS" \
        "$([ "$WL_BROKERS" = per-node ] && echo "$WL_NODES" || echo 1)" "$WL_PLACEMENT"
}

# CONNECTOR_ENV=(...) -- producer DARSHAN_MOFKA_* knobs. Omits ENABLE when connector.enable=0
# (that leaves Darshan running but not streaming -- a clean runtime-only baseline).
connector_env() {
    local group="$1"; load_run_config
    CONNECTOR_ENV=(
        DARSHAN_MOFKA_GROUP_FILE="$group"
        DARSHAN_MOFKA_TOPIC="$SRV_TOPIC"
        DARSHAN_MOFKA_BATCH="$C_BATCH"
        DARSHAN_MOFKA_MAX_BATCHES="$C_MAX_BATCHES"
        DARSHAN_MOFKA_TIMING="$C_TIMING"
        DARSHAN_MOFKA_FLUSH_MS="$C_FLUSH_MS"
    )
    [ "$C_ENABLE" = 1 ] && CONNECTOR_ENV=(DARSHAN_MOFKA_ENABLE=1 "${CONNECTOR_ENV[@]}")
}

# DARSHAN_ENV=(...) -- standard Darshan runtime env from server.config darshan:
darshan_env() {
    load_run_config
    DARSHAN_ENV=()
    [ "$D_NONMPI" = 1 ]        && DARSHAN_ENV+=(DARSHAN_ENABLE_NONMPI=1)
    [ -n "$D_MODMEM" ]         && DARSHAN_ENV+=(DARSHAN_MODMEM="$D_MODMEM")
    [ -n "$D_MOD_ENABLE" ]     && DARSHAN_ENV+=(DARSHAN_MOD_ENABLE="$D_MOD_ENABLE")
    [ -n "$D_MOD_DISABLE" ]    && DARSHAN_ENV+=(DARSHAN_MOD_DISABLE="$D_MOD_DISABLE")
    [ -n "$D_INTERNAL_TIMING" ] && DARSHAN_ENV+=(DARSHAN_INTERNAL_TIMING="$D_INTERNAL_TIMING")
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

# render bedrock JSON from server.config broker.* (margo threads, master DB backend)
render_bedrock_config() {
    local tmpl="$1" out="$2"; load_run_config
    "$PY" - "$tmpl" "$out" "$BRK_RPC_THREADS" "$BRK_PROGRESS" "$BRK_MASTER_DB" "$BRK_MASTER_DB_PATH" <<'PY'
import json, sys
tmpl, out, rpc, prog, mdb, mdbpath = sys.argv[1:7]
d = json.load(open(tmpl))
d.setdefault("margo", {})["rpc_thread_count"] = int(rpc)
d["margo"]["use_progress_thread"] = (str(prog).lower() == "true")
for p in d.get("providers", []):
    if p.get("name") == "master_database":
        if mdb == "rocksdb":
            p["config"] = {"database": {"type": "rocksdb", "config": {"path": mdbpath, "create_if_missing": True}}}
        else:
            p["config"] = {"database": {"type": "map"}}
json.dump(d, open(out, "w"), indent=4)
PY
}

# start the broker in <server_dir>: single bedrock, or one-per-node via the tm mpirun.
# Sets BROKER_PID and GROUP; creates the topic + partitions.
start_broker() {
    local srv="$1" nranks="${2:-1}"; load_run_config
    mkdir -p "$srv"; cd "$srv"; rm -f mofka.json bedrock.log
    local multi=0; { [ "$WL_BROKERS" = per-node ] || [ "$nranks" -gt 1 ]; } && multi=1
    if [ "$multi" = 1 ]; then
        render_bedrock_config "$REPO_ROOT/server/bedrock-config-mpi.json" "$srv/bedrock-config-mpi.json"
        mpirun --map-by ppr:1:node -n "$nranks" \
            bedrock "$SRV_PROTOCOL" -c "$srv/bedrock-config-mpi.json" -v info > "$srv/bedrock.log" 2>&1 &
    else
        render_bedrock_config "$REPO_ROOT/server/bedrock-config.json" "$srv/bedrock-config.json"
        bedrock "$SRV_PROTOCOL" -c "$srv/bedrock-config.json" -v info > "$srv/bedrock.log" 2>&1 &
    fi
    BROKER_PID=$!
    local i; for i in $(seq 1 120); do [ -f "$srv/mofka.json" ] && break; sleep 1; done
    [ -f "$srv/mofka.json" ] || { echo "broker failed to start; $srv/bedrock.log:"; tail -20 "$srv/bedrock.log"; return 1; }
    GROUP="$srv/mofka.json"
    broker_topic_partitions "$GROUP" "$nranks"
    cd - >/dev/null
}

# create the topic + SRV_PARTITIONS partitions (round-robin across ranks if multi-rank)
broker_topic_partitions() {
    local group="$1" nranks="${2:-1}"; load_run_config
    if [ "$SRV_PART_TYPE" = default ] && [ -z "$PART_PATH" ]; then
        echo "ERROR: partition_type: default needs server.config partition_opts.path (and abt_io)"; return 2
    fi
    mofkactl topic create "$SRV_TOPIC" --groupfile "$group" 2>/dev/null || true
    local extra=(); [ "$SRV_PART_TYPE" = default ] && extra=(--abt-io "$PART_ABTIO")
    local p
    for p in $(seq 0 $(( SRV_PARTITIONS - 1 ))); do
        mofkactl partition add "$SRV_TOPIC" --rank $(( p % nranks )) --type "$SRV_PART_TYPE" \
            "${extra[@]}" --groupfile "$group" 2>/dev/null \
            || echo "  WARN: partition add (rank $(( p % nranks )) $SRV_PART_TYPE) failed"
    done
}

# start the FlowCept consumer (drains topic -> mongo) in the background; sets CONSUMER_PID
start_consumer() {
    local run_dir="$1" group="$2"; load_run_config; mkdir -p "$run_dir"
    RUN_DIR="$run_dir" MONGO_DB="$SRV_MONGO_DB" MONGO_PORT="$SRV_MONGO_PORT" MONGOD="$MONGOD" \
      TOPIC="$SRV_TOPIC" MOFKA_GROUP="$group" \
      MQ_BUFFER_SIZE="$CONS_MQ_BUF" MQ_FLUSH_SECS="$CONS_MQ_FLUSH" \
      DB_BUFFER_SIZE="$CONS_DB_BUF" DB_FLUSH_SECS="$CONS_DB_FLUSH" \
      MONGO_CACHE_GB="$SRV_MONGO_CACHE_GB" MONGO_DBPATH="$SRV_MONGO_DBPATH" \
      bash "$REPO_ROOT/Client/capture_flowcept.sh" > "$run_dir/flowcept.out" 2>&1 &
    CONSUMER_PID=$!
    local i; for i in $(seq 1 120); do
        grep -q 'consumer alive' "$run_dir/flowcept.out" 2>/dev/null && return 0
        kill -0 "$CONSUMER_PID" 2>/dev/null || { echo "consumer died:"; tail -20 "$run_dir/flowcept.out"; return 1; }
        sleep 1
    done
    echo "consumer did not come up in 120s"; return 1
}

# signal the consumer to drain, export mongo->JSONL (<events>) WHILE mongod is still up,
# print the INGEST verdict to <out>, then stop the consumer.
stop_consumer_verdict() {
    local run_dir="$1" out="$2" events="$3"
    touch "$run_dir/SHUTDOWN"
    local i; for i in $(seq 1 120); do
        grep -q 'Export now' "$run_dir/flowcept.out" 2>/dev/null && break
        kill -0 "$CONSUMER_PID" 2>/dev/null || break; sleep 1
    done
    "$PY" "$REPO_ROOT/Client/export_jsonl.py" 127.0.0.1 "$SRV_MONGO_DB" \
        --mongo-port "$SRV_MONGO_PORT" > "$events" 2> "${events%.jsonl}.count" || true
    grep -E 'INGEST:|tasks total=' "$run_dir/flowcept.out" | tee "$out"
    kill "$CONSUMER_PID" 2>/dev/null; wait "$CONSUMER_PID" 2>/dev/null || true
}
