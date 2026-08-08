#!/bin/bash
# 4 workload node(s) + 1 broker/consumer = 5 total -> debug-scaling queue (<=1h).
# python-ml, ofi+cxi, 1 rank(s)/node. UNPROVEN on cxi streaming (job.sh:37 flood warning). Validate 1wl before 2/4wl.
# Submits 3 arms (baseline/runtimeonly/streaming) as 3 PBS jobs. Run: bash $0  (DRYRUN=1 to preview)
WLNODES=4 SRVNODES=1 WORKLOAD=python-ml PROTO=ofi+cxi TASKS=1 REPS="${REPS:-3}"
EVENTS="${EVENTS:-1000}" ML_CHECKPOINTS=2   # calibrated to 1wl proven ~538s/rep point
export ML_FILES="${ML_FILES:-64}" ML_ROWS="${ML_ROWS:-4096}" ML_COLS="${ML_COLS:-64}"
PARTITIONS=4 CONSUMERS=1
STUDY="${STUDY:-OVH_pythonml_4wl}"
source "$(dirname "$0")/_submit_lib.sh"
