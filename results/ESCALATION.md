# ESCALATION: Darshan→Mofka streaming adds +45% app-thread CPU on CPython — root cause unknown

**Audience:** a stronger model / Mochi-Mofka-Margo-Argobots expert. Everything below is
measured on Polaris (HPE Cray EX, AMD EPYC Milan, HPE Slingshot/CXI). Read fully.

## The one-sentence problem
With the streaming connector enabled, a compute-bound **CPython** workload's own
application thread (`RUSAGE_THREAD`) accumulates **~45% more CPU-seconds** than baseline —
NOT wall-clock stalling, NOT a busy sidecar core, and NOT explained by generic memory
contention. We cannot find where the cycles go. We believe we are using Mofka wrong
architecturally.

## Hard measurements (all same-node, same-allocation, sequential arms)

Workload: `io_bench_py` (pure-Python triple-loop matmul between POSIX I/O bursts),
1 rank/node, CXI, ~800 streamed events over the run, thread caps on
(OMP/OPENBLAS/MKL/NUMEXPR/VECLIB_NUM_THREADS=1). Connector fix applied:
`DIASPORA_C_SENDER_THREADS=1` (dedicated Argobots sender ES) + A′ yielding progress margo
config (`use_progress_thread:false` + basic_wait/fifo_wait `__progress__` xstream +
`progress_pool`).

| arm | wall (s) | cpu_self (all-thread) | cpu_thread (app thread) | wall−cpu_thread |
|---|---:|---:|---:|---:|
| baseline (NO_DARSHAN=1) | 302.44 | 301.64 | 301.64 | 0.80 |
| runtimeonly (ENABLE=0)  | 315.87 | 315.07 | 315.07 | 0.80 |
| streaming rep1          | 423.30 | 422.93 | 422.49 | 0.81 |
| streaming rep2          | 438.64 | 438.29 | 437.84 | 0.80 |
| streaming rep3          | 457.18 | 456.84 | 456.38 | 0.80 |

Reproduced on a second independent node (N4 job): baseline cpu_thread 294.8 →
streaming 422.5 / 470.6. Consistent.

### What these numbers rule OUT
1. **Not descheduling / not wall-only.** `wall − cpu_thread` is a CONSTANT 0.80s in every
   arm. The app thread is on-CPU ~100% of wall the whole time. So it is not being starved
   by a background thread stealing wall.
2. **Not a busy sidecar core.** `cpu_self ≈ cpu_thread` (ratio 1.00). Pre-fix this ratio
   was 2.0 (a pegged progress-spin core); the fix removed that. The +45% is ADDITIONAL to
   and separate from the old core-peg bug.
3. **Not Darshan instrumentation.** runtimeonly (Darshan on, streaming off) is only
   +4.5% over baseline. The jump is specifically from STREAMING (ENABLE=1).
4. **Not the connector's measured per-call cost.** Self-timed connector cost is
   negligible: init≈0.16s, push 797×≈19µs (sum 0.015s), send 797×≈2µs (sum 0.002s),
   finalize≈0.0001s. Total ≈ 0.18s = 0.04% of runtime. (This 0.04% matches the historical
   "0.05%" headline — which was ALWAYS self-timed only, never a wall A/B.)
5. **Not generic memory/cache contention.** Dedicated-compute-node native microbenchmark:
   a pointer-chasing thread run alongside a memory-heavy sibling thread (alloc/copy/scan,
   1 MiB buffers, like event serialization) inflated its `cpu_thread` by only **+1-2%**,
   and alongside a register-bound spinner by **+2%**. Generic sibling contention on this
   CPU is ~2%, three orders short of the +45% we see.
   (Probe: results/_probe/contention.c, job 7327725, AMD EPYC, x3004.)

### So the +45% is REAL app-thread CPU time, reproducible, and unexplained by any of the
usual suspects. ~120–155 CPU-seconds appear in the app thread that we cannot attribute.

## Architecture (how the connector currently works)

- Darshan LD_PRELOADs libdarshan.so; intercepts POSIX ops; per op calls
  `darshan_mofka_connector_send()` (darshan-runtime/lib/darshan-mofka.c) ON THE APP THREAD.
- send() (async mode, default): assigns seq, memcpy's a ~fixed struct into a ring buffer
  under a pthread_mutex, signals a condvar. Measured ~2µs. Cheap.
- A raw `pthread_create` DRAIN thread pops the ring and calls
  `diaspora_producer_push()` → MofkaProducer::push() → serialize + enqueue to
  ActiveProducerBatchQueue → Mercury RPC to broker.
- THE FIX we added: because the drain thread is a raw pthread and push() takes a
  `thallium::mutex` (ABT_mutex — illegal from a non-Argobots thread → scheduler corruption
  → prior wedge + pegged core), we now (a) give the producer a dedicated Argobots ES via
  `MofkaDriver::makeThreadPool(1)` and (b) dispatch the push onto that ES with
  `ThreadPool::pushWork()`. This fixed the wedge and the 2.0 core-peg (ratio → 1.0), and
  data integrity is perfect (VERDICT PASS, every counter matches native). But it did NOT
  remove the +45% app-thread CPU cost.

### Engine/margo config actually in effect (verified in the emitted "margo opts" line)
```
{"group_file":"…","margo":{"use_progress_thread":false,"rpc_thread_count":0,
 "argobots":{"pools":[
   {"name":"__primary__","kind":"fifo_wait","access":"mpmc"},
   {"name":"__progress__","kind":"fifo_wait","access":"mpmc"}],
  "xstreams":[
   {"name":"__primary__","scheduler":{"type":"basic_wait","pools":["__primary__"]}},
   {"name":"__progress__","scheduler":{"type":"basic_wait","pools":["__progress__"]}}]},
 "progress_pool":"__progress__"}}
```
Plus MOFKA_CLIENT_MODE=1 (non-listening producer endpoint). No `options ignored` /
`Could not find __primary__` warnings; margo honored `progress_pool`.

So at runtime the process has, on ONE node the app assumes it owns: the app thread (Python
interpreter), the `__primary__` ES, the `__progress__` ES, and our raw-pthread drain
thread. 1 rank/node CXI → the Python process is UNPINNED and floats across all cores.

## The leading suspicion (needs expert judgment)
Mofka is known to run with low overhead elsewhere. We suspect one of:
1. **We are creating too many Argobots ES / wrong pool topology**, and they thrash the
   scheduler or the app thread's core-affinity, inflating the app thread's retired-cycle
   count (e.g. constant ULT wakeups, futex/condvar traffic, or ABT scheduler polling that
   the kernel charges to the app thread's CPU time).
2. **The `basic_wait` progress ES is NOT actually sleeping on CXI** (na_cxi has no
   pollable fd / fi_trywait; HG_Progress busy-returns), so despite `basic_wait` the
   progress ULT self-requeues and the ES spins — but on a FLOATING/unpinned layout it
   shares the app thread's core via time-slice, and the accounting shows up as app
   cpu_thread. (But note: ratio cpu_self/cpu_thread=1.0 argues against a fully separate
   pegged core; the cost seems to land ON the app thread specifically.)
3. **We should be doing 1 rank/node with explicit CPU pinning / a reserved progress core**
   (the "caveat" hypothesis) — but the user has rejected burning a core, and generic
   contention is only ~2%, so pinning alone may not be the answer.
4. **We are calling push per-event (Adaptive batch) at ~800 events**, and each push does
   Mercury/Argobots work that, even dispatched to the sender ES, forces app-thread
   involvement (ULT scheduling boundaries, memory barriers, allocator contention with the
   Python allocator).

## Questions for the expert
1. What in the Mofka/Margo/Argobots client path would raise the APPLICATION thread's
   `RUSAGE_THREAD` CPU-seconds by ~45% while the connector's own push/send/init self-timers
   sum to 0.04%? Where do the missing ~140 CPU-seconds go and why are they charged to the
   app thread?
2. Is our engine ES/pool topology wrong for a pure producer? What is the canonical minimal
   client config that adds ~0 app-thread CPU (does Mofka expect the producer's ES to be
   pinned to a specific core, or to share `__primary__` with no extra xstream)?
3. On CXI specifically (no fi_trywait), how do low-overhead Mofka deployments prevent the
   progress loop from stealing the app's cycles WITHOUT a dedicated pinned core?
4. Is the raw-pthread-drain → pushWork-onto-ES hop itself the problem (cross-thread ULT
   creation per event causing app-thread-charged scheduler work)? Should the app thread
   instead push directly into an ABT pool it created, or should there be NO extra drain
   thread at all (push inline on the app thread, letting Adaptive batching + the sender ES
   do the async send)?
5. What instrumentation would definitively localize the ~140s? (perf record on the app
   thread with -g; ABT_TOOL / margo introspection; counting ABT_thread_create calls;
   futex/ctxsw counters via `perf stat -e context-switches,cs,cpu-migrations`?)

## Repro / artifacts
- Connector: darshan/darshan-runtime/lib/darshan-mofka.c (send at :456, drain at :233).
- Shim fix: diaspora-stream-api/src/c/diaspora_c.cpp (DIASPORA_C_SENDER_THREADS,
  abt_safe_push via pushWork). Committed to branch fix/abt-safe-sender-threadpool.
- Contention microbench: results/_probe/contention.c (job 7327725 output shows +1-2%).
- Full result data: results/OVH_iobenchpy_N1/{baseline,runtimeonly,streaming}/RUN*/workload.out
  (CPU_PROBE lines) and results/OVERHEAD_FINDINGS.md.
- Workload: workloads/python-ml/io_bench.py (has CPU_PROBE + new SPLIT io_s/matmul_s timers
  added but not yet run — running that split test is the OBVIOUS NEXT STEP: it will say
  whether the +140s is in the I/O region (inline connector) or the matmul region (contention)).

## The single most useful next experiment (not yet run)
Run io_bench_py streaming vs baseline and read the new `SPLIT io_s=… matmul_s=…` line
(already added to io_bench.py). This localizes the +140s to either:
  - io_s grows  → cost is INLINE on the app thread in the I/O/send path (connector/ABT work
                  charged to app thread) → fixable in connector/shim.
  - matmul_s grows → cost is contention slowing pure compute (no I/O) → scheduler/affinity/
                  ES-topology problem.
This one number will cut the search space in half. It needs one debug-node job.
