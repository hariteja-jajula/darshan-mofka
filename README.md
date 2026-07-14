# darshan-mofka

Workloads and overhead measurement for the Darshan → Mofka connector. Runs a workload
under Darshan, streams its I/O records to a Mofka broker, and measures the streaming
overhead. Requires an existing Darshan build, diaspora-c install, and mofka/mochi stack;
builds none of them.

## Overhead study

Each workload runs in three modes:

- `none`   — no Darshan (baseline wall time)
- `native` — Darshan logging to a `.darshan` file, no streaming
- `mofka`  — Darshan streaming every I/O op to the broker

Streaming overhead is `mofka` minus `native`. The workload (`io_ckpt.*`) is a checkpoint
app: compute epochs with periodic bounded checkpoint I/O (write, fsync, read-back) to
`/tmp`. The study sweeps producer batch size {0, 1, 64}, 5 repeats per cell; the MPI job
omits batch 1 (uses {0, 64}) to avoid deadlock at 256 producers.
`jobs/analyze_overhead.py` reduces each run to `SUMMARY_AUTO.md`; `slides/` renders the
tables.

## Layout

```
darshan-mofka/
├── darshan/              submodule — connector fork
│                         branches: darshan-mofka (per-op), darshan-aggregate (aggregate)
├── diaspora-stream-api/  submodule — diaspora-c source
├── workloads/            io_ckpt.c/.py, io_mpi_ckpt.c, io_test
├── jobs/                 PBS jobs, analyze_overhead.py
├── server/               broker start/stop, capture.py
└── slides/               result tables
```

Clone with `--recursive` (or `git submodule update --init --recursive`). The submodules
pin the Darshan and diaspora-c source commits; their installs live outside git and are
referenced by env vars.

## Dependencies

Referenced by env var; not built here.

| Dependency | Env var | Notes |
|---|---|---|
| diaspora-c install | `DIASPORA_C` | dir with `include/diaspora/diaspora_c.h`, `lib/libdiaspora-c.so` |
| mofka / mochi stack | `MOFKA_SPACK_VIEW` | spack view with `bedrock`, `mofkactl`, python + `mochi.mofka` |
| darshan install | `DARSHAN_PREFIX` | dir with `lib/libdarshan.so` (from `darshan/build.sh`) |
| C compiler | `CC` / `module load` | Improv: `module load gcc/13.2.0`, matching diaspora-c |

## Build order

`mofka/mochi stack → diaspora-c → darshan → workloads`. Steps 1–2 are skippable if the
stack or diaspora-c already exist; re-point the env vars instead.

1. **mofka/mochi stack (spack).** Provides `bedrock`, `mofkactl`, python, and the deps
   for diaspora-c. Install with spack and expose as a view at `$MOFKA_SPACK_VIEW`.

2. **diaspora-c** (in `diaspora-stream-api`):
   ```bash
   cd diaspora-stream-api
   cmake -S . -B _build -DENABLE_C_API=ON \
         -DCMAKE_PREFIX_PATH="$MOFKA_SPACK_VIEW" -DCMAKE_INSTALL_PREFIX=$PWD/install
   cmake --build _build -j && cmake --install _build     # DIASPORA_C = ./install
   ```

3. **darshan** — see [Build darshan](#build-darshan) (needs `$DIASPORA_C`).

4. **workloads** — configure and run (below).

## Configure

`server/env.sh` derives the repo root from its own location, sources the optional
`server/env.local.sh` (per-machine, git-ignored), then auto-discovers the install paths —
`MOFKA_SPACK_VIEW`, `DIASPORA_C`, `DARSHAN_PREFIX`, `PY` — in conventional locations (the
`_discover` calls in `env.sh`). `DIASPORA_C` points at the install root: the directory
containing `include/` and `lib/` (e.g. `diaspora-stream-api/install`, or
`../diaspora-c-install-fork`), not a subdirectory.

`env.local.sh` holds only what can't be discovered — module loads and transport. Copy it
from `env.local.sh.example`:

```bash
# server/env.local.sh
module load gcc/13.2.0 openmpi/4.1.8
export MOFKA_PROTOCOL=verbs        # verbs (IB); env.sh defaults to ofi+tcp; not ofi+verbs (times out)
```

Override discovery only when it fails: set the variable in the environment before
sourcing, e.g. `DIASPORA_C=/path/to/install`.

## Build darshan

```bash
cd darshan && git checkout darshan-mofka       # darshan-mofka or darshan-aggregate
DIASPORA_C=$DIASPORA_C ./build.sh              # -> darshan/install
cd ..
```

## Run

Single node:
```bash
cd server && ./start-server.sh          # start the broker
cd ../workloads && ./run.sh             # io_test under Darshan -> mofka
```

Overhead study (PBS), one job per language:
```bash
cd jobs
qsub overhead_CKPT_C.pbs                # io_ckpt.c,     single node
qsub overhead_CKPT_PY.pbs               # io_ckpt.py,    single node
qsub overhead_CKPT_MPI.pbs              # io_mpi_ckpt.c, multi-node
```
Knobs default in-script; override per submit, e.g.
`qsub -v EPOCH_COMPUTE_S=1.45 overhead_CKPT_C.pbs` (see the study-matrix block at the top
of each script). Output goes to `jobs/runs/<stamp>/`: `results.csv`, `SUMMARY_AUTO.md`,
`overhead_summary.csv`. Regenerate the deck with `python3 slides/build_slides.py` (writes
`slides/overhead_tables.html`).

## Connector env vars

Read by the connector on the Darshan process; see `workloads/run.sh`.

| var | controls | default |
|---|---|---|
| `DARSHAN_MOFKA_ENABLE` | master switch | off |
| `DARSHAN_MOFKA_GROUP_FILE` | mofka group file | required |
| `DARSHAN_MOFKA_TOPIC` | topic | `darshan` |
| `DARSHAN_MOFKA_ENABLE_{POSIX,STDIO,MPIIO,HDF5}` | per-module streaming | off |
| `DARSHAN_MOFKA_BATCH` | producer batch size (0 = adaptive) | `0` (`MOFKA_BATCH_SIZE`) |
| `DARSHAN_MOFKA_MAX_BATCHES` | max in-flight batches; must be ≥ events/run or the producer can deadlock | `0` |
| `DARSHAN_MOFKA_FLUSH_MS` | finalize flush timeout, ms | `5000` |
| `DARSHAN_MOFKA_TIMING` | emit per-op send-timing lines | off |
| `DARSHAN_MOFKA_VERBOSE` | verbose logging | off |

## Infrastructure env vars

`env.sh` auto-discovers these; set one explicitly only to override discovery.

| var | points at | discovered at |
|---|---|---|
| `DIASPORA_C` | diaspora-c install root (`include/`, `lib/`) | `diaspora-stream-api/install`, else `../diaspora-c-install-fork` |
| `MOFKA_SPACK_VIEW` | mofka/mochi spack view | `mofka-view` (up to two levels up) |
| `DARSHAN_PREFIX` | darshan install | `darshan/install` |
| `DARSHAN_LOGPATH` | native `.darshan` log dir | `darshan-logs` |
| `MOFKA_PROTOCOL` | transport | env.local.sh sets `verbs`; env.sh default `ofi+tcp` (not `ofi+verbs`) |
