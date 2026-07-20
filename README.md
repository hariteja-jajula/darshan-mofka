# darshan-mofka

Minimal demo for streaming Darshan runtime I/O events into a Mofka topic.

The demo runs one small C program under `LD_PRELOAD=libdarshan.so`. Darshan
intercepts the program's POSIX/STDIO I/O calls, builds JSON metadata events, pushes
them to Mofka, and `server/capture.py` consumes those events back out of the topic.

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

## 5. Run DLIO Benchmark

```bash
git clone https://github.com/argonne-lcf/dlio_benchmark
cd dlio_benchmark/
pip install .
dlio_benchmark ++workload.workflow.generate_data=True
```

## 6. Run The Darshan-Instrumented Workload

Run the C workload under Darshan and enable Mofka streaming:

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

Check that the workload ran:

```bash
cat /tmp/darshan-mofka-workload.out
```

Expected:

```text
mofka_forward_smoke complete: wrote/read POSIX and STDIO files in /tmp/mofka-forward-smoke
```

Check that the connector sent events:

```bash
grep 'darshan-mofka\[timing\] send' /tmp/darshan-mofka-workload.err | wc -l
```

Expected: a nonzero count. In the simple login-node smoke run this was `12`.

## 7. Capture Events From Mofka

Use the consumer in `server/capture.py` to drain the `darshan` topic to JSONL:

```bash
timeout 45 "$PY" server/capture.py "$ROOT/server/mofka.json" darshan 100 5 \
  > /tmp/darshan-mofka-events.jsonl \
  2> /tmp/darshan-mofka-capture.count
```

Print the captured count:

```bash
cat /tmp/darshan-mofka-capture.count
```

Expected:

```text
captured N
```

where `N` is nonzero. The earlier simple smoke run captured `12` events.

## 8. Verify The Captured Events

Check for POSIX events:

```bash
grep '"module":"POSIX"' /tmp/darshan-mofka-events.jsonl | head
```

Check for STDIO events:

```bash
grep '"module":"STDIO"' /tmp/darshan-mofka-events.jsonl | head
```

Check for read/write operations:

```bash
grep -E '"op":"(read|write)"' /tmp/darshan-mofka-events.jsonl | head
```

A compact summary is often easier to read:

```bash
"$PY" - <<'PY'
import json
from collections import Counter
mods = Counter()
ops = Counter()
with open('/tmp/darshan-mofka-events.jsonl') as f:
    for line in f:
        ev = json.loads(line)
        mods[ev.get('module')] += 1
        ops[ev.get('op')] += 1
print('modules:', dict(mods))
print('ops:', dict(ops))
PY
```

If you see `POSIX`, `STDIO`, and read/write operations, the full path worked:

```text
C workload -> Darshan connector -> Mofka topic -> capture.py consumer -> JSONL file
```

## 9. Reconstruct A Partial Darshan Log

If the normal Darshan shutdown path fails and no final `.darshan` log is produced,
the captured stream can be converted into a best-effort partial Darshan log:

```bash
./darshan/install/bin/darshan-mofka-reconstruct \
  /tmp/darshan-mofka-events.jsonl \
  /tmp/job_partial.darshan
```

Validate the reconstructed log with Darshan's parser:

```bash
./darshan/install/bin/darshan-parser --show-incomplete /tmp/job_partial.darshan | head -80
```

The reconstructed log is intentionally marked partial. It contains the latest module
record snapshots that reached Mofka, plus synthetic job/exe/mount metadata.

## 10. Stop Server

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

timeout 45 "$PY" server/capture.py "$ROOT/server/mofka.json" darshan 100 5 \
  > /tmp/darshan-mofka-events.jsonl \
  2> /tmp/darshan-mofka-capture.count

cat /tmp/darshan-mofka-workload.out
cat /tmp/darshan-mofka-capture.count
grep '"module":"POSIX"' /tmp/darshan-mofka-events.jsonl | head
grep '"module":"STDIO"' /tmp/darshan-mofka-events.jsonl | head
grep -E '"op":"(read|write)"' /tmp/darshan-mofka-events.jsonl | head

./darshan/install/bin/darshan-mofka-reconstruct \
  /tmp/darshan-mofka-events.jsonl \
  /tmp/job_partial.darshan
./darshan/install/bin/darshan-parser --show-incomplete /tmp/job_partial.darshan | head -80

bash server/stop-server.sh
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
