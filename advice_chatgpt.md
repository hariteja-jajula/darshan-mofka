# advice_chatgpt.md

Branch: `dev/cgpt`

Goal: make tomorrow's demo simple and separated: services on one node, workload on another node.

## What Changed

- Added two-node demo jobs:
- `jobs/c_two_node_flowcept.pbs`
- `jobs/dlio_two_node_flowcept.pbs`
- `jobs/two_node_demo.sh`
- Rank 0 runs Mofka + MongoDB + FlowCept and exports JSONL.
- Rank 1 runs the Darshan-instrumented C or DLIO workload.
- Added README section `Two-Node C And DLIO Demo` with minimal commands.
- Fixed `server/stop-server.sh` to honor `MOFKA_SERVER_DIR` so per-job brokers stop correctly.
- Fixed FlowCept settings rendering so `MONGO_PORT` actually reaches the YAML template.
- Updated Polaris env to derive paths from the checkout location and add known MongoDB env bins to `PATH` when present.
- Added gitignore rules for PBS/run artifacts.

## Verification

- Syntax checks passed:
- `bash -n jobs/two_node_demo.sh`
- `bash -n jobs/c_two_node_flowcept.pbs`
- `bash -n jobs/dlio_two_node_flowcept.pbs`
- `bash -n server/capture_flowcept.sh server/start-server.sh server/stop-server.sh server/env.sh server/env_polaris.sh`

## Submitted Jobs

- `7263441.polaris-pbs-01.hsn.cm.polaris.alcf.anl.gov`: C two-node FlowCept job from `dev/cgpt`; queued when submitted.

Older jobs I submitted from the original shared checkout before making this branch:

- `7263430.polaris-pbs-01.hsn.cm.polaris.alcf.anl.gov`: C smoke verification; queued.
- `7263432.polaris-pbs-01.hsn.cm.polaris.alcf.anl.gov`: compute-node preflight; queued.

All three were in `Q` state on the preemptable queue when last checked, so no runtime verdict yet.

## Tomorrow Demo Command

Inside a two-node interactive allocation:

```bash
cd /path/to/darshan-mofka
source server/env.sh --polaris
export RUN_DIR="$ROOT/server/_interactive_dlio_$(date +%Y%m%d_%H%M%S)"
export MOFKA_SERVER_DIR="$RUN_DIR/mofka"
export MONGO_DB="interactive_dlio"
export MONGO_PORT=27017
export EVENTS_JSONL="$RUN_DIR/events.jsonl"
mkdir -p "$RUN_DIR" "$MOFKA_SERVER_DIR"
mpiexec -n 2 --ppn 1 /bin/bash --noprofile --norc "$ROOT/jobs/two_node_demo.sh" dlio
cat "$RUN_DIR/export.count"
```

Expected success: `export.count` says `exported N...` with `N > 0`, and `$EVENTS_JSONL` contains POSIX/STDIO events.
