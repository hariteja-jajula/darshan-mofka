# darshan-mofka

Stream Darshan runtime I/O events into a Mofka topic.

The connector emits JSON metadata events from the Darshan runtime to Mofka;
FlowCept drains the topic into MongoDB. If the job exits before Darshan writes
its final log, a partial `.darshan` log can be reconstructed from the captured
stream.

## What it does

- Streams POSIX, STDIO, and MPI-IO events to Mofka, including STDIO close and
  `MPI_File_close` events.
- Reconstructs a partial Darshan log from the stream; reconstructed OPENS match
  the native Darshan log, aside from overlay/unknown-label differences.
- Rebuilds the stack from source with pinned versions and no hardcoded
  paths/accounts (see [`install/`](install/README.md)).

## Quickstart

The build has no compute-node internet dependency, so on Polaris only the final
run needs a compute node (the Mofka broker's fabric transport doesn't come up on
login nodes).

```bash
# 1. LOGIN node (internet): stage everything (spack, mongod, wheels, submodules) onto eagle
bash install/00-fetch.sh

# 2. LOGIN or COMPUTE node, OFFLINE: build from the staged sources
bash install/10-build.sh

# 3. COMPUTE node: run + verify the pipeline end to end
qsub -I -q debug -A <project> -l select=1 -l walltime=01:00:00 -l filesystems=home:eagle
cd <repo>
bash job.sh
```

`install/config.yaml` holds versions/names; `install/lock/` holds the exact
pinned concretization. See [`install/README.md`](install/README.md) for the
phase model, and [`docs/RUNBOOK.md`](docs/RUNBOOK.md) for the full manual
pipeline (useful for debugging or partial rebuilds).

## Verifying the result

After a run, `$EVENTS_JSONL` holds the streamed events. A compact summary:

```bash
"$PY" - "$EVENTS_JSONL" <<'PY'
import json, sys
from collections import Counter
mods, ops = Counter(), Counter()
for line in open(sys.argv[1]):
    ev = json.loads(line)
    mods[ev.get('module')] += 1
    ops[ev.get('op')] += 1
print('modules:', dict(mods))
print('ops:', dict(ops))
PY
```

Reconstruct a partial log from the stream and validate it with Darshan's parser:

```bash
./darshan/install/bin/darshan-mofka-reconstruct "$EVENTS_JSONL" /tmp/job_partial.darshan
./darshan/install/bin/darshan-parser --show-incomplete /tmp/job_partial.darshan | head -80
```

## Repository layout

```text
darshan-mofka/
├── darshan/              Darshan submodule with the Mofka connector
├── diaspora-stream-api/  Diaspora C API submodule used by the connector
├── flowcept/             FlowCept submodule (the live consumer)
├── build.sh              build the vendored darshan fork into darshan/install
├── job.sh                one-shot end-to-end demo on a compute node
├── install/              from-scratch reproducible build (config-driven, pinned)
├── docs/RUNBOOK.md       full manual pipeline + Polaris workarounds
├── server/               environment, broker start/stop, capture consumer
│   ├── spack/            Spack spec to rebuild the Mofka/FlowCept stack
│   └── requirements.txt  Python deps for the FlowCept consumer venv
└── workloads/            demo workloads (see workloads/README.md)
    ├── c/                POSIX/STDIO smoke + MPI-IO tests
    └── dlio/             optional DLIO benchmark
```

The old overhead-study jobs, result scripts, slides, and extra workloads were cut
from this branch. Recover them from the study branch if needed.

## What gets streamed

The connector streams JSON metadata events only, not application file contents.

The `rec_hex` field, when present, is a hex-encoded copy of Darshan's internal
module record at the time of the event. It is profiling/record state, not user
file data.

## Connector environment variables

Variables read by the Darshan-instrumented process:

| Variable | Meaning | Default |
|---|---|---|
| `DARSHAN_MOFKA_ENABLE` | Enables Mofka streaming | off |
| `DARSHAN_MOFKA_GROUP_FILE` | Mofka group file, usually `server/mofka.json` | required |
| `DARSHAN_MOFKA_TOPIC` | Topic name | `darshan` |
| `DARSHAN_MOFKA_BATCH` | Producer batch size; `0` means adaptive | `0` |
| `DARSHAN_MOFKA_MAX_BATCHES` | Max pending batches; `0` means library default | `0` |
| `DARSHAN_MOFKA_FLUSH_MS` | Finalize flush timeout in milliseconds | `5000` |
| `DARSHAN_MOFKA_TIMING` | Print per-call timing lines | off |
| `DARSHAN_MOFKA_VERBOSE` | Print connector setup details | off |

There are no per-module enable variables on this branch. If Darshan calls the
Mofka send hook, the connector forwards the event.

## More documentation

- [`install/README.md`](install/README.md) -- from-scratch reproducible build (phased, pinned).
- [`docs/RUNBOOK.md`](docs/RUNBOOK.md) -- full manual pipeline, one-shot block, troubleshooting, Polaris workarounds.
- [`workloads/README.md`](workloads/README.md) -- how to run each workload type (C smoke, MPI-IO, DLIO).
