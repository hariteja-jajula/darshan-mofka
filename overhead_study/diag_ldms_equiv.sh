#!/bin/bash
# diag_ldms_equiv.sh -- test the LDMS-EQUIVALENT fix: kill the Mofka progress thread.
#
# WHY: diag_samenode_fix.sh proved progress_timeout_ub_msec is INERT on CXI --
# streaming_fix (t=100) and streaming_spin (t=0) were byte-identical busy-poll
# (cpu_self ~= 2x cpu_thread, wall ~341 vs baseline ~233). So sleeping the progress
# thread doesn't work on this fabric. LDMS has NO progress thread at all
# (darshan-ldms.c: ldmsd_stream_publish runs inline on the app thread, 0 bg threads).
# The Mofka-side equivalent is use_progress_thread:false -> Margo progresses ON THE
# CALLING THREAD on demand. This tests whether that (a) removes the pegged core and
# (b) does NOT deadlock the single-threaded Python producer (MofkaDriver.cpp:117
# forces the thread on precisely to avoid that deadlock -- so this is the empirical
# question).
#
# Arms (same node, same knobs as diag_samenode_fix so rows compare 1:1):
#   1 baseline                    -- control (~233s expected)
#   2 streaming NOPROG (async)    -- PROGRESS_THREAD=0, ring+drain ON. Drain thread
#                                    drives progress during its own push. If CXI needs
#                                    a yielding wait, this may hang -> DEADLOCK signal.
#   3 streaming NOPROG SYNC       -- PROGRESS_THREAD=0 + ASYNC=0. FULL LDMS-equivalent:
#                                    inline push on the app thread, on-demand progress.
#   4 baseline2                   -- drift check
#   5 io_bench(C) NOPROG SYNC     -- C has no Python-ULT-yield risk; sanity that the
#                                    LDMS model reclaims the core when it DOESN'T deadlock.
#
# A HANG (no CPU_PROBE within the arm) is itself the answer: on-demand progress
# deadlocks that caller on CXI -> the progress thread is mandatory -> the only path
# left is affinity-isolation of the thread (mitigate, not remove). job.sh has its own
# timeouts; the driver also loops with a bounded flush so a true hang shows as FAILED.
set -uo pipefail
ROOT="${PBS_O_WORKDIR:-/eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight}"
while [ "$ROOT" != / ] && [ ! -d "$ROOT/workloads" ]; do ROOT="$(dirname "$ROOT")"; done
[ -d "$ROOT/workloads" ] || { echo "FATAL: cannot locate project root (no workloads/ dir)"; exit 1; }
cd "$ROOT"
LOG="$ROOT/results/diag_ldms_equiv.log"; mkdir -p "$ROOT/results"
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
    DARSHAN_MOFKA_TIMING=1 SKIP_BUILD=1 RESULTS_TAG="DIAGLDMS_${wl}/${tag}" \
    bash workloads/job.sh "$wl" >> "$LOG" 2>&1 \
    && say "  done $wl/$tag" || say "  FAILED $wl/$tag (continuing)"
  pkill -f 'bedrock ' 2>/dev/null || true; pkill -f mongod 2>/dev/null || true; sleep 4
}

say "===== io_bench_py: baseline, streaming(NOPROG async), streaming(NOPROG sync), baseline2 ====="
run_arm io_bench_py baseline   ofi+cxi 1 "$CMP_PY" 256 4 1 baseline
run_arm io_bench_py streaming   ofi+cxi 1 "$CMP_PY" 256 4 1 streaming_noprog_async \
        DARSHAN_MOFKA_PROGRESS_THREAD=0
run_arm io_bench_py streaming   ofi+cxi 1 "$CMP_PY" 256 4 1 streaming_noprog_sync \
        DARSHAN_MOFKA_PROGRESS_THREAD=0 DARSHAN_MOFKA_ASYNC=0
run_arm io_bench_py baseline2   ofi+cxi 1 "$CMP_PY" 256 4 1 baseline2

say "===== io_bench (C): baseline, streaming(NOPROG sync) -- core reclaimed when no deadlock? ====="
run_arm io_bench baseline   ofi+cxi 1 "$CMP_C" 512 4 1 baseline
run_arm io_bench streaming   ofi+cxi 1 "$CMP_C" 512 4 1 streaming_noprog_sync \
        DARSHAN_MOFKA_PROGRESS_THREAD=0 DARSHAN_MOFKA_ASYNC=0

say "===== DIAGLDMS DONE ====="
