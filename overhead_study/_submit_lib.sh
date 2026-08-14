#!/bin/bash

set -uo pipefail

# ------- knobs the caller must set (with sensible fallbacks) -------
WLNODES="${WLNODES:?set WLNODES (workload node count)}"
SRVNODES="${SRVNODES:-1}"                 # broker/consumer head node(s); always 1 here
WORKLOAD="${WORKLOAD:?set WORKLOAD}"      # io_bench|io_bench_py|python-ml|mpi|dlio|hep-salt
PROTO="${PROTO:?set PROTO}"              # ofi+cxi (mpmd) | ofi+tcp (legacy)
TASKS="${TASKS:?set TASKS}"              # ranks per workload node (cxi=1, tcp=32)
REPS="${REPS:-2}"
EVENTS="${EVENTS:-100}"                   # scale knob: C epochs / mpi STEPS / dlio num_files / (py: see ML_EPOCHS)
PARTITIONS="${PARTITIONS:-4}"
CONSUMERS="${CONSUMERS:-1}"
STUDY="${STUDY:?set STUDY (results/<STUDY>/<arm>)}"
ARMS="${ARMS:-baseline runtimeonly streaming}"
# io_bench compute knobs (ignored by non-io_bench workloads via run.sh:184 filter):
COMPUTE="${COMPUTE:-0}"; MATRIX_SIZE="${MATRIX_SIZE:-256}"
IO_SIZE_MB="${IO_SIZE_MB:-16}"; IO_ITERS="${IO_ITERS:-16}"; IO_SLEEP_MS="${IO_SLEEP_MS:-50}"; IO_BLOCK_KB="${IO_BLOCK_KB:-1024}"
# python-ml knobs (only used when WORKLOAD=python-ml):
ML_CHECKPOINTS="${ML_CHECKPOINTS:-1}"
# python-ml dataset-size knobs (forwarded only when set; run.sh reads them ONLY in the
# python-ml case, so they are inert for other workloads). Needed to scale python-ml to a
# ~300s+ real-work run for the overhead study (proven point: ML_FILES=64 ROWS=4096 COLS=64
# + EVENTS=1000 -> ~538s, results/NOSTREAM_pythonml).
ML_FILES="${ML_FILES:-}"; ML_ROWS="${ML_ROWS:-}"; ML_COLS="${ML_COLS:-}"
# connector knobs:
BATCH="${BATCH:-0}"
MAX_BATCHES="${MAX_BATCHES:-512}"
FLUSH_MS="${FLUSH_MS:-30000}"
TIMING="${TIMING:-1}"
RPC_THREAD_COUNT="${RPC_THREAD_COUNT:-4}"

# Allow workload launchers to reuse an existing custom Darshan build.
SKIP_BUILD="${SKIP_BUILD:-0}"

NCPUS="${NCPUS:-32}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[1]:-$0}")/.." && pwd)"
account="${PBS_ACCOUNT:-radix-io}"
[ -n "$account" ] || { echo "set PBS_ACCOUNT=<project>"; exit 1; }

# total nodes -> queue (unless caller overrode QUEUE)
NODES=$(( WLNODES + SRVNODES ))
if [ -z "${QUEUE:-}" ]; then
    if [ "$NODES" -le 2 ]; then QUEUE=debug; else QUEUE=debug-scaling; fi
fi
WALLTIME="${WALLTIME:-01:00:00}"

# Polaris needs -l filesystems (home + eagle are distinct Lustre mounts).
source "$ROOT/env/_profile.sh" >/dev/null 2>&1 || true
PBS_EXTRA=()

# Polaris requires an explicit filesystems resource.
if [[ "${ENV_PROFILE:-}" == polaris || "$(hostname)" == *polaris* || "$ROOT" == /eagle/* ]]; then
    PBS_EXTRA+=(-l "filesystems=${PBS_FILESYSTEMS:-home:eagle}")
fi

submit_arm() {
    local arm="$1" enable no_darshan tag adir
    case "$arm" in
        baseline)    enable=1; no_darshan=1 ;;   # ENABLE unused when NO_DARSHAN=1
        runtimeonly) enable=0; no_darshan=0 ;;
        streaming)   enable=1; no_darshan=0 ;;
        *) echo "unknown arm: $arm"; return 1 ;;
    esac
    tag="$STUDY/$arm"
    adir="$ROOT/results/$tag"; mkdir -p "$adir"

    # env-var-wins over config files: forward every knob job.sh/run.sh reads.
    local FWD="MOFKA_PROTOCOL=$PROTO,WORKLOAD=$WORKLOAD,NODES=$NODES,TASKS=$TASKS,REPS=$REPS"
    FWD="$FWD,EVENTS=$EVENTS,PARTITIONS=$PARTITIONS,CONSUMERS=$CONSUMERS,PLACEMENT=separate"
    FWD="$FWD,IO_SIZE_MB=$IO_SIZE_MB,IO_ITERS=$IO_ITERS,IO_SLEEP_MS=$IO_SLEEP_MS,IO_BLOCK_KB=$IO_BLOCK_KB"
    FWD="$FWD,COMPUTE=$COMPUTE,MATRIX_SIZE=$MATRIX_SIZE,ML_CHECKPOINTS=$ML_CHECKPOINTS"
    [ -n "$ML_FILES" ] && FWD="$FWD,ML_FILES=$ML_FILES"
    [ -n "$ML_ROWS" ]  && FWD="$FWD,ML_ROWS=$ML_ROWS"
    [ -n "$ML_COLS" ]  && FWD="$FWD,ML_COLS=$ML_COLS"
    FWD="$FWD,DARSHAN_MOFKA_BATCH=$BATCH,DARSHAN_MOFKA_MAX_BATCHES=$MAX_BATCHES,DARSHAN_MOFKA_FLUSH_MS=$FLUSH_MS"
    FWD="$FWD,DARSHAN_MOFKA_ENABLE=$enable,DARSHAN_MOFKA_TIMING=$TIMING"
    FWD="$FWD,DARSHAN_MOFKA_DROP_POLICY=block,RPC_THREAD_COUNT=$RPC_THREAD_COUNT"
    FWD="$FWD,SKIP_BUILD=$SKIP_BUILD,RESULTS_TAG=$tag"
    [ "$no_darshan" = 1 ] && FWD="$FWD,NO_DARSHAN=1"

    # human-readable config.txt in the arm dir (present even before the run lands).
    {
        echo "study=$STUDY arm=$arm  $(date -u +%FT%TZ)"
        echo "workload=$WORKLOAD proto=$PROTO wlnodes=$WLNODES srvnodes=$SRVNODES total_nodes=$NODES tasks_per_node=$TASKS reps=$REPS"
        echo "scale: events=$EVENTS compute=$COMPUTE matrix_size=$MATRIX_SIZE"
        echo "server: partitions=$PARTITIONS consumers=$CONSUMERS rpc_threads=$RPC_THREAD_COUNT queue=$QUEUE walltime=$WALLTIME"
        echo "arm_knobs: DARSHAN_MOFKA_ENABLE=$enable NO_DARSHAN=$no_darshan batch=$BATCH max_batches=$MAX_BATCHES flush_ms=$FLUSH_MS timing=$TIMING"
    } > "$adir/config.txt"

    echo "submit[$arm]: q=$QUEUE select=${NODES}:ncpus=${NCPUS}:mpiprocs=${NCPUS} wall=$WALLTIME $PROTO | $WORKLOAD ${TASKS}rk/node wl=$WLNODES reps=$REPS part=$PARTITIONS cons=$CONSUMERS -> results/$tag"
    if [ "${DRYRUN:-0}" = 1 ]; then
        echo "  DRYRUN qsub -A $account -q $QUEUE -l select=${NODES}:ncpus=${NCPUS}:mpiprocs=${NCPUS} -l walltime=$WALLTIME ${PBS_EXTRA[*]} -N dm_${WORKLOAD}_${WLNODES}wl_${arm} -j oe -o $adir/ -v \"$FWD\""
        return 0
    fi

    if ! printf 'cd "%s"\nbash workloads/job.sh\n' "$ROOT" | \
        qsub -A "$account" -q "$QUEUE" \
             -l select="${NODES}:ncpus=${NCPUS}:mpiprocs=${NCPUS}" \
             -l walltime="$WALLTIME" \
             "${PBS_EXTRA[@]}" \
             -N "dm_${WORKLOAD}_${WLNODES}wl_${arm}" \
             -j oe \
             -o "$adir/" \
             -v "$FWD"
    then
        echo "ERROR: qsub failed for arm=$arm" >&2
        return 1
    fi
}

echo "=== overhead config: $STUDY  ($WORKLOAD, $PROTO, wlnodes=$WLNODES total=$NODES tasks/node=$TASKS, arms: $ARMS, queue: $QUEUE) ==="

FINAL_RC=0
for a in $ARMS; do
    submit_arm "$a" || FINAL_RC=1
done

if [ "$FINAL_RC" -eq 0 ]; then
    echo "=== $STUDY submitted. watch: qstat -u $USER ; results in results/$STUDY/<arm>/ ==="
else
    echo "=== ERROR: one or more submissions failed ===" >&2
fi

exit "$FINAL_RC"