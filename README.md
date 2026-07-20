# darshan-mofka

Minimal demo for streaming Darshan runtime I/O events into a Mofka topic.

The demo runs one small C program under `LD_PRELOAD=libdarshan.so`. Darshan
intercepts the program's POSIX/STDIO I/O calls, builds JSON metadata events, pushes
them to Mofka, and FlowCept drains the topic into MongoDB.

## Polaris Allocation

```bash
qsub -I -A <project> -q <queue> -l select=<nodes>:ncpus=<cpus> -l walltime=<HH:MM:SS> -l filesystems=<filesystems>
```

## Repository Layout

```text
darshan-mofka/
├── darshan/              Darshan submodule with the Mofka connector
├── diaspora-stream-api/  Diaspora C API submodule used by the connector
├── server/               environment, broker start/stop, capture consumer
└── workloads/            demo workload: mofka_forward_smoke.c
```

The old overhead-study jobs, result scripts, slides, and extra workloads were cut
from this branch. Recover them from the study branch if needed.

## 1. Prepare Environment

From the repository root, choose the cluster profile:

```bash
git submodule update --init --recursive
source server/env.sh --polaris  # Polaris
# source server/env.sh --lcrc   # LCRC/Improv
```

Check that the main tools are visible:

```bash
printf 'MOFKA_SPACK_VIEW=%s\n' "$MOFKA_SPACK_VIEW"
command -v bedrock
command -v "$CC"
printf 'MOFKA_PROTOCOL=%s\n' "$MOFKA_PROTOCOL"
printf 'DIASPORA_C=%s\n' "$DIASPORA_C"
printf 'DARSHAN_PREFIX=%s\n' "$DARSHAN_PREFIX"
```

For other systems, either set `DARSHAN_MOFKA_ENV` to another committed profile
or create a local machine config:

```bash
cp server/env.local.sh.example server/env.local.sh
source server/env.sh
```

Then edit `server/env.local.sh` to load modules or set paths for your cluster.
`server/env.local.sh` is ignored by git.

## 2. Build Dependencies

If `diaspora-stream-api/install` already exists, skip this step.

```bash
cd diaspora-stream-api
cmake -S . -B _build -DENABLE_C_API=ON -DENABLE_PYTHON=ON \
      -DCMAKE_PREFIX_PATH="$MOFKA_SPACK_VIEW" \
      -DCMAKE_INSTALL_PREFIX="$PWD/install"
cmake --build _build -j
cmake --install _build
cd ..
```

Refresh the environment after building Diaspora. This is required because the install step creates `diaspora-stream-api/install/lib/python3.14/site-packages`, which must be on `PYTHONPATH` for Mofka's Python client to import `pydiaspora_stream_api`.

```bash
source server/env.sh --polaris  # or: source server/env.sh --lcrc on LCRC/Improv
printf 'PY=%s\n' "$PY"
"$PY" -VV
printf 'PYTHONPATH=%s\n' "$PYTHONPATH"
"$PY" - <<'PY'
import pydiaspora_stream_api
import mochi.mofka.client
print("mochi.mofka import OK")
PY
```

## 3. Build Darshan And The Demo Workload

Build the Darshan fork with Mofka support:

```bash
cd darshan
./build.sh
cd ..
```

Build the workload:

```bash
"$CC" -O2 workloads/mofka_forward_smoke.c -o workloads/mofka_forward_smoke
```

Confirm the Darshan library path:

```bash
darshan_lib
```

Expected: a path ending in `darshan/install/lib/libdarshan.so`.

## 4. Start Mofka Server

Start the local Bedrock/Mofka broker and create the `darshan` topic:

```bash
bash server/start-server.sh
```

Expected output looks like:

```text
starting bedrock (...) in .../server ...
mofka up: ... | topic 'darshan' | groupfile .../server/mofka.json (pid ...)
```

The important file is:

```bash
ls -l server/mofka.json
```

That group file is what the Darshan connector and the consumer both use to connect
to the same Mofka server.

## 5. Choose Output Files

Pick where this run writes its FlowCept artifacts and exported JSONL. Use different `MONGO_DB` and `EVENTS_JSONL` values for different workload runs if you want to keep them separate.

```bash
RUN_DIR="${RUN_DIR:-$ROOT/server/_flowcept_run}"
MONGO_DB="${MONGO_DB:-darshan_stream}"
MONGO_PORT="${MONGO_PORT:-27017}"
EVENTS_JSONL="${EVENTS_JSONL:-/tmp/darshan-mofka-events.jsonl}"
mkdir -p "$RUN_DIR"
```

## 6. Start FlowCept As The Live Consumer

Start FlowCept before the workload. It runs in the background and continuously drains the `darshan` Mofka topic into MongoDB.

```bash
MONGOD="${MONGOD:-$(command -v mongod || true)}"
[[ -x "$MONGOD" ]] || { echo "mongod not found; load MongoDB or set MONGOD=/path/to/mongod"; exit 1; }

RUN_DIR="$RUN_DIR" \
MONGO_DB="$MONGO_DB" \
MONGO_PORT="$MONGO_PORT" \
MONGOD="$MONGOD" \
MOFKA_GROUP="$ROOT/server/mofka.json" \
bash server/capture_flowcept.sh > "$RUN_DIR/flowcept_capture.out" 2>&1 &
FLOWCEPT_CAPTURE_PID=$!

until grep -q 'consumer alive' "$RUN_DIR/flowcept_capture.out"; do
  kill -0 "$FLOWCEPT_CAPTURE_PID" 2>/dev/null || { cat "$RUN_DIR/flowcept_capture.out"; exit 1; }
  sleep 1
done
```

## 7. Run A Darshan-Instrumented Workload

Run any workload under Darshan while FlowCept is draining the topic. This example uses the C smoke workload:

```bash
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
  ./workloads/mofka_forward_smoke /tmp/mofka-forward-smoke \
  > /tmp/darshan-mofka-workload.out \
  2> /tmp/darshan-mofka-workload.err
```

Check that the workload ran and sent events:

```bash
cat /tmp/darshan-mofka-workload.out
grep 'darshan-mofka\[timing\] send' /tmp/darshan-mofka-workload.err | wc -l
```

Expected: the workload prints `mofka_forward_smoke complete...` and the send count is nonzero.

## 8. Stop FlowCept And Export JSONL

Tell FlowCept to flush and stop its consumer, then export the workload-specific MongoDB records to JSONL:

```bash
touch "$RUN_DIR/SHUTDOWN"
until grep -q 'Export now' "$RUN_DIR/flowcept_capture.out"; do
  kill -0 "$FLOWCEPT_CAPTURE_PID" 2>/dev/null || { cat "$RUN_DIR/flowcept_capture.out"; exit 1; }
  sleep 1
done

"$PY" server/export_jsonl.py 127.0.0.1 "$MONGO_DB" --mongo-port "$MONGO_PORT" \
  > "$EVENTS_JSONL" \
  2> "$RUN_DIR/export.count"

cat "$RUN_DIR/export.count"
kill "$FLOWCEPT_CAPTURE_PID" 2>/dev/null || true
wait "$FLOWCEPT_CAPTURE_PID" 2>/dev/null || true
```

`server/capture.py` is still available as a simple debug drain, but the FlowCept path above is the live consumer path.

## 9. Verify Exported Events

Verify the JSONL exported for the workload you just ran:

```bash
grep '"module":"POSIX"' "$EVENTS_JSONL" | head
grep '"module":"STDIO"' "$EVENTS_JSONL" | head
grep -E '"op":"(read|write)"' "$EVENTS_JSONL" | head
```

A compact summary is often easier to read:

```bash
"$PY" - "$EVENTS_JSONL" <<'PY'
import json
import sys
from collections import Counter
mods = Counter()
ops = Counter()
with open(sys.argv[1]) as f:
    for line in f:
        ev = json.loads(line)
        mods[ev.get('module')] += 1
        ops[ev.get('op')] += 1
print('modules:', dict(mods))
print('ops:', dict(ops))
PY
```

## 10. Verify DLIO Events

If you exported a DLIO run to a separate JSONL file, point `EVENTS_JSONL` at that file and verify it the same way:

```bash
EVENTS_JSONL=/tmp/darshan-mofka-dlio-events.jsonl
grep '"module":"POSIX"' "$EVENTS_JSONL" | head
grep -Ei '"op":"(open|read|write|close)"' "$EVENTS_JSONL" | head
```

## 11. Reconstruct A Partial Darshan Log

If the normal Darshan shutdown path fails and no final `.darshan` log is produced,
the captured stream can be converted into a best-effort partial Darshan log:

```bash
./darshan/install/bin/darshan-mofka-reconstruct \
  "$EVENTS_JSONL" \
  /tmp/job_partial.darshan
```

Validate the reconstructed log with Darshan's parser:

```bash
./darshan/install/bin/darshan-parser --show-incomplete /tmp/job_partial.darshan | head -80
```

The reconstructed log is intentionally marked partial. It contains the latest module
record snapshots that reached Mofka, plus synthetic job/exe/mount metadata.

## 12. Stop Server

Stop the broker when done:

```bash
bash server/stop-server.sh
```

## One-Shot Command Block

After everything has been built once, this block runs the full demo:

```bash
source server/env.sh --polaris  # or: source server/env.sh --lcrc on LCRC/Improv
bash server/start-server.sh
"$CC" -O2 workloads/mofka_forward_smoke.c -o workloads/mofka_forward_smoke

RUN_DIR="${RUN_DIR:-$ROOT/server/_flowcept_run}"
MONGO_DB="${MONGO_DB:-darshan_stream}"
MONGO_PORT="${MONGO_PORT:-27017}"
EVENTS_JSONL="${EVENTS_JSONL:-/tmp/darshan-mofka-events.jsonl}"
mkdir -p "$RUN_DIR"
MONGOD="${MONGOD:-$(command -v mongod || true)}"
[[ -x "$MONGOD" ]] || { echo "mongod not found; load MongoDB or set MONGOD=/path/to/mongod"; exit 1; }
RUN_DIR="$RUN_DIR" MONGO_DB="$MONGO_DB" MONGO_PORT="$MONGO_PORT" MONGOD="$MONGOD" \
MOFKA_GROUP="$ROOT/server/mofka.json" \
bash server/capture_flowcept.sh > "$RUN_DIR/flowcept_capture.out" 2>&1 &
FLOWCEPT_CAPTURE_PID=$!
until grep -q 'consumer alive' "$RUN_DIR/flowcept_capture.out"; do
  kill -0 "$FLOWCEPT_CAPTURE_PID" 2>/dev/null || { cat "$RUN_DIR/flowcept_capture.out"; exit 1; }
  sleep 1
done

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
  ./workloads/mofka_forward_smoke /tmp/mofka-forward-smoke \
  > /tmp/darshan-mofka-workload.out \
  2> /tmp/darshan-mofka-workload.err

touch "$RUN_DIR/SHUTDOWN"
until grep -q 'Export now' "$RUN_DIR/flowcept_capture.out"; do
  kill -0 "$FLOWCEPT_CAPTURE_PID" 2>/dev/null || { cat "$RUN_DIR/flowcept_capture.out"; exit 1; }
  sleep 1
done
"$PY" server/export_jsonl.py 127.0.0.1 "$MONGO_DB" --mongo-port "$MONGO_PORT" \
  > "$EVENTS_JSONL" \
  2> "$RUN_DIR/export.count"
kill "$FLOWCEPT_CAPTURE_PID" 2>/dev/null || true
wait "$FLOWCEPT_CAPTURE_PID" 2>/dev/null || true

cat /tmp/darshan-mofka-workload.out
cat "$RUN_DIR/export.count"
grep '"module":"POSIX"' "$EVENTS_JSONL" | head
grep '"module":"STDIO"' "$EVENTS_JSONL" | head
grep -E '"op":"(read|write)"' "$EVENTS_JSONL" | head

./darshan/install/bin/darshan-mofka-reconstruct \
  "$EVENTS_JSONL" \
  /tmp/job_partial.darshan
./darshan/install/bin/darshan-parser --show-incomplete /tmp/job_partial.darshan | head -80

bash server/stop-server.sh
```

## Two-Node C And DLIO Demo

For overhead demos, do not co-locate the workload with Mofka, MongoDB, and FlowCept. Use two nodes: rank 0 runs the services, rank 1 runs the Darshan-instrumented workload.

From this repo in an interactive allocation or as batch jobs:

```bash
source server/env.sh --polaris
qsub jobs/c_two_node_flowcept.pbs
qsub jobs/dlio_two_node_flowcept.pbs
```

Both jobs write all artifacts under `server/_pbs_*_<jobid>/`. The exported stream is `events.jsonl`; `export.count` should say `exported N` with `N > 0`.

The DLIO job defaults to the sibling checkout at `../dlio_benchmark/dlio_benchmark`. Override with `DLIO_ROOT=/path/to/dlio_benchmark` if needed. It intentionally uses a tiny dataset so tomorrow's demo proves the path quickly:

```bash
DLIO_NUM_FILES_TRAIN=2 DLIO_NUM_FILES_EVAL=1 DLIO_EVALUATION=False \
  qsub jobs/dlio_two_node_flowcept.pbs
```

For a manual interactive run, allocate two nodes, then run the same helper through MPI:

```bash
source server/env.sh --polaris
export RUN_DIR="$ROOT/server/_interactive_dlio_$(date +%Y%m%d_%H%M%S)"
export MOFKA_SERVER_DIR="$RUN_DIR/mofka"
export MONGO_DB="interactive_dlio"
export MONGO_PORT=27017
export EVENTS_JSONL="$RUN_DIR/events.jsonl"
mkdir -p "$RUN_DIR" "$MOFKA_SERVER_DIR"
mpiexec -n 2 --ppn 1 /bin/bash --noprofile --norc "$ROOT/jobs/two_node_demo.sh" dlio
cat "$RUN_DIR/export.count"
```

## What Gets Streamed

The connector streams JSON metadata events. It does not stream the application's
actual file contents.

The `rec_hex` field, when present, is a hex-encoded copy of Darshan's internal
module record at the time of the event. It is profiling/record state, not user file
data.

## Connector Environment Variables

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

There are no per-module enable variables on this branch. If Darshan calls the Mofka
send hook, the connector forwards the event.

## Troubleshooting

If `server/mofka.json` is missing after starting the server, check:

```bash
cat server/bedrock.log
```

If `capture.py` captures zero events, check that the workload actually sent events:

```bash
grep 'darshan-mofka\[timing\] send' /tmp/darshan-mofka-workload.err | wc -l
```

If that count is zero, check that `LD_PRELOAD` points at the Darshan build:

```bash
darshan_lib
```

If Python cannot import Mofka, check `$PY`, `$PYTHONPATH`, and `server/env.local.sh`:

```bash
"$PY" - <<'PY'
import mochi.mofka.client
print('OK')
PY
```
