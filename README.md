# darshan-mofka

Minimal demo for streaming Darshan runtime I/O events into a Mofka topic.

The demo runs one small C program under `LD_PRELOAD=libdarshan.so`. Darshan
intercepts the program's POSIX/STDIO I/O calls, builds JSON metadata events, pushes
them to Mofka, and FlowCept drains the topic into MongoDB.

## Reproducible from-scratch build (recommended)

To rebuild the **entire** stack from nothing (spack stack, `mongod`, python
consumer, project source) with pinned versions and no hardcoded paths, use the
phased installer in [`install/`](install/README.md). It is split for Polaris'
no-internet-on-compute-nodes constraint:

```bash
# 1. LOGIN node (internet): download everything onto eagle
bash install/00-fetch.sh

# 2. COMPUTE node (offline): build from the fetched sources
qsub -I -q debug -A <project> -l select=1 -l walltime=01:00:00 -l filesystems=home:eagle
cd <repo>
bash install/10-build.sh

# 3. run the demo end to end
bash job.sh
```

`install/config.yaml` holds the versions/names; `install/lock/` holds the exact
pinned concretization. See [`install/README.md`](install/README.md) for details.
The sections below document the same steps **manually** (useful for debugging or
partial rebuilds).

## Prerequisites

Three things live outside this repo and must exist before the steps below work:

1. **A built Mofka/FlowCept Spack view** (Bedrock, Mochi, Mofka, Darshan). These are
   ~1 GB of compiled binaries, not committed. Rebuild them from the vendored spec in
   `server/spack/` (see `server/spack/README.md`), then point `MOFKA_SPACK_VIEW` at the
   resulting view. `server/env_polaris.sh` also auto-detects it if it sits at the
   author's default layout, but on a fresh account set `MOFKA_SPACK_VIEW` explicitly.
2. **A Python venv** with the FlowCept consumer's deps. Create it on top of the Spack
   view's python and install the requirements plus the flowcept submodule:
   ```bash
   python -m venv ../envs/flowcept-py314        # or anywhere; see env_polaris.sh
   source ../envs/flowcept-py314/bin/activate
   pip install -r server/requirements.txt       # PyPI deps (pymongo, redis, ...)
   pip install -e flowcept/                      # the flowcept submodule
   ```
   `server/requirements.lock.txt` has the exact frozen set if you need to reproduce it.
   (mochi.mofka / pydiaspora come from the Spack view, not pip.)
3. **`mongod`** (MongoDB server) — FlowCept's sink. External dep, not a pip package;
   grab the standalone tarball and set `MONGOD=/path/to/mongod` (see step 6).
   On Polaris it must live on a **shared filesystem (`eagle`)**, not `$HOME`
   (compute nodes can't see `$HOME`), and be fetched on a **login node** (compute
   nodes have no internet). Details in step 6.

The quickest path once all three exist: `PBS_ACCOUNT=<your_project> bash jobs/job.sh`
runs the whole pipeline below on a compute node in one shot.

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
│   ├── spack/            Spack spec to rebuild the Mofka/FlowCept stack on Polaris
│   └── requirements.txt  Python deps for the FlowCept consumer venv
├── jobs/                 job.sh: one-shot end-to-end demo on a compute node
└── workloads/            demo workloads: mofka_forward_smoke.c (POSIX/STDIO),
                          mofka_forward_mpiio.c (MPI-IO)
```

The old overhead-study jobs, result scripts, slides, and extra workloads were cut
from this branch. Recover them from the study branch if needed.

## 1. Prepare Environment

Run the build/streaming steps on a **compute node** (the Mofka broker's fabric
transport does not come up on Polaris login nodes). Grab one, e.g.:

```bash
qsub -I -q debug -A <project> -l select=1 -l walltime=01:00:00 -l filesystems=home:eagle
```

> **Compute-node note:** interactive PBS shells often start without `TERM` set,
> which garbles `clear`/editors. If so: `export TERM=xterm`.

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

> **Polaris note (validated):** the Cray `cc` wrapper injects a `darshan-runtime`
> pkg-config hook from the system `darshan` module, which fails the CMake compiler
> check with `Package 'zlib' ... required by 'darshan-runtime', not found`. Unload
> the module and put zlib on `PKG_CONFIG_PATH` **before** this build (the same hook
> also affects step 3):
>
> ```bash
> module unload darshan
> export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:${PKG_CONFIG_PATH#/soft/perftools/darshan/darshan-3.4.4/lib/pkgconfig:}"
> pkg-config --exists zlib && echo "zlib OK"   # sanity check
> ```

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

Build the Darshan fork with Mofka support.

> **Polaris note (validated):** re-sourcing `server/env.sh` after step 2 re-adds
> the system darshan pkg-config path, so re-apply the fix from step 2 before
> building the runtime:
>
> ```bash
> module unload darshan   # avoids Cray cc wrapper's darshan-runtime pkg-config hook
> export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:${PKG_CONFIG_PATH#/soft/perftools/darshan/darshan-3.4.4/lib/pkgconfig:}"
> ```

```bash
cd darshan
./build.sh
cd ..
```

Build the workloads (the non-MPI smoke test and the MPI-IO test):

```bash
"$CC" -O2 workloads/mofka_forward_smoke.c -o workloads/mofka_forward_smoke
"$CC" -O2 workloads/mofka_forward_mpiio.c -o workloads/mofka_forward_mpiio
```

`mofka_forward_mpiio` exercises the MPIIO module (and its `MPI_File_close`
streaming hook). On Polaris the Cray `cc` wrapper is MPI-aware, so `$CC` links
MPI automatically; on other systems use `mpicc`.

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

> Make sure `server/env.sh` is sourced in this shell (it sets `$ROOT`); otherwise these paths collapse and the watch loops silently grep the wrong file.

```bash
RUN_DIR="${RUN_DIR:-$ROOT/server/_flowcept_run}"
MONGO_DB="${MONGO_DB:-darshan_stream}"
MONGO_PORT="${MONGO_PORT:-27017}"
EVENTS_JSONL="${EVENTS_JSONL:-/tmp/darshan-mofka-events.jsonl}"
mkdir -p "$RUN_DIR"
```

## 6. Start FlowCept As The Live Consumer

Start FlowCept before the workload. It runs in the background and continuously drains the `darshan` Mofka topic into MongoDB.

FlowCept's sink is a local MongoDB, so `mongod` must be reachable. It is an external
dependency (not built by this repo, and not a pip package — `mongod` is the MongoDB
*server*; the venv only has `pymongo`, the client). It runs as its own process, so it
never conflicts with the flowcept venv.

> **Polaris placement (important):** compute nodes **cannot see `$HOME`**, and they
> have **no internet**. So `mongod` must (1) be *downloaded/created on a login node*
> and (2) live on a **shared filesystem the compute nodes can see (`eagle`)** — not
> under `$HOME`. A `mongod` in a `$HOME` conda env will fail the `[[ -x ]]` check on
> a compute node. Put it under the repo (which is on `eagle`) and point `MONGOD` at it.

First check whether a usable `mongod` already exists on `eagle`:

```bash
find "$ROOT/.." -maxdepth 4 -name mongod -type f 2>/dev/null   # e.g. a prior conda env on eagle
```

If one is found and runs (`"$MONGOD" --version` prints and `ldd "$MONGOD" | grep -i "not found"` is empty), just point at it:

```bash
export MONGOD=/eagle/<proj>/<user>/.../envs/<mongo-env>/bin/mongod
```

Otherwise get one — **on a login node** (internet + `$HOME` both available there),
installing INTO the repo on `eagle`:

```bash
# Option A (portable, no root/conda): standalone MongoDB server tarball -> eagle
cd "$ROOT"                                   # $ROOT is on eagle
curl -sL https://fastdl.mongodb.org/linux/mongodb-linux-x86_64-ubuntu2204-7.0.14.tgz | tar xz
export MONGOD="$PWD/mongodb-linux-x86_64-ubuntu2204-7.0.14/bin/mongod"

# Option B (conda): create the env at a prefix ON EAGLE (not the default ~/ location)
# conda create -y -p "$ROOT/server/_mongo_env" -c conda-forge mongodb
# export MONGOD="$ROOT/server/_mongo_env/bin/mongod"
```

Then, back on the compute node, confirm it before starting the consumer:

```bash
[[ -x "$MONGOD" ]] && "$MONGOD" --version | head -1 || echo "MONGOD not set/visible on this node"
```

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

### 7b. Run The MPI-IO Workload (exercises the MPIIO module)

To test the MPIIO -> Mofka path, run the MPI workload under `mpiexec`. This is a
real MPI job, so do **not** set `DARSHAN_ENABLE_NONMPI`. Use more than one rank so
the shared-file / cross-rank behavior is exercised:

```bash
darshan_ensure_logdir

mpiexec -n 4 env \
  DARSHAN_MOFKA_ENABLE=1 \
  DARSHAN_MOFKA_GROUP_FILE="$ROOT/server/mofka.json" \
  DARSHAN_MOFKA_TOPIC=darshan \
  DARSHAN_MOFKA_TIMING=1 \
  DARSHAN_MOFKA_FLUSH_MS=10000 \
  DARSHAN_LOGPATH="$DARSHAN_LOGPATH" \
  LD_PRELOAD="$(darshan_lib)" \
  ./workloads/mofka_forward_mpiio /tmp/mofka-forward-mpiio \
  > /tmp/darshan-mofka-mpiio.out \
  2> /tmp/darshan-mofka-mpiio.err
```

Check it ran and streamed MPIIO events (including close):

```bash
cat /tmp/darshan-mofka-mpiio.out
grep 'darshan-mofka\[timing\] send' /tmp/darshan-mofka-mpiio.err | wc -l
grep -c '"module":"MPIIO"' "$EVENTS_JSONL"     # after the consumer drains
```

Expected: prints `mofka_forward_mpiio complete...`, a nonzero send count, and
MPIIO events (with `"op":"close"` present) in the captured JSONL. For a lossless
manual capture, pass the exact expected event count as `capture.py`'s target, or
start the consumer before the workload with a generous idle timeout.

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

## Optional DLIO Quickstart

This is the upstream DLIO quickstart. If DLIO is used as a Darshan-Mofka workload, start Mofka and FlowCept first, then choose a separate `MONGO_DB` and `EVENTS_JSONL` for the DLIO run.

```bash
git clone https://github.com/argonne-lcf/dlio_benchmark
cd dlio_benchmark/
pip install .
dlio_benchmark ++workload.workflow.generate_data=True
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
