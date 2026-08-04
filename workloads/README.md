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

## Verify fidelity (optional 5th step) — reconstruct + compare

`run_producer.sh` keeps the native log in `server/_demo_native/` (it prints the path).
The consumer leaves mongod up so you can export the streamed events, RECONSTRUCT a
`.darshan` from them, and compare it counter-for-counter to the native log:

    # 1. export the streamed events from mongo (same login node as the consumer)
    install/_venv/bin/python3 Client/export_jsonl.py 127.0.0.1 darshan_stream \
      --mongo-port 27099 > events.jsonl

    # 2. RECONSTRUCT a .darshan from the stream (darshan-mofka-reconstruct <events> <outdir>)
    darshan/darshan-util/install/bin/darshan-mofka-reconstruct events.jsonl server/_demo_streamed/

    # 3. compare reconstructed vs native, counter-for-counter
    install/_venv/bin/python3 workloads/strict_compare.py \
      server/_demo_streamed server/_demo_native perproc
    # -> VERDICT: PASS  (every streamed integer counter matches native)

This is the reconstruct step the automated `job.sh` also runs (job.sh:259). To eyeball them
as HTML instead, see "Compare native vs streamed .darshan with pydarshan" below and point it
at `server/_demo_native` + `server/_demo_streamed`.

## Compare native vs streamed .darshan with pydarshan (HTML reports)

Any streaming run leaves two logs to compare side-by-side:
- `native/*.darshan`   — the log Darshan wrote directly (ground truth)
- `streamed/*.darshan` — the log rebuilt from the Mofka stream (`darshan-mofka-reconstruct`)

Generate a pydarshan HTML report for each and open them next to each other. pydarshan needs
the util lib on `LD_LIBRARY_PATH`, and the `.darshan` files are read-only so copy them to a
writable dir first (`-m darshan summary` writes `<name>_report.html` beside the input):

    cd <repo-root>
    export LD_LIBRARY_PATH="$PWD/darshan/darshan-util/install/lib:$LD_LIBRARY_PATH"
    PY="$PWD/install/_venv/bin/python3"

    # pick a completed streaming run (has both native/ and streamed/)
    RUN=results/PAPER_iobench/streaming_rep1/RUN1        # or any results/<study>/streaming*/RUN*

    mkdir -p /tmp/darshan_cmp && cd /tmp/darshan_cmp
    cp "$OLDPWD/$RUN"/native/*.darshan   native.darshan   && chmod u+w native.darshan
    cp "$OLDPWD/$RUN"/streamed/*.darshan streamed.darshan && chmod u+w streamed.darshan

    "$PY" -m darshan summary native.darshan      # -> native_report.html
    "$PY" -m darshan summary streamed.darshan    # -> streamed_report.html

    ls -la native_report.html streamed_report.html   # open both in a browser to compare

The I/O counters (POSIX/STDIO/MPI-IO/HDF5) match exactly between the two. The HEATMAP/DXT
trace modules are NOT streamed by design, so those panels differ (native has them, streamed
does not) — that is expected, not data loss.

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
