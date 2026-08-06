#!/bin/bash
# diag_profile.sh -- the loop-ending experiment: HEAVILY INSTRUMENTED python-ml,
# 3 arms, to localize the +45-66% streaming overhead to a REGION and a MECHANISM.
#
# Every prior experiment used coarse wall/CPU timers -- they can prove "+120 CPU-s
# exist on the app thread" but not WHERE inside the thread the cycles go, so the
# investigation looped. This run adds two orthogonal heavy profilers:
#
#   (1) In-workload (train.py ML_PROFILE=1): per-REGION wall + app-thread CPU
#       (write / read / compute) and RUSAGE_THREAD deltas -- minor-faults,
#       involuntary ctx-sw (preemption), voluntary ctx-sw (blocking), utime/stime.
#       BLAS pinned to 1 thread (ML_BLAS_THREADS=1) so the app thread is the SOLE
#       compute thread and cpu_ratio (proc/thread) reads ~1.0 when clean.
#   (2) Hardware counters (DM_WRAP_PERF=1, perf stat): task-clock, cycles,
#       instructions, cache-misses, dTLB-load-misses, context-switches,
#       cpu-migrations, minor-faults -- ONLY if perf is permitted on the compute
#       node (probed below; skipped safely if paranoid blocks it).
#
# ARMS (same MPMD/cxi launch each time; only the connector state changes):
#   baseline     NO_DARSHAN=1               python, no libdarshan, no stream. Reference.
#   runtimeonly  NO_DARSHAN=0 ENABLE=0      libdarshan instruments I/O, does NOT stream.
#                                           Isolates Darshan-instrumentation cost.
#   streaming    NO_DARSHAN=0 ENABLE=1      full Mofka streaming (Adaptive, default
#                                           progress thread -- Fix-B shape, no MARGO_JSON).
#
# THE DECISIVE READS (compare arm-to-arm in results/DIAGPROF_python-ml/*/):
#   * region=compute cpu_s FLAT but wall grows  -> overhead is in I/O/wait, not compute.
#   * region=compute cpu_s GROWS baseline->stream-> app thread burns MORE cycles for the
#     SAME matmuls => microarch contention (the ESCALATION +120 CPU-s), confirmed.
#       - perf instructions FLAT + cycles/cache-misses UP => memory/cache contention
#         (fix: allocator isolation e.g. jemalloc, or ES cpu-bind away from app core).
#       - perf instructions UP                            => real inline work on app
#         thread (fix: move connector work off the app thread).
#       - cpu-migrations / nivcsw UP                      => unpinned/preempted
#         (fix: taskset/--cpu-bind the workload rank).
#       - thread minflt UP / proc minflt >> thread minflt => allocator churn on the
#         drain/progress thread bleeding into the app (fix: allocator isolation).
#
# Usage (submit; 2 nodes fit debug):
#   qsub -A radix-io -q debug -l select=2:ncpus=32:mpiprocs=32 \
#        -l walltime=01:00:00 -l filesystems=home:eagle -j oe \
#        -o overhead_study/diag_profile.OU overhead_study/diag_profile.sh
set -uo pipefail
# PBS copies this script into a spool dir, so BASH_SOURCE-relative resolution breaks.
ROOT="${PBS_O_WORKDIR:-/eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight}"
while [ "$ROOT" != / ] && [ ! -d "$ROOT/workloads" ]; do ROOT="$(dirname "$ROOT")"; done
[ -d "$ROOT/workloads" ] || { echo "FATAL: cannot locate project root (no workloads/ dir)"; exit 1; }
cd "$ROOT"
LOG="$ROOT/results/diag_profile.log"; mkdir -p "$ROOT/results"
say(){ echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

FULL_NODEFILE="${PBS_NODEFILE:?must run inside a PBS job}"
mapfile -t ALLNODES < <(sort -u "$FULL_NODEFILE")
say "allocation: ${#ALLNODES[@]} nodes: ${ALLNODES[*]}"
[ "${#ALLNODES[@]}" -ge 2 ] || { say "need >=2 nodes"; exit 1; }
say "broker node = ${ALLNODES[0]} | workload node = ${ALLNODES[1]}"

# --- perf capability probe (compute node) --------------------------------------
# DM_WRAP_PERF=1 makes run.sh prefix the workload rank with `perf stat`. If perf is
# denied (perf_event_paranoid), that prefix FAILS and would kill the arm. Probe it
# on the WORKLOAD node via mpiexec (login-node paranoid != compute-node paranoid),
# and enable the wrap only if the probe succeeds. RUSAGE profiler stands alone otherwise.
# PALS flag style matches env/common.sh: `mpiexec --cpu-bind none --hosts <h> -n <n>`.
# timeout guard: a wedged probe must never stall the arms.
WRAP_PERF=0
if command -v perf >/dev/null 2>&1 && \
   timeout 60 mpiexec --cpu-bind none --hosts "${ALLNODES[1]}" -n 1 --ppn 1 \
     perf stat -e instructions -- true >/dev/null 2>&1; then
  WRAP_PERF=1
  say "perf probe: OK on ${ALLNODES[1]} -> DM_WRAP_PERF=1 (hardware counters ON)"
else
  say "perf probe: BLOCKED on ${ALLNODES[1]} -> DM_WRAP_PERF=0 (RUSAGE profiler only)"
fi

# python-ml config: compute-bound, same dataset shape as the 881s baseline so the
# mechanism is the one we've been chasing. Real calibration from job 7365177:
# ~0.257 s/epoch STREAMING, ~0.15 s/epoch baseline. 600 epochs => streaming arm
# ~2.6 min, baseline ~1.5 min; 3 arms + per-arm broker/reconstruct overhead ~= 12 min,
# well inside debug's 1h. Longer = more stable per-region CPU counters.
EVENTS=${EVENTS:-600}          # ML_EPOCHS
CHECKPOINTS=${CHECKPOINTS:-2}
ML_FILES=${ML_FILES:-64}
ML_ROWS=${ML_ROWS:-4096}
ML_COLS=${ML_COLS:-64}
PARTITIONS=${PARTITIONS:-16}
CONSUMERS=${CONSUMERS:-1}

# run_arm <enable> <no_darshan> <tag>
#   ML_PROFILE=1 + ML_BLAS_THREADS=1 turn on the in-workload heavy profiler.
#   DM_WRAP_PERF gated by the probe. No MARGO_JSON => default progress thread (Fix-B shape).
run_arm() {
  local enable="$1" nod="$2" tag="$3"
  say "RUN python-ml/$tag (enable=$enable no_darshan=$nod wrap_perf=$WRAP_PERF)"
  PBS_NODEFILE="$FULL_NODEFILE" \
  env \
    MOFKA_PROTOCOL=ofi+cxi WORKLOAD=python-ml TASKS=1 REPS=1 PLACEMENT=separate \
    EVENTS="$EVENTS" CHECKPOINTS="$CHECKPOINTS" \
    ML_FILES="$ML_FILES" ML_ROWS="$ML_ROWS" ML_COLS="$ML_COLS" \
    ML_PROFILE=1 ML_BLAS_THREADS=1 \
    PARTITIONS="$PARTITIONS" CONSUMERS="$CONSUMERS" \
    DM_MPSTAT=1 DM_MPSTAT_INT=5 DM_WRAP_PERF="$WRAP_PERF" \
    DARSHAN_MOFKA_ENABLE="$enable" NO_DARSHAN="$nod" DARSHAN_MOFKA_BATCH=0 \
    DARSHAN_MOFKA_TIMING=1 SKIP_BUILD=1 DIASPORA_C_SENDER_THREADS=1 \
    RESULTS_TAG="DIAGPROF_python-ml/${tag}" \
    bash workloads/job.sh python-ml >> "$LOG" 2>&1 \
    && say "  done python-ml/$tag" || say "  FAILED python-ml/$tag (continuing)"
  pkill -f 'bedrock ' 2>/dev/null || true; pkill -f mongod 2>/dev/null || true; sleep 4
}

say "===== python-ml HEAVY PROFILE: baseline -> runtimeonly -> streaming ====="
run_arm 0 1 baseline       # no libdarshan at all: pure compute reference
run_arm 0 0 runtimeonly    # libdarshan instruments I/O, no stream: Darshan-only cost
run_arm 1 0 streaming      # full Mofka streaming: the arm that pays +45-66%
say "===== DIAGPROF DONE (read MLPROF lines in workload.*.out; perf.*.txt if wrap on) ====="
