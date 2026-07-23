# How to run

The whole pipeline is config-driven: you edit **two files**, then submit one command.
Nothing else needs touching.

```
program does I/O ─▶ Darshan (LD_PRELOAD) ─▶ Mofka broker ─▶ FlowCept ─▶ MongoDB
                                                                          │
                       reconstruct a .darshan log from the stream ◀───────┘
                       and compare it 1:1 to the real (native) log
```

## 1. Pick what to run — `workloads/workload.config`

```yaml
workload: c            # c | python-ml
events: 8              # scale: training steps / write-events
checkpoints: 2         # number of checkpoints across the run
reps: 1                # repeat the run N times

topology:
  nodes: 1             # nodes to request
  tasks: 1             # workload processes / MPI ranks
  placement: colocated # colocated (workload shares a broker node) | separate (own node)
  brokers: 1           # 1 (single broker) | per-node (one broker per node)

pbs:                   # how the job is submitted
  account: radix-io
  queue: debug
  walltime: "00:30:00"
  ncpus: 32
```

## 2. Tune how it streams (optional) — two more config files

Config is split by role; you rarely need these for a first run:
- **`workloads/workload.config`** (producer) — also holds `connector:` (batch, flush_ms, …)
  and `darshan:` env (modmem, module enable/disable), since those run on the workload node.
- **`server/server.config`** (broker) — transport, topic, partitions, partition_type, and
  `broker:` margo threads / master DB.
- **`Client/client.config`** (consumer + sink) — the MongoDB `mongo:` settings and the
  FlowCept `consumer:` buffers.

## 3. Submit

```bash
PBS_ACCOUNT=radix-io bash submit.sh          # sizes the allocation from topology.nodes + pbs.*
SKIP_BUILD=1 PBS_ACCOUNT=radix-io bash submit.sh   # reuse an existing build (faster)
```

`submit.sh` reads the node count and PBS settings from the config and launches
`workloads/job.sh`, which stands up the broker + consumer for your topology, runs the
workload, reconstructs the log, and compares it to the native one.

## 4. Read the output — `results/<TAG>_<N>NODE_<P>PROC_<B>Broker-<placement>/RUN<n>/`

The folder name is derived from your topology, so runs are self-describing. Inside each `RUN<n>`:

| file | what it is |
|---|---|
| `events.jsonl` | the Darshan events that were streamed |
| `native.darshan` / `partial.darshan` | the real log vs. the one rebuilt from the stream |
| `native_report.html` / `*.html` | pydarshan reports (open to eyeball) |
| `compare.txt` | `VERDICT: PASS` if the rebuilt log matches the native op-counts |
| `workload.out` / `workload.err` | workload output + connector timing |
| `ingest.txt` | `INGEST: PASS` and the streamed event count |

The job also prints the resolved run up front (`run: … topology: … stream: …`) so you can
confirm your config took effect, and the PBS console log is `results/<jobid>.imgt1.OU`.

## Examples (just change the config)

- **Single node** (default): `nodes: 1, placement: colocated, brokers: 1`.
- **Server + workload split**: `nodes: 2, placement: separate, brokers: 1` — broker on one
  node, workload on the other.
- **Broker per node**: `nodes: 2, placement: colocated, brokers: per-node` — one broker per
  node (MPI-bootstrapped), no ssh.
- **Bigger run**: raise `events` (e.g. `50000`); the workload prints the event count up front.
