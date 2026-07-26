# workloads/

Workloads that exercise the Darshan→Mofka connector, plus the runner that drives the
whole pipeline. It is config-driven: edit a config file, then submit one command.

- [`workload.config`](workload.config) — pick the workload, its size, and the topology
  (nodes / tasks / placement / brokers). This is where you say what to run and where.
- [`job.sh`](job.sh) — the runner. Reads `workload.config` + `../server/server.config`,
  stands up the broker + FlowCept consumer for the topology, runs the workload, reconstructs
  the `.darshan` log from the stream, and compares it to the native log.

## The workloads

| Workload | Directory | Exercises |
|---|---|---|
| C (non-MPI) | [`c/`](c/README.md) | POSIX + STDIO (models an ML train loop: writes per epoch, STDIO checkpoints) |
| python-ml | [`python-ml/`](python-ml/README.md) | POSIX + STDIO from a small ML-style train/eval |
| MPI-IO | [`mpi/`](c/README.md) | MPIIO module (real MPI job) |
| DLIO | [`dlio/`](dlio/README.md) | POSIX via a realistic DL I/O benchmark (optional) |

## 1. Pick what to run — `workload.config`

For a first run you usually only touch this file (and your PBS account); the rest
have sensible defaults.

```yaml
workload: c            # c | python-ml | mpi
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

Size is controlled by `events` + `checkpoints` (no wall-clock knob) — the C workload
prints the exact event count before it runs. Any config key can be overridden for one
run with an env var of the same UPPERCASE name (e.g. `EVENTS=50000 bash submit.sh`).

## 2. Tune how it streams (optional)

Config is split by role, so the rest is grouped where it belongs. You rarely need
these for a first run:

- `workloads/workload.config` (producer) — also holds `connector:` (batch, flush_ms, …)
  and `darshan:` env (modmem, module enable/disable), since those run on the workload node.
- `server/server.config` (broker) — transport, topic, partitions, partition_type, and
  `broker:` margo threads / master DB.
- `Client/client.config` (consumer + sink) — the MongoDB `mongo:` settings and the
  FlowCept `consumer:` buffers.

## 3. Submit

```bash
PBS_ACCOUNT=radix-io bash submit.sh                 # sizes the allocation from topology.nodes + pbs.*
SKIP_BUILD=1 PBS_ACCOUNT=radix-io bash submit.sh    # reuse an existing build (faster)
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
