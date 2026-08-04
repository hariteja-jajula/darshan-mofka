#!/bin/bash
# 2 workload node(s) + 1 broker/consumer = 3 total -> debug-scaling queue (<=1h).
# python-ml, ofi+cxi, 1 rank(s)/node. UNPROVEN on cxi streaming (job.sh:37 flood warning). Validate 1wl before 2/4wl.
# Submits 3 arms (baseline/runtimeonly/streaming) as 3 PBS jobs. Run: bash $0  (DRYRUN=1 to preview)
WLNODES=2 SRVNODES=1 WORKLOAD=python-ml PROTO=ofi+cxi TASKS=1 REPS=2
EVENTS=50 ML_CHECKPOINTS=1   # EVENTS=ML_EPOCHS; UNCALIBRATED -- validate at 1wl first
PARTITIONS=4 CONSUMERS=1
STUDY=OVH_pythonml_2wl
source "$(dirname "$0")/_submit_lib.sh"
