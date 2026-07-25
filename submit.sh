#!/bin/bash
# submit.sh -- send workloads/job.sh to a PBS allocation sized from the config.
#
# The broker needs a compute node (its fabric does not come up on login nodes). Edit
# workloads/workload.config (workload + topology + pbs) and server/server.config, then:
#   PBS_ACCOUNT=<project> bash submit.sh          # uses topology.nodes, pbs.walltime/queue/ncpus
#   SKIP_BUILD=1 PBS_ACCOUNT=radix-io bash submit.sh   # reuse an existing build
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib/config.sh"
WC="$ROOT/workloads/workload.config"

nodes="${NODES:-$(cfg_get "$WC" topology.nodes 1)}"
ncpus="${NCPUS:-$(cfg_get "$WC" pbs.ncpus 32)}"
walltime="${WALLTIME:-$(cfg_get "$WC" pbs.walltime 00:30:00)}"
queue="${QUEUE:-$(cfg_get "$WC" pbs.queue debug)}"   # QUEUE=compute for >1h / big rungs (72h cap)
account="${PBS_ACCOUNT:-$(cfg_get "$WC" pbs.account "")}"
[ -n "$account" ] || { echo "set an allocation: PBS_ACCOUNT=<project> bash submit.sh (or pbs.account in workload.config)"; exit 1; }

# forward only operational overrides; workload + knobs come from the config files
FWD=""
[ -n "${SKIP_BUILD:-}" ]            && FWD="${FWD:+$FWD,}SKIP_BUILD=$SKIP_BUILD"
[ -n "${MONGOD:-}" ]                && FWD="${FWD:+$FWD,}MONGOD=$MONGOD"
[ -n "${DARSHAN_MOFKA_PROFILE:-}" ] && FWD="${FWD:+$FWD,}DARSHAN_MOFKA_PROFILE=$DARSHAN_MOFKA_PROFILE"
# config-override knobs, so a run can be retargeted without editing the config file
# (topology + broker knobs included so the stress ladder is env-driven per rung)
for v in WORKLOAD EVENTS CHECKPOINTS REPS DARSHAN_MOFKA_ENABLE DARSHAN_MOFKA_TIMING \
         STUDY_EVENTS STUDY_REPS STUDY_TAG STUDY_WORKLOADS \
         NODES TASKS PLACEMENT BROKERS PARTITIONS MOFKA_PARTITION_TYPE \
         MOFKA_PROTOCOL RPC_THREAD_COUNT DRAIN_WAIT_S CONSUMERS NA_OFI_TX_SIZE NA_OFI_RX_SIZE MOFKA_NA_DOMAIN MOFKA_CLIENT_MODE; do
    [ -n "${!v:-}" ] && FWD="${FWD:+$FWD,}$v=${!v}"
done

# RUN_SCRIPT selects what the allocation runs (default: the standard runner).
RUN_SCRIPT="${RUN_SCRIPT:-workloads/job.sh}"
# mpiprocs=ncpus makes PBS/tm expose ncpus MPI slots per node (default is 1), so mpirun can
# place multiple ranks/node without oversubscription.
echo "submitting: select=${nodes}:ncpus=${ncpus}:mpiprocs=${ncpus} walltime=$walltime queue=$queue account=$account run=$RUN_SCRIPT"
qsub -A "$account" -q "$queue" -l select="${nodes}:ncpus=${ncpus}:mpiprocs=${ncpus}" -l walltime="$walltime" \
     -N dm_run -j oe -o "$ROOT/results/" ${FWD:+-v "$FWD"} <<PBS
cd "$ROOT"
bash "$RUN_SCRIPT"
PBS
