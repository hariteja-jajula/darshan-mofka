# darshan-mofka harness

Test harness for the **darshan → mofka** connector. This repo **builds nothing itself** —
it *points at* an already-available darshan build and diaspora-c install, brings up a
mofka broker, and runs workloads under darshan so I/O records stream to mofka.

## Workspace layout (three sibling repos)

```
<workspace>/
├── darshan/               connector fork — build with its own ./build.sh
│                          (branches: darshan-mofka = per-op firehose,
│                                     darshan-aggregate = aggregate/reconstructor)
├── darshan-mofka/         this harness (server / jobs / workloads)
└── diaspora-stream-api/   diaspora-c source (its built install lives elsewhere)
```

## Prerequisites — provided, NOT built here

You point the harness at these; it does not build or vendor them.

| Dependency | Point at it with | Notes |
|---|---|---|
| diaspora-c install | `DIASPORA_C` | dir with `include/diaspora/diaspora_c.h` + `lib/libdiaspora-c.so` |
| mofka / mochi stack | `MOFKA_SPACK_VIEW` | spack view providing `bedrock`, `mofkactl`, python w/ `mochi.mofka` |
| built darshan | `DARSHAN_PREFIX` | dir with `lib/libdarshan.so` (from `../darshan/build.sh`) |
| C compiler | `module load` / `CC` | on Improv: `module load gcc/13.2.0` (match diaspora-c's toolchain) |

## Configure — `server/env.local.sh` (machine-specific, git-ignored)

Copy `server/env.local.sh.example` → `server/env.local.sh` and set the pointers:

```bash
module load gcc/13.2.0 openmpi/4.1.8
export DIASPORA_C=/home/hjajula/internship/diaspora-c-install-fork
export MOFKA_SPACK_VIEW=/home/hjajula/internship/mofka-view
export PY="$MOFKA_SPACK_VIEW/bin/python"
export DARSHAN_PREFIX=$HOME/internship/darshan-mofka/darshan/install
export MOFKA_PROTOCOL=ofi+verbs       # or ofi+tcp
```

## Build darshan (points at the available diaspora-c)

The build lives in the darshan repo, not here:

```bash
cd ../darshan && git checkout darshan-mofka          # pick the version
DIASPORA_C=$DIASPORA_C ./build.sh                    # -> ../darshan/install
export DARSHAN_PREFIX=$PWD/install
```
Already have a darshan install elsewhere? Skip this and just set `DARSHAN_PREFIX`.

## Run — single node

```bash
cd server && ./start-server.sh                       # mofka broker
cd ../workloads && ./run.sh                           # io_test under darshan -> mofka
```

## Run — multi-node (PBS)

```bash
qsub -A <account> -q debug -l select=2:ncpus=128:mpiprocs=128 -l walltime=00:30:00
cd jobs && bash multinode-percore.pbs                 # per-core; also singlenode.pbs / multinode.pbs
```

## All the "point at what's available" knobs

| var | points at | default |
|---|---|---|
| `DIASPORA_C` | diaspora-c install | (required, in env.local.sh) |
| `MOFKA_SPACK_VIEW` | mofka/mochi spack view | (in env.local.sh) |
| `DARSHAN_PREFIX` | built darshan install | `$ROOT/darshan-install` |
| `DARSHAN_SRC` | darshan source (for `../darshan/build.sh`) | `../darshan/darshan-runtime` |
| `DARSHAN_LOGPATH` | where native `.darshan` logs go | `$ROOT/darshan-logs` |
| `MOFKA_PROTOCOL` | transport | `ofi+verbs` |

Nothing here clones or compiles a dependency — swap in a different darshan branch,
diaspora-c, or mofka stack purely by re-pointing these variables.
