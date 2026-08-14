#!/bin/bash
# phase2_sweep.sh -- Phase-2 batch-size sweep submitter (SCRATCH; not committed until the
# sweep is proven). Wraps overhead_study/run_overhead.sh with the pinned python-ml params
# that produce the 641k-event regime (ML_FILES=64 ML_ROWS=4096 ML_COLS=64 EVENTS=1000,
# ~250s/rep) and drives the batch knob DARSHAN_MOFKA_BATCH.
#
# Design (see PHASE0_LOG.md "PHASE 2 -- BATCH SWEEP"):
#   - python-ml (641k events) is the PRIMARY sweep: batch in {0(adaptive),100,1000,10000}
#     all FILL and transmit mid-run -> all meaningful.
#   - io_bench (~600-1400 events) is SECONDARY: batch {0,100} meaningful; 10000 = "never
#     fills" validity check.
#   - Each job: baseline x1, runtimeonly x1, streaming x3, one PBS allocation, q=debug, cxi.
#
# Usage:
#   DRYRUN=1 bash overhead_study/phase2_sweep.sh python-ml 0        # dry-run one cell
#   bash overhead_study/phase2_sweep.sh python-ml 100              # submit one cell
#   START-SMALL: submit ONE cell, verify clean, THEN submit the next. Do NOT fire the whole
#   matrix at once (queue discipline: 1 running + 1 queued max).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WL="${1:?usage: phase2_sweep.sh <python-ml|io_bench> <batch:0|100|1000|10000>}"
BATCH="${2:?need a batch size (0=adaptive)}"

# batch=0 means "unset the knob" so the connector uses its adaptive default (byte-for-byte
# the old submit path). N>0 exports DARSHAN_MOFKA_BATCH=N.
if [ "$BATCH" = 0 ]; then
  BATCH_ENV=()            # unset -> adaptive
  BTAG="adaptive"
else
  BATCH_ENV=(DARSHAN_MOFKA_BATCH="$BATCH")
  BTAG="b${BATCH}"
fi

case "$WL" in
  python-ml)
    # pinned 641k-event params (proven: job 7418520 completed in <1hr)
    PARAMS=(WORKLOAD=python-ml ML_FILES=64 ML_ROWS=4096 ML_COLS=64 EVENTS=1000)
    STUDY="P2_pythonml_${BTAG}"
    ;;
  io_bench)
    # keep io_bench's own realistic scale; do NOT inflate events just to fill big batches
    PARAMS=(WORKLOAD=io_bench IO_ITERS=8 COMPUTE=72 MATRIX_SIZE=512 CHECKPOINT_EVERY=4)
    STUDY="P2_iobench_${BTAG}"
    ;;
  *) echo "unknown workload: $WL" >&2; exit 2 ;;
esac

echo "=== Phase-2 cell: WL=$WL batch=$BATCH ($BTAG) STUDY=$STUDY ==="
env "${PARAMS[@]}" "${BATCH_ENV[@]}" \
    STUDY="$STUDY" BASE_REPS=1 RUNTIME_REPS=1 STREAM_REPS=3 WALLTIME=01:00:00 \
    bash "$ROOT/overhead_study/run_overhead.sh"
