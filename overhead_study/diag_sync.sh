#!/bin/bash
# diag_sync.sh -- test the user's hypothesis DIRECTLY: does reverting async->sync
# (DARSHAN_MOFKA_ASYNC=0, the "exact prior synchronous inline push" per commit
# 48ed37f0) fix the busy-poll, with the progress thread left at its DEFAULT (ON)?
#
# This isolates ONLY the sync-vs-async change -- unlike diag_ldms_equiv.sh which also
# turns the progress thread off. Prediction (to be tested, not assumed): sync alone
# will NOT reclaim the core, because the Margo PROGRESS thread is spawned by the Mofka
# engine at init independent of how we push. But we measure rather than argue.
#
# Same node, same knobs as diag_samenode_fix so all rows compare 1:1 to prior runs.
# Arms:
#   1 baseline                 -- control (~233s)
#   2 streaming_sync           -- ASYNC=0 only (progress thread DEFAULT/on)   <-- THE test
#   3 streaming_async          -- default async (reproduce +45% busy-poll, in-alloc control)
#   4 baseline2                -- drift check
#   5 io_bench(C) streaming_sync -- ASYNC=0, C twin
#
# NOTE: the rebuilt connector injects margo{timeout:100,rpc:0} by default, but we
# proved BOTH are inert on CXI (timeout=100==timeout=0; rpc threads aren't the spinner).
# The progress thread is ON in arms 2/3/5, so this is a faithful "original sync" test
# of whether pushing inline vs off-thread changes the pegged-core behavior.
set -uo pipefail
ROOT="${PBS_O_WORKDIR:-/eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight}"
while [ "$ROOT" != / ] && [ ! -d "$ROOT/workloads" ]; do ROOT="$(dirname "$ROOT")"; done
[ -d "$ROOT/workloads" ] || { echo "FATAL: cannot locate project root (no workloads/ dir)"; exit 1; }
cd "$ROOT"
LOG="$ROOT/results/diag_sync.log"; mkdir -p "$ROOT/results"
say(){ echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

FULL_NODEFILE="${PBS_NODEFILE:?must run inside a PBS job}"
mapfile -t ALLNODES < <(sort -u "$FULL_NODEFILE")
say "allocation: ${#ALLNODES[@]} nodes: ${ALLNODES[*]}"
[ "${#ALLNODES[@]}" -ge 2 ] || { say "need >=2 nodes"; exit 1; }
say "broker node = ${ALLNODES[0]} | workload node (reused by ALL arms) = ${ALLNODES[1]}"

CMP_PY=${CMP_PY:-8}
CMP_C=${CMP_C:-24}
ITERS=${ITERS:-16}

# run_arm <wl> <arm> <proto> <tasks> <compute> <matrix> <part> <cons> <tag> [extra KEY=VAL ...]
run_arm() {
  local wl="$1" arm="$2" proto="$3" tasks="$4" compute="$5" matrix="$6" part="$7" cons="$8" tag="$9"
  shift 9
  local extra=( "$@" )
  local enable=1 nod=0
  case "$arm" in baseline*) nod=1;; darshan-only) enable=0;; streaming*) enable=1;; esac
  say "RUN $wl/$tag (enable=$enable no_darshan=$nod compute=$compute matrix=$matrix extra=[${extra[*]:-}])"
  PBS_NODEFILE="$FULL_NODEFILE" \
  env "${extra[@]}" \
    MOFKA_PROTOCOL="$proto" WORKLOAD="$wl" TASKS="$tasks" REPS=1 PLACEMENT=separate \
    EVENTS=100 PARTITIONS="$part" CONSUMERS="$cons" \
    IO_SIZE_MB=16 IO_ITERS="$ITERS" IO_SLEEP_MS=50 IO_BLOCK_KB=1024 \
    COMPUTE="$compute" MATRIX_SIZE="$matrix" \
    DARSHAN_MOFKA_ENABLE="$enable" NO_DARSHAN="$nod" DARSHAN_MOFKA_DROP_POLICY=block \
    DARSHAN_MOFKA_TIMING=1 SKIP_BUILD=1 RESULTS_TAG="DIAGSYNC_${wl}/${tag}" \
    bash workloads/job.sh "$wl" >> "$LOG" 2>&1 \
    && say "  done $wl/$tag" || say "  FAILED $wl/$tag (continuing)"
  pkill -f 'bedrock ' 2>/dev/null || true; pkill -f mongod 2>/dev/null || true; sleep 4
}

say "===== io_bench_py: baseline, streaming_SYNC(ASYNC=0), streaming_ASYNC(default), baseline2 ====="
run_arm io_bench_py baseline        ofi+cxi 1 "$CMP_PY" 256 4 1 baseline
run_arm io_bench_py streaming        ofi+cxi 1 "$CMP_PY" 256 4 1 streaming_sync  DARSHAN_MOFKA_ASYNC=0
run_arm io_bench_py streaming        ofi+cxi 1 "$CMP_PY" 256 4 1 streaming_async DARSHAN_MOFKA_ASYNC=1
run_arm io_bench_py baseline2        ofi+cxi 1 "$CMP_PY" 256 4 1 baseline2

say "===== io_bench (C): baseline, streaming_SYNC(ASYNC=0) ====="
run_arm io_bench baseline        ofi+cxi 1 "$CMP_C" 512 4 1 baseline
run_arm io_bench streaming        ofi+cxi 1 "$CMP_C" 512 4 1 streaming_sync DARSHAN_MOFKA_ASYNC=0

say "===== DIAGSYNC DONE ====="
