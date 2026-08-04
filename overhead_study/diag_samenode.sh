#!/bin/bash
# diag_samenode.sh -- ROOT-CAUSE the io_bench_py streaming wall gap with ZERO node
# confound. Runs INSIDE one PBS allocation (2 nodes = 1 broker + 1 workload) and drives
# ALL arms of a workload back-to-back reusing the SAME workload node (job.sh always puts
# the app rank on NODELIST[1]). So baseline vs streaming differ ONLY by the connector,
# never by which physical CPU they landed on.
#
# Emits, per arm: the self-timed WORK wall AND the CPU_PROBE line (Python only) that
# splits the two candidate mechanisms:
#   cpu_thread/wall ~1.0            -> app thread ran flat out; matmul NOT slowed
#   cpu_thread/wall  <1.0           -> app thread starved of CPU (a bg thread stole its core)
#   cpu_self  >> cpu_thread ~= wall -> a bg (progress/rpc) thread busy-burned a whole core
#
# Order per workload: baseline, darshan-only, streaming, baseline2 (drift check).
# Short compute (~2 min/arm) so the whole thing fits a 1h debug slot with margin.
#
# Usage (submit):  qsub -A radix-io -q debug -l select=2:ncpus=32:mpiprocs=32 \
#                       -l walltime=00:50:00 -l filesystems=home:eagle -j oe \
#                       -o overhead_study/diag_samenode.OU overhead_study/diag_samenode.sh
set -uo pipefail
# PBS copies this script into a spool dir, so BASH_SOURCE-relative resolution breaks.
# Prefer PBS_O_WORKDIR (the dir qsub was run from); fall back to the known project root.
ROOT="${PBS_O_WORKDIR:-/eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight}"
# If qsub was run from overhead_study/ or results/, climb to the project root (has workloads/).
while [ "$ROOT" != / ] && [ ! -d "$ROOT/workloads" ]; do ROOT="$(dirname "$ROOT")"; done
[ -d "$ROOT/workloads" ] || { echo "FATAL: cannot locate project root (no workloads/ dir)"; exit 1; }
cd "$ROOT"
LOG="$ROOT/results/diag_samenode.log"; mkdir -p "$ROOT/results"
say(){ echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

FULL_NODEFILE="${PBS_NODEFILE:?must run inside a PBS job}"
mapfile -t ALLNODES < <(sort -u "$FULL_NODEFILE")
say "allocation: ${#ALLNODES[@]} nodes: ${ALLNODES[*]}"
[ "${#ALLNODES[@]}" -ge 2 ] || { say "need >=2 nodes"; exit 1; }
# node0 = broker/consumer, node1 = the ONE workload node reused by every arm.
say "broker node = ${ALLNODES[0]} | workload node (reused by ALL arms) = ${ALLNODES[1]}"

# short-but-real knobs: enough compute to expose a % gap, short enough for many arms/hour.
CMP_PY=${CMP_PY:-8}          # matmul reps/iter @ 256  (~2 min pure-python)
CMP_C=${CMP_C:-24}           # matmul reps/iter @ 512  (~2 min C)
ITERS=${ITERS:-16}

run_arm() {   # <wl> <arm> <proto> <tasks> <compute> <matrix> <part> <cons> <tag>
  local wl="$1" arm="$2" proto="$3" tasks="$4" compute="$5" matrix="$6" part="$7" cons="$8" tag="$9"
  local enable=1 nod=0
  case "$arm" in baseline*) nod=1;; darshan-only) enable=0;; streaming) enable=1;; esac
  say "RUN $wl/$tag (enable=$enable no_darshan=$nod compute=$compute matrix=$matrix)"
  PBS_NODEFILE="$FULL_NODEFILE" \
    MOFKA_PROTOCOL="$proto" WORKLOAD="$wl" TASKS="$tasks" REPS=1 PLACEMENT=separate \
    EVENTS=100 PARTITIONS="$part" CONSUMERS="$cons" \
    IO_SIZE_MB=16 IO_ITERS="$ITERS" IO_SLEEP_MS=50 IO_BLOCK_KB=1024 \
    COMPUTE="$compute" MATRIX_SIZE="$matrix" \
    DARSHAN_MOFKA_ENABLE="$enable" NO_DARSHAN="$nod" DARSHAN_MOFKA_DROP_POLICY=block \
    DARSHAN_MOFKA_TIMING=1 SKIP_BUILD=1 RESULTS_TAG="DIAG_${wl}/${tag}" \
    bash workloads/job.sh "$wl" >> "$LOG" 2>&1 \
    && say "  done $wl/$tag" || say "  FAILED $wl/$tag (continuing)"
  pkill -f 'bedrock ' 2>/dev/null || true; pkill -f mongod 2>/dev/null || true; sleep 4
}

say "===== io_bench_py: baseline, darshan-only, streaming, baseline2 (same node) ====="
run_arm io_bench_py baseline     ofi+cxi 1 "$CMP_PY" 256 4 1 baseline
run_arm io_bench_py darshan-only ofi+cxi 1 "$CMP_PY" 256 4 1 darshan-only
run_arm io_bench_py streaming    ofi+cxi 1 "$CMP_PY" 256 4 1 streaming
run_arm io_bench_py baseline2    ofi+cxi 1 "$CMP_PY" 256 4 1 baseline2

say "===== io_bench (C): baseline, streaming (same node -- is C truly immune?) ====="
run_arm io_bench baseline  ofi+cxi 1 "$CMP_C" 512 4 1 baseline
run_arm io_bench streaming ofi+cxi 1 "$CMP_C" 512 4 1 streaming

say "===== DIAG DONE ====="
