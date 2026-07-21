# install/ -- from-scratch reproducible build

Builds the entire darshan-mofka stack from nothing: the native spack stack
(Bedrock/Mochi/Mofka/cmake/darshan-util deps), `mongod`, the python consumer, and
the project source (darshan + diaspora) — driven by one config file with **no
hardcoded paths, accounts, or usernames**.

## Why it's phased (Polaris has no internet on compute nodes)

You are right: **compute nodes cannot download anything.** So the build is split:

| Phase | Script | Where | Does |
|-------|--------|-------|------|
| 1 fetch | `00-fetch.sh` | **login node** (internet) | submodules, clone+`spack fetch`, conda `mongod`, pip wheels → all onto **eagle** |
| 2 build | `10-build.sh` | login **or** compute (offline) | `spack install`, diaspora, darshan runtime, darshan-util, workload |
| 3 freeze | `20-freeze.sh` | compute (after a good run) | snapshot exact versions → `install/lock/` |

Everything created lands under the repo (which is on **eagle**), so the compute-node
build phase and the runtime both see it.

## config.yaml -- the single source of truth

Only **versions and names** live in `install/config.yaml` (spack ref, mongodb
version, env/dir names). Paths are derived at run time from the repo location. To
change a version, edit `config.yaml`; the scripts read it (via `install/_lib.sh`).

## Usage

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
