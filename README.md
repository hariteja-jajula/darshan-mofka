# darshan-mofka

Minimal demo for streaming Darshan runtime I/O events into a Mofka topic.

This repo keeps the demo small on purpose: build the Darshan fork, start a local
Mofka broker, run one tiny C workload under `LD_PRELOAD`, then consume the JSON
metadata events with `server/capture.py`.

## Layout

```text
darshan-mofka/
├── darshan/              submodule: Darshan fork with the Mofka connector
├── diaspora-stream-api/  submodule: Diaspora C bindings used by the connector
├── server/               env, broker start/stop, and capture consumer
└── workloads/            one C smoke workload
```

The old overhead-study workloads, PBS jobs, slides, and generated result files are
not on this clean branch. They can be recovered from the old study branch if needed.

## Requirements

You need a Mochi/Mofka software environment that provides:

- `bedrock`
- `mochi.mofka` Python bindings
- `mofkactl`
- a C compiler

You also need the `diaspora-stream-api` C install available through `DIASPORA_C`.
The default `server/env.sh` auto-discovers common in-tree install locations, but
cluster-specific module loads and paths should go in `server/env.local.sh`.

Start from the example:

```bash
cp server/env.local.sh.example server/env.local.sh
```

Then edit `server/env.local.sh` for the machine if auto-discovery is not enough.
That file is intentionally ignored by git.

## Build

Clone with submodules or initialize them after cloning:

```bash
git submodule update --init --recursive
```

Source the environment:

```bash
source server/env.sh
```

If `diaspora-stream-api/install` does not exist yet, build the C bindings:

```bash
cd diaspora-stream-api
cmake -S . -B _build -DENABLE_C_API=ON \
      -DCMAKE_PREFIX_PATH="$MOFKA_SPACK_VIEW" \
      -DCMAKE_INSTALL_PREFIX="$PWD/install"
cmake --build _build -j
cmake --install _build
cd ..
```

Build Darshan with the Mofka connector:

```bash
source server/env.sh
cd darshan
./build.sh
cd ..
```

Build the demo workload:

```bash
cc -O2 workloads/mofka_forward_smoke.c -o workloads/mofka_forward_smoke
```

## Run Demo

Start a local Mofka broker and create the `darshan` topic:

```bash
source server/env.sh
bash server/start-server.sh
```

Run the workload under Darshan:

```bash
source server/env.sh
darshan_ensure_logdir

env \
  DARSHAN_ENABLE_NONMPI=1 \
  DARSHAN_MOFKA_ENABLE=1 \
  DARSHAN_MOFKA_GROUP_FILE="$ROOT/server/mofka.json" \
  DARSHAN_MOFKA_TOPIC=darshan \
  DARSHAN_MOFKA_TIMING=1 \
  DARSHAN_MOFKA_BATCH=0 \
  DARSHAN_MOFKA_MAX_BATCHES=64 \
  DARSHAN_LOGPATH="$DARSHAN_LOGPATH" \
  LD_PRELOAD="$(darshan_lib)" \
  ./workloads/mofka_forward_smoke /tmp/mofka-forward-smoke
```

Capture streamed events from Mofka:

```bash
timeout 45 "$PY" server/capture.py "$ROOT/server/mofka.json" darshan 100 5 \
  > /tmp/darshan-mofka-events.jsonl \
  2> /tmp/darshan-mofka-capture.count

cat /tmp/darshan-mofka-capture.count
grep '"module":"POSIX"' /tmp/darshan-mofka-events.jsonl | head
grep '"module":"STDIO"' /tmp/darshan-mofka-events.jsonl | head
grep -E '"op":"(read|write)"' /tmp/darshan-mofka-events.jsonl | head
```

Stop the broker:

```bash
bash server/stop-server.sh
```

Expected result: `capture.py` reports a nonzero event count and the JSONL contains
POSIX and STDIO records from `mofka_forward_smoke.c`.

## Connector Environment

These variables are read in the Darshan-instrumented process:

| Variable | Meaning | Default |
|---|---|---|
| `DARSHAN_MOFKA_ENABLE` | Enables Mofka streaming in Darshan | off |
| `DARSHAN_MOFKA_GROUP_FILE` | Mofka group file, usually `server/mofka.json` | required |
| `DARSHAN_MOFKA_TOPIC` | Topic name | `darshan` |
| `DARSHAN_MOFKA_BATCH` | Producer batch size; `0` means adaptive | `0` |
| `DARSHAN_MOFKA_MAX_BATCHES` | Max pending batches; `0` means library default | `0` |
| `DARSHAN_MOFKA_FLUSH_MS` | Finalize flush timeout in milliseconds | `5000` |
| `DARSHAN_MOFKA_TIMING` | Print per-call timing lines | off |
| `DARSHAN_MOFKA_VERBOSE` | Print connector setup details | off |

There are no per-module enable variables on this branch. If Darshan calls the
Mofka send hook, the connector forwards the event.

## What Is Streamed

Darshan sends JSON metadata events to Mofka. The connector does not stream the
application's actual file data. The optional `rec_hex` field is a hex-encoded
snapshot of Darshan's internal module record, not the file contents.
