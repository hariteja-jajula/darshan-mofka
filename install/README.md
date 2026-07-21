# install/ -- automated setup (backup path)

This is the **automated backup** to the manual setup in the top-level
[README](../README.md). Prefer the README's "Dependencies & Environments" steps
if you already have parts of the stack (run `bash check-deps.sh` first to see what
you're missing). Use `setup.sh` when you'd rather build everything in one shot.

`install/setup.sh` builds the darshan-mofka stack from source: the native spack
stack (Bedrock/Mochi/Mofka/cmake/darshan-util deps), `mongod`, the python
consumer, and the project source (darshan + diaspora). Paths, accounts, and
usernames are not hardcoded.

## Usage

Run where you have internet (on Polaris: a login node). It clones/pins spack,
creates the env from `server/spack/spack.yaml`, installs it, sets up `mongod` and
the python venv, and builds diaspora + darshan + the workload:

```bash
bash install/setup.sh
```

Then run the demo end to end on a compute node:

```bash
qsub -I -q debug -A <proj> -l select=1 -l walltime=01:00:00 -l filesystems=home:eagle
cd <repo>
bash job.sh
```

`setup.sh` reuses whatever already exists (spack env, `mongod`, venv, diaspora
install), so re-running it is cheap.

## config.yaml

`install/config.yaml` holds versions and names (spack commit, mongodb version,
env/dir names). Paths are derived at run time from the repo location. To change a
version, edit `config.yaml`; `setup.sh` reads it via `install/_lib.sh`.

## What is / isn't committed

- **Committed:** `config.yaml` (names+versions), `setup.sh`, `_lib.sh`. The exact
  spack concretization is pinned in `server/spack/spack.lock`.
- **Not committed** (large/host-specific, rebuilt by `setup.sh`): `_spack/`,
  `_venv/`, `_mofka/`, `server/_mongo_env/`, `darshan/install*`,
  `diaspora-stream-api/install`.

## Relationship to the rest of the repo

- Reuses `server/spack/spack.yaml` (+ `spack.lock`) as the spack spec — no duplication.
- Reuses `server/requirements.txt` for the python deps.
- `mongod` resolution: `server/env_polaris.sh` auto-detects `server/_mongo_env`.
- After building, `bash job.sh` runs the full pipeline end to end.
