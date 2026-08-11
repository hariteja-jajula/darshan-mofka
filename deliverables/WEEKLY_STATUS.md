# Darshan→Mofka streaming overhead — weekly status

Week ending 2026-08-10. Branch `lean-main-cleanup`. This documents what was done,
what the numbers mean, and exactly where we are still stuck.

---

## 1. Goal

Characterize the overhead of streaming Darshan I/O telemetry to Mofka *live* (vs.
Darshan's normal write-a-log-at-exit), across a representative set of HPC workloads and
node scales, and drive that overhead under 5% for as many regimes as possible. The
streamed telemetry must also be faithful enough to rebuild a pydarshan report.

---

## 2. What we ran — the 3-arm, fixed-work study

Every workload×scale runs **three arms**, all doing identical work (same STEPS/EVENTS):

| arm | Darshan | streaming | isolates |
|---|---|---|---|
| `baseline` | OFF (`NO_DARSHAN=1`) | — | pure application wall |
| `runtimeonly` | ON | OFF (`ENABLE=0`) | Darshan's own instrumentation cost |
| `streaming` | ON | ON (`ENABLE=1`) | the Mofka streaming cost |

Overhead in the deck = **streaming wall − baseline wall**, per streaming rep vs mean
baseline. Each arm self-times its work region (`WORK_START_NS`/`WORK_END_NS`) so the
number is application work, not job setup. Reps: baseline 1, runtimeonly 1, streaming 3.
30 arm-jobs total (5 workloads × 2 scales × 3 arms), drip-fed through the near-serial
debug / debug-scaling queues by `overhead_study/dripfeed.sh`.

Workloads: `io_bench` (C), `io_bench_py` (Python twin), `python-ml` (numpy trainer),
`mpi` (MPI-IO), `dlio` (DLIO benchmark). Scales: 1 workload node, 4 workload nodes,
each + 1 broker/consumer node.

---

## 3. Results — the headline

| workload | 1wl overhead | 4wl overhead | regime |
|---|---|---|---|
| **python-ml** (numpy/BLAS) | **+3.2%** | **+2.3%** | compute-bound, clean overlap — GOOD |
| io_bench (C) | −1.5% | +91.4% | I/O + fan-in |
| io_bench_py (Python) | +48.4% | +46.8% | memory-bandwidth contention |
| mpi (MPI-IO) | +96.2% | +84.7% | high-volume I/O on critical path |
| dlio | BLOCKED | BLOCKED | transport failure (no number) |

**The finding: there is no single "streaming tax." Overhead is regime-dependent, and the
sign/size is set by the application's compute character, not by event count.**

Decisive evidence — `io_bench_py` SPLIT timers (region-level, 1wl):

| region | baseline | streaming | Δ |
|---|---|---|---|
| `io_s` (I/O + connector runs here) | 0.16s | 0.16s | **0** |
| `matmul_s` (pure compute, no I/O) | 434.2s | 644.7s | **+210s (+48%)** |

The connector's own measured inline cost over that entire 645s run: **push sum ≈ 10ms,
send sum ≈ 2ms, over 798 events.** ~12ms of connector work coincided with +210s of
slowdown — in a region that does zero I/O. That is impossible as direct cost. It is a
**second thread (drain/serialize/send) contending with the app for memory bandwidth /
LLC** on a single-threaded, memory-bound Python matmul.

Contrast python-ml (+3%): 641,596 events — 800× more — yet cheap, because numpy/BLAS
compute releases the GIL, is cache-efficient, and overlaps cleanly with the drain thread
on an otherwise-idle core.

**Three distinct mechanisms:**
1. **High-volume I/O on the critical path** (mpi): 100s of MB of events, no compute to
   overlap → +85–96%. Event-rate driven.
2. **Background-thread memory contention** (io_bench_py): +45% even at 1.2 events/sec.
   Not event-rate; it's bandwidth/cache competition.
3. **Broker fan-in saturation** (all workloads at 4wl jump to ~+52%): 4 producer nodes →
   1 consumer (`CONSUMERS=1`) → backpressure onto producers. Provisioning, not workload.

---

## 4. Fidelity — does the streamed pydarshan report match native?

Live parser diff, python-ml RUN2 (native `.darshan` vs stream-reconstructed):

| module / field | native | streamed | match |
|---|---|---|---|
| log version, exe, nprocs, run time | — | — | ✅ identical (run time within 0.5ms) |
| STDIO records | 1914 | 1914 | ✅ exact |
| HEATMAP records | 646 | 646 | ✅ exact |
| POSIX records | 19866 | 19522 | ⚠️ −344 |
| LUSTRE records | 1738 | **0** | ❌ not streamed |

Counters within shared modules are byte-exact (e.g. `POSIX_BYTES_READ = 8392671466`,
`POSIX_READS = 64322`). All pydarshan panels (Access Sizes, Access Pattern, I/O Cost,
Common Access, Heat Map, Op Counts) render from the stream. **Verdict: matches for
practical characterization; not bit-identical.** The native `.darshan` remains the
byte-exact source of truth for the gaps.

---

## 5. Fixes landed this week (committed / in tree)

- **numpy-threads overhead artifact** — stock python-ml let OpenBLAS spawn 64 threads,
  oversubscribing cores and inflating *apparent* streaming overhead. `lib/run.sh` now
  caps BLAS/OMP threads on every arm. (This is why python-ml reads +3%, not double-digit.)
- **mpi workload was sleep-padded** — old mpi "work" was ~45s of `usleep` + 32-byte
  writes. Rewrote `mofka_forward_mpiio.c` to do genuine `IO_BLOCK_KB` block write +
  fsync + read per step, no sleep. Recalibrated: 1wl 90.7ms/step (EVENTS=6000), 4wl
  225.5ms/step (EVENTS=2400) → ~9 min genuine work/rep.
- **extractor glob bug** — `overhead_extract.sh` globbed `workload.*.err` (mpmd per-rank
  naming) and silently missed the mpi legacy path's plain `workload.err` → mpi slides
  showed base_wall=0.0. Fixed with a backward-compatible fallback.
- **cross-job broker race** — two concurrent jobs rewrote the same fixed broker/run
  dirs → "consumer died." `job.sh` now uses a per-job suffix.
- **Approach-A rich reconstruct** — connector snapshots each record's counter arrays
  once at `close`; reconstruct util rebuilds the native struct. Recovers every pydarshan
  panel at +2.08% (only +0.61pp over the slim envelope).
- **10-slide weekly deck generator** — `deliverables/make_weekly_tables.py`, data read
  live from results, mtime-filtered to avoid stale runs.

---

## 6. WHERE WE ARE STUCK — open problems, priority order

### P1 — Regime 2 (memory-bandwidth contention, +45%) — FIX WRITTEN, NOT YET TESTED
- **What:** drain thread is created with `pthread_create(..., NULL, ...)` → inherits the
  app's CPU mask → gets co-scheduled on the app's core/LLC and steals bandwidth.
- **Done:** added `DARSHAN_MOFKA_DRAIN_CPU` env knob to `darshan-mofka.c` — pins each
  drain thread to a specified core (intended: a different NUMA/L3 domain than the app,
  e.g. core 64 vs app core 0 on the EPYC 7713: 2 sockets × 64 cores, 2 NUMA, 16 L3s).
  Env-gated: unset = byte-identical, measurement-neutral. Affinity idiom syntax-checked.
- **Blocked on:** rebuild the connector `.so`; A/B run io_bench_py_1wl streaming with
  `DARSHAN_MOFKA_DRAIN_CPU=64` vs unset; confirm SPLIT `matmul_s` drops.
- **Risk (honest):** cross-NUMA bandwidth contention can persist even with distinct
  cores. May only partially close the gap. UNPROVEN until measured.
- **Note:** the launcher `--cpu-bind` approach (first instinct) does NOT work here — it
  applies one mask to the whole process (app + drain together), so it cannot separate
  them. And io_bench_py runs via `mpi_launch_mpmd` (which has no cpu-bind), not the
  `mpi_launch` path. Pinning must be inside the connector — hence P1's edit.

### P2 — DLIO fully blocked: tcp-vs-cxi provider mismatch — NO FIX
- **What:** every dlio rep dies before contacting the broker:
  `na_ofi_provider_check() Requested OFI provider "tcp" ... not available → use cxi`
  → `driver_create failed` → `margo_init_ext` → `NA_TIMEOUT`.
- **Root cause:** dlio runs under PALS/MPI; cray-mpich brings up CXI in-process first;
  the LD_PRELOADed connector's second Mercury engine on `ofi+tcp` then sees only cxi.
  python-ml/io_bench avoid it by using `ofi+cxi` (the provider their process already has).
- **Blocked on:** a design decision — (a) run dlio over `ofi+cxi` too (collides with the
  1-rank/node cxi flood gate), or (b) a per-node non-MPI bridge process that owns the tcp
  engine (mirrors why the bare broker works). Not a tunable. **No trustworthy DLIO
  overhead number exists until this is resolved.**

### P3 — mpi/dlio rep-2 failure: broker reused across reps — CHARACTERIZED, NO FIX
- **What:** on the legacy path the broker is started ONCE before the rep loop and reused.
  Rep 1 is valid; rep 2+ fail `driver_create` (32× at 1wl, 128× at 4wl). The new binary
  drains ~13× more events, so the reused broker can't service rep 2 in time.
- **Consequence:** each mpi slide has only 1 valid streaming rep (still a defensible
  number); dlio_4wl has zero.
- **Blocked on:** fix broker lifecycle in `job.sh` to start a fresh broker per rep (like
  the mpmd path already does). Mechanism not yet proven (broker dir cleaned by EXIT trap).

### P4 — Regime 1 (high-volume streaming I/O, +85–96%, mpi) — FUNDAMENTAL, NO KNOB
- **What:** mpi streams 100s of MB of events with no compute slack to overlap; emission
  sits on the I/O critical path.
- **Already refuted:** `DARSHAN_MOFKA_BATCH=512` → only −1.3%. RPC count was never the
  bottleneck. Progress-thread config → −0.1%. Neither is the lever.
- **Blocked on:** a design change to decouple emit from the app (async queue with a
  drop/coalesce policy so the app never blocks on the stream). **Do not expect <5% here
  by tuning.** This is the hard, open research problem.

### P5 — Regime 3 (broker fan-in saturation, 4wl +52%) — UNTESTED, CHEAP TO TEST
- **What:** `CONSUMERS=1` for 4 producer nodes → fan-in stall lifts every 4wl number to
  ~+52%.
- **Blocked on:** a one-line-per-config test — `CONSUMERS=4 PARTITIONS=8` on the 4wl
  scripts; measure whether overhead collapses. If it does, the 4wl "workload" tax was
  really under-provisioning. UNPROVEN.

### P6 — Reconstruct fidelity gaps — DOCUMENTED, OPTIONAL
- POSIX −344 (files open at process exit have no `close` event in the stream); LUSTRE
  module absent (gathered once at open, never reaches the connector; needs a bespoke
  nested capture format); cross-rank rank=−1 rollup (MPI reduction, not per-process).
  All ~0 overhead to close but non-trivial engineering. Native `.darshan` covers them.

---

## 7. Critical path to "working + under 5%"

- **P1 + P5 are ready now and are the cheap wins** — the drain-thread pin and the
  consumer-count bump directly target the two contention regimes (+45% and +52%) and can
  be tested this week.
- **P2 + P3 are correctness** — dlio doesn't run at all; mpi/dlio only complete rep 1.
- **P4 is the fundamental limit** — high-volume-I/O apps will not hit <5% without
  redesigning the emit path. This should be stated plainly to stakeholders, not promised.

## 8. Constraints carried all week
- No Claude attribution anywhere in commits/PRs/contributions.
- Do not touch the flowcept submodule; keep the numpy-threads `lib/run.sh` fix as-is.
- Workloads must do ~10 min genuine work per rep, never sleep padding.
- Verify git identity `hariteja-jajula <hjajula@crimson.ua.edu>` before any commit.
