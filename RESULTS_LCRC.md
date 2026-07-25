# LCRC/Improv multi-node + overhead results (updated 2026-07-25)

All runs on Improv, account `radix-io`, `debug` queue. No SSH anywhere: remote ranks
are launched through the PBS **`tm`** launcher of the **system** Open MPI
(`--with-tm=/opt/pbs`, a spack `external`/`buildable:false` in `server/spack/spack-lcrc.yaml`).
Transport = **tcp** (Improv compute nodes expose no usable OFI `verbs` domain).

## 1. Multi-node broker — PASS  (`study/mn_broker_lcrc.pbs`, job 7670184)

2 `bedrock` daemons, one per node, form a single flock group via `bootstrap:mpi`:

```
launch used tm, no ssh
GO: 2-member MPI(tm) group across 2 nodes
bedrock @ ofi+tcp://10.128.16.14  +  ofi+tcp://10.128.16.15
13 sends → tasks total=13 darshan=13 modules={POSIX:4, STDIO:9} → INGEST: PASS
```

## 2. Server/workload split — PASS  (`study/mn_split_lcrc.pbs`, job 7670194)

Broker + FlowCept consumer + mongod on the **server node**; the Darshan workload on a
**separate node**, streaming over tcp:

```
server=i001, workload=i002 (WORKLOAD_HOST=i002), no ssh
INGEST: PASS
avg_push (REMOTE, workload→server over tcp) = 38.7 µs   (vs ~37 µs co-located)
```

**Topology conclusion.** Remote per-push (~38.7 µs) ≈ co-located (~37 µs): the connector
uses Adaptive batching (fire-and-batch, non-blocking), so the producer does **not** block
on the network. A broker on every node buys ~nothing for the hot path here, so the simpler
**1 server + N workload nodes** deployment is the right default; scale to multiple brokers
only when a single broker's ingest becomes the bottleneck at large N.

## 3. Connector overhead study — complete  (`study/overhead_split_lcrc.pbs`, job 7670201)

Split topology (server=i001, workload=i002, tcp). 3 configs × 3 reps × 2 workloads.
`noinstr` = no Darshan; `baseline` = Darshan on, Mofka off; `mofka` = Darshan + streaming.

| workload | config | walltime mean ± sd (s) | connector adds |
|---|---|---|---|
| c | noinstr | 0.023 ± 0.011 | |
| c | baseline | 0.087 ± 0.003 | |
| c | mofka | 0.514 ± 0.090 | **+0.427 s (+490 % vs baseline)** |
| python-ml | noinstr | 0.093 ± 0.058 | |
| python-ml | baseline | 0.124 ± 0.001 | |
| python-ml | mofka | 0.485 ± 0.263 | **+0.361 s (+290 % vs baseline)** |

Connector's own phases (from `DARSHAN_MOFKA_TIMING`, mofka runs):

| workload | init | finalize (drain) | avg push |
|---|---|---|---|
| c | ~65 ms | ~361 ms | **42.9 µs** |
| python-ml | ~60 ms | ~289 ms | **42.8 µs** |

**Read honestly.** The per-event cost is **tiny and stable (~43 µs/push)**, independent of
workload and of node placement. The large percentages are **fixed one-time costs**: broker
connect/init (~60–65 ms) and the finalize drain of pending batches at shutdown
(~290–360 ms, high variance — e.g. python-ml finalize ranged 56–655 ms across reps). These
workloads finish in <0.13 s, so the fixed tax dwarfs them; on a real long-running HPC job
those costs amortize to ~0 and only the ~43 µs/push matters. The finalize variance is the
open robustness item (a longer/acknowledged final flush or a dropped-record counter).

## 4. Sustained per-push — steady state  (`study/overhead_split_lcrc.pbs` w/ EPOCHS, job 7670401)

C workload scaled to **50,000 epochs (~50,152 events)** via the config knobs, split topology:

| config | walltime mean ± sd (s) |
|---|---|
| c noinstr | 0.299 ± 0.004 |
| c baseline | 0.395 ± 0.007 |
| c mofka | 3.523 ± 0.346 |

Connector (mofka): init ~65 ms, **finalize (drain) ~600 ms**, **avg_push = 37.2 µs**, ≈14–16k events/s.

**Key finding:** the per-push cost is **~37 µs and does not degrade** from smoke (~13 events) to
sustained (~50k events) — it's a flat per-event tax, so a real long job's connector cost is
`events × ~37 µs`. The only load-dependent term is the **finalize drain** (~360 ms at smoke →
~600 ms at 50k), which scales with the pending-batch backlog at shutdown (robustness item G8).

## 5. Multi-node scaling, attach curve, and the drain ceiling (2026-07-25 campaign)

A chained campaign (`workloads/job.sh` per cell, dedicated-broker `separate` topology
unless noted) mapped how the pipeline scales. Two independent limits emerged — a
producer-side **attach cap** and a consumer-side **drain ceiling** — plus a flat per-event cost.

**Attach rate** (`attached` = connector `initialize` count; `requested` = tasks × workload-nodes):

| tasks/node | example | requested | attached | attach rate |
|---|---|---|---|---|
| 1 | 4 nodes / 8 nodes | 4 / 8 | 4 / 8 | **100%** |
| 2 | 3 / 5 / 9 nodes | 4 / 8 / 16 | 2 / 4 / 7 | **~50%** |
| 4–32 | 2 nodes, per-node broker | 8…64 | 2…16 | **25%** |

The cleanest measurement is the single-node probe (N producers on **one** node → one
remote broker):

| N producers on one node | 1 | 2 | 4 | 8 | 16 | 32 |
|---|---|---|---|---|---|---|
| attached | 1 | 1 | 1 | 2 | 4 | 8 |
| attach rate | 100% | 50% | 25% | 25% | 25% | 25% |

Improv over tcp attaches **cleanly only at 1 task/node**: it falls to 50% at 2 and a hard
25% floor (attached ≈ N/4) beyond. A per-node *local* broker gives no benefit (2n×4t still
25%), so it is not broker fan-in. Polaris's CXI fabric shows the *same* failure signature (`einval == 3·N`)
but a gentler slope (100% at 2/node, ~75% at 4–32) — pinning the root cause to **Mofka
client concurrency (upstream), not the transport**. Practical rule: **scale by nodes at
1 producer/node**; treat >1/node as an overhead-under-contention curve, not a clean config.

**Per-event push cost is flat ~24.5 µs (median)** across every cell — 2 to 16 producers,
10k to 400k events, co-located or split — i.e. it does not degrade under attach pressure.
Init ~60–120 ms/rank; finalize grows with the shutdown backlog.

**Drain ceiling — found and fixed.** A single FlowCept consumer + mongod caps throughput:

| topology | events | sent | exported | verdict |
|---|---|---|---|---|
| 8n × 1t (**pre-fix**) | 400k | 400,104 | **95,191** | MISMATCH (76% lost) |
| 9n × 2t, partitions=8 (**post-fix**) | 400k | 400,296 | **400,304** | **PASS** |

The loss was entirely consumer-side: `capture_flowcept.sh` rendered only 4 of the settings
placeholders (so `client.config`'s 1000-doc batches never applied), the mongo dbpath was on
GPFS, and the graceful stop was wrapped in `timeout 60` — truncating the final drain of a large
backlog. The minimal fix (render the buffer/flush knobs, node-local `/tmp` dbpath,
`timeout ${STOP_TIMEOUT:-600}`) took delivery from **24% → 100% at 400k**, no broker change needed.

## Workload knobs (C)

`workloads/workload.config` — two knobs, event count known ahead of time:

```
epochs=8              # one POSIX write per epoch (train log)
checkpoint_every=4    # an STDIO checkpoint file every N epochs
# POSIX = epochs+2 ; STDIO = 3*(epochs/checkpoint_every) ; the workload prints the estimate
```
Override per-run with env `EPOCHS` / `CHECKPOINT_EVERY` (both set ⇒ exact count, no file read).

## Reproduce

The standalone `study/*.pbs` drivers that produced §1–4 have been folded into the one
config-driven runner (`workloads/job.sh`) + `submit.sh`; every result reproduces by passing
the topology/scale as env overrides (each is one PBS job):

```bash
cd /home/hjajula/repro-fromscratch/darshan-mofka   # a checkout on the system-external-openmpi stack
PBS_ACCOUNT=radix-io NODES=2 BROKERS=per-node bash submit.sh                              # §1 multi-node broker
PBS_ACCOUNT=radix-io NODES=2 PLACEMENT=separate bash submit.sh                            # §2 server/workload split
PBS_ACCOUNT=radix-io NODES=3 TASKS=2 PLACEMENT=separate EVENTS=20000 bash submit.sh       # §5 multi-node scaling
PBS_ACCOUNT=radix-io NODES=9 TASKS=2 PLACEMENT=separate PARTITIONS=8 EVENTS=50000 bash submit.sh  # §5 400k drain
```

Each run lands in `results/C_<N>NODE_<P>PROC_<B>Broker-<placement>/RUN*/` with the native and
reconstructed `.darshan`, the streamed `events.jsonl`, the ingest verdict, and the reconstruct diff.

Validate reconstruct.c 1:1 (native vs reconstructed HTML, from a neutral dir to avoid the
repo `darshan/` source shadowing the pip package):

```bash
M=/gpfs/fs1/home/hjajula/darshan-mofka-flowcept/darshan-mofka; U=$M/darshan/darshan-util/install
export PATH="$U/bin:$PATH" LD_LIBRARY_PATH="$U/lib:$LD_LIBRARY_PATH"
cd /tmp && $M/install/_venv/bin/python -m darshan summary <run>/native.darshan  --output <run>/native.html
cd /tmp && $M/install/_venv/bin/python -m darshan summary <run>/partial.darshan --output <run>/reconstructed.html
# already generated for C_1NODE_1PROC_1Broker-colocated/RUN1 and PYTHONML_.../RUN1
```
