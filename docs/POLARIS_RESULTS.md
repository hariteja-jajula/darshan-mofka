# darshan-mofka Polaris results (polaris-verify branch)

All runs on ALCF Polaris, account radix-io, debug queue, 1 node unless noted.
Authoritative log for each run is the PBS `.oNNNN` file (archived per results dir).

## e2e reproducibility (single node)

| job | what | result |
|---|---|---|
| 7273369 | e2e with explicit `--polaris` | INGEST: PASS, 13 docs, modules={POSIX:4,STDIO:9}, reconstructed OPENS match native (overlay/unknown mount diff only) |
| 7273397 | e2e config-driven (no flag, `cluster: polaris`) | INGEST: PASS — proves the config knob drives the pipeline |

## Arm 1 — connector overhead (job 7273451, exit 0, 19s)

Workload: `mofka_forward_loop` 1 file × 8000 writes × 4096 B (~8006 events).
Baseline = `env -u DARSHAN_MOFKA_ENABLE` (native Darshan, connector OFF, because
DARSHAN_MOFKA_ENABLE is a getenv presence-check). mofka = connector ON. N=3 interleaved.

- baseline wall: mean 0.0494 s (stddev 0.0031)
- mofka wall:    mean 0.4959 s (stddev 0.0050)
- **overhead: +0.447 s absolute; +904 %** on this deliberately event-heavy / IO-light microbench
- **per-push latency: mean 32.3 µs, p50 22.0 µs, p99 ~80–90 µs** (the transferable number)
- throughput: ~16,000 events/s; init ~56 ms; finalize (batch drain) ~97–106 ms
- baseline validity: 14 native `.darshan` logs written; all 3 mofka reps HEALTH=PASS

**Read honestly:** 904 % is the per-event cost isolated by a microbench that does
almost no real I/O (8000 tiny tmpfs writes take ~0.05 s, streaming their events
takes ~0.45 s). It is NOT a realistic whole-application overhead — it is the price
of streaming every event with no aggregation. The ~32 µs/push figure is the one
that transfers; a real workload's overhead depends on its event rate. Matches the
historical producer-side cost model (~15–52 µs/event).

## Arm 2 — partition-count throughput curve (job 7273454, exit 0)

Workload: `mofka_forward_loop` 1×50000×4096 (~50006 events), 3 reps per cell.
Single producer, LOOSE ordering (spreads events across partitions).

**memory partitions (all HEALTH=PASS):**

| parts | thr evt/s | push_mean µs | p50 µs | p99 µs | finalize µs |
|---|---|---|---|---|---|
| 1 | 20,353 | 32.6 | 22.2 | 89.9 | ~100k–412k |
| 2 | 21,473 | 38.2 | 34.9 | 68.5 | ~6–9 |
| 4 | 20,849 | 39.3 | 38.9 | 66.4 | ~14–21 |
| 8 | 20,716 | 39.7 | 40.5 | 65.9 | ~15–23 |

**Findings:**
1. **Throughput is flat (~20–21k evt/s) across 1→8 partitions.** Memory-backed
   partitions are enqueue-bound on a *single* producer's send path — adding
   partitions does not raise aggregate throughput because the bottleneck is the
   producer, not per-partition write parallelism. (Matches the Mofka docs: one
   write-loop ULT per partition helps *multi*-producer / on-disk fan-out, not a
   single in-memory producer.) p50 rises slightly (routing overhead) while p99
   *falls* (tail spread across partitions).
2. **Finalize (drain) time collapses from ~100–412 ms at 1 partition to ~6–23 µs
   at ≥2 partitions.** With 1 partition the whole batch drains through one
   write-loop at finalize; with ≥2 the events overlap-drain during the run so
   finalize is trivial. n_send=50006 in every case (no producer-side loss).

**default (persistent) partitions: HEALTH=FAIL, all 12 runs.** Every push errored
with `PartitionSelector has no target to select from`; broker log:
`Could not create partition ... DefaultPartitionManager JSON validation`. The
`default` manager needs an explicit abt-io/data target that `start_server.sh`'s
bare `mofkactl partition add --type default` does not supply. The `default`
throughput numbers in partcurve_result.txt are therefore meaningless (flagged
FAIL). **The health gate correctly caught this** — n_send was still 50006, so a
send-count gate would have falsely passed it. Fixing the `default` arm needs the
partition-add to pass an abt-io instance (`--abt-io`) or a partition path; logged
as a follow-up.

## Arm 3 — 2-node MPI broker ingest proof (job 7273475, exit 0, 51s) — PASS

Stood up bedrock across **2 nodes** (`x3001c0s19b0n0` + `x3001c0s19b1n0`) via flock
`bootstrap:mpi` (bedrock-config.mpi.json, master DB gated to rank 0), launched with
PALS `mpiexec --ppn 1` from `server/start_server.mpi.sh`.

- **2-member group formed** (2 distinct addresses in mofka.json) — the MPI bootstrap
  works with the spack-built bedrock (linked to cray-mpich 8.1.28, ABI clean).
- 2 memory partitions added round-robin (one per rank).
- Ran the proven smoke workload + FlowCept consumer against the multi-node broker:
  13 sends → `tasks total=13 darshan=13 modules={POSIX:4, STDIO:9}` → **INGEST: PASS**.

**This proves the full Darshan→Mofka→FlowCept→Mongo pipeline works end-to-end
against a genuine multi-node MPI-bootstrapped broker on Polaris**, not just the
single-node `bootstrap:self` case.

## Arm 3b — 2-node MPI throughput sweep (job 7274785, debug-scaling, PASS)

Loop workload (1×50000×4096, ~50k events) against the 2-node MPI broker, 3 reps:

| layout | members | median thr | p50 | p99 |
|---|---|---|---|---|
| 1 partition | 2 nodes | 18,992 evt/s | 21.9 µs | 87.4 µs |
| 2 partitions (one per rank) | 2 nodes | 19,037 evt/s | 22.6 µs | 88.7 µs |

**Finding: throughput is flat (~19k evt/s) across the 2-node broker too**, and
marginally below the single-node ~20k (cross-node network hop). Same conclusion as
the single-node partition curve: a *single* producer is enqueue-bound on its own
send path, so spreading partitions across a second node does not raise aggregate
throughput. Raising throughput would require *multiple concurrent producers* (many
ranks each with the connector), which is the real next experiment.

## Budget

All jobs charged `radix-io` (debug + debug-scaling). Total real node-hours ≈ 0.15
(e2e ×2 + overhead + partition curve + from-scratch e2e on 1 node; MPI proof +
throughput sweep on 2 nodes — each 19s–3min). Far under the ~100 NH available.
