# workloads/

Workloads for exercising the Darshan-Mofka connector. Each subdirectory has its
own README with build, run, and verify steps.

## Choosing what to run: `workload.config`

You pick the workload and its size in one place — [`workload.config`](workload.config) —
and `job.sh` reads it. Two knobs control the size, and the event count is derived from
them (no wall-clock knob):

```yaml
workload: c        # c | python-ml | mpi | dlio
events: 8          # training steps / epochs
checkpoints: 2     # how many checkpoints to write across the run
```

For the C workload that means `events + 2` POSIX events plus `3 x checkpoints` STDIO
events; for python-ml, `events` becomes epochs and `checkpoints` the number of
checkpoint files. Override any key for a single run with an env var of the same
uppercase name, e.g. `EVENTS=50000 CHECKPOINTS=50 bash job.sh`.

| Workload | Directory | Exercises | Notes |
|---|---|---|---|
| C smoke (non-MPI) | [`c/`](c/README.md) | POSIX + STDIO modules (incl. STDIO close) | the default `job.sh` workload |
| MPI-IO | [`c/`](c/README.md) | MPIIO module (incl. `MPI_File_close`) | real MPI job; run under `mpiexec` |
| DLIO | [`dlio/`](dlio/README.md) | POSIX via a realistic DL I/O benchmark | optional; external benchmark |

Before running any workload you need the stack built and a Mofka broker +
FlowCept consumer up. See the top-level [`README.md`](../README.md) quickstart,
or [`docs/RUNBOOK.md`](../docs/RUNBOOK.md) for the full manual pipeline.
