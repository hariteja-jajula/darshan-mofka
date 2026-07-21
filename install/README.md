# install/ -- automated setup (backup path)

This is the **automated backup** to the manual setup in the top-level
[README](../README.md). Prefer the README's "Dependencies & Environments" steps
if you already have parts of the stack (run `bash check-deps.sh` first to see what
you're missing). Use these scripts when you'd rather stage and build everything
from pinned versions in one shot.

Builds the darshan-mofka stack from source: the native spack stack
(Bedrock/Mochi/Mofka/cmake/darshan-util deps), `mongod`, the python consumer, and
the project source (darshan + diaspora). Paths, accounts, and usernames are not
hardcoded.

## Why it's phased (Polaris has no internet on compute nodes)

Polaris compute nodes cannot download dependencies, so the build is split:

| Phase | Script | Where | Does |
|-------|--------|-------|------|
| 1 fetch | `00-fetch.sh` | **login node** (internet) | submodules, clone+`spack fetch`, conda `mongod`, pip wheels → all onto **eagle** |
| 2 build | `10-build.sh` | login **or** compute (offline) | `spack install`, diaspora, darshan runtime, darshan-util, workload |
| 3 freeze | `20-freeze.sh` | compute (after a good run) | snapshot exact versions → `install/lock/` |

Everything created lands under the repo (which is on **eagle**), so the compute-node
build phase and the runtime both see it.

## config.yaml

`install/config.yaml` contains versions and names (spack ref, mongodb version,
env/dir names). Paths are derived at run time from the repo location. To change a
version, edit `config.yaml`; the scripts read it via `install/_lib.sh`.

## Usage

`install/00-fetch.sh` starts with a preflight check for Spack, environment
modules, compiler/MPI wrappers, Polaris externals, `mongod`, and Python >= 3.11.
For missing pieces the installer can create under the repo (pinned Spack,
`mongod`, venv), it asks before doing so. Set `INSTALL_ASSUME_YES=1` for
non-interactive runs.

```bash
# --- phase 1: LOGIN node (has internet) ---
bash install/00-fetch.sh

# --- phase 2: compute node (offline OK) ---
qsub -I -q debug -A <proj> -l select=1 -l walltime=01:00:00 -l filesystems=home:eagle
cd <repo>
bash install/10-build.sh

# --- run the demo end to end ---
bash job.sh

# --- phase 3: freeze exact versions for shipping ---
bash install/20-freeze.sh
git add install/lock && git commit -m "pin build"
```

## What is / isn't committed

- **Committed:** `config.yaml` (names+versions), the phase scripts, and after a
  freeze, `install/lock/` (exact `spack.lock`, `requirements.lock`,
  `mongo.lock.yml`, `versions.txt`).
- **Not committed** (large/host-specific, rebuilt from the above): `_spack/`,
  `_venv/`, `server/_mongo_env/`, `darshan/install*`, `diaspora-stream-api/install`.

## Relationship to the rest of the repo

- Reuses `server/spack/spack.yaml` + `spack.lock` as the spack spec (config points
  at them) — no duplication.
- Reuses `server/requirements.txt` for the python deps.
- `mongod` resolution: `server/env_polaris.sh` auto-detects `server/_mongo_env`.
- After building, `bash job.sh` runs the validated README pipeline end to end.
