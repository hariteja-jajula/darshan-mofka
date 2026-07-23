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

nodes=$(cfg_get "$WC" topology.nodes 1)
ncpus=$(cfg_get "$WC" pbs.ncpus 32)
walltime=$(cfg_get "$WC" pbs.walltime 00:30:00)
queue=$(cfg_get "$WC" pbs.queue debug)
account="${PBS_ACCOUNT:-$(cfg_get "$WC" pbs.account "")}"
[ -n "$account" ] || { echo "set an allocation: PBS_ACCOUNT=<project> bash submit.sh (or pbs.account in workload.config)"; exit 1; }

# forward only operational overrides; workload + knobs come from the config files
FWD=""
[ -n "${SKIP_BUILD:-}" ]            && FWD="${FWD:+$FWD,}SKIP_BUILD=$SKIP_BUILD"
[ -n "${MONGOD:-}" ]                && FWD="${FWD:+$FWD,}MONGOD=$MONGOD"
[ -n "${DARSHAN_MOFKA_PROFILE:-}" ] && FWD="${FWD:+$FWD,}DARSHAN_MOFKA_PROFILE=$DARSHAN_MOFKA_PROFILE"

echo "submitting: select=${nodes}:ncpus=${ncpus} walltime=$walltime queue=$queue account=$account"
qsub -A "$account" -q "$queue" -l select="${nodes}:ncpus=${ncpus}" -l walltime="$walltime" \
     -N dm_run -j oe -o "$ROOT/results/" ${FWD:+-v "$FWD"} <<PBS
cd "$ROOT"
bash workloads/job.sh
PBS
