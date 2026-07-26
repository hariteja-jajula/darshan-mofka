# install/ -- automated setup (backup path)

This is the **automated backup** to the manual setup in the top-level
[README](../README.md). Prefer the README's "Quick start" steps
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

Then run the demo end to end. `submit.sh` sizes and submits the PBS job for you;
pick the workload with `WORKLOAD=` or in `workloads/workload.config`:

```bash
PBS_ACCOUNT=<acct> bash submit.sh
```

`setup.sh` reuses whatever already exists (spack env, `mongod`, venv, diaspora
install), so re-running it is cheap.

## LCRC build notes

Two small things are needed to build the stack from scratch on an LCRC login node,
and `setup.sh` already handles both:

- Mercury is built without its shared-memory plugin (`~sm`), because the login
  node's ptrace setting blocks the shared-memory self-test.
- Spack fetches sources with `curl`, because the login node's Python cannot verify
  the TLS certificate of some GNU mirrors. Source integrity is still checked by
  SHA-256.

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
- `mongod` resolution: `env/polaris.sh` auto-detects `server/_mongo_env`.
- After building, `PBS_ACCOUNT=<acct> bash submit.sh` runs the full pipeline end to end.
