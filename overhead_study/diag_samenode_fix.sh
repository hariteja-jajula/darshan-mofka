#!/bin/bash
# diag_samenode_fix.sh -- POST-FIX re-run of diag_samenode.sh to test whether the
# progress-thread busy-poll fix (margo config injected into the connector opts:
# progress_timeout_ub_msec + rpc_thread_count:0) actually drops streaming wall/CPU
# back toward baseline WHILE staying cheap. Uses the SAME node/knobs as the pre-fix
# run so rows are directly comparable to results/diag_samenode.log.
#
# The open question this answers: does the CXI provider actually BLOCK-wait when we
# set progress_timeout_ub_msec>0? If yes, the FIX arm's cpu_self collapses from ~2x
# wall (a pegged core) to ~1x wall. The SPIN control (timeout=0) reproduces the old
# busy-poll IN THE SAME ALLOCATION, so the timeout is proven to be the lever (not
# some other environmental change between the two jobs).
#
# Per arm we read: self-timed WORK wall + CPU_PROBE (wall/cpu_self/cpu_thread) +
# the connector's `darshan-mofka[cfg] margo opts:` line (confirms the knobs took).
#
# Usage (submit):  qsub -A radix-io -q debug -l select=2:ncpus=32:mpiprocs=32 \
#                       -l walltime=00:50:00 -l filesystems=home:eagle -j oe \
#                       -o overhead_study/diag_samenode_fix.OU overhead_study/diag_samenode_fix.sh
set -uo pipefail
# PBS copies this script into a spool dir, so BASH_SOURCE-relative resolution breaks.
ROOT="${PBS_O_WORKDIR:-/eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight}"
while [ "$ROOT" != / ] && [ ! -d "$ROOT/workloads" ]; do ROOT="$(dirname "$ROOT")"; done
[ -d "$ROOT/workloads" ] || { echo "FATAL: cannot locate project root (no workloads/ dir)"; exit 1; }
cd "$ROOT"
LOG="$ROOT/results/diag_samenode_fix.log"; mkdir -p "$ROOT/results"
say(){ echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

FULL_NODEFILE="${PBS_NODEFILE:?must run inside a PBS job}"
mapfile -t ALLNODES < <(sort -u "$FULL_NODEFILE")
say "allocation: ${#ALLNODES[@]} nodes: ${ALLNODES[*]}"
[ "${#ALLNODES[@]}" -ge 2 ] || { say "need >=2 nodes"; exit 1; }
say "broker node = ${ALLNODES[0]} | workload node (reused by ALL arms) = ${ALLNODES[1]}"

# SAME knobs as the pre-fix diag so rows compare 1:1.
CMP_PY=${CMP_PY:-8}          # matmul reps/iter @ 256  (~4 min pure-python)
CMP_C=${CMP_C:-24}           # matmul reps/iter @ 512  (~2.5 min C)
ITERS=${ITERS:-16}

# run_arm <wl> <arm> <proto> <tasks> <compute> <matrix> <part> <cons> <tag> [extra env KEY=VAL ...]
run_arm() {
  local wl="$1" arm="$2" proto="$3" tasks="$4" compute="$5" matrix="$6" part="$7" cons="$8" tag="$9"
  shift 9
  local extra=( "$@" )        # extra DARSHAN_MOFKA_* knobs for the streaming sweep
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
    DARSHAN_MOFKA_TIMING=1 SKIP_BUILD=1 RESULTS_TAG="DIAGFIX_${wl}/${tag}" \
    bash workloads/job.sh "$wl" >> "$LOG" 2>&1 \
    && say "  done $wl/$tag" || say "  FAILED $wl/$tag (continuing)"
  pkill -f 'bedrock ' 2>/dev/null || true; pkill -f mongod 2>/dev/null || true; sleep 4
}

say "===== io_bench_py: baseline, streaming(FIX t=100 rpc=0), streaming(SPIN t=0), baseline2 (same node) ====="
run_arm io_bench_py baseline      ofi+cxi 1 "$CMP_PY" 256 4 1 baseline
run_arm io_bench_py streaming      ofi+cxi 1 "$CMP_PY" 256 4 1 streaming_fix \
        DARSHAN_MOFKA_PROGRESS_TIMEOUT_MS=100 DARSHAN_MOFKA_RPC_THREADS=0
run_arm io_bench_py streaming      ofi+cxi 1 "$CMP_PY" 256 4 1 streaming_spin \
        DARSHAN_MOFKA_PROGRESS_TIMEOUT_MS=0   DARSHAN_MOFKA_RPC_THREADS=0
run_arm io_bench_py baseline2      ofi+cxi 1 "$CMP_PY" 256 4 1 baseline2

say "===== io_bench (C): baseline, streaming(FIX) -- confirm the wasted core is reclaimed in C too ====="
run_arm io_bench baseline   ofi+cxi 1 "$CMP_C" 512 4 1 baseline
run_arm io_bench streaming  ofi+cxi 1 "$CMP_C" 512 4 1 streaming_fix \
        DARSHAN_MOFKA_PROGRESS_TIMEOUT_MS=100 DARSHAN_MOFKA_RPC_THREADS=0

say "===== DIAGFIX DONE ====="
