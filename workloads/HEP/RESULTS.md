# HEP/SALT streaming — verification & overhead

Darshan I/O telemetry streamed live through the Mofka connector during GN2/SALT
GPU training (High Energy Physics jet tagging), on ALCF Polaris.

## Setup

- **Platform:** Polaris, debug queue, 2 nodes (1 broker/consumer + 1 workload), `ofi+cxi`, MPMD launch.
- **Workload:** SALT `fit` (GN2 model) in `salt-dev.sif`, torch 2.12.0+cu126 on A100-SXM4-40GB, 2 epochs on the synthetic `dummy_data/` HDF5 set.
- **Connector:** ring-free direct `diaspora_producer_push()`; slim per-op envelope (live telemetry). Native `.darshan` remains the source of truth for full heatmaps.
- **Reps:** 3 per arm. `EVENTS=100`, `WALLTIME=00:30:00`.

Reproduce:

```
ARMS="baseline runtimeonly streaming" STUDY=HEP_VERIFY REPS=3 \
  EVENTS=100 WALLTIME=00:30:00 bash workloads/HEP/run_HEP.sh
bash deliverables/hep_overhead_extract.sh results/HEP_VERIFY
```

## Verification (streaming works end-to-end)

SALT trains 2 epochs cleanly under active streaming (no `OSError: [Errno 0]`,
no `<frozen getpath>` abort — see the errno fix below), and events land in the
consumer. Per-rep live events streamed, all `INGEST: PASS`:

| rep  | events | modules              |
|------|--------|----------------------|
| RUN1 | 5302   | POSIX 5065 + STDIO 237 |
| RUN2 | 6625   | POSIX + STDIO        |
| RUN3 | 6875   | POSIX + STDIO        |

Ops observed: `open / refopen / read / write / seek / close`.

## Overhead (wall clock, workload region)

RUN1 in every arm is a container cold-cache outlier (first Apptainer launch on
the node pays image warmup), so the honest steady-state number is the **warm
mean (RUN2+)**; the all-reps mean is shown too.

| arm          | warm mean (RUN2+) | all mean | per-rep (s), RUN1=cold |
|--------------|-------------------|----------|------------------------|
| baseline     | **74.56 s**       | 76.48 s  | 80.32, 74.08, 75.04    |
| runtimeonly  | 85.67 s           | 90.32 s  | 99.63, 86.68, 84.65    |
| streaming    | 84.95 s           | 88.88 s  | 96.73, 84.91, 85.00    |

**Overhead vs baseline (warm):**

- Darshan runtime instrumentation (`runtimeonly`): **+11.11 s / +14.9 %**
- Darshan + live Mofka streaming (`streaming`): **+10.39 s / +13.9 %**

### Takeaway

Live Mofka streaming adds **no measurable cost on top of Darshan's runtime
instrumentation** — streaming (84.95 s) is within run-to-run jitter of
runtimeonly (85.67 s), even a hair lower. The whole ~14 % is the Darshan
instrumentation layer on this short, GPU-bound run; the ring-free direct-push
connector's live streaming is effectively free relative to it.

Connector push cost (streaming arm, weighted mean across ranks/reps):
~360–490 µs per push, ~18.8 k pushes total across 3 reps.

## The errno fix (why streaming previously crashed SALT)

The connector runs synchronously inside Darshan's POSIX/STDIO wrappers, between
the real syscall and the application's `errno` check. `diaspora_producer_push()`
and `darshan_core_wtime()` issue their own syscalls that overwrite `errno`, so
an instrumented app saw a corrupted `errno` — CPython's `<frozen getpath>`
aborted at interpreter startup with `OSError: [Errno 0]` under active streaming.
Fixed by save-on-entry / restore-on-every-exit in the connector
(`darshan-runtime/lib/darshan-mofka.c`, 13 sites across
initialize/send/finalize). This is why SALT trained fine when `libmofka.so`
failed to load (producer NULL → send early-returns) but crashed once the
connector became active.

_Numbers above from study `HEP_VERIFY` (jobs 7459748 / 7459966 / 7460072 / 7460177)._
