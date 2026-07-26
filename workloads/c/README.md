# workloads/c/ -- C smoke + MPI-IO workloads

Two C workloads for exercising the connector's POSIX, STDIO, and MPI-IO paths.

| Source | Module(s) | MPI? |
|---|---|---|
| `mofka_forward_smoke.c` | POSIX + STDIO (incl. STDIO close) | no |
| `mofka_forward_mpiio.c` | MPIIO (incl. `MPI_File_close`) | yes |

Prereqs: the stack is built (see the top-level [README](../../README.md)
"Quick start", or `bash install/setup.sh`), the broker is up
(`bash server/start_server.sh`), and a FlowCept consumer is draining the topic.

`$CC` is set by `env/server.sh`. On Polaris the Cray `cc` wrapper is MPI-aware,
so it links MPI automatically; on other systems use `mpicc` for the MPI-IO build.

## Build

```bash
"$CC" -O2 workloads/c/mofka_forward_smoke.c -o workloads/c/mofka_forward_smoke   # non-MPI smoke
"$CC" -O2 workloads/c/mofka_forward_mpiio.c -o workloads/c/mofka_forward_mpiio   # MPI-IO
```

## Run

The full run env block (`LD_PRELOAD`, the `DARSHAN_MOFKA_*` variables, and the
`darshan_ensure_logdir` / `mpiexec` invocation) is in
[docs/RUNBOOK.md](../../docs/RUNBOOK.md) step 7. In short: run the smoke test
non-MPI (`DARSHAN_ENABLE_NONMPI=1`), and run the MPI-IO test under `mpiexec -n 4`
with `DARSHAN_ENABLE_NONMPI` *unset* so the shared-file / cross-rank behavior is
exercised.

## Verify

```bash
cat /tmp/darshan-mofka-workload.out                                # "..._smoke complete..." / "..._mpiio complete..."
grep 'darshan-mofka\[timing\] send' /tmp/darshan-mofka-workload.err | wc -l   # nonzero send count
```

After the consumer drains, check the exported JSONL:

```bash
grep '"module":"POSIX"' "$EVENTS_JSONL" | head
grep '"module":"STDIO"' "$EVENTS_JSONL" | head
grep -c '"module":"MPIIO"' "$EVENTS_JSONL"     # MPI-IO run
grep '"op":"close"' "$EVENTS_JSONL" | head     # MPI_File_close streamed
```
