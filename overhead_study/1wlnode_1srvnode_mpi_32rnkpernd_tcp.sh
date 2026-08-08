#!/bin/bash
# 1 workload node(s) + 1 broker/consumer = 2 total -> debug queue (<=1h).
# mpi, ofi+tcp, 32 rank(s)/node. TCP/legacy path (mpi is blocked on cxi by job.sh:36 Gate-0).
# Submits 3 arms (baseline/runtimeonly/streaming) as 3 PBS jobs. Run: bash $0  (DRYRUN=1 to preview)
WLNODES=1 SRVNODES=1 WORKLOAD=mpi PROTO=ofi+tcp TASKS=32 REPS="${REPS:-2}"
EVENTS=900   # STEPS; ~800-1000 ~= 10 min @ 32 ranks (calibration.md)
PARTITIONS=16 CONSUMERS=16
STUDY=OVH_mpi_1wl
source "$(dirname "$0")/_submit_lib.sh"
