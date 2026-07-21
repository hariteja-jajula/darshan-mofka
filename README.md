# darshan-mofka

Stream Darshan runtime I/O events into a Mofka topic.

The connector emits JSON metadata events from the Darshan runtime to Mofka;
FlowCept drains the topic into MongoDB. If the job exits before Darshan writes
its final log, a partial `.darshan` log can be reconstructed from the captured
stream.

## What it does

- Streams POSIX, STDIO, and MPI-IO events to Mofka, including STDIO close and
  `MPI_File_close` events.
- Reconstructs a partial Darshan log from the stream; reconstructed OPENS match
  the native Darshan log, aside from overlay/unknown-label differences.
- Builds from source with pinned versions and no hardcoded paths/accounts.

## Check your setup

Darshan devs on Polaris usually already have most of the stack. Before setting up
anything, see what you have and what's missing (this downloads nothing):

```bash
bash check-deps.sh
```

It prints a PRESENT/MISSING row per dependency and exits 0 when everything is
ready (then just `bash job.sh`). For anything MISSING, follow the section below.

## Dependencies & Environments

Four layers. Each is declared in-repo; get them however you prefer (reuse an
existing build, module load, spack, conda, pip). Then `source server/env.sh
--polaris` so the demo finds them.

**1. Native HPC stack (spack view): Bedrock, Mochi, Mofka, Darshan-util deps.**
Spec: [`server/spack/spack.yaml`](server/spack/spack.yaml) (+ `spack.lock` for the
exact pinned concretization). See [`server/spack/README.md`](server/spack/README.md).

```bash
git clone --depth=1 https://github.com/spack/spack.git
. spack/share/spack/setup-env.sh
spack env create flowcept-mofka-polaris server/spack/spack.yaml
spack env activate flowcept-mofka-polaris
# edit spack.yaml: point develop.mofka.path at a mofka checkout, then:
spack install -j4            # -j4: Polaris login-node fork cap
export MOFKA_SPACK_VIEW="$(spack location --env flowcept-mofka-polaris)/.spack-env/view"
```

**2. Python consumer venv (>= 3.11).** Deps: [`server/requirements.txt`](server/requirements.txt)
(exact pins in `server/requirements.lock.txt`).

```bash
python -m venv ../envs/flowcept-py314
source ../envs/flowcept-py314/bin/activate
pip install -r server/requirements.txt
pip install -e flowcept/          # the flowcept submodule
```

(mochi.mofka / pydiaspora come from the spack view, not pip.)

**3. MongoDB server (`mongod`) — FlowCept's sink.** External dep, not pip. Reuse
one on a shared filesystem, or install a standalone tarball / conda `mongodb`,
then `export MONGOD=/path/to/mongod`. On Polaris it must live on **eagle** (compute
nodes can't see `$HOME`). Details in [`docs/RUNBOOK.md`](docs/RUNBOOK.md) step 6.

**4. Project source (submodules) + the Darshan fork.**

```bash
git submodule update --init --recursive
source server/env.sh --polaris
DIASPORA_C="$DIASPORA_C" ./build.sh      # builds darshan/install (the Mofka connector)
```

## Run

Once `check-deps.sh` is green, run end to end on a **compute node** (the Mofka
broker's fabric transport doesn't come up on login nodes):

```bash
qsub -I -q debug -A <project> -l select=1 -l walltime=01:00:00 -l filesystems=home:eagle
cd <repo>
bash job.sh
```

See [`docs/RUNBOOK.md`](docs/RUNBOOK.md) for the full manual pipeline (broker +
consumer + workload + export), and [`workloads/README.md`](workloads/README.md)
for the individual workloads.

## Automated setup (backup)

If you'd rather not set up the layers by hand, the `install/` scripts stage and
build everything from pinned versions (Polaris has no internet on compute nodes,
so fetch runs on a login node):

```bash
bash install/00-fetch.sh    # LOGIN node (internet): stage spack, mongod, wheels, submodules -> eagle
bash install/10-build.sh    # LOGIN or COMPUTE node, offline: build from the staged sources
bash job.sh                 # COMPUTE node: run + verify
```

`install/config.yaml` holds versions/names; `install/lock/` holds the exact
pinned concretization. See [`install/README.md`](install/README.md).

## Verifying the result

After a run, `$EVENTS_JSONL` holds the streamed events. A compact summary:

```bash
"$PY" - "$EVENTS_JSONL" <<'PY'
import json, sys
from collections import Counter
mods, ops = Counter(), Counter()
for line in open(sys.argv[1]):
    ev = json.loads(line)
    mods[ev.get('module')] += 1
    ops[ev.get('op')] += 1
print('modules:', dict(mods))
print('ops:', dict(ops))
PY
```

Reconstruct a partial log from the stream and validate it with Darshan's parser:

```bash
./darshan/install/bin/darshan-mofka-reconstruct "$EVENTS_JSONL" /tmp/job_partial.darshan
./darshan/install/bin/darshan-parser --show-incomplete /tmp/job_partial.darshan | head -80
```

## Repository layout

```text
darshan-mofka/
├── darshan/              Darshan submodule with the Mofka connector
├── diaspora-stream-api/  Diaspora C API submodule used by the connector
├── flowcept/             FlowCept submodule (the live consumer)
├── build.sh              build the vendored darshan fork into darshan/install
├── check-deps.sh         read-only dependency check (skip setup you already have)
├── job.sh                one-shot end-to-end demo on a compute node
├── install/              automated setup backup (config-driven, pinned)
├── docs/RUNBOOK.md       full manual pipeline + Polaris workarounds
├── server/               environment, broker start/stop, capture consumer
│   ├── spack/            Spack spec to rebuild the Mofka/FlowCept stack
│   └── requirements.txt  Python deps for the FlowCept consumer venv
└── workloads/            demo workloads (see workloads/README.md)
    ├── c/                POSIX/STDIO smoke + MPI-IO tests
    └── dlio/             optional DLIO benchmark
```

The old overhead-study jobs, result scripts, slides, and extra workloads were cut
from this branch. Recover them from the study branch if needed.

## What gets streamed

The connector streams JSON metadata events only, not application file contents.

The `rec_hex` field, when present, is a hex-encoded copy of Darshan's internal
module record at the time of the event. It is profiling/record state, not user
file data.

## Connector environment variables

Variables read by the Darshan-instrumented process:

| Variable | Meaning | Default |
|---|---|---|
| `DARSHAN_MOFKA_ENABLE` | Enables Mofka streaming | off |
| `DARSHAN_MOFKA_GROUP_FILE` | Mofka group file, usually `server/mofka.json` | required |
| `DARSHAN_MOFKA_TOPIC` | Topic name | `darshan` |
| `DARSHAN_MOFKA_BATCH` | Producer batch size; `0` means adaptive | `0` |
| `DARSHAN_MOFKA_MAX_BATCHES` | Max pending batches; `0` means library default | `0` |
| `DARSHAN_MOFKA_FLUSH_MS` | Finalize flush timeout in milliseconds | `5000` |
| `DARSHAN_MOFKA_TIMING` | Print per-call timing lines | off |
| `DARSHAN_MOFKA_VERBOSE` | Print connector setup details | off |

There are no per-module enable variables on this branch. If Darshan calls the
Mofka send hook, the connector forwards the event.

## More documentation

- [`server/spack/README.md`](server/spack/README.md) -- rebuild the native Mofka/FlowCept stack.
- [`docs/RUNBOOK.md`](docs/RUNBOOK.md) -- full manual pipeline, one-shot block, troubleshooting, Polaris workarounds.
- [`workloads/README.md`](workloads/README.md) -- how to run each workload type (C smoke, MPI-IO, DLIO).
- [`install/README.md`](install/README.md) -- automated setup backup (phased, pinned).
