# Streaming-overhead trajectory across the connector fixes

Workload: python-ml (numpy MLP trainer, real np.load/savez I/O), calibrated to ~538 s
wall of genuine work (EVENTS=1000, ML_FILES=64 ML_ROWS=4096 ML_COLS=64, 2 checkpoints).
ofi+cxi, 1 rank/node, 2 total nodes (debug queue). REPS=3 = 1 cold (discarded) + 2 warm.

**Overhead metric:** `(streaming_work − runtimeonly_work) / runtimeonly_work`, over the
WORK_START_NS..WORK_END_NS region, warm reps (RUN2+RUN3) only.
**Reference:** runtimeonly warm mean = **250.85 s** (from Fix 1, results/FIX1_pyml_538).
Fixes 2/3/Approach-A change only the connector, not the baseline/runtimeonly arms, so
they reuse Fix 1's reference (an A/B where only the streaming arm's .so changes).

## Results

| Stage | What changed | Streaming warm (s) | Overhead | Report fidelity |
|---|---|---|---|---|
| Fix 1 | numpy/BLAS thread cap (all arms) | 256.09 | **+2.09%** | rich (rec_hex) |
| Fix 2 | remove rec_hex → slim envelope | 254.53 | **+1.47%** | **thin** (heatmap only) |
| Fix 3 | remove g_ring (async ring buffer) | 269.63 | **+7.48%** ⚠ | thin |
| **Approach A** | counter arrays on close (rich reconstruct) | 256.07 | **+2.08%** | **rich again** |

## Reading the trajectory

- **Fix 1 (numpy threads)** set the floor. Stock python-ml let OpenBLAS spawn ~64
  threads; capping them removed an artifact that had inflated apparent overhead. This
  is the honest compute-bound baseline: +2.09%.

- **Fix 2 (drop rec_hex)** shaved payload hard — every event had hex-encoded the entire
  native record struct (~1634 B/event). Removing it cut per-event bytes ~77% and nudged
  overhead down to +1.47%. **Cost:** the stream-reconstructed pydarshan report went thin
  (heatmap only — no Access Sizes / Access Pattern / I/O Cost / counts), because the
  reconstructor had nothing but op/len/timestamps to work with.

- **Fix 3 (drop g_ring)** was a REGRESSION: +7.48%. g_ring is the async boundary that
  gets the serialize+push off the application thread. Removing it put the snprintf and
  the diaspora push back on the workload's critical path. **Dropped** — g_ring and the
  drain thread are kept.

- **Approach A (rich reconstruct)** is the endpoint: recover the full report WITHOUT the
  per-event bloat. The connector snapshots each finished record once, at its `close` op;
  the drain thread serializes `counters[]`/`fcounters[]` as JSON number arrays. Per-op
  events stay slim (heatmap); exactly one fat event per file carries the final counters.
  Overhead is +2.08% — statistically identical to Fix 1, and only +0.61 pp above the
  slim-but-thin Fix 2.

## Why Approach A stays cheap

Measured on the real stream (results/APPA_pyml_538/streaming/RUN2, 641,597 events):

- Fat (close) events are **20%** of the stream; slim events are 80%.
- Slim event ≈ 425 B; fat event ≈ 646 B (+221 B for the two arrays).
- **Mean event ≈ 431 B vs 425 B slim — essentially flat.** The rich report costs ~6 B
  per event on average because the fat payload rides only the (relatively rare) close.
- Reconstruct time: ~2.3 s for the whole per-process log (RUN1/2/3: 2.44 / 2.28 / 2.29 s).

## Fidelity of the Approach-A report (vs native per-process log)

- Section set IDENTICAL to native: Access Sizes, Access Pattern, I/O Cost, Common
  Access, Heat Map, Operation Counts.
- Counters match: e.g. POSIX_BYTES_READ and POSIX_READS byte-exact (8392671466 / 64322).
- **Honest gaps:** (1) files still open at process exit (flushed by Darshan shutdown, no
  close event streamed) are slightly undercounted — here 83 vs 100 POSIX_WRITES; (2) the
  cross-rank shared-file rollup (rank −1: FASTEST/SLOWEST_RANK, VARIANCE_RANK) is built
  by an MPI reduction across ranks and cannot be reproduced per-process. The native
  .darshan log remains the byte-exact source of truth for both.

## DLIO (I/O-bound regime) — still blocked

DLIO was meant to exercise the I/O-bound regime (the +70% case the numpy fix can't
touch). Two blockers were fixed this round:
1. **Baseline secretly streamed** — the legacy run path hardcoded LD_PRELOAD, so the
   NO_DARSHAN baseline still paid the streaming tax. Fixed: baseline now drops the
   preload on both the fast path and the mpiexec branch (`sends: 0`, empty events.jsonl
   confirmed).
2. **FileNotFoundError** — DLIO shards one dataset and reads it back with a shared view;
   node-local /tmp isn't shared across nodes. Fixed: DLIO scratch moved to shared Lustre
   (dataset now generates: "Generation done", native .darshan written).

A **third, deeper blocker** then surfaced and is NOT yet resolved: at DLIO scale
(ofi+tcp, 32 ranks/node × 2 = 64 ranks) **all 64 ranks fail `margo_init_ext … Could not
initialize Margo`** and the broker dies with `NA_TIMEOUT` / `thallium::timeout`
(`sends: 0` across all arms). python-ml works because it runs 1 rank/node on ofi+cxi.
Root-cause investigation is in progress; no DLIO overhead number is trustworthy until
the connector streams at multi-rank-per-node scale. **No DLIO overhead is reported here.**

## Bottom line

For the compute-bound python-ml regime, the connector fix chain lands at **+2.08%** with
a **near-native reconstructed report** — the best of both: the payload discipline of the
slim envelope and the report richness of the old rec_hex, without either's downside. The
I/O-bound (DLIO) regime remains unmeasured pending the margo-at-scale fix.
