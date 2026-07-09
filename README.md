# darshan-mofka harness

Test harness for the **darshan → mofka** connector. This repo **builds nothing itself** —
it *points at* an already-available darshan build and diaspora-c install, brings up a
mofka broker, and runs workloads under darshan so I/O records stream to mofka.

## Layout (harness umbrella + submodules)

```
darshan-mofka/            this harness (umbrella repo)
├── darshan/              submodule — connector fork
│                         (branches: darshan-mofka = per-op firehose,
│                                    darshan-aggregate = aggregate/reconstructor)
├── diaspora-stream-api/  submodule — diaspora-c source
└── server/ jobs/ workloads/
```

Clone with `git clone --recursive` (or `git submodule update --init --recursive` if
already cloned). The submodules pin the darshan + diaspora-c source commits; their
built *installs* still live outside git and are pointed at by env vars (below).

## Prerequisites — provided, NOT built here

You point the harness at these; it does not build or vendor them.

| Dependency | Point at it with | Notes |
|---|---|---|
| diaspora-c install | `DIASPORA_C` | dir with `include/diaspora/diaspora_c.h` + `lib/libdiaspora-c.so` |
| mofka / mochi stack | `MOFKA_SPACK_VIEW` | spack view providing `bedrock`, `mofkactl`, python w/ `mochi.mofka` |
| built darshan | `DARSHAN_PREFIX` | dir with `lib/libdarshan.so` (from `darshan/build.sh`) |
| C compiler | `module load` / `CC` | on Improv: `module load gcc/13.2.0` (match diaspora-c's toolchain) |

## Installation flow (dependency order)

Each layer needs the one above it:
`mochi/mofka stack → diaspora-c → darshan → harness`.

**0. Clone the harness with its submodules**
```bash
git clone --recursive <this-harness>        # brings darshan/ + diaspora-stream-api/
# already cloned non-recursively? git submodule update --init --recursive
```

**1. mochi/mofka stack (spack) — one-time, heaviest.** Provides `bedrock`/`mofkactl`/python
*and* the deps to build diaspora-c.
```bash
spack -e spack-env install          # → a view: $MOFKA_SPACK_VIEW
```
*Skip if you already have a `mofka-view` — just point `MOFKA_SPACK_VIEW` at it.*

**2. diaspora-c (from `diaspora-stream-api`)**
```bash
cd diaspora-stream-api
cmake -S . -B _build -DENABLE_C_API=ON \
      -DCMAKE_PREFIX_PATH="$MOFKA_SPACK_VIEW" -DCMAKE_INSTALL_PREFIX=$PWD/install
cmake --build _build -j && cmake --install _build     # → $DIASPORA_C = ./install
```
*Skip if you already have a diaspora-c install — point `DIASPORA_C` at it.*

**3. darshan** — build against diaspora-c (see *Build darshan* below; needs `$DIASPORA_C`).

**4. harness** — configure + run (see *Configure* and *Run* below; points at
`$DARSHAN_PREFIX`, `$MOFKA_SPACK_VIEW`, `$DIASPORA_C`).

> Nothing here rebuilds a dependency you already have — steps 1–2 are skippable by
> re-pointing the env vars. On a machine where the stack + diaspora-c already exist,
> installation is just steps 3–4.

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

The build lives in the darshan submodule:

```bash
cd darshan && git checkout darshan-mofka             # pick the version (darshan-mofka / darshan-aggregate)
DIASPORA_C=$DIASPORA_C ./build.sh                    # -> darshan/install
cd ..
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
| `DARSHAN_PREFIX` | built darshan install | set to `$ROOT/darshan/install` |
| `DARSHAN_LOGPATH` | where native `.darshan` logs go | `$ROOT/darshan-logs` |
| `MOFKA_PROTOCOL` | transport | `ofi+verbs` |

Nothing here clones or compiles a dependency — swap in a different darshan branch,
diaspora-c, or mofka stack purely by re-pointing these variables.
