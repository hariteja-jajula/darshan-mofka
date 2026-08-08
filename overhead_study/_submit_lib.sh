#!/bin/bash
# _submit_lib.sh -- shared submit logic for the per-config overhead-study jobs.
#
# Each overhead_study/<...>.sh sets a handful of knobs then `source`s this file.
# For that ONE (workload, scale) config it submits up to 3 arms, each as its own
# PBS job that runs REPS reps via workloads/job.sh, routed into
# results/<STUDY>/<arm>/ :
#   baseline      NO_DARSHAN=1              (raw workload, no libdarshan, no stream)
#   runtimeonly   DARSHAN_MOFKA_ENABLE=0   (Darshan instruments, no streaming)
#   streaming     DARSHAN_MOFKA_ENABLE=1   (Darshan + Mofka async, full pipeline)
#
# The streaming arm emits per-call timing to workload.*.err (DARSHAN_MOFKA_TIMING=1);
# read it with deliverables/overhead_extract.sh -> init_us, finalize_us, per-push.
#
# Queue is auto-selected by TOTAL node count (WLNODES + SRVNODES):
#   <=2 total -> debug ;  3..10 total -> debug-scaling   (both walltime 01:00:00)
# Override with QUEUE=... / WALLTIME=... in the calling file if needed.
#
# Submit with:  bash overhead_study/<file>.sh     (NOT `qsub <file>` -- these call
# qsub internally with -A). Set DRYRUN=1 to print the qsub commands without submitting.
set -uo pipefail

# ------- knobs the caller must set (with sensible fallbacks) -------
WLNODES="${WLNODES:?set WLNODES (workload node count)}"
SRVNODES="${SRVNODES:-1}"                 # broker/consumer head node(s); always 1 here
WORKLOAD="${WORKLOAD:?set WORKLOAD}"      # io_bench|io_bench_py|python-ml|mpi|dlio
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
MAX_BATCHES="${MAX_BATCHES:-512}"; FLUSH_MS="${FLUSH_MS:-30000}"; TIMING="${TIMING:-1}"
RPC_THREAD_COUNT="${RPC_THREAD_COUNT:-4}"
SKIP_BUILD="${SKIP_BUILD:-1}"
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
[[ "${ENV_PROFILE:-}" == polaris ]] && PBS_EXTRA+=(-l "filesystems=${PBS_FILESYSTEMS:-home:eagle}")

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
    FWD="$FWD,DARSHAN_MOFKA_MAX_BATCHES=$MAX_BATCHES,DARSHAN_MOFKA_FLUSH_MS=$FLUSH_MS"
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
        echo "arm_knobs: DARSHAN_MOFKA_ENABLE=$enable NO_DARSHAN=$no_darshan timing=$TIMING"
    } > "$adir/config.txt"

    echo "submit[$arm]: q=$QUEUE select=${NODES}:ncpus=${NCPUS}:mpiprocs=${NCPUS} wall=$WALLTIME $PROTO | $WORKLOAD ${TASKS}rk/node wl=$WLNODES reps=$REPS part=$PARTITIONS cons=$CONSUMERS -> results/$tag"
    if [ "${DRYRUN:-0}" = 1 ]; then
        echo "  DRYRUN qsub -A $account -q $QUEUE -l select=${NODES}:ncpus=${NCPUS}:mpiprocs=${NCPUS} -l walltime=$WALLTIME ${PBS_EXTRA[*]} -N dm_${WORKLOAD}_${WLNODES}wl_${arm} -j oe -o $adir/ -v \"$FWD\""
        return 0
    fi
    qsub -A "$account" -q "$QUEUE" \
         -l select="${NODES}:ncpus=${NCPUS}:mpiprocs=${NCPUS}" -l walltime="$WALLTIME" \
         "${PBS_EXTRA[@]}" -N "dm_${WORKLOAD}_${WLNODES}wl_${arm}" -j oe -o "$adir/" -v "$FWD" <<PBS
cd "$ROOT"
bash workloads/job.sh
PBS
}

echo "=== overhead config: $STUDY  ($WORKLOAD, $PROTO, wlnodes=$WLNODES total=$NODES tasks/node=$TASKS, arms: $ARMS, queue: $QUEUE) ==="
for a in $ARMS; do submit_arm "$a"; done
echo "=== $STUDY submitted. watch: qstat -u $USER ; results in results/$STUDY/<arm>/ ==="
