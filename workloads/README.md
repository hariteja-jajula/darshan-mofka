# workloads/

Demo workloads run under `LD_PRELOAD=libdarshan.so` so the Darshan-Mofka
connector streams their I/O events into the `darshan` Mofka topic. Each
subdirectory has its own README with build + run + verify steps.

| Workload | Directory | Exercises | Notes |
|---|---|---|---|
| C smoke (non-MPI) | [`c/`](c/README.md) | POSIX + STDIO modules (incl. STDIO close) | the default `job.sh` workload |
| MPI-IO | [`c/`](c/README.md) | MPIIO module (incl. `MPI_File_close`) | real MPI job; run under `mpiexec` |
| DLIO | [`dlio/`](dlio/README.md) | POSIX via a realistic DL I/O benchmark | optional; external benchmark |

Before running any workload you need the stack built and a Mofka broker +
FlowCept consumer up. See the top-level [`README.md`](../README.md) quickstart,
or [`docs/RUNBOOK.md`](../docs/RUNBOOK.md) for the full manual pipeline.
