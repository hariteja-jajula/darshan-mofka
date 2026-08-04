# Overhead study — findings & reconciliation (2026-08-04)

## The central reconciliation: "0.05%" vs "+45%"

The famous **0.05% overhead was ALWAYS the connector's SELF-TIMED cost** (init+push+send+
finalize measured inside the process), never a wall-time A/B. Our new runs reproduce it
exactly: **0.04%** (io_bench_py N1 streaming: init 0.16s + push 0.015s + send 0.003s +
finalize 0.0001s = ~0.18s of 438s work).

The self-timed number was never wrong — but it hid the real application cost, because the
streaming machinery (Argobots sender ES + progress ES + event serialization + async drain)
runs CONCURRENTLY and steals cycles from the app thread. That cost does not appear in any
per-call timer.

## What last week actually showed (audit of results_old/, 2026-07-28)

Same-node, same-allocation 3-arm wall A/B DID exist last week:
| workload | baseline | streaming | gap |
|---|---:|---:|---:|
| python-ml | 156.4s | 178.1s | +13.9% |
| C io_bench | 14.6s | 72.2s | +395% |
| MPI | 58.6s | 161.4s | +175% |
| dlio | 114.3s | 126.6s | +10.7% |

So large same-node wall gaps were ALWAYS present. Only ONE gap was ever dismissed as "node
variance": the cross-node C io_bench headline (633s vs 1134s on DIFFERENT nodes, overhead.md).

## New capability this week: CPU_PROBE (cpu_self vs cpu_thread)

Added this week to io_bench.c and io_bench.py. Emits:
  CPU_PROBE wall=W cpu_self=S cpu_thread=T
- cpu_self  = RUSAGE_SELF (all threads in process)
- cpu_thread= RUSAGE_THREAD (the app compute thread only)
Ratio cpu_self/cpu_thread ~= 1.0 means NO extra core burned (the ABT-context fix works);
~2.0 meant a sidecar core was pegged (pre-fix bug).

## The fix (committed): DIASPORA_C_SENDER_THREADS + ABT-safe push

Root cause: connector drain thread (raw pthread) called MofkaProducer::push() which takes a
thallium::mutex (ABT_mutex) -> illegal from non-Argobots thread -> scheduler corruption ->
mid-run wedge + pegged sidecar core. Fix: dedicated Argobots sender ES + dispatch push onto
it via pushWork. Result: ratio 2.0 -> 1.0, no wedge, VERDICT PASS.

## New same-node results WITH the fix (2026-08-04)

io_bench_py (Python, CXI, ~600 events, thread-capped baseline):
| arm | N1 cpu_thread | N4 cpu_thread |
|---|---:|---:|
| baseline    | 301.6 | 294.8 |
| runtimeonly | 315.1 | 299.6 |
| streaming   | 422.5 / 437.8 / 456.4 | 422.5 / 470.6 |

- Ratio cpu_self/cpu_thread = 1.00 everywhere -> NO extra core (fix works).
- runtimeonly ~= baseline (Darshan instrumentation ~+2-5%).
- streaming cpu_thread consistently +40-55% over baseline, REPRODUCIBLE across 5 reps on 2
  independent nodes. This is the APP THREAD's own CPU time rising, not wall/deschedule, not a
  sidecar core -> real cycle-stealing (cache/memory-bandwidth contention from concurrent
  event serialization hitting the pointer-chasing CPython interpreter).

## Caveat: C io_bench is too clock-noisy to measure here

C N1: baseline cpu_thread=556.7s vs runtimeonly cpu_thread=348.9s -- identical compute, 60%
different CPU time. Register-bound C matmul is turbo/thermal-clock-sensitive across time
windows, so its arm-to-arm variance SWAMPS any overhead signal. C cannot confirm the
"immune" side at this COMPUTE. Would need many reps or a clock-stable compute kernel.

## Bottom line

- Connector per-call cost: negligible (~0.04%), always was.
- Live streaming's REAL application cost is workload-specific and can be large; for
  compute-bound CPython it is ~+45% app-thread CPU, invisible to self-timed metrics.
- The fix eliminated the pegged sidecar core and the wedge (correctness), but did NOT
  eliminate the concurrent cycle-stealing cost on memory-sensitive workloads.
