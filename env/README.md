# env

These scripts set up the shell environment for the demo. There are two you source
directly, depending on which machine role you are on.

## Which one to source

```bash
source env/server.sh     # the node that runs the broker, consumer, and MongoDB
source env/workload.sh   # the node that runs the Darshan-instrumented program
```

Both take an optional `--lcrc` or `--polaris` flag. If you leave it off, they
detect the cluster for you (LCRC/Improv vs. Polaris).

For a single-node run (like `job.sh`) you can source both; they layer cleanly.

## What each one gives you

- `server.sh` — the Python with FlowCept, the Mofka Python bindings, and the path
  to `mongod`. This is the consumer/broker side.
- `workload.sh` — the compiler, the Diaspora C library the connector links
  against, and the Darshan library you `LD_PRELOAD`. This is the producer side.

## The rest of the files

You don't source these directly; the two above pull them in.

- `_profile.sh` — decides whether you're on LCRC or Polaris.
- `common.sh` — loads the compiler and MPI modules shared by both sides.
- `lcrc.sh`, `polaris.sh` — the per-cluster details (where the Mofka stack lives,
  which network transport to use, where to find a recent CMake).

Everything here loads libraries through `module load` or the Spack stack. Nothing
hardcodes a path to a `.so` file.
