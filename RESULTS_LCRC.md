# LCRC/Improv results (updated 2026-07-25)

All runs on Improv, account `radix-io`, `debug` queue. No SSH anywhere: remote ranks
are launched through the PBS `tm` launcher of the system Open MPI
(`--with-tm=/opt/pbs`, a spack `external`/`buildable:false` in
`server/spack/spack-lcrc.yaml`).

Transport is **verbs** (InfiniBand, `mlx5_0`). It is the working default: it scales
to full-node multi-process, whereas tcp caps at ~2 producers/node (see §4). A verbs
producer must name its local network domain via `MOFKA_NA_DOMAIN` — a connecting
client can't auto-select the domain the way a listening broker does. That is a patch
to Mofka's `MofkaDriver.cpp` that honors `MOFKA_NA_DOMAIN`.

## 1. Fidelity — single rank, verbs (verified 2026-07-25)

The reconstructed `.darshan` is compared against the workload's native Darshan log.

**C workload — byte-exact.** `darshan-parser` shows zero counter differences vs the
native log; pydarshan reports the counters identical. Ingest and the reconstruct
verdict both pass.

```text
INGEST: PASS
modules: {'POSIX': 4, 'STDIO': 9}
VERDICT: PASS
```

**python-ml workload — approximate, not exact.** The pipeline completes, but the
rebuilt log is missing records. Roughly 15 of the ~36 POSIX records are Python
interpreter-startup files (stdlib `.py`, `lib-dynload/*.so`, `<STDIN>`/`<STDERR>`)
opened during the connector's ~215 ms init window, before the producer is up. Their
per-op sends are no-ops at that point, so those records never reach the stream even
though Darshan records them in memory. They are present in the native log and absent
from the reconstruction. This is a missing-records gap, not a crash.

A finalize records-sweep (`DARSHAN_MOFKA_FINAL_SWEEP`, in the connector) was written
to close the gap by re-streaming every record's final struct at shutdown. It is
**disabled by default** because enabling it hangs python-ml at finalize: the sweep's
records are new async sends issued from the atexit/shutdown context, and Mofka's
producer sender loop runs on the margo progress pool, so a send RPC started as the
process winds down never progresses. A proper fix needs a Mofka-side change (run the
producer sender on a dedicated, non-progress pool). C is unaffected and never enables
the sweep.

## 2. Multi-node broker — PASS  (`study/mn_broker_lcrc.pbs`, job 7670184)

2 `bedrock` daemons, one per node, form a single flock group via `bootstrap:mpi`:

```text
launch used tm, no ssh
GO: 2-member MPI(tm) group across 2 nodes
bedrock @ 2 nodes
13 sends → tasks total=13 darshan=13 modules={POSIX:4, STDIO:9} → INGEST: PASS
```

## 3. Server/workload split — PASS  (`study/mn_split_lcrc.pbs`, job 7670194)

Broker + FlowCept consumer + mongod on the server node; the Darshan workload on a
separate node, streaming to it. Remote per-push ≈ co-located per-push: the connector
uses adaptive batching (fire-and-batch, non-blocking), so the producer does not block
on the network. A broker on every node buys ~nothing for the hot path here, so the
simpler **1 server + N workload nodes** deployment is the right default. Scale to
multiple brokers only when a single broker's ingest becomes the bottleneck at large N.

## 4. Producer attach — verbs scales, tcp caps low

**verbs (default).** With the producer's local domain named via `MOFKA_NA_DOMAIN`
(e.g. `mlx5_0`) and `MOFKA_CLIENT_MODE=1` (non-listening producer endpoint), ~128
producers attach per node. At 1 producer/node the attach rate stays 100% and scales
cleanly by adding nodes.

**tcp (earlier investigation, why it doesn't scale).** The single-node probe (N
producers on one node → one remote broker):

| N producers on one node | 1 | 2 | 4 | 8 | 16 | 32 |
|---|---|---|---|---|---|---|
| attached | 1 | 1 | 1 | 2 | 4 | 8 |
| attach rate | 100% | 50% | 25% | 25% | 25% | 25% |

tcp attaches cleanly only at 1 task/node, falls to 50% at 2, and hits a hard 25%
floor (attached ≈ N/4) beyond. A per-node local broker gives no benefit, so it is not
broker fan-in.

### Root cause and the fix

The failing ranks die in Mercury 2.4.1 `na_ofi`, not in Mofka:
`na_ofi.c:6268 na_ofi_msg_send() fi_senddata(... data=1) → -22 (EINVAL)` →
`mercury_core.c:4180 hg_core_forward_na()`. Traced through the stack:

1. The connector creates one Mofka producer per process, no per-node gating
   (`darshan-mofka.c` init runs in every rank).
2. Mofka's driver builds each producer's Thallium engine in `THALLIUM_SERVER_MODE`
   (a listener) by default; the engine cache is per-process, so N ranks/node means N
   listening `na_ofi` endpoints on one NIC.
3. Listener endpoints request 8× larger fabric queues (`na_ofi.c:3688-3709` sizes
   tx/rx at 4096 vs 512 for a client, special-cased to tcp and cxi). N endpoints × 8×
   queues exhausts per-NIC resources; the EINVAL surfaces from the lazy connect under
   the concurrent burst.

The fix has two parts, both applied in this repo's `MofkaDriver.cpp`:

- `MOFKA_CLIENT_MODE=1` builds the producer engine in `THALLIUM_CLIENT_MODE`. A
  producer only pushes, so it needn't listen; client endpoints are non-listening and
  512-deep, which stops many producers/node from exhausting the NIC's queues.
- `MOFKA_NA_DOMAIN` names the producer's local verbs domain so the connecting client
  can select it (otherwise verbs fails with `No provider found for "verbs;ofi_rxm" on
  domain "(null)"`).

With both, ~128 producers/node attach over verbs. A zero-rebuild mitigation that
confirms the queue-size mechanism on tcp is `NA_OFI_TX_SIZE=512 NA_OFI_RX_SIZE=512`.

## 5. Overhead

Per-event push cost is flat ~25 µs (p50) across every cell measured — 2 to 128
producers, smoke (~13 events) to sustained (~50k events), co-located or split — i.e.
it does not degrade under attach pressure. The connector's fixed costs are one-time:

| phase | cost |
|---|---|
| init (broker/topic/producer attach) | ~215–243 ms / rank |
| per-op push | ~25 µs (p50), flat to 128 producers/node |
| finalize (drain pending batches) | ~200–375 ms |

Read honestly: the per-event tax is tiny and stable, so a real long job's connector
cost is `events × ~25 µs`. Init and finalize are fixed and amortize toward zero on a
long-running job; the finalize term grows with the pending-batch backlog at shutdown.
The tiny smoke workloads finish in well under a second, so on those the fixed tax
dominates the percentages — not the per-event cost.

## 6. Drain

A single FlowCept consumer plus one mongod is the throughput ceiling under bursty,
high-volume streaming. The runner shards the drain: N FlowCept consumers each pin a
disjoint subset of Mofka partitions (`targets`) and all share one mongod. FlowCept
upserts on the unique `task_id` index, so overlapping or duplicate events collapse
and reconstruct reads a single collection — a mis-set shard just re-upserts, never
duplicates. Set `consumer.consumers` (`CONSUMERS`) with server `partitions ≥
consumers` to scale the pull.

Two ceilings to plan around:

- **Partitions must scale with concurrency.** `partitions=1` saturates around ~7
  producers / ~150k events. Use `partitions ≥ producers` for high fan-in.
- **Broker memory-partition shedding.** With `partition_type: memory`, large event
  counts (~800k, ~1.6 GB) exceed what the in-RAM partitions retain before the
  consumers drain them. Beyond ~½M events the durable path is `partition_type:
  default` (on-disk chunks) and/or more consumer shards.

## Workload knobs (C)

`workloads/workload.config` — two knobs, event count known ahead of time:

```text
epochs=8              # one POSIX write per epoch (train log)
checkpoint_every=4    # an STDIO checkpoint file every N epochs
# POSIX = epochs+2 ; STDIO = 3*(epochs/checkpoint_every) ; the workload prints the estimate
```

Override per-run with env `EPOCHS` / `CHECKPOINT_EVERY` (both set means an exact
count, no file read).

## Reproduce

The standalone `study/*.pbs` drivers have been folded into the one config-driven
runner (`workloads/job.sh`) + `submit.sh`; each result reproduces by passing the
topology/scale as env overrides (each is one PBS job):

```bash
cd /home/hjajula/repro-fromscratch/darshan-mofka
PBS_ACCOUNT=radix-io NODES=2 BROKERS=per-node bash submit.sh                              # §2 multi-node broker
PBS_ACCOUNT=radix-io NODES=2 PLACEMENT=separate bash submit.sh                            # §3 server/workload split
PBS_ACCOUNT=radix-io NODES=3 TASKS=2 PLACEMENT=separate EVENTS=20000 bash submit.sh       # §4 multi-node scaling
PBS_ACCOUNT=radix-io NODES=9 TASKS=2 PLACEMENT=separate PARTITIONS=8 EVENTS=50000 bash submit.sh  # §6 sharded drain
```

Each run lands in `results/C_<N>NODE_<P>PROC_<B>Broker-<placement>/RUN*/` with the
native and reconstructed `.darshan`, the streamed `events.jsonl`, the ingest verdict,
and the reconstruct diff.

Render native-vs-reconstructed HTML summaries (from a neutral dir so the repo
`darshan/` source doesn't shadow the pip package):

```bash
M=/home/hjajula/repro-fromscratch/darshan-mofka; U=$M/darshan/darshan-util/install
export PATH="$U/bin:$PATH" LD_LIBRARY_PATH="$U/lib:$LD_LIBRARY_PATH"
cd /tmp && $M/install/_venv/bin/python -m darshan summary <run>/native.darshan  --output <run>/native.html
cd /tmp && $M/install/_venv/bin/python -m darshan summary <run>/partial.darshan --output <run>/reconstructed.html
```
</content>
