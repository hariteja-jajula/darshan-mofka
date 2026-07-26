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

Clone with submodules:

```bash
git clone https://github.com/hariteja-jajula/darshan-mofka.git
cd darshan-mofka
git submodule update --init --recursive
```

See what you already have (this downloads nothing):

```bash
bash check-deps.sh
```

If anything is missing, build it all from source with one command. Run this on a
login node (it needs internet); the first build compiles the full Mofka stack, so
it takes a while:

```bash
DARSHAN_MOFKA_PROFILE=lcrc bash install/setup.sh
```

Then run the whole pipeline on a compute node and check the result:

```bash
PBS_ACCOUNT=<your_project> bash submit.sh
```

`submit.sh` sizes the PBS allocation from `topology.nodes` and the `pbs:` block in
`workloads/workload.config`, runs the workload on a compute node (the broker's
network transport does not come up on login nodes), reconstructs a `.darshan` log
from the stream, and compares it to the native one. Results land in
`results/<TAG>_<N>NODE_<P>PROC_<B>Broker-<placement>/RUN<n>/`; a default single-node
C run is `results/C_1NODE_1PROC_1Broker-colocated/RUN1/`.

### What success looks like

The job output ends with:

```text
INGEST: PASS
modules: {'POSIX': 4, 'STDIO': 9}
VERDICT: PASS
```

and the run's `compare.txt` shows the rebuilt log matching the real one:

```text
reconstructed modules: ['POSIX', 'STDIO']  op-totals: {'READS': 2, 'WRITES': 3, 'OPENS': 3}
native        modules: ['POSIX', 'STDIO']  op-totals: {'READS': 2, 'WRITES': 3, 'OPENS': 3}
VERDICT: PASS
```

`VERDICT: PASS` means the log rebuilt from the Mofka stream has the same modules and
the same open/read/write counts as the real Darshan log. Small differences are
expected and allowed: the mount label (`unknown` vs `rootfs`), timestamps, the pid,
and the synthetic job/exe metadata.

## Results at a glance

Verified on LCRC/Improv, 2026-07-25.

- **The C workload is byte-exact** over verbs — the rebuilt log matches the native
  one with zero counter differences. python-ml completes but its reconstruction is
  approximate (interpreter-startup files opened during connector init are missed).
- **Scales to ~128 producers/node over verbs** (`MOFKA_NA_DOMAIN` +
  `MOFKA_CLIENT_MODE=1`); tcp caps at ~2/node.
- **Steady-state cost is ~25 µs per I/O event** (p50, flat to 128 producers/node);
  init and finalize are one-time.

See `results/{c,python-ml,mpi}/` for each workload's native and streamed `.darshan` logs plus
their pydarshan HTML summaries (`native.html`, `streamed.html`).

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
results/              c/ python-ml/ mpi/ = per-workload artifacts (native/streamed .darshan + HTML); run folders land here too
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
| `DARSHAN_MOFKA_FINAL_SWEEP` | Re-stream every record's final struct at shutdown. Off by default — enabling it hangs python-ml at finalize (see the KNOWN ISSUE note in `darshan-mofka.c`) | off |
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

## More docs

- [workloads/README.md](workloads/README.md) — the test workloads and how to run them.
- `results/<workload>/` — per-workload artifacts: native + streamed `.darshan` logs and their
  pydarshan HTML (`native.html`, `streamed.html`).
</content>
</invoke>
