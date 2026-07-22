# Progress: LCRC/Improv e2e and reproducibility

Date: 2026-07-22
Branch: `docs/readme-restructure`

## Current Status

The POSIX/STDIO end-to-end pipeline works on LCRC/Improv using the current local changes.

Successful debug job:

```text
7668554.imgt1
```

Evidence from `darshan_mofka_e2e.out`:

```text
mofka up: ofi+verbs;ofi_rxm://10.128.16.14:40219 | topic 'darshan'
consumer alive (pid 1709529)
mofka_forward_smoke complete: wrote/read POSIX and STDIO files in /tmp/mofka-forward-smoke
sends: 13
exported 13 darshan docs from darshan_stream.tasks
exported lines: 13
tasks total=13  darshan=13  modules={'POSIX': 4, 'STDIO': 9}
INGEST: PASS
modules: {'POSIX': 4, 'STDIO': 9}
ops: {'open': 5, 'write': 4, 'read': 2, 'close': 2}
reconstructed 3 module records (2 pruned as empty) from 13 streamed events into /tmp/job_partial.darshan
########## DONE ##########
events: /tmp/darshan-mofka-events.jsonl   reconstructed: /tmp/job_partial.darshan
```

The reconstructed OPENS matched the native Darshan log except for the expected mount label difference:

```text
reconstructed: unknown
native:        rootfs
```

## What Was Fixed

### Profile selection

The repo previously assumed Polaris in several places. On this system the PBS resource is Improv/LCRC, so the Polaris Spack externals do not exist:

```text
/opt/cray/pe/mpich/8.1.28/ofi/gnu/12.3
/opt/cray/libfabric/2.2.0rc1
```

Scripts now auto-select `profile=lcrc` on this machine, or honor:

```bash
DARSHAN_MOFKA_PROFILE=lcrc
DARSHAN_MOFKA_ENV=lcrc
```

Changed files:

```text
check-deps.sh
install/setup.sh
job.sh
jobs/job.sh
server/env_lcrc.sh
```

### LCRC environment

`server/env_lcrc.sh` now prefers repo-local pieces created by setup:

```text
install/_venv/bin/python3
server/_mongo_env/bin/mongod
diaspora-stream-api/install
```

It also finds the existing CMake 3.31 install under the current LCRC Spack tree:

```text
~/mofka_tests/spack/opt/spack/*/cmake-3.31*/bin/cmake
```

The current successful environment used:

```text
cmake version 3.31.11
GCC 13.2.0 runtime
OpenMPI 4.1.8 module
Mofka stack from ~/mofka_tests/spack
```

### C++ runtime ordering

FlowCept/Mofka Python imports failed with:

```text
libstdc++.so.6: version `GLIBCXX_3.4.32' not found
```

Root cause: the Mofka/Python extension was built requiring GCC 13's `libstdc++.so.6.0.32`, but the runtime loader sometimes picked the older Spack GCC 8 runtime first.

Fix:

- `server/env_lcrc.sh` records the GCC 13 runtime dir in `DARSHAN_MOFKA_CXX_RUNTIME_DIR`.
- `server/env.sh` force-prepends that dir to `LD_LIBRARY_PATH`.
- `server/env.sh` also prepends `libstdc++.so.6` to `LD_PRELOAD` before inherited XALT preload.

This made the FlowCept consumer import path work in PBS.

### Python dependencies

FlowCept startup failed once with:

```text
ModuleNotFoundError: No module named 'pandas'
```

Added to `server/requirements.txt`:

```text
pandas==2.3.3
pyarrow==22.0.0
```

These are needed by FlowCept's MongoDB DAO path.

### MongoDB

No MongoDB module, conda, mamba, or existing `mongod` was present on this system. Installed MongoDB locally under:

```text
server/_mongo_env/bin/mongod
```

Using tarball:

```text
mongodb-linux-x86_64-rhel8-7.0.14.tgz
```

This is generated/local and should not be committed.

### Installer config parsing

`install/_lib.sh` returned inline YAML comments as part of scalar values. This broke:

```yaml
flowcept_editable: "flowcept"    # submodule, pip install -e
```

It produced an invalid editable path. The config reader now strips inline comments from scalar strings.

## Current Reproducibility Level

The repo is now reproducible on this account/machine after setup, but it is not yet fully self-contained for an outside reviewer.

What is repo-local after setup:

```text
install/_venv/
server/_mongo_env/
diaspora-stream-api/install/
darshan/install/
darshan/darshan-util/install/
workloads/c/mofka_forward_smoke
```

What still depends on pre-existing external state:

```text
~/mofka_tests/spack
/gpfs/fs1/soft/improv/software
```

The important external dependency is the LCRC Mofka/Mochi/Bedrock Spack stack:

```text
Bedrock
Mofka
Mochi/Margo/Mercury
Thallium
Argobots
Yokan/Flock
Mofka Python bindings
pydiaspora_stream_api dependencies
CMake 3.31
GCC/OpenMPI module stack
```

The current repo does not yet build or download that stack into a repo-local path for LCRC/Improv.

## Why `~/mofka_tests/spack` Is Still Used

`server/env_lcrc.sh` currently does:

```bash
source "$HOME/mofka_tests/spack/share/spack/setup-env.sh"
spack env activate flowcept-mofka
spack location -i mofka+python
```

That path is where the working LCRC Mofka stack already exists. It is not appropriate as the final reviewer-facing dependency path.

The stack should not be committed to git. It is large compiled state and should be recreated by script/spec.

## What The Next Agent Should Do

### Goal

Make `bash install/setup.sh` capable of creating the LCRC Mofka stack under the repo or a documented adjacent path, without assuming `~/mofka_tests/spack` exists.

Target reviewer flow:

```bash
git clone <repo>
cd darshan-mofka
git submodule update --init --recursive
DARSHAN_MOFKA_PROFILE=lcrc bash install/setup.sh
bash check-deps.sh
qsub -A <account> jobs/job.sh
```

### Recommended implementation

Add an LCRC Spack spec and wire setup to use it.

Suggested files:

```text
server/spack/lcrc/spack.yaml
server/spack/lcrc/spack.lock
```

or:

```text
server/spack/spack-lcrc.yaml
server/spack/spack-lcrc.lock
```

Then update `install/config.yaml` to include profile-specific Spack specs:

```yaml
spack:
  profiles:
    polaris:
      env_name: flowcept-mofka-polaris
      env_spec: server/spack/spack.yaml
      env_lock: server/spack/spack.lock
    lcrc:
      env_name: flowcept-mofka-lcrc
      env_spec: server/spack/spack-lcrc.yaml
      env_lock: server/spack/spack-lcrc.lock
```

Then change `install/setup.sh` so for `profile=lcrc` it:

```text
1. clones Spack into install/_spack if missing
2. clones Mofka source into install/_mofka if missing
3. creates/activates the LCRC Spack env
4. runs spack develop for Mofka if needed
5. concretizes and installs
6. sets MOFKA_SPACK_VIEW to the repo-local env/view or Mofka prefix
7. continues with MongoDB, venv, Diaspora, Darshan, util, workload
```

### Important details for LCRC spec

Use the working stack as reference:

```bash
source ~/mofka_tests/spack/share/spack/setup-env.sh
spack env activate flowcept-mofka
spack find
spack find -p mofka
spack find -p cmake
spack config get packages
spack config get concretizer
```

The working modules used by `server/env_lcrc.sh` are:

```bash
module load gcc/13.2.0 openmpi/4.1.8
```

CMake 3.31 is required. The currently working install is:

```text
~/mofka_tests/spack/opt/spack/linux-zen/cmake-3.31.11-.../bin/cmake
```

The working Mofka prefix is:

```text
/gpfs/fs1/home/hjajula/mofka_tests/spack/opt/spack/linux-zen3/mofka-main-...
```

### MongoDB setup

The current `install/setup.sh` can reuse a local `mongod` if present. On this machine, no conda/mamba/MongoDB module existed, so I manually downloaded:

```text
https://fastdl.mongodb.org/linux/mongodb-linux-x86_64-rhel8-7.0.14.tgz
```

and extracted it to:

```text
server/_mongo_env/
```

A future improvement is for `install/setup.sh` to do this tarball fallback automatically when conda is unavailable.

### PBS details

This cluster rejected:

```text
#PBS -l filesystems=home:eagle
```

with:

```text
qsub: Unknown resource Resource_List.filesystems
```

So `jobs/job.sh` no longer includes that directive.

Working manual wrapper used:

```bash
#PBS -N darshan_mofka_e2e
#PBS -A radix-io
#PBS -q debug
#PBS -l select=1:ncpus=32
#PBS -l walltime=00:30:00
#PBS -j oe

cd /home/hjajula/darshan-mofka-flowcept/darshan-mofka
export DARSHAN_MOFKA_PROFILE=lcrc
bash job.sh
```

## Files Modified But Not Generated

Source/script changes to commit:

```text
check-deps.sh
install/_lib.sh
install/setup.sh
job.sh
jobs/job.sh
server/env.sh
server/env_lcrc.sh
server/requirements.txt
progress.md
```

Generated/local artifacts not to commit:

```text
install/_venv/
server/_mongo_env/
diaspora-stream-api/install/
diaspora-stream-api/_build/
darshan/install/
darshan/_build/
darshan/darshan-util/_build_util/
darshan_mofka_e2e.out
darshan_mofka_audit_e2e.out
server/_flowcept_run/
server/mofka.json
server/bedrock.log
server/bedrock.pid
```

## Verification Commands Already Run

```bash
bash check-deps.sh
bash install/setup.sh
qsub /tmp/opencode/darshan_mofka_e2e.pbs
```

Successful check after setup:

```text
All dependencies present -- you can skip setup and run:  bash job.sh
```

Successful e2e job:

```text
7668554.imgt1
```

## Current Branch Note

Push changes to the current branch only:

```text
docs/readme-restructure
```

Do not push this work to `main`.
