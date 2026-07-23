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

## What's in here

```text
darshan/              Darshan, with the Mofka connector (the part bound for upstream)
diaspora-stream-api/  the C streaming API the connector uses
flowcept/             the consumer that drains the stream into MongoDB
env/                  environment setup (server side and workload side)
server/               start/stop the Mofka broker
Client/               the FlowCept consumer and the export-to-JSON tool
Database/             get a local MongoDB
workloads/            programs to exercise the connector (C, MPI-IO, DLIO, python-ml)
install/              one-command setup that builds everything
job.sh                run the full pipeline once, on a compute node
submit.sh             send job.sh to PBS
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

## More docs

- [REPRODUCE.md](REPRODUCE.md) — build from scratch and check the result.
- [docs/SCHEMA.md](docs/SCHEMA.md) — what one streamed event contains.
- [docs/MOFKA_NOTES.md](docs/MOFKA_NOTES.md) — how the Mofka pieces are configured, from the official docs.
- [docs/RUNBOOK.md](docs/RUNBOOK.md) — the full manual pipeline, step by step.
- [workloads/README.md](workloads/README.md) — the test workloads.
