#!/bin/bash
#PBS -N darshan_mofka_demo
#PBS -A PROJECT
#PBS -q debug
#PBS -l select=1:ncpus=32
#PBS -l walltime=00:30:00
#PBS -l filesystems=home:eagle
#PBS -j oe
#
# End-to-end README demo on a compute node:
#   broker -> live FlowCept consumer -> Darshan-instrumented workload -> MongoDB -> JSONL
# Runs two workloads: the C smoke test and DLIO. Run it either way:
#   PBS_ACCOUNT=<your_project> bash jobs/job.sh   # self-submits to a compute node
#   qsub -A <your_project> jobs/job.sh            # submit directly
# The '#PBS -A PROJECT' line above is a placeholder; set your allocation via
# PBS_ACCOUNT (bash path) or 'qsub -A' (direct path).
set -uo pipefail

# --- keep all real work on compute nodes: self-submit when run on a login node ---
# mongod is FlowCept's sink and an external dep. Resolve it here (where the user's
# PATH/conda is active) and forward it into the batch job, which starts from a clean
# environment. Set MONGOD=/path/to/mongod, or put mongod on PATH, before running.
if [[ -z "${PBS_JOBID:-}" ]]; then
    cd "$(dirname "${BASH_SOURCE[0]}")/.."
    ACCOUNT="${PBS_ACCOUNT:-${PBS_A:-}}"
    [[ -n "$ACCOUNT" ]] || { echo "set your allocation: PBS_ACCOUNT=<project> bash jobs/job.sh"; exit 1; }
    MONGOD="${MONGOD:-$(command -v mongod || true)}"
    [[ -x "$MONGOD" ]] || { echo "mongod not found; set MONGOD=/path/to/mongod or put it on PATH"; exit 1; }
    # forward MONGOD (always) and MOFKA_SPACK_VIEW (if the user overrode it) into the job
    FWD="MONGOD=$MONGOD"
    [[ -n "${MOFKA_SPACK_VIEW:-}" ]] && FWD="$FWD,MOFKA_SPACK_VIEW=$MOFKA_SPACK_VIEW"
    exec qsub -A "$ACCOUNT" -v "$FWD" jobs/job.sh
fi

ROOT="${PBS_O_WORKDIR:-$(pwd)}"; cd "$ROOT"
source server/env.sh --polaris

# Per-job broker + FlowCept run dir so concurrent jobs never collide.
export MOFKA_SERVER_DIR="$ROOT/server/_pbs_${PBS_JOBID%%.*}/mofka"
RUN_DIR="$ROOT/server/_pbs_${PBS_JOBID%%.*}/flowcept"
GROUP="$MOFKA_SERVER_DIR/mofka.json"
mkdir -p "$MOFKA_SERVER_DIR" "$RUN_DIR"

# mongod is an external dep: honor $MONGOD, else find it on PATH.
MONGOD="${MONGOD:-$(command -v mongod || true)}"
[[ -x "$MONGOD" ]] || { echo "mongod not found; load MongoDB or set MONGOD=/path/to/mongod"; exit 1; }

# --- 1. broker + darshan topic ---------------------------------------------
bash server/stop-server.sh >/dev/null 2>&1 || true
bash server/start-server.sh
trap 'bash server/stop-server.sh >/dev/null 2>&1 || true' EXIT

# --- 2. live FlowCept consumer (drains the topic into MongoDB during the run) ---
RUN_DIR="$RUN_DIR" MONGO_DB=darshan_stream MONGO_PORT=27017 MONGOD="$MONGOD" \
MOFKA_GROUP="$GROUP" bash server/capture_flowcept.sh > "$RUN_DIR/flowcept.out" 2>&1 &
FC=$!
until grep -q 'consumer alive' "$RUN_DIR/flowcept.out"; do
    kill -0 "$FC" 2>/dev/null || { echo "consumer failed to start"; cat "$RUN_DIR/flowcept.out"; exit 1; }
    sleep 1
done

# run "$@" under the Darshan->Mofka connector. The live consumer drains the topic
# during the run, so delivery does not depend on the finalize-time flush.
darshan_ensure_logdir >/dev/null
run_instrumented() {
    env DARSHAN_ENABLE_NONMPI=1 DARSHAN_MOFKA_ENABLE=1 \
        DARSHAN_MOFKA_GROUP_FILE="$GROUP" DARSHAN_MOFKA_TOPIC=darshan \
        DARSHAN_MOFKA_BATCH=0 DARSHAN_MOFKA_MAX_BATCHES=64 DARSHAN_MOFKA_TIMING=1 \
        DARSHAN_LOGPATH="$DARSHAN_LOGPATH" LD_PRELOAD="$(darshan_lib)" "$@"
}

# --- 3. workload A: C smoke test -------------------------------------------
"$CC" -O2 workloads/mofka_forward_smoke.c -o workloads/mofka_forward_smoke
run_instrumented ./workloads/mofka_forward_smoke "$RUN_DIR/c_smoke" \
    > "$RUN_DIR/c.out" 2> "$RUN_DIR/c.err"
echo "C workload sends: $(grep -c 'darshan-mofka\[timing\] send' "$RUN_DIR/c.err")"

# --- 4. workload B: DLIO (runs under system python3.12, so scrub the py3.14 vars) ---
run_instrumented env -u PYTHONPATH -u PYTHONSAFEPATH -u PYTHONHOME \
    dlio_benchmark ++workload.workflow.generate_data=True ++workload.workflow.train=True \
    ++workload.dataset.data_folder="$RUN_DIR/dlio_data" ++workload.dataset.num_files_train=8 \
    ++workload.dataset.num_samples_per_file=1 ++workload.dataset.record_length_bytes=1024 \
    ++workload.dataset.num_subfolders_train=0 ++workload.dataset.num_subfolders_eval=0 \
    ++workload.reader.batch_size=2 ++workload.reader.read_threads=1 \
    ++workload.train.epochs=1 ++workload.train.computation_time=0.01 \
    hydra.run.dir="$RUN_DIR/dlio" > "$RUN_DIR/dlio.out" 2> "$RUN_DIR/dlio.err"
echo "DLIO workload sends: $(grep -c 'darshan-mofka\[timing\] send' "$RUN_DIR/dlio.err")"

# --- 5. stop the consumer (flushes buffer), then export MongoDB -> JSONL -----
touch "$RUN_DIR/SHUTDOWN"
until grep -q 'Export now' "$RUN_DIR/flowcept.out"; do
    kill -0 "$FC" 2>/dev/null || { echo "consumer died before export"; tail -40 "$RUN_DIR/flowcept.out"; exit 1; }
    sleep 1
done
EVENTS="$RUN_DIR/events.jsonl"
"$PY" server/export_jsonl.py 127.0.0.1 darshan_stream > "$EVENTS" 2> "$RUN_DIR/export.count"
kill "$FC" 2>/dev/null || true; wait "$FC" 2>/dev/null || true

# --- 6. verify events were saved -------------------------------------------
echo "=== ingest verdict ==="; grep -E 'INGEST:|tasks total=' "$RUN_DIR/flowcept.out"
echo "=== $(cat "$RUN_DIR/export.count") ==="
echo "exported JSONL lines: $(wc -l < "$EVENTS")"
"$PY" - "$EVENTS" <<'PY'
import json, sys
from collections import Counter
mods, ops = Counter(), Counter()
for line in open(sys.argv[1]):
    ev = json.loads(line); mods[ev.get('module')] += 1; ops[ev.get('op')] += 1
print("modules:", dict(mods)); print("ops:", dict(ops))
PY
