# Deploying / shipping darshan-mofka reproducibly

This repo ships **recipes, not binaries**. The stack has four dependency layers,
each reproduced a different way. This doc maps each layer to its exact
reproduction command, then describes the single-node and split-node run models.

## The four layers

| # | Layer | What | Reproduce with | In git |
|---|-------|------|----------------|--------|
| 1 | Native HPC stack | Bedrock, Mochi (margo/mercury/thallium/warabi/yokan/flock), Mofka, cmake, Darshan-util deps (~1 GB compiled) | `server/spack/spack.yaml` + `spack.lock` → `spack install` | spec only |
| 2 | Python consumer | flowcept, pymongo, pydantic, … (venv on the spack python) | `server/requirements.txt` + `pip install -e flowcept/` | reqs + submodule |
| 3 | MongoDB server (`mongod`) | the DB server binary (FlowCept's sink) — **not** a pip package | `server/mongo-environment.yml` → `conda env create` | conda spec |
| 4 | Project source | darshan fork (Mofka connector), diaspora-stream-api, workloads | git submodules + `darshan/build.sh` | yes |

Binaries for layers 1–3 are large/host-specific and are **not** committed. Rebuild
them from the specs above on the target machine.

## Fresh-account bring-up (Polaris)

```bash
# 0. clone + submodules
git clone <this repo> darshan-mofka && cd darshan-mofka
git submodule update --init --recursive

# 1. native stack (see server/spack/README.md) -- on a login node, -j4
git clone --depth=1 https://github.com/spack/spack.git
. spack/share/spack/setup-env.sh
spack env create flowcept-mofka-polaris server/spack/spack.lock   # pinned
spack env activate flowcept-mofka-polaris
spack install -j4
export MOFKA_SPACK_VIEW="$(spack location --env)/.spack-env/view"

# 2. python venv (layer 2)
python -m venv ../envs/flowcept-py314
source ../envs/flowcept-py314/bin/activate
pip install -r server/requirements.txt
pip install -e flowcept/

# 3. mongod (layer 3) -- install to a prefix on EAGLE (compute nodes can't see $HOME)
conda env create -p "$PWD/server/_mongo_env" -f server/mongo-environment.yml
#   env_polaris.sh auto-detects server/_mongo_env/bin/mongod

# 4. project source (layer 4) -- on a compute node
source server/env.sh --polaris
module unload darshan
export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:${PKG_CONFIG_PATH#/soft/perftools/darshan/darshan-3.4.4/lib/pkgconfig:}"
cd diaspora-stream-api && cmake -S . -B _build -DENABLE_C_API=ON -DENABLE_PYTHON=ON \
     -DCMAKE_PREFIX_PATH="$MOFKA_SPACK_VIEW" -DCMAKE_INSTALL_PREFIX="$PWD/install" \
     && cmake --build _build -j && cmake --install _build && cd ..
source server/env.sh --polaris          # re-source: puts pydiaspora on PYTHONPATH
cd darshan && ./build.sh && cd ..
```

Then run the demo (single-node README §4–§12, or the split model below).

## Why everything must live on `eagle`

Polaris **compute nodes cannot see `$HOME`.** Every artifact the runtime touches —
the spack view, the venv, `mongod`, the darshan lib, and the broker group file
`mofka.json` — must sit on a shared filesystem (`eagle`). `server/env_polaris.sh`
and the role scripts assume this. In particular `mongod` is resolved in order:
`$MONGOD` → `server/_mongo_env/bin/mongod` → known on-eagle conda envs → `PATH`.

## Run models

### Single node (README)
Server + workload co-located. Follow `README.md` §4–§12, or the one-shot block at
the end of the README. Validated: POSIX/STDIO events stream, close events land,
reconstruct matches native.

### Split nodes (server role / workload role)
The pipeline couples the two roles ONLY through a shared run dir on eagle:

```
$RUN_DIR/mofka.json   broker address (routable HSN) written by the server node
$RUN_DIR/READY        server up: broker + mongod + consumer alive
$RUN_DIR/DONE         workload side finished
$RUN_DIR/events.jsonl exported result
```

- **Server role** (1 node): `server/roles/server-node.sh` — broker + mongod +
  FlowCept consumer; publishes `mofka.json` + `READY`, idles until `DONE`, then
  flushes + exports MongoDB → JSONL.
- **Workload role** (N nodes): `server/roles/workload-node.sh` — needs no broker,
  mongod, or python; just sources env (for the view libs on `LD_LIBRARY_PATH`),
  waits for `READY`, then runs a workload under `LD_PRELOAD="$(darshan_lib)"` with
  `DARSHAN_MOFKA_GROUP_FILE=$RUN_DIR/mofka.json`.
- **Orchestrator**: `jobs/split_nodes.pbs` — requests `select=N`, puts the server
  role on node 0 and the workload role on nodes 1..N-1 via PALS
  (`mpiexec --ppn 1 --hosts`), coordinating through `$RUN_DIR` on eagle.

```bash
PBS_ACCOUNT=<project> NNODES=2 bash jobs/split_nodes.pbs
```

## Capturing the exact environment for a ship

After a good run on a compute node, snapshot what was actually in play:

```bash
source server/env.sh --polaris
bash server/capture-env.sh          # writes server/env-snapshot/
```

That records loaded modules, demo env vars, toolchain versions, `spack find`,
`pip freeze`, the conda mongo env export, and an import sanity check — committed so
a reviewer can see the precise versions behind the pinned specs.
