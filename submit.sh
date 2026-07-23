#!/bin/bash
# submit.sh -- send job.sh to a compute node through PBS.
#
# The broker needs a compute node (its network transport does not come up on login
# nodes), so this is how you run the demo in batch.
#
# Runs the workload chosen in workloads/workload.config. Edit that file (and
# server/server.config) to change what runs; you rarely pass anything here.
#
# Usage:
#   PBS_ACCOUNT=<project> bash submit.sh [walltime] [queue]
#   # examples:
#   PBS_ACCOUNT=radix-io bash submit.sh                 # runs workloads/workload.config, 30 min, debug
#   SKIP_BUILD=1 PBS_ACCOUNT=radix-io bash submit.sh    # reuse an existing build
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCOUNT="${PBS_ACCOUNT:-${ACCOUNT:-}}"
[ -n "$ACCOUNT" ] || { echo "set your allocation:  PBS_ACCOUNT=<project> bash submit.sh"; exit 1; }
WALLTIME="${1:-00:30:00}"; QUEUE="${2:-debug}"

# only forward operational overrides; the workload + its knobs come from the config files
FWD=""
[ -n "${SKIP_BUILD:-}" ]            && FWD="${FWD:+$FWD,}SKIP_BUILD=$SKIP_BUILD"
[ -n "${MONGOD:-}" ]                && FWD="${FWD:+$FWD,}MONGOD=$MONGOD"
[ -n "${DARSHAN_MOFKA_PROFILE:-}" ] && FWD="${FWD:+$FWD,}DARSHAN_MOFKA_PROFILE=$DARSHAN_MOFKA_PROFILE"

# submit an inline wrapper so PBS_O_WORKDIR is the repo; the wrapper cds there and
# runs job.sh from the real tree (qsub otherwise copies the script to a spool dir).
qsub -A "$ACCOUNT" -q "$QUEUE" -l select=1:ncpus=32 -l walltime="$WALLTIME" \
     -N dm_run -j oe -o "$ROOT/results/" ${FWD:+-v "$FWD"} <<PBS
cd "$ROOT"
bash job.sh
PBS
