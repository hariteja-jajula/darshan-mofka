#!/bin/bash
# 1 workload node(s) + 1 broker/consumer = 2 total -> debug queue (<=1h).
# dlio, ofi+tcp, 32 rank(s)/node. TCP/legacy path. Known POSIX_SEEKS agg mismatch(1) in reconstruct (calibration.md).
# Submits 3 arms (baseline/runtimeonly/streaming) as 3 PBS jobs. Run: bash $0  (DRYRUN=1 to preview)
WLNODES=1 SRVNODES=1 WORKLOAD=dlio PROTO=ofi+tcp TASKS=32 REPS=2
EVENTS=320   # num_files_train; ~300-350 ~= 10 min (calibration.md)
PARTITIONS=16 CONSUMERS=16
STUDY=OVH_dlio_1wl
source "$(dirname "$0")/_submit_lib.sh"
