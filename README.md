# darshan-mofka

Stream Darshan's I/O events out of a running job, live, into Mofka.

## Why

Darshan writes its log file once, at the very end of a job. If the job crashes or
is killed first, that log is never written and you lose all the I/O profiling for
the run.

This project adds a small connector to Darshan that sends each I/O event to a
[Mofka](https://mofka.readthedocs.io) message stream as it happens. A consumer
saves those events, and a tool rebuilds a partial `.darshan` log from them. So even
if the job dies early, you still have the I/O record up to the moment it stopped.

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
                                                                  partial .darshan log
```

The connector is the part that would go upstream into Darshan. Everything else in
this repo is the harness that runs it and proves it works.

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

The reconstructed log is faithful to the one Darshan writes natively:

- **Single rank — byte-identical.** The streamed-and-rebuilt log matches the native
  log exactly: executable, run time, the I/O HEATMAP, all 154 POSIX/STDIO counters,
  and the mount table all compare equal (`DATA: IDENTICAL`).
- **Multi-node — validated end-to-end.** With a dedicated broker node and producers
  spread across separate workload nodes, every producer streams and the reconstruct
  step passes against native. The same topology validates on both LCRC/Improv (tcp)
  and ALCF/Polaris (CXI).
- **Cost.** Steady-state the connector adds ~25–45 µs per I/O event (median ~25 µs);
  startup ~0.5 s per rank.

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

## The knobs the connector reads

Set these in the environment of the Darshan-instrumented program:

| Variable | What it does | Default |
|---|---|---|
| `DARSHAN_MOFKA_ENABLE` | Turn streaming on | off |
| `DARSHAN_MOFKA_GROUP_FILE` | The broker's group file (`server/mofka.json`) | required |
| `DARSHAN_MOFKA_TOPIC` | Topic to send to | `darshan` |
| `DARSHAN_MOFKA_BATCH` | Producer batch size; `0` means adaptive | `0` |
| `DARSHAN_MOFKA_MAX_BATCHES` | Max pending batches; `0` means library default | `0` |
| `DARSHAN_MOFKA_FLUSH_MS` | How long to wait for a final flush, in ms | `5000` |
| `DARSHAN_MOFKA_TIMING` | Print per-call timing | off |

When Darshan is built without the connector (`--with-diaspora-c` absent), none of
this exists and Darshan behaves exactly as it does upstream.

## Limitations

- **Producers per node.** Many producers on one node all connecting to a single
  broker exhaust the node's fabric endpoints (~2–3 attach over `ofi+tcp` on Improv;
  the same class of limit appears as "CXI alloc failed" on Polaris, degrading to
  ~75% attach). The fix is topology, not tuning: dedicate a broker node and scale
  out by adding workload nodes rather than stacking ranks on one.
- **Drain throughput.** A single FlowCept consumer + MongoDB is the ceiling under
  bursty, high-volume streaming. Raise it with larger consumer buffers (`client.config`),
  more topic partitions (`server.config`), and a node-local Mongo dbpath.

## More docs

- [REPRODUCE.md](REPRODUCE.md) — build from scratch and check the result.
- [RESULTS_LCRC.md](RESULTS_LCRC.md) — multi-node topology and overhead numbers.
- [docs/SCHEMA.md](docs/SCHEMA.md) — what one streamed event contains.
- [docs/MOFKA_NOTES.md](docs/MOFKA_NOTES.md) — how the Mofka pieces are configured, from the official docs.
- [docs/RUNBOOK.md](docs/RUNBOOK.md) — the full manual pipeline, step by step.
- [workloads/README.md](workloads/README.md) — the test workloads.
