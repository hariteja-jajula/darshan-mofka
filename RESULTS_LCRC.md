# LCRC/Improv multi-node + overhead results (2026-07-23)

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

## Workload knobs (C)

`workloads/workload.config` — two knobs, event count known ahead of time:

```
epochs=8              # one POSIX write per epoch (train log)
checkpoint_every=4    # an STDIO checkpoint file every N epochs
# POSIX = epochs+2 ; STDIO = 3*(epochs/checkpoint_every) ; the workload prints the estimate
```
Override per-run with env `EPOCHS` / `CHECKPOINT_EVERY` (both set ⇒ exact count, no file read).

## Reproduce

```bash
R=/home/hjajula/repro-fromscratch/darshan-mofka   # a checkout on the system-external-openmpi stack
qsub -A radix-io -v REPO=$R study/mn_broker_lcrc.pbs       # multi-node broker + ingest
qsub -A radix-io -v REPO=$R study/mn_split_lcrc.pbs        # server/workload split + ingest
qsub -A radix-io -v REPO=$R study/overhead_split_lcrc.pbs  # overhead study (default 8 epochs)
qsub -A radix-io -v REPO=$R,EPOCHS=50000,CHECKPOINT_EVERY=1000 study/overhead_split_lcrc.pbs  # sustained
```

Validate reconstruct.c 1:1 (native vs reconstructed HTML, from a neutral dir to avoid the
repo `darshan/` source shadowing the pip package):

```bash
M=/gpfs/fs1/home/hjajula/darshan-mofka-flowcept/darshan-mofka; U=$M/darshan/darshan-util/install
export PATH="$U/bin:$PATH" LD_LIBRARY_PATH="$U/lib:$LD_LIBRARY_PATH"
cd /tmp && $M/install/_venv/bin/python -m darshan summary <run>/native.darshan  --output <run>/native.html
cd /tmp && $M/install/_venv/bin/python -m darshan summary <run>/partial.darshan --output <run>/reconstructed.html
# already generated for C_1NODE_1PROC_1Broker-colocated/RUN1 and PYTHONML_.../RUN1
```
