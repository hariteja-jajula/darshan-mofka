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
WORKLOAD_CONFIG="${WORKLOAD_CONFIG:-$REPO_ROOT/workloads/workload.config}"   # producer/workload
SERVER_CONFIG="${SERVER_CONFIG:-$REPO_ROOT/server/server.config}"           # broker
CLIENT_CONFIG="${CLIENT_CONFIG:-$REPO_ROOT/Client/client.config}"           # consumer + mongo sink

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
    # --- server.config: broker + connector + darshan env + sink ---
    SRV_TOPIC=$(_cfg_env MOFKA_TOPIC "$SERVER_CONFIG" topic darshan)
    SRV_PARTITIONS=$(_cfg_env PARTITIONS "$SERVER_CONFIG" partitions 1)
    SRV_PART_TYPE=$(_cfg_env MOFKA_PARTITION_TYPE "$SERVER_CONFIG" partition_type memory)
    SRV_PROTOCOL=$(_cfg_env MOFKA_PROTOCOL "$SERVER_CONFIG" protocol auto)
    [ "$SRV_PROTOCOL" = auto ] && SRV_PROTOCOL="${MOFKA_PROTOCOL_DEFAULT:-tcp}"   # profile default
    # connector + darshan env are producer-side -> workload.config
    C_ENABLE=$(_cfg_env DARSHAN_MOFKA_ENABLE "$WORKLOAD_CONFIG" connector.enable 1)
    C_BATCH=$(_cfg_env DARSHAN_MOFKA_BATCH "$WORKLOAD_CONFIG" connector.batch 0)
    C_MAX_BATCHES=$(_cfg_env DARSHAN_MOFKA_MAX_BATCHES "$WORKLOAD_CONFIG" connector.max_batches 64)
    C_FLUSH_MS=$(_cfg_env DARSHAN_MOFKA_FLUSH_MS "$WORKLOAD_CONFIG" connector.flush_ms 5000)
    C_TIMING=$(_cfg_env DARSHAN_MOFKA_TIMING "$WORKLOAD_CONFIG" connector.timing 1)
    C_CLIENT_MODE=$(_cfg_env MOFKA_CLIENT_MODE "$WORKLOAD_CONFIG" connector.client_mode 1)  # producer non-listening endpoint (attach fix)
    C_NA_DOMAIN=$(_cfg_env MOFKA_NA_DOMAIN "$WORKLOAD_CONFIG" connector.na_domain "")        # local na_ofi domain (verbs needs it, e.g. mlx5_0)
    C_FINAL_SWEEP=$(_cfg_env DARSHAN_MOFKA_FINAL_SWEEP "$WORKLOAD_CONFIG" connector.final_sweep 0)  # re-stream final records at shutdown; DISABLED (hangs python-ml, see run.sh connector_env note)
    D_NONMPI=$(_cfg_env DARSHAN_ENABLE_NONMPI "$WORKLOAD_CONFIG" darshan.enable_nonmpi 1)
    D_MODMEM=$(_cfg_env DARSHAN_MODMEM "$WORKLOAD_CONFIG" darshan.modmem "")
    D_MOD_ENABLE=$(_cfg_env DARSHAN_MOD_ENABLE "$WORKLOAD_CONFIG" darshan.mod_enable "")
    D_MOD_DISABLE=$(_cfg_env DARSHAN_MOD_DISABLE "$WORKLOAD_CONFIG" darshan.mod_disable "")
    D_INTERNAL_TIMING=$(_cfg_env DARSHAN_INTERNAL_TIMING "$WORKLOAD_CONFIG" darshan.internal_timing "")
    # consumer + mongo sink are client-side -> client.config
    SRV_MONGO_DB=$(_cfg_env MONGO_DB "$CLIENT_CONFIG" mongo.db darshan_stream)
    SRV_MONGO_PORT=$(_cfg_env MONGO_PORT "$CLIENT_CONFIG" mongo.port 27017)
    SRV_MONGO_CACHE_GB=$(_cfg_env MONGO_CACHE_GB "$CLIENT_CONFIG" mongo.cache_gb "")
    SRV_MONGO_DBPATH=$(_cfg_env MONGO_DBPATH "$CLIENT_CONFIG" mongo.dbpath "")
    CONS_MQ_BUF=$(_cfg_env MQ_BUFFER_SIZE "$CLIENT_CONFIG" consumer.mq_buffer_size 50)
    CONS_MQ_FLUSH=$(_cfg_env MQ_FLUSH_SECS "$CLIENT_CONFIG" consumer.mq_flush_secs 5)
    CONS_DB_BUF=$(_cfg_env DB_BUFFER_SIZE "$CLIENT_CONFIG" consumer.db_buffer_size 50)
    CONS_DB_FLUSH=$(_cfg_env DB_FLUSH_SECS "$CLIENT_CONFIG" consumer.db_flush_secs 5)
    CONS_N=$(_cfg_env CONSUMERS "$CLIENT_CONFIG" consumer.consumers 1)   # parallel sharded drainers
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
    # Always pass ENABLE explicitly (=0 for the runtime-only baseline) so it also
    # reaches the workload on the separate-node path, where the env is rebuilt from
    # this array rather than inherited. The connector honors an explicit 0.
    CONNECTOR_ENV=(
        DARSHAN_MOFKA_ENABLE="$C_ENABLE"
        DARSHAN_MOFKA_GROUP_FILE="$group"
        DARSHAN_MOFKA_TOPIC="$SRV_TOPIC"
        DARSHAN_MOFKA_BATCH="$C_BATCH"
        DARSHAN_MOFKA_MAX_BATCHES="$C_MAX_BATCHES"
        DARSHAN_MOFKA_TIMING="$C_TIMING"
        DARSHAN_MOFKA_FLUSH_MS="$C_FLUSH_MS"
    )
    # Async off-the-hot-path knobs: the connector defaults async ON, so these only need to be
    # forwarded when explicitly set. On the separate-node path the workload env is rebuilt from
    # this array (not inherited), so pass through any that are set rather than relying on MPI
    # env-forwarding. (The A/B DARSHAN_MOFKA_ASYNC=0 arm in particular depends on this.)
    for _k in DARSHAN_MOFKA_ASYNC DARSHAN_MOFKA_QUEUE_DEPTH DARSHAN_MOFKA_DROP_POLICY \
              DARSHAN_MOFKA_DRAIN_THREADS DARSHAN_MOFKA_JOIN_MS DARSHAN_MOFKA_VERBOSE \
              DARSHAN_MOFKA_DRAIN_CPU_BASE DARSHAN_MOFKA_DRAIN_CPU_STRIDE \
              DARSHAN_MOFKA_RAW_JSON \
              DARSHAN_MOFKA_MARGO_JSON DIASPORA_C_SENDER_THREADS; do
        [ -n "${!_k:-}" ] && CONNECTOR_ENV+=( "$_k=${!_k}" )
    done
    # Producer-only: make the connector's Mofka engine non-listening (patched mofka reads
    # MOFKA_CLIENT_MODE) so many producers/node stop exhausting the NIC's fabric queues. Only
    # added to the PRODUCER env here; the FlowCept consumer never sees it, so it keeps SERVER_MODE.
    [ "$C_CLIENT_MODE" = 1 ] && CONNECTOR_ENV+=( MOFKA_CLIENT_MODE=1 )
    # Optional: shrink the producer's Mercury na_ofi send/recv queues further (CLIENT_MODE gives
    # 512; smaller = fewer per-node fabric resources = more producers/node attach). Passed through
    # when set in the environment (na_ofi.c reads NA_OFI_TX_SIZE/RX_SIZE).
    [ -n "${NA_OFI_TX_SIZE:-}" ] && CONNECTOR_ENV+=( NA_OFI_TX_SIZE="$NA_OFI_TX_SIZE" )
    [ -n "${NA_OFI_RX_SIZE:-}" ] && CONNECTOR_ENV+=( NA_OFI_RX_SIZE="$NA_OFI_RX_SIZE" )
    # Name the local na_ofi domain for the producer (verbs can't default it on connect). Patched
    # mofka reads MOFKA_NA_DOMAIN and qualifies the engine protocol (ofi+verbs;ofi_rxm://mlx5_0).
    # ONLY pass it for a verbs transport: it names a *verbs HCA* (e.g. mlx5_0). On an ofi+tcp
    # fabric (Polaris/Slingshot has no mlx5_0) mofka would form `ofi+tcp://mlx5_0`, which na_ofi
    # rejects with "No provider found for tcp on domain mlx5_0" -> margo_init fails -> the producer
    # never attaches and 0 events stream. Gating on the resolved protocol keeps LCRC (verbs) working
    # with na_domain:mlx5_0 in workload.config while Polaris (ofi+tcp) omits it.
    if [ -n "$C_NA_DOMAIN" ]; then
        case "$SRV_PROTOCOL" in
            *verbs*) CONNECTOR_ENV+=( MOFKA_NA_DOMAIN="$C_NA_DOMAIN" ) ;;
            *) : "not verbs ($SRV_PROTOCOL) -> MOFKA_NA_DOMAIN dropped (would break ofi+tcp)" ;;
        esac
    fi
    # Finalize records-sweep: would re-stream every module record's final struct at shutdown to
    # close the python-ml init-window counter gap. DISABLED by default: enabling it hangs python-ml
    # at finalize (the extra records are new async sends from the atexit context, and mofka's
    # producer sender runs on the margo progress pool, so they never progress). Only an explicit
    # final_sweep:1 / DARSHAN_MOFKA_FINAL_SWEEP=1 turns it on -- for experiments once mofka is fixed.
    # See the KNOWN ISSUE note in darshan_mofka_connector_flush_records (darshan-mofka.c).
    [ "$C_FINAL_SWEEP" = 1 ] && CONNECTOR_ENV+=( DARSHAN_MOFKA_FINAL_SWEEP=1 )
}

# DARSHAN_ENV=(...) -- standard Darshan runtime env from server.config darshan:
darshan_env() {
    load_run_config
    DARSHAN_ENV=()
    # DARSHAN_ENABLE_NONMPI fires darshan's load-time constructor
    # (darshan/darshan-runtime/lib/darshan-core-init-finalize.c:101 serial_init), which
    # calls darshan_core_initialize BEFORE the app's MPI_Init. For a real MPI job that
    # latches using_mpi=0 (darshan-core.c:218 PMPI_Initialized reads false pre-init; the
    # first-init-wins guard at :206 means the MPI_Init wrapper's later re-init is a no-op),
    # so the rank reduction never runs and each rank writes its own nprocs=1 log instead of
    # one rank=-1 shared log. MUST be unset for mpi.
    # dlio is ALSO a real MPI app: dlio_benchmark unconditionally calls MPI.Init()
    # (install/_dlio_venv/.../dlio_benchmark/utils/utility.py:130-131, main.py:394) and
    # MPI.Finalize() (utility.py:199). With DARSHAN_ENABLE_NONMPI=1 Darshan inits serial at
    # LD_PRELOAD load-time and defers shutdown to its atexit handler, which then runs its rank
    # reduction AFTER dlio already called MPI.Finalize() -> "MPI routine (internal_Reduce_c)
    # after finalizing MPICH" abort. Excluding dlio here lets Darshan finalize inside
    # the PMPI_Finalize wrapper (before MPICH teardown) and emit ONE shared rank=-1 log, exactly
    # like the mpi workload -> dlio must ALSO use strict_compare cmp_mode=mpi.
    [ "$D_NONMPI" = 1 ] && [ "$WL_TYPE" != mpi ] && [ "$WL_TYPE" != dlio ] && DARSHAN_ENV+=(DARSHAN_ENABLE_NONMPI=1)
    # DLIO: `import tensorflow` (>1024 .pyc files) + generate_data (num_files_train npz)
    # blow past Darshan's default 1024-record/module cap (darshan.h:232), silently dropping
    # every later record from BOTH the native log AND the Mofka stream (same POSIX_PRE_RECORD
    # gate, darshan-posix.c:259,422) -> vacuous strict-compare. The config raises MAX_RECORDS
    # *and* MODMEM (the 4 MiB pool caps records, darshan-core.c:2571). Gated to dlio so it can
    # never perturb c/mpi/python-ml.
    [ "$WL_TYPE" = dlio ] && DARSHAN_ENV+=(DARSHAN_CONFIG_PATH="$REPO_ROOT/config/darshan_dlio.conf")
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
        io_bench|io_bench_py)  WORKLOAD_ENV=(); for _k in IO_SIZE_MB IO_ITERS IO_SLEEP_MS IO_BLOCK_KB COMPUTE_MODE COMPUTE MATRIX_SIZE ML_FILES CHECKPOINT_EVERY; do
                       [ -n "${!_k:-}" ] && WORKLOAD_ENV+=("$_k=${!_k}"); done  # tunable; else built-in defaults (C + Python twin share knobs)
                       # Cap library threading so the CPU_PROBE app thread is the ONLY compute
                       # thread -- otherwise a BLAS/OMP/runtime helper thread inflates cpu_self
                       # (RUSAGE_SELF, all-threads) even in the NO_DARSHAN baseline, masking the
                       # connector's real per-core cost. Measurement-neutral across all arms.
                       WORKLOAD_ENV+=(OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 \
                                      NUMEXPR_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1) ;;
        python-ml) WORKLOAD_ENV=(ML_EPOCHS="$WL_EVENTS" ML_CHECKPOINTS="$WL_CHECKPOINTS")

                   _mlbt="${ML_BLAS_THREADS:-1}"
                   WORKLOAD_ENV+=(OMP_NUM_THREADS="$_mlbt" OPENBLAS_NUM_THREADS="$_mlbt" \
                                  MKL_NUM_THREADS="$_mlbt" NUMEXPR_NUM_THREADS="$_mlbt" \
                                  VECLIB_MAXIMUM_THREADS="$_mlbt")

                   for _k in ML_FILES ML_ROWS ML_COLS ML_WRITE_MODE ML_PROFILE ML_BLAS_THREADS; do
                       [ -n "${!_k:-}" ] && WORKLOAD_ENV+=("$_k=${!_k}"); done ;;
        mpi)       WORKLOAD_ENV=(STEPS="$WL_EVENTS")  # repeat REAL block write+read WL_EVENTS times (overhead-study fixed-work scale knob)

                   [ -n "${IO_BLOCK_KB:-}" ] && WORKLOAD_ENV+=(IO_BLOCK_KB="$IO_BLOCK_KB") ;;
        dlio)
                   WORKLOAD_ENV=(OMP_NUM_THREADS=1 TF_NUM_INTRAOP_THREADS=1 TF_NUM_INTEROP_THREADS=1 TF_CPP_MIN_LOG_LEVEL=3)

                   if [ -n "${MPICH_DIR:-}" ] && [ -e "$MPICH_DIR/lib/libmpi_gnu_123.so.12" ]; then
                       WORKLOAD_ENV+=(LD_LIBRARY_PATH="$MPICH_DIR/lib:${LD_LIBRARY_PATH:-}")
                   fi
                   ;;

        hep-salt)
                   WORKLOAD_ENV=(
                       PYTHONNOUSERSITE=1
                   )
                   ;;

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
    local srv="$1" nranks="${2:-1}" bhf="${3:-}"; load_run_config
    mkdir -p "$srv"; cd "$srv"; rm -f mofka.json bedrock.log
    local multi=0; { [ "$WL_BROKERS" = per-node ] || [ "$nranks" -gt 1 ]; } && multi=1
    # ofi+cxi must launch under mpiexec so bedrock inherits the job-wide Slingshot VNI, and
    # each bedrock must collapse Polaris's two VNIs to one (margo mishandles multi-VNI ->
    # "Invalid domain auth_key"). tcp/others keep the bare launch. lead[] is the argv that
    # precedes the bedrock CLI args (a collapse-then-exec shim for cxi, plain bedrock otherwise).
    local lead=(bedrock)
    [[ "$SRV_PROTOCOL" == *cxi* ]] && lead=(bash -c "$(cxi_collapse) exec bedrock \"\$@\"" bedrock)
    local cfg
    if [ "$multi" = 1 ]; then
        cfg="$srv/bedrock-config-mpi.json"; render_bedrock_config "$REPO_ROOT/server/bedrock-config-mpi.json" "$cfg"
        mpi_launch "$nranks" 1                       # one bedrock/node over the PBS reservation
        "${MPI_LAUNCH[@]}" "${lead[@]}" "$SRV_PROTOCOL" -c "$cfg" -v info > "$srv/bedrock.log" 2>&1 &
    elif [[ "$SRV_PROTOCOL" == *cxi* ]]; then
        cfg="$srv/bedrock-config.json"; render_bedrock_config "$REPO_ROOT/server/bedrock-config.json" "$cfg"
        mpi_launch 1 1 "$bhf"                        # pin the lone broker to its node (bhf)
        "${MPI_LAUNCH[@]}" "${lead[@]}" "$SRV_PROTOCOL" -c "$cfg" -v info > "$srv/bedrock.log" 2>&1 &
    else
        cfg="$srv/bedrock-config.json"; render_bedrock_config "$REPO_ROOT/server/bedrock-config.json" "$cfg"
        bedrock "$SRV_PROTOCOL" -c "$cfg" -v info > "$srv/bedrock.log" 2>&1 &
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
    # Serializer: default (parse+dump round-trip) unless the raw-json handoff is on, in which case
    # the topic advertises the "raw" serializer in the master DB -- both the connector producer and
    # the FlowCept consumer read this back, so the choice propagates to both ends automatically.
    local ser_opt=()
    if [ -n "${DARSHAN_MOFKA_RAW_JSON:-}" ] && [ "${DARSHAN_MOFKA_RAW_JSON}" != 0 ]; then
        ser_opt=( -s raw )
    fi
    mofkactl topic create "$SRV_TOPIC" "${ser_opt[@]}" --groupfile "$group" 2>/dev/null || true
    local extra=(); [ "$SRV_PART_TYPE" = default ] && extra=(--abt-io "$PART_ABTIO")
    local p
    for p in $(seq 0 $(( SRV_PARTITIONS - 1 ))); do
        mofkactl partition add "$SRV_TOPIC" --rank $(( p % nranks )) --type "$SRV_PART_TYPE" \
            "${extra[@]}" --groupfile "$group" 2>/dev/null \
            || echo "  WARN: partition add (rank $(( p % nranks )) $SRV_PART_TYPE) failed"
    done
}

# Parallel sharded drain: CONS_N FlowCept consumers each pinned to a DISJOINT partition subset
# (Mofka `targets`), ALL sharing ONE mongod. FlowCept upserts on the unique task_id index, so a
# shared sink de-dups for free and reconstruct reads one collection -- simpler and safer than one
# mongod per shard (an over- or mis-set shard just re-upserts, never duplicates). Consumer 0 is the
# LEAD (owns the mongod + verdict/export); 1..N-1 are followers that attach to it. CONS_N=1 is the
# original single-consumer path (identical). Set consumer.consumers (CONSUMERS) with server
# partitions >= consumers to scale the pull. Fills CONSUMER_PIDS / CONSUMER_DIRS.

# partition indices for shard k of C over P partitions -> "[i,j,..]" (contiguous, remainder
# spread to the first shards; empty for the single-consumer case = all partitions).
_shard_targets() {
    local k="$1" C="$2" P="$3"
    [ "$C" -le 1 ] && { echo ""; return; }
    local base=$((P / C)) rem=$((P % C)) start count i list=""
    if [ "$k" -lt "$rem" ]; then start=$((k * (base + 1))); count=$((base + 1))
    else start=$((rem * (base + 1) + (k - rem) * base)); count=$base; fi
    for ((i = 0; i < count; i++)); do list="${list:+$list,}$((start + i))"; done
    echo "[$list]"
}

# launch consumer shard k (role lead|follower) into $cdir; ALL share MONGO_PORT (one mongod).
_launch_consumer() {
    local k="$1" C="$2" P="$3" group="$4" role="$5" cdir="$6"
    local targets; targets="$(_shard_targets "$k" "$C" "$P")"; mkdir -p "$cdir"
    FC_ROLE="$role" RUN_DIR="$cdir" MONGO_DB="$SRV_MONGO_DB" MONGO_PORT="$SRV_MONGO_PORT" \
      MONGOD="$MONGOD" MONGO_CACHE_GB="$SRV_MONGO_CACHE_GB" MONGO_DBPATH="$SRV_MONGO_DBPATH" \
      TOPIC="$SRV_TOPIC" MOFKA_GROUP="$group" MOFKA_TARGETS="$targets" \
      MQ_BUFFER_SIZE="$CONS_MQ_BUF" MQ_FLUSH_SECS="$CONS_MQ_FLUSH" \
      DB_BUFFER_SIZE="$CONS_DB_BUF" DB_FLUSH_SECS="$CONS_DB_FLUSH" \
      bash "$REPO_ROOT/Client/capture_flowcept.sh" > "$cdir/flowcept.out" 2>&1 &
    CONSUMER_PIDS+=("$!"); CONSUMER_DIRS+=("$cdir")
}

_wait_alive() {   # $1=pid $2=dir $3=label
    local i; for i in $(seq 1 120); do
        grep -q 'consumer alive' "$2/flowcept.out" 2>/dev/null && return 0
        kill -0 "$1" 2>/dev/null || { echo "$3 died:"; tail -20 "$2/flowcept.out"; return 1; }
        sleep 1
    done
    echo "$3 did not come up in 120s"; return 1
}

start_consumer() {
    local run_dir="$1" group="$2"; load_run_config; mkdir -p "$run_dir"
    local C="${CONS_N:-1}" P="$SRV_PARTITIONS" k
    [ "$C" -gt "$P" ] && { echo "CONSUMERS=$C > PARTITIONS=$P; clamping to $P"; C="$P"; }
    CONSUMER_PIDS=(); CONSUMER_DIRS=()
    # lead (k=0) starts the one shared mongod, then followers attach to it.
    local lead_dir; [ "$C" -le 1 ] && lead_dir="$run_dir" || lead_dir="$run_dir/c0"
    _launch_consumer 0 "$C" "$P" "$group" lead "$lead_dir"
    _wait_alive "${CONSUMER_PIDS[0]}" "${CONSUMER_DIRS[0]}" "lead consumer" || return 1
    for ((k = 1; k < C; k++)); do
        _launch_consumer "$k" "$C" "$P" "$group" follower "$run_dir/c$k"
        _wait_alive "${CONSUMER_PIDS[$k]}" "${CONSUMER_DIRS[$k]}" "consumer $k" || return 1
    done
    echo "started $C consumer(s) sharing mongod:$SRV_MONGO_PORT ($C shard(s) of $P partition(s))"
    return 0
}

# stop followers first (they flush their shard into the shared mongod), then the lead (flush +
# hold mongod open); export ONCE -> <events>, verdict -> <out>, then stop everything.
stop_consumer_verdict() {
    local run_dir="$1" out="$2" events="$3"
    local wait_s="${DRAIN_WAIT_S:-600}" n="${#CONSUMER_PIDS[@]}" k i
    for ((k = 1; k < n; k++)); do touch "${CONSUMER_DIRS[$k]}/SHUTDOWN"; done
    for ((k = 1; k < n; k++)); do
        for i in $(seq 1 "$wait_s"); do kill -0 "${CONSUMER_PIDS[$k]}" 2>/dev/null || break; sleep 1; done
    done
    touch "${CONSUMER_DIRS[0]}/SHUTDOWN"
    for i in $(seq 1 "$wait_s"); do
        grep -q 'Export now' "${CONSUMER_DIRS[0]}/flowcept.out" 2>/dev/null && break
        kill -0 "${CONSUMER_PIDS[0]}" 2>/dev/null || break; sleep 1
    done
    "$PY" "$REPO_ROOT/Client/export_jsonl.py" 127.0.0.1 "$SRV_MONGO_DB" \
        --mongo-port "$SRV_MONGO_PORT" > "$events" 2> "${events%.jsonl}.count" || true
    grep -E 'INGEST:|tasks total=' "${CONSUMER_DIRS[0]}/flowcept.out" | tee "$out"
    for ((k = 0; k < n; k++)); do kill "${CONSUMER_PIDS[$k]}" 2>/dev/null; wait "${CONSUMER_PIDS[$k]}" 2>/dev/null || true; done
}

# =============================== MPMD (ofi+cxi) path ===============================
# run_mpmd_rep <RES> -- run ONE rep as a SINGLE MPMD mpiexec: broker + FlowCept consumer(s)
# + Darshan workload as :-separated sections in ONE launch, so PALS gives the whole launch
# ONE shared Slingshot job VNI (the ONLY way cross-node ofi+cxi routes -- 3 separate launches
# get 3 non-routable VNIs). Proven recipe:
#   Lever 1 = single MPMD mpiexec (mpi_launch_mpmd).  Lever 2 = PMI-strip before exec (PALS
#   injects a phantom PMI world that hangs non-MPI bedrock).  + cxi_collapse (margo multi-VNI
#   bug) + exec bedrock DIRECTLY </dev/null.  Sections coordinate via files on the Eagle FS.
# Leaves $RES/events.jsonl for the reconstruct+strict_compare tail in job.sh (UNCHANGED).
# Success = $COORD/ALL_DONE present AND $RES/events.jsonl non-empty; the mpiexec
# EXIT CODE IS MEANINGLESS (we kill the still-running broker).  Non-MPI workloads only (Gate-0).
# Relies on job.sh-main globals: ROOT, SRV_NODE, WL_NODES_ARR, WL_TOTAL_RANKS, ENV_PROFILE, PY.
# Reuses: render_bedrock_config, connector_env, darshan_env, workload_env, darshan_lib,
# broker_topic_partitions, _shard_targets, pmi_strip, cxi_collapse, mpi_launch_mpmd.
run_mpmd_rep() {
    local RES="$1"; load_run_config
    case "$WL_TYPE" in
        mpi|dlio) echo "run_mpmd_rep: WL_TYPE=$WL_TYPE unsupported over cxi/mpmd (Gate-0) -- MPI runs via RUN_MODE=legacy"; return 2 ;;
    esac
    [[ "$SRV_PROTOCOL" == *cxi* ]] || echo "run_mpmd_rep: WARN protocol=$SRV_PROTOCOL is not cxi (this path is for ofi+cxi)"
    local COORD="$RES/coord" SEC="$RES/sections"
    rm -rf "$COORD" "$SEC"; mkdir -p "$COORD" "$SEC" "$RES/fc"

    # bedrock config: group_manager "file":"mofka.json" is RELATIVE, so the broker section cd's
    # into $COORD and writes $COORD/mofka.json there -- the shared-FS flag the others poll for.
    render_bedrock_config "$REPO_ROOT/server/bedrock-config.json" "$COORD/bedrock-config.json"

    # Producer env, serialized into the workload section (bash arrays don't cross mpiexec). Mirror
    # the legacy separate-node path (run_workload_once): env $ESTR DARSHAN_LOGPATH LD_PRELOAD cmd.
    connector_env "$COORD/mofka.json"; darshan_env; workload_env
    local ESTR="${CONNECTOR_ENV[*]} ${DARSHAN_ENV[*]} ${WORKLOAD_ENV[*]}"
    local DLIB; DLIB="${DARSHAN_LIB_SO:-$(darshan_lib)}"   # reuse the once-resolved path (job.sh); fall back if called standalone
    local CMD
    case "$WL_TYPE" in
        c)           CMD="./workloads/c/mofka_forward_smoke" ;;
        io_bench)    CMD="./workloads/c/io_bench" ;;
        io_bench_py) CMD="$PY workloads/python-ml/io_bench.py" ;;
        python-ml)   CMD="$PY workloads/python-ml/train.py" ;;
        hep-salt)    CMD="$ROOT/workloads/HEP/run_salt_streaming.sh" ;;
        *)           echo "run_mpmd_rep: unknown non-MPI workload '$WL_TYPE'"; return 2 ;;
    esac
    local STRIP COLLAPSE; STRIP="$(pmi_strip)"; COLLAPSE="$(cxi_collapse)"

    # ---------------- s_broker.sh  (N0, 1 rank) ----------------
    {
        printf '#!/bin/bash\n'
        printf 'ROOT=%q COORD=%q RES=%q PROFILE=%q SRV_PROTOCOL=%q\n' "$ROOT" "$COORD" "$RES" "$ENV_PROFILE" "$SRV_PROTOCOL"
        printf '%s\n' 'RANKID="${PALS_RANKID:-0}"'      # (unused by broker; kept for uniformity)
        printf '%s\n' "$STRIP"                          # drop PALS phantom PMI (keeps SLINGSHOT_*)
        printf '%s\n' "$COLLAPSE"                        # collapse Polaris' 2 VNIs -> 1 (margo bug)
        cat <<'BROKER'
cd "$COORD"; rm -f mofka.json
source "$ROOT/env/server.sh" --"$PROFILE" >/dev/null 2>&1
cd "$COORD"
echo "s_broker host=$(hostname -s) proto=$SRV_PROTOCOL VNIS=[${SLINGSHOT_VNIS:-}]" >&2
exec bedrock "$SRV_PROTOCOL" -c "$COORD/bedrock-config.json" -v info > "$RES/broker.log" 2>&1 </dev/null
BROKER
    } > "$SEC/s_broker.sh"

    # ---------------- s_consumer.sh  (N0, CONS_N ranks) ----------------
    # Each rank atomically claims a shard id via mkdir; shard 0 = LEAD (creates topic+partitions,
    # owns the shared mongod + export/ALL_DONE); 1..N-1 = followers that attach. capture_flowcept.sh
    # already honors every knob below (FC_ROLE, FLAGDIR->CONSUMER_READY, SHUTDOWN_FLAG, EXPORT_ON_STOP/
    # EXPORT_OUT/ALL_DONE_FLAG, MOFKA_GROUP/MOFKA_TARGETS). Config scalars come from load_run_config
    # (identical to the head node: submit_cxi.sh forwards CONSUMERS/PARTITIONS/... via qsub -v).
    {
        printf '#!/bin/bash\n'
        printf 'ROOT=%q COORD=%q RES=%q PROFILE=%q\n' "$ROOT" "$COORD" "$RES" "$ENV_PROFILE"
        printf '%s\n' 'RANKID="${PALS_RANKID:-0}"'
        printf '%s\n' "$STRIP"
        printf '%s\n' "$COLLAPSE"
        cat <<'CONSUMER'
cd "$ROOT"
source "$ROOT/env/server.sh" --"$PROFILE" >/dev/null 2>&1
source "$ROOT/lib/run.sh"; load_run_config          # reuse _shard_targets + broker_topic_partitions
echo "s_consumer rank=$RANKID host=$(hostname -s) VNIS=[${SLINGSHOT_VNIS:-}]" >&2
SHARD_ID=0
for i in $(seq 0 $((CONS_N - 1))); do mkdir "$COORD/claim_$i" 2>/dev/null && { SHARD_ID=$i; break; }; done
role=follower; [ "$SHARD_ID" = 0 ] && role=lead
for _ in $(seq 1 "${MOFKA_GROUP_WAIT_S:-180}"); do [ -s "$COORD/mofka.json" ] && break; sleep 1; done
if [ ! -s "$COORD/mofka.json" ]; then echo "consumer shard=$SHARD_ID: no mofka.json" >&2; touch "$COORD/CONS_FAIL.$SHARD_ID"; exit 1; fi
[ "$SHARD_ID" = 0 ] && broker_topic_partitions "$COORD/mofka.json" 1   # LEAD creates topic+partitions once
[ "$SHARD_ID" = 0 ] && touch "$COORD/TOPIC_READY"                      # signal topic created
# All consumers wait until the topic exists in the master DB before open_topic (race fix):
# the lead's topic-create must commit before any consumer/producer opens it, else
# "Topic not found in master database". Wait for the flag + a small settle sleep.
for _ in $(seq 1 60); do [ -f "$COORD/TOPIC_READY" ] && break; sleep 1; done
sleep 3
targets="$(_shard_targets "$SHARD_ID" "$CONS_N" "$SRV_PARTITIONS")"
cdir="$RES/fc/c$SHARD_ID"; mkdir -p "$cdir"
export_on_stop=0; all_done_flag=""
[ "$SHARD_ID" = 0 ] && { export_on_stop=1; all_done_flag="$COORD/ALL_DONE"; }
FC_ROLE="$role" RUN_DIR="$cdir" FLAGDIR="$COORD" \
  MONGO_DB="$SRV_MONGO_DB" MONGO_PORT="$SRV_MONGO_PORT" MONGOD="$MONGOD" \
  MONGO_CACHE_GB="$SRV_MONGO_CACHE_GB" MONGO_DBPATH="$SRV_MONGO_DBPATH" \
  TOPIC="$SRV_TOPIC" MOFKA_GROUP="$COORD/mofka.json" MOFKA_TARGETS="$targets" \
  MQ_BUFFER_SIZE="$CONS_MQ_BUF" MQ_FLUSH_SECS="$CONS_MQ_FLUSH" \
  DB_BUFFER_SIZE="$CONS_DB_BUF" DB_FLUSH_SECS="$CONS_DB_FLUSH" \
  SHUTDOWN_FLAG="$COORD/SHUTDOWN" MOFKA_GROUP_WAIT_S="${MOFKA_GROUP_WAIT_S:-180}" \
  EXPORT_ON_STOP="$export_on_stop" EXPORT_OUT="$RES/events.jsonl" ALL_DONE_FLAG="$all_done_flag" \
  bash "$ROOT/Client/capture_flowcept.sh" > "$cdir/flowcept.out" 2>&1
rc=$?
touch "$COORD/CONS_DONE.$SHARD_ID"
[ "$rc" -ne 0 ] && touch "$COORD/CONS_FAIL.$SHARD_ID"
exit "$rc"
CONSUMER
    } > "$SEC/s_consumer.sh"

    # ---------------- s_workload.sh  (N1..Nk, WL_TOTAL_RANKS ranks) ----------------
    # Non-MPI POSIX workload under the Darshan->Mofka connector. Waits for CONSUMER_READY, then runs
    # exactly like the legacy separate-node launch (env $ESTR DARSHAN_LOGPATH LD_PRELOAD cmd) so the
    # native .darshan logs land in $RES for the reconstruct+strict_compare tail. ESTR/DLIB/CMD/WL_TYPE
    # are baked from the head node (arrays don't cross mpiexec).
    {
        printf '#!/bin/bash\n'
        printf 'ROOT=%q COORD=%q RES=%q PROFILE=%q WL_TYPE=%q\n' "$ROOT" "$COORD" "$RES" "$ENV_PROFILE" "$WL_TYPE"
        printf 'NO_DARSHAN=%q\n' "${NO_DARSHAN:-0}"
        # DM_MPSTAT=1 -> sample per-core CPU (mpstat -P ALL) on the workload rank (non-invasive).
        printf 'DM_MPSTAT=%q\n' "${DM_MPSTAT:-0}"
        printf 'DM_MPSTAT_INT=%q\n' "${DM_MPSTAT_INT:-5}"
        printf 'ESTR=%q\n' "$ESTR"
        printf 'DLIB=%q\n' "$DLIB"
        printf 'CMD=%q\n' "$CMD"
        # DM_WRAP_PERF=1 -> prefix the workload rank with perf stat (trisection diagnostics).
        if [ "${DM_WRAP_PERF:-0}" = 1 ]; then
            printf 'PERFWRAP=%q\n' "perf stat -o $RES/perf.$( [ "${NO_DARSHAN:-0}" = 1 ] && echo baseline || echo streaming ).\${RANKID}.txt -e task-clock,cycles,ref-cycles,instructions,dTLB-load-misses,cache-misses,context-switches,cpu-migrations,minor-faults --"
        else
            printf 'PERFWRAP=%q\n' ""
        fi
        printf '%s\n' 'RANKID="${PALS_RANKID:-0}"'
        printf '%s\n' "$STRIP"
        printf '%s\n' "$COLLAPSE"
        cat <<'WORKLOAD'
cd "$ROOT"
source "$ROOT/env/workload.sh" --"$PROFILE" >/dev/null 2>&1
echo "s_workload rank=$RANKID host=$(hostname -s) VNIS=[${SLINGSHOT_VNIS:-}]" > "$RES/workload.$RANKID.out"
for _ in $(seq 1 "${CONSUMER_READY_WAIT_S:-180}"); do [ -f "$COORD/CONSUMER_READY" ] && break; sleep 1; done
if [ ! -f "$COORD/CONSUMER_READY" ]; then echo "workload rank=$RANKID: CONSUMER_READY never appeared" >> "$RES/workload.$RANKID.out"; touch "$COORD/WL_FAIL.$RANKID"; exit 3; fi
scratch="/tmp/dm_${WL_TYPE}_${RANKID}_$$"; mkdir -p "$scratch"
# NO_DARSHAN=1 (baseline arm): run the workload WITHOUT LD_PRELOAD'ing libdarshan, so it
# does raw I/O only (no instrumentation, no streaming). Gives a true no-Darshan wall time.
# Shell-level WORK window (rank 0) so EVERY workload -- even black-box ones like dlio that
# emit no WORK markers -- has a valid workload wall that EXCLUDES broker/consumer setup and
# post-run drain (arm-to-arm timestamps are not a valid workload comparison). If the workload
# also prints its own WORK_START/END (mpi, io_bench), those take precedence in extraction.
_wl_t0=$(date +%s.%N)
# Non-invasive per-core CPU sampler (one per workload NODE): mpstat -P ALL in the background,
# writing $RES/mpstat.$RANKID.txt for the whole workload window. Killed right after the run.
# Gate on the NODE-LOCAL rank (PALS_LOCAL_RANKID=0), not the global PALS_RANKID -- in the MPMD
# launch the workload rank's global id is offset past broker+consumer (e.g. 2), so a global
# "==0" test would never fire on the workload node.
_mpstat_pid=""
if [ "${DM_MPSTAT:-0}" = 1 ] && [ "${PALS_LOCAL_RANKID:-0}" = 0 ] && command -v mpstat >/dev/null 2>&1; then
  mpstat -P ALL "${DM_MPSTAT_INT:-5}" > "$RES/mpstat.$RANKID.txt" 2>/dev/null &
  _mpstat_pid=$!
fi
if [ "${PALS_LOCAL_RANKID:-0}" = 0 ]; then
  echo "WORK_SH_START_NS $(date +%s%N)" >> "$RES/workload.$RANKID.out"
fi

if [ "$WL_TYPE" = "hep-salt" ]; then

  # HEP wrapper injects LD_PRELOAD inside the Apptainer container.
  ${PERFWRAP:-} env $ESTR \
    DARSHAN_LOGPATH="$RES" \
    DARSHAN_LIB_SO="$DLIB" \
    NO_DARSHAN="${NO_DARSHAN:-0}" \
    "$CMD" \
    >> "$RES/workload.$RANKID.out" \
    2> "$RES/workload.$RANKID.err"

elif [ "${NO_DARSHAN:-0}" = 1 ]; then

  ${PERFWRAP:-} env $ESTR \
    DARSHAN_LOGPATH="$RES" \
    $CMD "$scratch" \
    >> "$RES/workload.$RANKID.out" \
    2> "$RES/workload.$RANKID.err"

else

  ${PERFWRAP:-} env $ESTR \
    DARSHAN_LOGPATH="$RES" \
    LD_PRELOAD="$DLIB" \
    $CMD "$scratch" \
    >> "$RES/workload.$RANKID.out" \
    2> "$RES/workload.$RANKID.err"

fi

rc=$?

if [ "${PALS_LOCAL_RANKID:-0}" = 0 ]; then
  echo "WORK_SH_END_NS $(date +%s%N)" >> "$RES/workload.$RANKID.out"
fi
[ -n "$_mpstat_pid" ] && kill "$_mpstat_pid" 2>/dev/null || true
rm -rf "$scratch" 2>/dev/null || true
touch "$COORD/WL_DONE.$RANKID"
[ "$rc" -ne 0 ] && touch "$COORD/WL_FAIL.$RANKID"
exit "$rc"
WORKLOAD
    } > "$SEC/s_workload.sh"

    chmod +x "$SEC"/s_broker.sh "$SEC"/s_consumer.sh "$SEC"/s_workload.sh

    # ---------------- launch: ONE MPMD mpiexec (shared job VNI) ----------------
    local WL_HOSTS; WL_HOSTS="$(IFS=,; printf '%s' "${WL_NODES_ARR[*]}")"
    mpi_launch_mpmd \
        "$SRV_NODE 1 $SEC/s_broker.sh" \
        "$SRV_NODE $CONS_N $SEC/s_consumer.sh" \
        "$WL_HOSTS $WL_TOTAL_RANKS $SEC/s_workload.sh"
    echo "mpmd launch: broker[$SRV_NODE x1] : consumer[$SRV_NODE x$CONS_N] : workload[$WL_HOSTS x$WL_TOTAL_RANKS]  (proto=$SRV_PROTOCOL)"
    "${MPI_MPMD[@]}" > "$RES/mpmd.log" 2>&1 &
    local MPMD_PID=$!

    # ---------------- drive shutdown + watch for terminal state ----------------
    # When all workload ranks have touched WL_DONE.*, signal SHUTDOWN so the lead consumer flushes,
    # exports events.jsonl, and touches ALL_DONE. Terminal states: ALL_DONE (ok) | *_FAIL (bad) |
    # mpiexec death (bad) | ceiling (bad). The mpiexec exit code is IGNORED by design (amendment #6).
    local shutdown_sent=0 verdict="" ndone
    local deadline=$(( $(date +%s) + ${MPMD_CEIL_S:-1500} ))
    while :; do
        if [ "$shutdown_sent" = 0 ]; then
            ndone=$(find "$COORD" -maxdepth 1 -name 'WL_DONE.*' 2>/dev/null | wc -l)
            if [ "$ndone" -ge "$WL_TOTAL_RANKS" ]; then
                touch "$COORD/SHUTDOWN"; shutdown_sent=1
                echo "all $WL_TOTAL_RANKS workload rank(s) done -> touched SHUTDOWN"
            fi
        fi
        [ -f "$COORD/ALL_DONE" ] && { verdict=all_done; break; }
        if find "$COORD" -maxdepth 1 -name '*_FAIL.*' 2>/dev/null | grep -q .; then verdict="fail_flag:$(find "$COORD" -maxdepth 1 -name '*_FAIL.*' -printf '%f ' 2>/dev/null)"; break; fi
        kill -0 "$MPMD_PID" 2>/dev/null || { verdict=mpiexec_exit; break; }
        [ "$(date +%s)" -ge "$deadline" ] && { verdict=ceiling; break; }
        sleep 3
    done

    # ---------------- teardown (kill the still-running broker; exit code meaningless) ----------------
    # NB: PALS_RANKID is GLOBAL across MPMD sections (broker=0, consumer=1.., workload=last), so the
    # workload rank is NOT rank 0 -- grab whatever workload.*.out exists. pkill matches 'bedrock '
    # (trailing space) NOT "bedrock $SRV_PROTOCOL": the '+' in ofi+cxi is a regex metachar and would
    # fail to match the real cmdline (same pattern job.sh's EXIT trap uses).
    kill "$MPMD_PID" 2>/dev/null || true
    pkill -f 'bedrock ' 2>/dev/null || true
    wait "$MPMD_PID" 2>/dev/null || true
    local _w0; _w0="$(ls "$RES"/workload.*.out 2>/dev/null | head -1)"
    [ -n "$_w0" ] && cp "$_w0" "$RES/workload.out" 2>/dev/null || true
    grep -h -E 'INGEST:|tasks total=' "$RES"/fc/c0/flowcept.out 2>/dev/null > "$RES/ingest.txt" || true

    # ---------------- verdict: ALL_DONE + non-empty events.jsonl (amendment #6) ----------------
    local nlines; nlines="$(wc -l < "$RES/events.jsonl" 2>/dev/null || echo 0)"
    echo "run_mpmd_rep verdict=$verdict  events.jsonl=${nlines} lines  mofka=$(grep -oE 'ofi\+cxi://[^"]+' "$COORD/mofka.json" 2>/dev/null | head -1)"
    # Runtime-only arm (DARSHAN_MOFKA_ENABLE=0) AND baseline arm (NO_DARSHAN=1) legitimately
    # stream 0 events, so an empty events.jsonl is expected -- success is ALL_DONE alone. The
    # streaming arm still requires non-empty events.jsonl (amendment #6).
    if [ "$verdict" = all_done ] && \
       { [ "${DARSHAN_MOFKA_ENABLE:-1}" = 0 ] || [ "${NO_DARSHAN:-0}" = 1 ] || [ -s "$RES/events.jsonl" ]; }; then
        return 0
    fi
    echo "run_mpmd_rep FAIL ($verdict) -- diagnostics:"
    echo "--- broker.log (tail) ---";           tail -15 "$RES/broker.log"          2>/dev/null
    echo "--- mpmd.log (tail) ---";             tail -15 "$RES/mpmd.log"            2>/dev/null
    echo "--- fc/c0/flowcept.out (tail) ---";   tail -25 "$RES/fc/c0/flowcept.out"  2>/dev/null
    echo "--- workload.0.err (tail) ---";       tail -20 "$RES/workload.0.err"      2>/dev/null
    return 1
}
