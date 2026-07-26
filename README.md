# darshan-mofka

Stream Darshan's I/O events out of a running job, live, into Mofka.

## Why

Darshan writes its log file once, at the very end of a job. If the job crashes or
is killed first, that log is never written and you lose all the I/O profiling for
the run.

This project adds a connector to Darshan that sends each I/O event to a
[Mofka](https://mofka.readthedocs.io) message stream as it happens. A consumer
saves those events, and a tool rebuilds a `.darshan` log from them. So even if the
job dies early, you still have the I/O record up to the moment it stopped.

## How it fits together

```text
  your program
      │  (Darshan intercepts open/read/write/close)
      ▼
  Darshan + Mofka connector ──► Mofka broker ──► FlowCept consumer ──► MongoDB
                                                                          │
                                                          export to JSON  ▼
                                                                    events.jsonl
                                                                          │
                                                        darshan-mofka-reconstruct
                                                                          ▼
                                                                     .darshan log
```

The connector (`darshan/darshan-runtime/lib/darshan-mofka.c`, loaded via
`LD_PRELOAD`) is the part meant to go upstream into Darshan. Everything else in this
repo is the harness that runs it and checks it against native Darshan.

## Quick start

First see what you already have (this downloads nothing):

```bash
bash check-deps.sh
```

If anything is missing, build it all from source with one command (run on a login
node; it has internet):

```bash
DARSHAN_MOFKA_PROFILE=lcrc bash install/setup.sh
```

Then run the whole pipeline on a compute node and check the result:

```bash
PBS_ACCOUNT=<your_project> bash submit.sh
```

See [REPRODUCE.md](REPRODUCE.md) for the exact expected output.

## Results

Verified on LCRC/Improv, 2026-07-25, single rank, verbs transport.

- **C workload — byte-exact.** The rebuilt log matches the native one exactly:
  `darshan-parser` reports zero counter differences, and pydarshan reports the
  counters identical. Ingest and the reconstruct verdict both pass.
- **python-ml workload — approximate.** The pipeline completes, but the rebuilt log
  is missing records, not counter-exact. Roughly 15 of ~36 POSIX records are Python
  interpreter-startup files (stdlib `.py`, `lib-dynload/*.so`, `<STDIN>`/`<STDERR>`)
  opened during the connector's ~215 ms init window, before the producer is up.
  Their per-op sends are no-ops at that point, so those records never reach the
  stream even though Darshan records them in memory. They appear in the native log
  but not in the reconstruction. See [RESULTS_LCRC.md](RESULTS_LCRC.md) for the
  detail and the disabled workaround.
- **Scaling.** Over verbs (InfiniBand, `mlx5_0`) with the producer's local domain
  named via `MOFKA_NA_DOMAIN` and `MOFKA_CLIENT_MODE=1`, ~128 producers attach per
  node. tcp caps at ~2 producers per node. See RESULTS for the attach curve and
  root cause.
- **Cost.** Steady-state the connector adds ~25 µs per I/O event (p50), flat out to
  128 producers/node. Init is ~0.22–0.24 s per rank (one-time) and finalize is
  ~0.2–0.38 s.

See [RESULTS_LCRC.md](RESULTS_LCRC.md) for the full topology and overhead numbers.

## What's in here

```text
darshan/              Darshan, with the Mofka connector (the part bound for upstream)
diaspora-stream-api/  the C streaming API the connector uses
flowcept/             the consumer that drains the stream into MongoDB
env/                  environment setup (server side and workload side)
server/               start/stop the Mofka broker
Client/               the FlowCept consumer and the export-to-JSON tool
Database/             get a local MongoDB
workloads/            the workloads (C, MPI-IO, DLIO, python-ml) and job.sh, the runner
install/              one-command setup that builds everything
submit.sh             size a PBS allocation from the config and run workloads/job.sh on it
results/              one folder per run, with all its output
```

Each folder has its own README with the details.

## Connector environment variables

Set these in the environment of the Darshan-instrumented program. The connector
reads:

| Variable | What it does | Default |
|---|---|---|
| `DARSHAN_MOFKA_ENABLE` | Turn streaming on | off |
| `DARSHAN_MOFKA_GROUP_FILE` | The broker's group file (`server/mofka.json`) | required |
| `DARSHAN_MOFKA_TOPIC` | Topic to send to | `darshan` |
| `DARSHAN_MOFKA_BATCH` | Producer batch size; `0` means adaptive | `0` |
| `DARSHAN_MOFKA_MAX_BATCHES` | Max pending batches; `0` means library default | `0` |
| `DARSHAN_MOFKA_FLUSH_MS` | How long to wait for a final flush, in ms | `5000` |
| `DARSHAN_MOFKA_FINAL_SWEEP` | Re-stream every record's final struct at shutdown. Off by default — enabling it hangs python-ml at finalize (see RESULTS_LCRC.md) | off |
| `DARSHAN_MOFKA_TIMING` | Print per-call timing | off |
| `DARSHAN_MOFKA_VERBOSE` | Extra diagnostics | off |

Two more variables are read by the Mofka driver (patched `MofkaDriver.cpp`) and
control how the producer attaches to the fabric:

| Variable | What it does | Default |
|---|---|---|
| `MOFKA_NA_DOMAIN` | Name the producer's local network domain (e.g. `mlx5_0`). Required on verbs: a connecting client can't auto-select the domain the way a listening broker does. | unset |
| `MOFKA_CLIENT_MODE` | `1` makes the producer's Mercury endpoint non-listening (`THALLIUM_CLIENT_MODE`, shallower fabric queues), so many producers per node don't exhaust the NIC's queues. Consumers stay in server mode. | unset (server mode) |

When Darshan is built without the connector (`--with-diaspora-c` absent), none of
this exists and Darshan behaves exactly as it does upstream.

## Limitations

- **python-ml reconstruction is not counter-exact.** Interpreter-startup files
  opened during the connector's init window are missed (see Results). The C
  workload is byte-exact. A finalize records-sweep
  (`DARSHAN_MOFKA_FINAL_SWEEP`) was written to close the gap but is disabled by
  default: enabling it hangs python-ml at shutdown, because the sweep's sends are
  issued from the atexit context and Mofka's producer sender runs on the margo
  progress pool, which no longer advances as the process exits. Closing this
  properly needs a Mofka-side change.
- **Producers per node depends on transport.** Over tcp, only ~2 producers per node
  attach before the NIC's fabric endpoints are exhausted. Over verbs, name the
  producer's domain (`MOFKA_NA_DOMAIN`) and set `MOFKA_CLIENT_MODE=1` and ~128
  producers per node attach. See RESULTS_LCRC.md for the na_ofi root cause.
- **Drain throughput.** A single FlowCept consumer plus MongoDB is the ceiling under
  bursty, high-volume streaming. The runner shards the drain: N consumers each pin a
  disjoint subset of Mofka partitions and share one mongod, with FlowCept upserting
  on a unique `task_id` so shards dedup safely. Also raise partition count
  (`server.config`) and use a node-local Mongo dbpath.

## More docs

- [REPRODUCE.md](REPRODUCE.md) — build from scratch and check the result.
- [RESULTS_LCRC.md](RESULTS_LCRC.md) — multi-node topology and overhead numbers.
- [docs/SCHEMA.md](docs/SCHEMA.md) — what one streamed event contains.
- [docs/MOFKA_NOTES.md](docs/MOFKA_NOTES.md) — how the Mofka pieces are configured, from the official docs.
- [docs/RUNBOOK.md](docs/RUNBOOK.md) — the full manual pipeline, step by step.
- [workloads/README.md](workloads/README.md) — the test workloads.
</content>
</invoke>
