#!/bin/bash
# overhead_study.sh -- ONE-file overhead study driver.
#
# For a given config it submits up to 3 arms, each as its own PBS job that runs
# REPS reps via workloads/job.sh, routed into results/<STUDY>/<arm>/ :
#   baseline      NO_DARSHAN=1              (raw workload, no libdarshan, no stream)
#   runtimeonly   ENABLE=0                  (Darshan instruments, no streaming)
#   streaming     ENABLE=1                  (Darshan + Mofka async, full pipeline)
# Overhead tomorrow = streaming wall vs runtimeonly wall (and vs baseline).
#
# Each arm dir gets a config.txt recording every knob. The wall time per rep is in
# each RUN<n>/workload.*.out (the C/io_bench workloads print their own timing).
#
# Usage (edit KNOBS below, or override on the command line):
#   PBS_ACCOUNT=radix-io bash overhead_study.sh
#   WORKLOAD=c NODES=2 TASKS=1 EVENTS=500000 ARMS="streaming" bash overhead_study.sh   # one arm test
#
# ARMS selects which arms to submit (space-separated): baseline runtimeonly streaming
set -euo pipefail

# ===================== KNOBS (edit these) =====================
STUDY="${STUDY:-OVERHEAD_C}"     # results/<STUDY>/<arm> ; make unique per study
WORKLOAD="${WORKLOAD:-c}"        # c | io_bench | python-ml
NODES="${NODES:-2}"              # total nodes: 1 broker/consumer + (NODES-1) workload nodes
TASKS="${TASKS:-1}"              # workload procs per workload node
REPS="${REPS:-3}"               # reps per arm
EVENTS="${EVENTS:-500000}"       # workload scale (C epochs; io_bench: see io_bench knobs)
PARTITIONS="${PARTITIONS:-4}"
CONSUMERS="${CONSUMERS:-1}"
PROTOCOL="${PROTOCOL:-ofi+cxi}"  # ofi+cxi -> mpmd path (non-MPI); ofi+tcp -> legacy path (mpi/dlio)
QUEUE="${QUEUE:-preemptable}"    # debug (<=2 nodes,1h) | debug-scaling | preemptable (10 nodes,72h)
WALLTIME="${WALLTIME:-02:00:00}"
NCPUS="${NCPUS:-32}"
RPC_THREADS="${RPC_THREADS:-4}"  # broker margo rpc_thread_count
# io_bench-only knobs (ignored for c/python-ml):
IO_SIZE_MB="${IO_SIZE_MB:-16}"; IO_ITERS="${IO_ITERS:-16}"; IO_SLEEP_MS="${IO_SLEEP_MS:-50}"; IO_BLOCK_KB="${IO_BLOCK_KB:-1024}"
COMPUTE="${COMPUTE:-0}"; MATRIX_SIZE="${MATRIX_SIZE:-256}"
# connector knobs:
BATCH="${BATCH:-0}"   # DARSHAN_MOFKA_BATCH: 0=Adaptive (send-per-event); N=block until N records batched
MAX_BATCHES="${MAX_BATCHES:-512}"; FLUSH_MS="${FLUSH_MS:-30000}"; TIMING="${TIMING:-1}"
SKIP_BUILD="${SKIP_BUILD:-1}"
ARMS="${ARMS:-baseline runtimeonly streaming}"
# ==============================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
account="${PBS_ACCOUNT:-radix-io}"
[ -n "$account" ] || { echo "set PBS_ACCOUNT=<project>"; exit 1; }

source "$ROOT/env/_profile.sh" >/dev/null 2>&1 || true
PBS_EXTRA=()
[[ "${ENV_PROFILE:-}" == polaris ]] && PBS_EXTRA+=(-l "filesystems=${PBS_FILESYSTEMS:-home:eagle}")

submit_arm() {
    local arm="$1" enable no_darshan tag
    case "$arm" in
        baseline)    enable=1; no_darshan=1 ;;   # ENABLE unused when NO_DARSHAN=1
        runtimeonly) enable=0; no_darshan=0 ;;
        streaming)   enable=1; no_darshan=0 ;;
        *) echo "unknown arm: $arm"; return 1 ;;
    esac
    tag="$STUDY/$arm"

    # Common config overrides forwarded to job.sh (env-wins over config files).
    local FWD="MOFKA_PROTOCOL=$PROTOCOL,WORKLOAD=$WORKLOAD,NODES=$NODES,TASKS=$TASKS,REPS=$REPS"
    FWD="$FWD,EVENTS=$EVENTS,PARTITIONS=$PARTITIONS,CONSUMERS=$CONSUMERS,PLACEMENT=separate"
    FWD="$FWD,IO_SIZE_MB=$IO_SIZE_MB,IO_ITERS=$IO_ITERS,IO_SLEEP_MS=$IO_SLEEP_MS,IO_BLOCK_KB=$IO_BLOCK_KB"
    FWD="$FWD,COMPUTE=$COMPUTE,MATRIX_SIZE=$MATRIX_SIZE"
    FWD="$FWD,DARSHAN_MOFKA_BATCH=$BATCH,DARSHAN_MOFKA_MAX_BATCHES=$MAX_BATCHES,DARSHAN_MOFKA_FLUSH_MS=$FLUSH_MS,DARSHAN_MOFKA_ENABLE=$enable"
    FWD="$FWD,DARSHAN_MOFKA_TIMING=$TIMING,RPC_THREADS=$RPC_THREADS,RESULTS_TAG=$tag"
    [ "$no_darshan" = 1 ] && FWD="$FWD,NO_DARSHAN=1"
    [ -n "$SKIP_BUILD" ] && FWD="$FWD,SKIP_BUILD=$SKIP_BUILD"
    [ -n "${DARSHAN_MOFKA_ASYNC:-}" ] && FWD="$FWD,DARSHAN_MOFKA_ASYNC=$DARSHAN_MOFKA_ASYNC"
    [ -n "${DARSHAN_MOFKA_DROP_POLICY:-}" ] && FWD="$FWD,DARSHAN_MOFKA_DROP_POLICY=$DARSHAN_MOFKA_DROP_POLICY"
    [ -n "${DARSHAN_MOFKA_QUEUE_DEPTH:-}" ] && FWD="$FWD,DARSHAN_MOFKA_QUEUE_DEPTH=$DARSHAN_MOFKA_QUEUE_DEPTH"
    [ -n "${DIASPORA_C_SENDER_THREADS:-}" ] && FWD="$FWD,DIASPORA_C_SENDER_THREADS=$DIASPORA_C_SENDER_THREADS"

    # Drop a human-readable config.txt into the arm dir (created now so it's there even before run).
    local adir="$ROOT/results/$tag"; mkdir -p "$adir"
    {
        echo "study=$STUDY arm=$arm  $(date -u +%FT%TZ)"
        echo "workload=$WORKLOAD nodes=$NODES tasks=$TASKS reps=$REPS events=$EVENTS"
        echo "protocol=$PROTOCOL partitions=$PARTITIONS consumers=$CONSUMERS rpc_threads=$RPC_THREADS queue=$QUEUE walltime=$WALLTIME"
        echo "arm_knobs: DARSHAN_MOFKA_ENABLE=$enable NO_DARSHAN=$no_darshan async=${DARSHAN_MOFKA_ASYNC:-1}"
        [ "$WORKLOAD" = io_bench ] && echo "io_bench: size_mb=$IO_SIZE_MB iters=$IO_ITERS sleep_ms=$IO_SLEEP_MS block_kb=$IO_BLOCK_KB compute=$COMPUTE matrix_size=$MATRIX_SIZE"
    } > "$adir/config.txt"

    # DARSHAN_MOFKA_MARGO_JSON carries argobots JSON with commas, which would corrupt the
    # comma-delimited qsub -v list. Export it inside the here-doc instead (only when set);
    # run.sh forwards it into CONNECTOR_ENV -> reaches the workload rank on both paths.
    local margo_line=""
    [ -n "${DARSHAN_MOFKA_MARGO_JSON:-}" ] && \
        margo_line="export DARSHAN_MOFKA_MARGO_JSON='${DARSHAN_MOFKA_MARGO_JSON}'"

    echo "submit[$arm]: q=$QUEUE nodes=$NODES tasks=$TASKS reps=$REPS events=$EVENTS part=$PARTITIONS cons=$CONSUMERS -> results/$tag"
    qsub -A "$account" -q "$QUEUE" \
         -l select="${NODES}:ncpus=${NCPUS}:mpiprocs=${NCPUS}" -l walltime="$WALLTIME" \
         "${PBS_EXTRA[@]}" -N "dm_${arm}" -j oe -o "$adir/" -v "$FWD" <<PBS
cd "$ROOT"
$margo_line
bash workloads/job.sh
PBS
}

echo "=== overhead study: $STUDY ($WORKLOAD, nodes=$NODES tasks=$TASKS, arms: $ARMS) ==="
for a in $ARMS; do submit_arm "$a"; done
echo "=== submitted. watch: qstat -u $USER ; results in results/$STUDY/<arm>/ ==="
