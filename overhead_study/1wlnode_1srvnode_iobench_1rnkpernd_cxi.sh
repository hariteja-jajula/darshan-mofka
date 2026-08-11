#!/bin/bash
# 1 workload node(s) + 1 broker/consumer = 2 total -> debug queue (<=1h).
# io_bench = REALISTIC C train-style workload (dataset write once + per-epoch re-read +
# cache-tiled matmul + periodic checkpoint), the C twin of python-ml. ~250s/rep (calibrated:
# 1 epoch ~31s login-node @ IO_ITERS x ML_FILES x COMPUTE@N=512; ~8 epochs ~= python-ml scale).
# Submits 3 arms (baseline/runtimeonly/streaming) as 3 PBS jobs. Run: bash $0  (DRYRUN=1 to preview)
WLNODES=1 SRVNODES=1 WORKLOAD=io_bench PROTO=ofi+cxi TASKS=1 REPS="${REPS:-3}"
IO_ITERS="${IO_ITERS:-8}" ML_FILES="${ML_FILES:-8}" IO_SIZE_MB="${IO_SIZE_MB:-16}" \
  COMPUTE="${COMPUTE:-72}" MATRIX_SIZE="${MATRIX_SIZE:-512}" CHECKPOINT_EVERY="${CHECKPOINT_EVERY:-4}"
export IO_ITERS ML_FILES IO_SIZE_MB COMPUTE MATRIX_SIZE CHECKPOINT_EVERY
PARTITIONS=4 CONSUMERS=1     # 1 workload node -> 1 consumer is enough
STUDY="${STUDY:-OVH_iobench_1wl}"
source "$(dirname "$0")/_submit_lib.sh"
