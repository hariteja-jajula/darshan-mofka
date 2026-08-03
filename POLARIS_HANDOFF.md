# Polaris Agent Handoff — Darshan→Mofka overhead root cause & fix

Status: an LCRC-side effort (this doc's author) has, with a Mofka-expert review of the
actual Mofka source, identified what is very likely the REAL root cause of both the
mid-run wedge/hang AND the wall-time overhead. This supersedes the earlier "busy-poll
core peg is the whole story" theory. Please read, then coordinate: we will develop on a
branch here, you validate on Polaris/CXI, and we merge.

## Correction to the earlier theory
Earlier we blamed the margo progress thread busy-polling a core (contention → +43% on
Python). New evidence contradicts that being the WHOLE story:
- **Pinning the progress ES to an isolated core did NOT recover wall time.** If it were pure
  sibling-core contention, pinning would have fixed it. It didn't. → contention is not the
  dominant cost.
- **The streaming process WEDGES MID-RUN** (per-call timing lines stream, then stop; core
  pegged for minutes; connector finalize never reached). It is stuck in the steady-state
  send path, not at teardown.

## The actual root cause (from Mofka source @ commit 6bddc5b)
`diaspora_producer_push()` does NOT call margo inline — it only enqueues. The blocking
send RPC (`ProducerBatch::send()` → blocking thallium RPC → `margo_wait`) runs on Mofka's
**sender ULT**, which by default is scheduled on the **margo progress pool**
(`MofkaDriver::defaultThreadPool()` → `get_progress_pool()`, MofkaDriver.cpp:765;
`MofkaTopicHandle.cpp:29` falls back to it when no ThreadPool is passed — and the C shim
never passes one).

So the sender ULT (parked in a blocking RPC waiting for the broker) and the network
progress loop that must run to COMPLETE that RPC share ONE execution stream. Under any
broker slowness/backpressure this self-serializes and can wedge. Pinning can't fix it;
it's serialization/deadlock, not contention.

## The fix (implemented here on branch — see below)
Give the producer a **dedicated Argobots ThreadPool(1)** so the sender ULT runs on its OWN
execution stream, decoupled from the progress pool. This is exactly what Mofka's own
`example/python/work.py` does (`producer(..., thread_pool=mofka.ThreadPool(1))`), which is
the only long-running-producer example in the repo.

Because `start_progress_thread()` and thread pools are NOT exposed in the diaspora C API,
we extended the C shim:

### Code changes made (in this repo)
1. `diaspora-stream-api/include/diaspora/diaspora_c.h` — new
   `diaspora_producer_create_ex(driver, topic, name, batch, max_batches, ordering, thread_count)`.
2. `diaspora-stream-api/src/c/diaspora_c.cpp` — implements it: when `thread_count>0`,
   `tp = d->impl.makeThreadPool(ThreadCount{n})` then `topic.producer(name, bs, tp, ord)`.
   `thread_count==0` = legacy (progress-pool) behavior. Original `diaspora_producer_create`
   now delegates with `thread_count=0`.
3. `darshan/darshan-runtime/lib/darshan-mofka.c`:
   - producer create now calls `diaspora_producer_create_ex(g_driver, ...)` with
     `producer_threads` from env `DARSHAN_MOFKA_PRODUCER_THREADS` (DEFAULT 1).
   - Also added earlier: `DARSHAN_MOFKA_MARGO_JSON` (inject margo/argobots config, e.g. a
     yielding `basic_wait` progress ES) and `DARSHAN_MOFKA_FAST_EXIT` (leak engine at exit
     to dodge the mercury teardown deadlock; also auto-triggered when drain-join times out).
4. `lib/run.sh` — forwards `DARSHAN_MOFKA_PRODUCER_THREADS`, `DARSHAN_MOFKA_MARGO_JSON`,
   `DARSHAN_MOFKA_FAST_EXIT` to the workload env.

### New env knobs
| Knob | Default | Meaning |
|---|---|---|
| `DARSHAN_MOFKA_PRODUCER_THREADS` | 1 | dedicated sender ES count. **1 = the fix.** 0 = legacy bug (sender on progress pool). |
| `DARSHAN_MOFKA_MARGO_JSON` | unset | verbatim margo config object (progress-ES scheduler/affinity). |
| `DARSHAN_MOFKA_FAST_EXIT` | unset | 1 = skip mercury teardown at finalize (leak; OS reclaims). |

## What Polaris should test (A/B, same allocation)
Run the same workload three ways and compare wall + CPU + whether it wedges:
1. `DARSHAN_MOFKA_ENABLE=0` — baseline (control).
2. `DARSHAN_MOFKA_ENABLE=1 DARSHAN_MOFKA_PRODUCER_THREADS=0` — reproduces the wedge/overhead.
3. `DARSHAN_MOFKA_ENABLE=1 DARSHAN_MOFKA_PRODUCER_THREADS=1` — the fix.

Also set `DARSHAN_MOFKA_VERBOSE=1` (prints `producer_threads=N`), `DARSHAN_MOFKA_TIMING=1`
(per-call push/send µs), `DARSHAN_MOFKA_FAST_EXIT=1`, and bounded
`DARSHAN_MOFKA_JOIN_MS=3000 DARSHAN_MOFKA_FLUSH_MS=3000`.

**Success criteria for the fix (arm 3):**
- No `drain join timed out; leaking producer+engine` message (i.e. `g_leak_engine` stays 0).
- `diaspora_producer_flush_timeout` returns OK (not TIMEOUT) at finalize.
- Wall time ≈ baseline (arm 3 close to arm 1; arm 2 much worse or wedged).
- CPU: check whether `cpu_self` drops toward `cpu_thread` (core reclaimed) — NOTE this may
  still NOT fully drop on CXI because CXI can't block-wait (progress spins regardless). If so,
  ALSO try `DARSHAN_MOFKA_MARGO_JSON` with a yielding progress ES; if that still spins on CXI
  (expected, since earlier `progress_timeout_ub_msec` had no effect), the core-peg is a CXI
  fabric limitation separate from the wedge — but the WEDGE and the wall overhead should be
  fixed by PRODUCER_THREADS=1 regardless.

## Important CXI-specific caveats
- CXI cannot block-wait (proven earlier: `progress_timeout_ub_msec` had zero effect). So a
  yielding progress ES may not reclaim the core on CXI. The ThreadPool(1) fix targets the
  WEDGE + serialization, which is fabric-independent — that should improve CXI wall time even
  if the core stays warm. Measure both.
- Keep `DARSHAN_MOFKA_FAST_EXIT=1` on CXI — the mercury teardown deadlock is worse there.
- CXI is 1-rank/node only for streaming (existing gate). Multi-rank uses ofi+tcp.

## Branching plan
- Develop the fix on a branch (e.g. `fix/producer-threadpool`) off the current tree.
- Polaris: create/check out the same branch, `SKIP_BUILD=0` for the first run (the shim
  gained a new symbol `diaspora_producer_create_ex` — MUST rebuild diaspora-stream-api AND
  the darshan connector; a header-existence guard will skip it, so force the diaspora rebuild).
- Report back: arm2 vs arm3 wall, wedge/no-wedge, CPU ratio, flush OK/TIMEOUT. We merge once
  both LCRC (tcp/verbs) and Polaris (cxi) confirm the wedge is gone.

## Open questions for coordination
1. On CXI does PRODUCER_THREADS=1 alone stop the wedge AND recover wall? (LCRC will confirm on tcp.)
2. Does the core stay pegged on CXI even after the fix (fabric limitation) — and is that
   acceptable if wall is recovered, or do we still want cpubind as a CXI-only add-on?
3. Batching: connector defaults to Adaptive (~1 RPC/event). Consider `DARSHAN_MOFKA_BATCH=N`
   + periodic flush if RPC count shows as a cost (likely minor at 1-3 evt/s).
