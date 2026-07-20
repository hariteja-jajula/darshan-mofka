#!/bin/bash
set -euo pipefail

mode="${1:-c}"
rank="${PMI_RANK:-${PALS_RANKID:-0}}"
ROOT="${ROOT:?set ROOT to the darshan-mofka checkout}"
RUN_DIR="${RUN_DIR:?set RUN_DIR}"
MOFKA_SERVER_DIR="${MOFKA_SERVER_DIR:-$RUN_DIR/mofka}"
MOFKA_GROUP="$MOFKA_SERVER_DIR/mofka.json"
MONGO_DB="${MONGO_DB:-darshan_demo_${PBS_JOBID:-manual}}"
MONGO_PORT="${MONGO_PORT:-27017}"
EVENTS_JSONL="${EVENTS_JSONL:-$RUN_DIR/events.jsonl}"
FLOWCEPT_OUT="$RUN_DIR/flowcept_capture.out"
FLOWCEPT_PID_FILE="$RUN_DIR/flowcept.pid"
READY="$RUN_DIR/READY"
DONE="$RUN_DIR/DONE"
FAILED="$RUN_DIR/FAILED"

mkdir -p "$RUN_DIR" "$MOFKA_SERVER_DIR"
cd "$ROOT"
source server/env.sh --polaris
export MOFKA_SERVER_DIR

wait_for() {
    local path="$1" label="$2" max="${3:-120}"
    for _ in $(seq 1 "$max"); do
        [[ -e "$path" ]] && return 0
        [[ -e "$FAILED" ]] && { echo "$label failed before ready"; exit 1; }
        sleep 1
    done
    echo "timeout waiting for $label: $path"
    exit 1
}

run_under_darshan() {
    local out="$1" err="$2"; shift 2
    darshan_ensure_logdir >/dev/null
    env -u PYTHONSAFEPATH PYTHONHOME=/usr \
        DARSHAN_ENABLE_NONMPI=1 \
        DARSHAN_MOFKA_ENABLE=1 \
        DARSHAN_MOFKA_GROUP_FILE="$MOFKA_GROUP" \
        DARSHAN_MOFKA_TOPIC=darshan \
        DARSHAN_MOFKA_TIMING=1 \
        DARSHAN_MOFKA_BATCH=0 \
        DARSHAN_MOFKA_MAX_BATCHES="${DARSHAN_MOFKA_MAX_BATCHES:-64}" \
        DARSHAN_MOFKA_FLUSH_MS="${DARSHAN_MOFKA_FLUSH_MS:-5000}" \
        DARSHAN_LOGPATH="$DARSHAN_LOGPATH" \
        LD_PRELOAD="$(darshan_lib)" \
        "$@" > "$out" 2> "$err"
}

if [[ "$rank" == 0 ]]; then
    trap 'touch "$FAILED"; bash server/stop-server.sh || true' ERR EXIT
    rm -f "$READY" "$DONE" "$FAILED" "$FLOWCEPT_PID_FILE"
    bash server/stop-server.sh || true
    bash server/start-server.sh > "$RUN_DIR/start-server.out" 2>&1
    RUN_DIR="$RUN_DIR" MONGO_DB="$MONGO_DB" MONGO_PORT="$MONGO_PORT" \
        MOFKA_GROUP="$MOFKA_GROUP" bash server/capture_flowcept.sh \
        > "$FLOWCEPT_OUT" 2>&1 &
    echo $! > "$FLOWCEPT_PID_FILE"
    until grep -q 'consumer alive' "$FLOWCEPT_OUT"; do
        kill -0 "$(cat "$FLOWCEPT_PID_FILE")" 2>/dev/null || { cat "$FLOWCEPT_OUT"; exit 1; }
        sleep 1
    done
    touch "$READY"
    wait_for "$DONE" workload-done 900
    touch "$RUN_DIR/SHUTDOWN"
    until grep -q 'Export now' "$FLOWCEPT_OUT"; do
        kill -0 "$(cat "$FLOWCEPT_PID_FILE")" 2>/dev/null || { cat "$FLOWCEPT_OUT"; exit 1; }
        sleep 1
    done
    "$PY" server/export_jsonl.py 127.0.0.1 "$MONGO_DB" --mongo-port "$MONGO_PORT" \
        > "$EVENTS_JSONL" 2> "$RUN_DIR/export.count"
    kill "$(cat "$FLOWCEPT_PID_FILE")" 2>/dev/null || true
    wait "$(cat "$FLOWCEPT_PID_FILE")" 2>/dev/null || true
    bash server/stop-server.sh || true
    trap - ERR EXIT
else
    trap 'touch "$FAILED"' ERR
    wait_for "$READY" service-ready 180
    case "$mode" in
        c)
            "$CC" -O2 workloads/mofka_forward_smoke.c -o "$RUN_DIR/mofka_forward_smoke"
            run_under_darshan "$RUN_DIR/c.out" "$RUN_DIR/c.err" \
                "$RUN_DIR/mofka_forward_smoke" "/tmp/mofka-forward-smoke-${PBS_JOBID:-manual}"
            ;;
        dlio)
            DLIO_ROOT="${DLIO_ROOT:-$ROOT/../dlio_benchmark/dlio_benchmark}"
            cd "$DLIO_ROOT"
            data_dir="$RUN_DIR/dlio_data"
            common=(workload=default
                ++workload.dataset.data_folder="$data_dir"
                ++workload.dataset.num_files_train="${DLIO_NUM_FILES_TRAIN:-2}"
                ++workload.dataset.num_files_eval="${DLIO_NUM_FILES_EVAL:-1}"
                ++workload.dataset.record_length_bytes="${DLIO_RECORD_LENGTH_BYTES:-1024}"
                ++workload.dataset.num_subfolders_train=0
                ++workload.dataset.num_subfolders_eval=0
                ++workload.reader.batch_size="${DLIO_BATCH_SIZE:-1}"
                ++workload.reader.batch_size_eval=1
                ++workload.reader.read_threads=1
                ++workload.train.epochs="${DLIO_EPOCHS:-1}"
                ++workload.train.computation_time=0.01
                ++workload.evaluation.eval_time=0.01)
            dlio_benchmark "${common[@]}" ++workload.workflow.generate_data=True \
                ++workload.workflow.train=False hydra.run.dir="$RUN_DIR/dlio_generate" \
                > "$RUN_DIR/dlio_generate.out" 2> "$RUN_DIR/dlio_generate.err"
            run_under_darshan "$RUN_DIR/dlio_train.out" "$RUN_DIR/dlio_train.err" \
                dlio_benchmark "${common[@]}" ++workload.workflow.generate_data=False \
                ++workload.workflow.train=True ++workload.workflow.evaluation="${DLIO_EVALUATION:-False}" \
                hydra.run.dir="$RUN_DIR/dlio_train"
            ;;
        *)
            echo "unknown mode: $mode" >&2
            exit 2
            ;;
    esac
    touch "$DONE"
fi
