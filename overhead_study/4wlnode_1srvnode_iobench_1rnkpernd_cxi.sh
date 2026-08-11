#!/bin/bash
# 4 workload node(s) + 1 broker/consumer = 5 total -> debug-scaling queue (<=1h).
# io_bench = REALISTIC C train-style workload (dataset write once + per-epoch re-read +
# cache-tiled matmul + periodic checkpoint), the C twin of python-ml. ~250s/rep.
# CONSUMERS scaled to workload nodes (4) so broker fan-in does not backpressure producers
# (the old CONS=1 caused the +57-91% 4wl blowup). PARTITIONS >= CONSUMERS with headroom.
# Submits 3 arms (baseline/runtimeonly/streaming) as 3 PBS jobs. Run: bash $0  (DRYRUN=1 to preview)
WLNODES=4 SRVNODES=1 WORKLOAD=io_bench PROTO=ofi+cxi TASKS=1 REPS="${REPS:-3}"
IO_ITERS="${IO_ITERS:-8}" ML_FILES="${ML_FILES:-8}" IO_SIZE_MB="${IO_SIZE_MB:-16}" \
  COMPUTE="${COMPUTE:-72}" MATRIX_SIZE="${MATRIX_SIZE:-512}" CHECKPOINT_EVERY="${CHECKPOINT_EVERY:-4}"
export IO_ITERS ML_FILES IO_SIZE_MB COMPUTE MATRIX_SIZE CHECKPOINT_EVERY
PARTITIONS=16 CONSUMERS=4    # 4 workload nodes -> 4 sharded consumers (fan-in fix)
STUDY="${STUDY:-OVH_iobench_4wl}"
source "$(dirname "$0")/_submit_lib.sh"
