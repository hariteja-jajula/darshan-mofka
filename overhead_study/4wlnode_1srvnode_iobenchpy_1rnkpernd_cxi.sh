#!/bin/bash
# 4 workload node(s) + 1 broker/consumer = 5 total -> debug-scaling queue (<=1h).
# io_bench_py, ofi+cxi, 1 rank(s)/node. COMPUTE=15@N=256 ~= 10 min/rep (calibration.md); Python twin of io_bench.
# Submits 3 arms (baseline/runtimeonly/streaming) as 3 PBS jobs. Run: bash $0  (DRYRUN=1 to preview)
WLNODES=4 SRVNODES=1 WORKLOAD=io_bench_py PROTO=ofi+cxi TASKS=1 REPS="${REPS:-2}"
EVENTS=100 COMPUTE=15 MATRIX_SIZE=256
PARTITIONS=4 CONSUMERS=1
STUDY=OVH_iobenchpy_4wl
source "$(dirname "$0")/_submit_lib.sh"
