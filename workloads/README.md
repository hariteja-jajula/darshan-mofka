# workloads/

Workloads for exercising the Darshan→Mofka connector, plus the one runner that drives
the whole pipeline.

- **[`workload.config`](workload.config)** — pick the workload, its size, and the topology
  (nodes / tasks / placement / brokers). The one file you edit to say *what to run and where*.
- **[`job.sh`](job.sh)** — the runner. Reads `workload.config` + `../server/server.config`,
  stands up the broker + FlowCept consumer for the topology, runs the workload, reconstructs
  the `.darshan` log from the stream, and compares it 1:1 to the native log.

**To run, see [`../WORKFLOW.md`](../WORKFLOW.md)** — the short edit-config → `submit.sh` →
`results/` guide. In brief:

```bash
# edit workloads/workload.config, then:
PBS_ACCOUNT=radix-io bash submit.sh
```

## The workloads

| Workload | Directory | Exercises |
|---|---|---|
| C (non-MPI) | [`c/`](c/README.md) | POSIX + STDIO (models an ML train loop: writes per epoch, STDIO checkpoints) |
| python-ml | [`python-ml/`](python-ml/README.md) | POSIX + STDIO from a small ML-style train/eval |
| MPI-IO | [`mpi/`](c/README.md) | MPIIO module (real MPI job) |
| DLIO | [`dlio/`](dlio/README.md) | POSIX via a realistic DL I/O benchmark (optional) |

Size is controlled by `events` + `checkpoints` in `workload.config` (no wall-clock knob) —
the C workload prints the exact event count before it runs. Any config key can be overridden
for one run with an env var of the same UPPERCASE name (e.g. `EVENTS=50000 bash submit.sh`).
