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

---

# Manual demo (login node, no PBS) — run the pipeline by hand

For a live demo you can drive each role yourself instead of `job.sh`. This uses the
**legacy / TCP path** (the same one MPI/DLIO use): no `qsub`, no `mpiexec`, no CXI — it
runs entirely on a login node over `ofi+tcp`. Three roles, three terminals.

> **IMPORTANT: run all three terminals on the SAME login node** (the mongod + broker are
> local to that node). First, reset any leftover state:
>
>     bash server/reset_demo.sh

The three roles map to the pipeline:

    broker (Mofka/bedrock)  <--  producer (workload + LD_PRELOAD libdarshan)
             |
             v
        consumer (FlowCept + mongod)  -->  events.jsonl  -->  reconstruct  -->  compare vs native

## Terminal 1 — server (broker + darshan topic)

    cd <repo-root>
    bash server/start_server.sh          # ofi+tcp; creates server/mofka.json; LEAVE RUNNING

Starts `bedrock`, creates the `darshan` topic + a partition, and writes the group file
`server/mofka.json` (the address the other two roles connect to). It prints
`SERVER READY` and the broker endpoint. Ctrl-C stops the broker.
Knobs: `PROTOCOL=ofi+cxi` (on a compute node), `TOPIC=darshan`, `PARTITIONS=1`.

## Terminal 2 — consumer (FlowCept drains the topic into mongod)

    cd <repo-root>
    source env/server.sh                 # sets PY to the venv that has flowcept + mongod on PATH
    MOFKA_GROUP=$PWD/server/mofka.json TOPIC=darshan \
    MONGO_DB=darshan_stream MONGO_PORT=27099 \
      bash Client/capture_flowcept.sh    # LEAVE RUNNING; prints "consumer alive"

Subscribes to the `darshan` topic and writes every received event into mongod. Must be
started AFTER the server (it needs `server/mofka.json`). `TOPIC`/`MONGO_PORT` must match
what the producer/reconstruct use.

## Terminal 3 — producer (workload under the Darshan->Mofka connector)

    cd <repo-root>
    bash server/run_producer.sh io_bench        # or: io_bench_py | python-ml

Runs the workload with `LD_PRELOAD=libdarshan.so` and `DARSHAN_MOFKA_ENABLE=1`, so every
POSIX/STDIO op is streamed to the broker. You'll see `darshan-mofka[timing] send/push`
lines (the connector's per-event cost) and a clean `finalize`. It also writes a native
`.darshan` log to its scratch dir.
Knobs: `WL=io_bench_py`, `IO_ITERS=8`, `IO_SLEEP_MS=50`, `COMPUTE=2`, `MATRIX_SIZE=128`.

## Finish + confirm capture (terminal 2)

Once the producer is done, flush the consumer and land everything in mongo:

    touch server/_flowcept_run/SHUTDOWN

The consumer flushes, prints the ingest verdict, and exits cleanly, e.g.:

    tasks total=63  darshan=63  modules={'POSIX': 52, 'STDIO': 10}
    INGEST: PASS

That `INGEST: PASS` (darshan count == events produced) is the proof the full pipeline
worked: producer -> broker -> consumer -> mongo, lossless.

## Verify fidelity (optional 5th step)

The consumer leaves mongod up so you can export the events, then rebuild a `.darshan` from
the stream and compare it, counter-for-counter, to the native log:

    install/_venv/bin/python3 Client/export_jsonl.py 127.0.0.1 darshan_stream \
      --mongo-port 27099 > events.jsonl

    B=darshan/darshan-util/install/bin
    $B/darshan-mofka-reconstruct <path>/events.jsonl streamed/     # rebuild from the stream
    # put the producer's native *.darshan into native/, then:
    install/_venv/bin/python3 workloads/strict_compare.py streamed native perproc
    # -> VERDICT: PASS  (every streamed integer counter matches native)

## If the manual steps break — one-shot fallback

The whole pipeline (broker + consumer + producer + reconstruct + compare) in ONE command,
on one node over TCP, no PBS:

    RESULTS_TAG=demo MOFKA_PROTOCOL=ofi+tcp WORKLOAD=io_bench \
    NODES=1 TASKS=1 REPS=1 EVENTS=100 \
      bash workloads/job.sh

Results land in `results/demo/RUN1/` (events.jsonl, streamed/, native/, compare.txt).

## Notes
- **TCP vs CXI:** login node = `ofi+tcp` (works anywhere). A compute node with Slingshot can
  use `PROTOCOL=ofi+cxi`. MPI-IO must use TCP (MPI_Init is incompatible with the CXI MPMD launch).
- **The fix knob:** `DIASPORA_C_SENDER_THREADS=1` (set by default in `run_producer.sh`) runs the
  producer's sender on a dedicated Argobots ES (ABT-safe push) — this is the connector fix.
- **What each role needs:** producer needs `server/mofka.json` + `libdarshan.so`; consumer needs
  `server/mofka.json` + mongod (bundled at `server/_mongo_env/bin/mongod`) + the flowcept venv
  (from `source env/server.sh`).
