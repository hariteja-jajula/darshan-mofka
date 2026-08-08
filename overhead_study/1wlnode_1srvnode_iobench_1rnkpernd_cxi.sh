#!/bin/bash
# 1 workload node(s) + 1 broker/consumer = 2 total -> debug queue (<=1h).
# io_bench, ofi+cxi, 1 rank(s)/node. COMPUTE=72@N=512 ~= 10 min/rep (calibration.md); ~600 events.
# Submits 3 arms (baseline/runtimeonly/streaming) as 3 PBS jobs. Run: bash $0  (DRYRUN=1 to preview)
WLNODES=1 SRVNODES=1 WORKLOAD=io_bench PROTO=ofi+cxi TASKS=1 REPS="${REPS:-2}"
EVENTS=100 COMPUTE=72 MATRIX_SIZE=512
PARTITIONS=4 CONSUMERS=1
STUDY=OVH_iobench_1wl
source "$(dirname "$0")/_submit_lib.sh"
