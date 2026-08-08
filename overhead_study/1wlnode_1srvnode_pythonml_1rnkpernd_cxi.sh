#!/bin/bash
# 1 workload node(s) + 1 broker/consumer = 2 total -> debug queue (<=1h).
# python-ml, ofi+cxi, 1 rank(s)/node. UNPROVEN on cxi streaming (job.sh:37 flood warning). Validate 1wl before 2/4wl.
# Submits 3 arms (baseline/runtimeonly/streaming) as 3 PBS jobs. Run: bash $0  (DRYRUN=1 to preview)
# REPS=3 = 1 cold (discarded) + 2 warm samples. Single warm sample is unusable given the
# measured 3.6x cold/warm swing at sub-second scale; 2 warm lets us see if they agree.
# 3 x ~538s work + broker/reconstruct still fits the 1h debug walltime.
WLNODES=1 SRVNODES=1 WORKLOAD=python-ml PROTO=ofi+cxi TASKS=1 REPS="${REPS:-3}"
# EVENTS=ML_EPOCHS. Calibrated to ~300s+ REAL work so per-event streaming cost dominates
# the constant init/finalize cost (proven point: results/NOSTREAM_pythonml did ~538s at
# EVENTS=1000 + the big dataset below; the old EVENTS=50 gave only ~0.2s -> pure noise).
EVENTS="${EVENTS:-1000}" ML_CHECKPOINTS=2
# big dataset (forwarded via _submit_lib.sh -> run.sh python-ml case): real np.load/savez I/O.
export ML_FILES="${ML_FILES:-64}" ML_ROWS="${ML_ROWS:-4096}" ML_COLS="${ML_COLS:-64}"
PARTITIONS=4 CONSUMERS=1
STUDY="${STUDY:-OVH_pythonml_1wl}"   # overridable so each fix routes to its own results dir
source "$(dirname "$0")/_submit_lib.sh"
