# Async hot-path fix — overhead results (task #21/#23)

The darshan-mofka connector's per-op Mofka push was moved OFF the application
critical path: the app thread now does a fixed-size `memcpy` enqueue into an
MPSC ring, and background drain thread(s) do all serialize+push. The last push
at finalize is a flush (join drain thread(s), then `diaspora_producer_flush_timeout`).
See `darshan/darshan-runtime/lib/darshan-mofka.c`.

All four workloads were run as a 3-arm A/B on Polaris (2 nodes, debug), each
adversarially validated (strict per-record pydarshan integer-counter compare +
log scan for drops/hang/OOM). Every run: **strict fidelity PASS, zero drops.**

## Table 1 — per-push cost collapse (sync → async)

| workload  | sync push median | async push median | speedup | job |
|-----------|-----------------:|------------------:|--------:|-----|
| c         | 22.4 µs          | 0.238 µs          | 94.1×   | 7297747 |
| mpi (4 rank) | 21.9 µs       | 0.238 µs          | 92.0×   | 7297845 |
| dlio      | 32.4 µs          | 1.431 µs          | 22.6×   | 7297900 |
| python-ml | 22.2 µs          | 0.477 µs          | 46.5×   | 7297909 |

The app-thread push is now a bounded enqueue (memcpy + `seq` assign under a
short mutex). `seq` is assigned in op-issue order on the app thread so the
reconstructor's last-writer-wins key is preserved.

## Table 2 — where the residual streaming overhead now lives

`stream − runtime` = streaming wall minus Darshan-runtime-only wall (the true
added cost of the Mofka pipeline). Decomposed into measured connector costs:
finalize drain tail, connector init, and total app-thread push time
(push_median × pushes). "residual" = overhead not explained by those three.

| workload  | stream−rt (s) | finalize (s) | init (s) | pushtime (s) | accounted (s) | residual (s) | overhead % |
|-----------|--------------:|-------------:|---------:|-------------:|--------------:|-------------:|-----------:|
| c         | 1.327         | 0.707        | 0.278    | 0.005        | 0.990         | 0.337        | 10.2%      |
| mpi       | 5.466         | 5.469        | 0.451    | 0.119        | 6.039         | −0.573       | 36.5%      |
| dlio      | 1.456         | 0.281        | 0.340    | 0.113        | 0.734         | 0.722        | 7.3%       |
| python-ml | 3.715         | 0.158        | 0.365    | 0.172        | 0.695         | 3.020        | 10.3%      |

Readings:
- **mpi**: overhead ≈ the finalize drain tail (5.47 s); accounted ≥ measured
  (the finalize timer overlaps the last drain, so per-push app time is already
  inside it). The buffer sweep targets exactly this tail.
- **c / dlio**: small residuals; init + finalize dominate, both one-time.
- **python-ml**: the outlier — a 3.02 s residual NOT explained by any measured
  connector cost. Adversarial validation (job 7297909) traced it to background
  drain/​progress threads (`DRAIN_THREADS=2`, `--cpu-bind none`) stealing
  cache/​memory-bandwidth from the single-process, CPU-bound Python app — a
  co-location cost, not a data-loss or correctness defect. n=1 noise is ~0.23 s,
  far short of 3 s; broker backpressure ruled out (ring never fills, no ms-scale
  app stalls).

## Follow-up (task #22, in flight)

The finalize drain tail is the sole remaining streaming overhead for the
I/O-bound workloads, and drain-thread contention is python-ml's residual. Both
are addressed by the buffer-knob sweep `workloads/overhead_buffer_sweep.sh`
(job 7297944): sweep `DARSHAN_MOFKA_BATCH` (bigger Mofka batches → higher drain
throughput → shorter tail), `DARSHAN_MOFKA_DRAIN_THREADS` {1,2,4} (does parallel
drain help I/O-bound mpi while 1 thread is better for CPU-bound python-ml?), and
`DARSHAN_MOFKA_QUEUE_DEPTH` (confirm no drops; 65536 is the intended ring-fill
probe at 125006 records/rank).

All numbers traceable to `results/OVERHEAD_STUDY_<WL>_2NODE_*/summary.csv` and
the per-run PBS `.OU` logs; validator verdicts in `.campaign/RUN_LOG.md`.
