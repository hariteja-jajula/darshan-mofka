# workloads/c/ -- C smoke + MPI-IO workloads

Two C workloads for exercising the connector's POSIX, STDIO, and MPI-IO paths.

| Source | Module(s) | MPI? |
|---|---|---|
| `mofka_forward_smoke.c` | POSIX + STDIO (incl. STDIO close) | no |
| `mofka_forward_mpiio.c` | MPIIO (incl. `MPI_File_close`) | yes |

Prereqs: the stack is built (`bash install/10-build.sh`), the broker is up
(`bash server/start-server.sh`), and a FlowCept consumer is draining the topic.
See the top-level [README](../../README.md) or
[docs/RUNBOOK.md](../../docs/RUNBOOK.md).

`$CC` is set by `server/env.sh`. On Polaris the Cray `cc` wrapper is MPI-aware,
so it links MPI automatically; on other systems use `mpicc` for the MPI-IO build.

## C smoke (non-MPI)

Build:

```bash
"$CC" -O2 workloads/c/mofka_forward_smoke.c -o workloads/c/mofka_forward_smoke
```

Run (note `DARSHAN_ENABLE_NONMPI=1` -- this is not an MPI job):

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
  ./workloads/c/mofka_forward_smoke /tmp/mofka-forward-smoke \
  > /tmp/darshan-mofka-workload.out \
  2> /tmp/darshan-mofka-workload.err
```

Verify it ran and streamed events:

```bash
cat /tmp/darshan-mofka-workload.out   # prints "mofka_forward_smoke complete..."
grep 'darshan-mofka\[timing\] send' /tmp/darshan-mofka-workload.err | wc -l   # nonzero
```

After the consumer drains, check the exported JSONL:

```bash
grep '"module":"POSIX"' "$EVENTS_JSONL" | head
grep '"module":"STDIO"' "$EVENTS_JSONL" | head
grep -E '"op":"(read|write)"' "$EVENTS_JSONL" | head
```

## MPI-IO

Build:

```bash
"$CC" -O2 workloads/c/mofka_forward_mpiio.c -o workloads/c/mofka_forward_mpiio
```

Run under `mpiexec` with more than one rank so the shared-file / cross-rank
behavior is exercised. Do **not** set `DARSHAN_ENABLE_NONMPI` -- this is a real
MPI job:

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
  ./workloads/c/mofka_forward_mpiio /tmp/mofka-forward-mpiio \
  > /tmp/darshan-mofka-mpiio.out \
  2> /tmp/darshan-mofka-mpiio.err
```

Verify it ran and streamed MPIIO events (including close):

```bash
cat /tmp/darshan-mofka-mpiio.out   # prints "mofka_forward_mpiio complete..."
grep 'darshan-mofka\[timing\] send' /tmp/darshan-mofka-mpiio.err | wc -l   # nonzero
grep -c '"module":"MPIIO"' "$EVENTS_JSONL"   # after the consumer drains
grep '"op":"close"' "$EVENTS_JSONL" | head    # MPI_File_close streamed
```
