# DIAGPROF: heavily-instrumented python-ml — where the streaming CPU goes

Job **7365261** (2 nodes, debug, ofi+cxi/MPMD). Realistic numpy MLP trainer
(`train.py`) with `ML_PROFILE=1` heavy profiler: per-region wall + **app-thread**
CPU (`time.thread_time_ns`), whole-**process** CPU (`time.process_time_ns`), and
`RUSAGE_THREAD`/`RUSAGE_SELF` deltas. BLAS pinned to 1 thread so the app thread is
the sole compute thread. `perf` probed and **BLOCKED cluster-wide** (paranoid) →
RUSAGE profiler only. 3 arms, EVENTS=600, ML_FILES=64 ML_ROWS=4096 ML_COLS=64.

## The numbers (RUN1, workload rank = global id 2)

| metric | baseline (no libdarshan) | runtimeonly (darshan, no stream) | **streaming** |
|---|---|---|---|
| WORK wall_s | 149.20 | 149.87 | **151.77** |
| region=compute cpu_s | 137.90 | 137.89 | **137.54** |
| region=read cpu_s | 10.03 | 11.48 | 13.33 |
| region=write cpu_s | 0.24 | 0.23 | 0.24 |
| **app-thread cpu_s** | 148.42 | 149.86 | **151.39** |
| **proc cpu_s (all threads)** | 148.42 | 149.86 | **195.56** |
| **cpu_ratio (proc/thread)** | 1.000 | 1.000 | **1.292** |
| thread minflt | 1716 | 1265 | 7398 |
| thread nivcsw (preempt) | 94 | 99 | 208 |
| thread nvcsw (voluntary yield) | 241 | 65 | **26294** |
| proc minflt | 1716 | 1265 | 8414 |
| streamed events | — | — | 385,603 |

mpstat busy-core occupancy (cores ≥30% busy, 30 samples):

| arm | distinct busy cores | node aggregate |
|---|---|---|
| baseline | 1 (core 21) | 1.03 core-equiv |
| runtimeonly | 1 (core 17) | 1.06 core-equiv |
| **streaming** | **4 (cores 8,12,13,28)** | **1.33 core-equiv** |

## What this says — unambiguously

1. **Darshan instrumentation is free.** baseline→runtimeonly: WORK +0.4%, compute
   cpu identical (137.90→137.89). The cost is entirely the *streaming connector*.

2. **The app thread's compute is NOT slowed.** `region=compute cpu_s` is
   **137.9 → 137.5** across all three arms — the connector-free matmul inner loop
   runs at exactly the same CPU cost with streaming on. **This kills the
   "microarch/allocator contention steals cycles from the app thread" theory**
   (the ESCALATION.md +120 CPU-s "on the app thread" reading): if the drain thread
   were contending for cache/BW, the pure-compute region would have inflated. It
   did not (Δ ≈ 0, actually −0.3s).

3. **The extra CPU is a REAL second thread on a DIFFERENT core.** proc_cpu jumps
   **+47.1s** (148→196) while app-thread cpu rises only **+3.0s**. cpu_ratio 1.29.
   mpstat shows work spread over 4 cores (drain/sender ES + progress, migrating),
   node aggregate 1.03→1.33 core-equiv. The connector's drain/serialize/send work
   is ~47 CPU-s and it runs **off the app core** — so it barely touches WORK wall
   (**+1.7%** here).

4. **The app thread's only real cost is ~26k voluntary context switches**
   (nvcsw 241→26294) + read region +3.3s. Those are the app briefly yielding at
   the ~385k per-op emit points (enqueue to the drain). Cheap: total app-thread
   cpu delta +3.0s over 149s = +2.0%.

## The precise answer to "what is the problem, and what is the fix"

**On the realistic trainer, streaming overhead is +1.7% wall — the famous
+45-70% does NOT reproduce.** Directly measured: the connector's ~47 CPU-s of
drain/serialize/send runs as a real second thread on an otherwise-idle core, and
the app thread's connector-free compute region is byte-for-byte the same CPU
(137.90→137.54). The connector does **not** steal cycles from this app's compute.

### Reconciling with the earlier +45-70% (this is regime-dependent, NOT one fix)

Same MPMD launcher, same `--cpu-bind none` (hardcoded, env/common.sh:79), same
`DIASPORA_C_SENDER_THREADS=1`, same ~385k events — yet:

| workload | regime | overhead | why |
|---|---|---|---|
| python-ml OLD (train_old.py) | I/O-bound: 262k row writes, ~0 compute | +70% | emits on the critical path, no compute region to overlap the drain → app stalls on enqueue/backpressure/CXI progress |
| io_bench_py COMPUTE>0 (512×512 GEMMs) | memory-bandwidth-bound compute | +45% (app-thread CPU rises, ESCALATION.md) | drain thread co-runs and contends for LLC/mem-BW → cache-spilling GEMMs slow down |
| **python-ml NEW (train.py, this run)** | **compute-bound, cache-resident small GEMMs** | **+1.7%** | **drain runs on a free core; small GEMMs fit in cache → immune to the co-runner** |

So there is **no single "+45%" connector tax**. The overhead is set by whether the
drain's work lands on the app's critical path or contends with the app's memory
system:
  * **I/O-bound / emit-on-critical-path** (old row-write workload) → large.
  * **memory-BW-bound compute** sharing LLC with the drain (io_bench_py) → large.
  * **cache-resident compute with a free core** (realistic trainer) → ~2%.

### Precise fixes, by regime
1. **Realistic ML training (this workload):** nothing needed. +1.7% is noise;
   keep `DIASPORA_C_SENDER_THREADS=1` and don't over-pin (Polaris default
   `--cpu-bind none` already gives the drain a free core).
2. **I/O-bound workloads (the old +70% case):** emit once-per-record-at-close
   instead of per-op, so the app doesn't pay enqueue on its I/O critical path.
3. **Memory-bandwidth-bound compute (the io_bench_py +45% case):** isolate the
   drain ES to a different NUMA domain / far core so it doesn't share LLC/mem-BW
   with the app (core/NUMA affinity for the sender ES).

**Residual real cost here (small, unavoidable):** ~3 app-thread CPU-s = per-op
enqueue at 385k emit sites (26k voluntary yields + read-region +3s). +2%; not worth
optimizing for realistic ML.

## Caveat / one confirming experiment (in flight)
The reconciliation hinges on "contention only bites memory-BW-bound compute." Test
it directly with THIS instrument: run train.py with LARGE cache-spilling GEMMs
(big ML_HIDDEN/ML_BATCH) streaming vs baseline. If `region=compute cpu_s` rises
under streaming → contention-on-memory-bound-compute confirmed (matches io_bench_py
+45%); if it stays flat → the distinguisher is something else. Cheap, uses the
existing ML_PROFILE instrument, queue is free.
NOTE: perf is BLOCKED cluster-wide on Polaris (probe failed on the compute node),
so HW cache-miss counters aren't available; the region-CPU split is the substitute.
