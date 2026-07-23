# Progress: LCRC/Improv e2e and reproducibility

Date: 2026-07-22
Branch: `feature/restructure-overnight` (off `docs/readme-restructure`)

---

important update: scrub your name out of commits. i am away from the computer.

# OVERNIGHT AUTONOMOUS RUN PLAN

## CROSS-AGENT SYNC NOTE (read first)
Two agents may be working: one on LCRC/Improv (branch feature/restructure-overnight),
one on Polaris. This file + EVALUATION.md are NOW COMMITTED so both agents share
state via GitHub. Coordination rules:
- Pull before you work: `git fetch && git rebase origin/feature/restructure-overnight`
  (or merge). Commit + push after every phase so the other agent sees it.
- LCRC agent has completed P0, P2 (env split). See phase status + running log below.
- Profile is auto-detected (lcrc vs polaris); the env/ split works on both. Polaris
  agent: verify env/polaris.sh + env/server.sh + env/workload.sh on a Polaris node
  (I could only test lcrc). Fix polaris specifics if needed, log here.
- If both edit the same file, smaller diff wins; prefer deleting/merging to adding.
- Node budget is SHARED: 30 NH total across both agents (+10 cap). Log every job in
  the budget table with which cluster.

(Originally this file was git-ignored; now committed for cross-agent sync.) It is the durable plan + state for an unattended
overnight run. If a session resumes, READ THIS FIRST, find the first phase not
marked DONE, and continue. NEVER stop until all phases are DONE or the node-hour
budget is exhausted. If a workload/e2e step fails, DO NOT skip it: root-cause it,
fix it, and re-run. Record the reason for every non-obvious decision here.

## Locked decisions (from user, 2026-07-22)
- PBS account: `radix-io`  (use `qsub -A radix-io`)
- Strategy: work on branch `feature/restructure-overnight`; keep the known-good
  setup intact; push to origin after every phase.
- Unattended installs: AUTO-install missing deps non-interactively (log every
  install). Keep an interactive `--ask` mode in build.sh for humans (default
  auto during the automated run via `BUILD_ASSUME_YES=1`).
- Overhead design: baseline (connector OFF) vs mofka (ON), 3 reps each, for the
  C workload and the python-ml workload. Report mean/stddev walltime + per-op
  timing. 2 nodes: 1 workload node + 1 server node.
- Comparison pass criterion: PASS if module record set and open/read/write/close
  counts match native; ALLOW known diffs (mount label `unknown` vs `rootfs`,
  timestamps, pid, synthetic job/exe metadata). Matches prior documented result.
- Push cadence: commit + push after each phase passes its check. progress.md and
  EVALUATION.md stay UNCOMMITTED (both git-ignored).

## Additional locked decisions (user, 2026-07-22, before leaving for the night)
- OVERHEAD METRICS: also time (a) initialization phase, (b) average push cost,
  (c) finalize phase. Add minimal timing to the connector if DARSHAN_MOFKA_TIMING
  doesn't already expose init/finalize/per-push. Any added darshan line -> vet +
  log reason. (P9/P10)
- NON-DESTRUCTIVE + new dirs OK: if there is a genuine need for another directory
  to hold something, create it. The only thing that is "bad" is writing too many
  lines of code. Minimize LOC, not directories.
- NO ABSOLUTE PATHS TO LIBS/.so: never reference .so files / libraries / compiler
  runtimes by absolute path. Always via `module load` (or a var derived from a
  module). Offenders found (fix in refactor):
    * server/env_polaris.sh:75  /opt/cray/libfabric/*/lib64  -> module load libfabric ($CRAY_LIBFABRIC_PREFIX)
    * docs/RUNBOOK.md:97,138     /soft/perftools/darshan/.../pkgconfig strip -> module unload darshan
    * (spack.yaml externals are OK - that is the intended single source of truth)
- ENV RE-SOURCE ROOT CAUSE (confirmed): env.sh computes DARSHAN_MOFKA_CXX_RUNTIME_DIR
  ONCE from the g++ active at source time; the diaspora CMake build reorders
  LD_LIBRARY_PATH / drops LD_PRELOAD, so a newer/older libstdc++ (GLIBCXX) wins ->
  must re-source env.sh after building diaspora. FIX DIRECTION: separate envs
  cleanly + make the C++ runtime pin idempotent/re-derivable, prefer resolving
  libstdc++ via `module load gcc/gcc-native` consistently on both server &
  workload sides rather than LD_PRELOAD. Target: clear distinction between a
  SERVER env and a WORKLOAD env that are each easy to load and don't clobber each
  other. (see env layer analysis below)
- FINAL REPRO TEST: clone repo into GLOBAL SCRATCH and build EVERYTHING in place
  (including libraries/spack stack) then run e2e. Scratch = /lcrc/globalscratch/hjajula
  (writable, 2.5P free). Do the heavy from-scratch spack build on a LOGIN node
  (free, no node-hours); reserve compute nodes for e2e + overhead. If home `du`
  exceeds, build DLIO and other workloads in /lcrc/globalscratch/hjajula.
- INSTALL PERMISSION: blanket yes - pip/spack/git installs into account/venv/scratch
  as needed, log every one.
- PYTHON-ML FRAMEWORK: PyTorch preferred. RISK: py3.14 may lack torch wheels. If
  torch will not install on py3.14 after real attempts, fall back to a separate
  torch-capable python (system/conda) for the ML workload ONLY, or
  numpy+scikit-learn as last resort; document the choice. Do not idle on this.
- BLOCKER POLICY: the e2e already works, so nothing should truly block. If stuck,
  check the previous main-branch merge / reference branches for how it works
  (refs: origin/feature/reproducible-split-nodes has split-node deploy commit
  c63fcea; origin/add-mpi-workload has MPI-IO smoke). Skip forward, keep other
  phases moving, document, return later. Never idle.
- BUDGET OVERFLOW RULE: 30 node-hours target; if exhausted by morning, may use
  UP TO 10 MORE node-hours for final tests (hard cap 40).
- PUSH: origin push access confirmed (fork hariteja-jajula/darshan-mofka).

## Node-hour budget: 30 node-hours total (hard cap 40 incl. +10 for final tests).
Track every job here. node-hours = nodes * walltime(hours).

| job id | phase | nodes | walltime | node-hrs | cumulative | note |
|---|---|---:|---:|---:|---:|---|
| (none yet) | | | | | 0.0 | |

Budget rule: before submitting a job, check cumulative + estimate < 30. Prefer
the `debug` queue for short e2e checks (cheap); reserve `compute` for the
overhead runs. Always request the SMALLEST walltime that fits.

## Guiding principles (apply to every change)
1. MINIMIZE lines of code and files. Prefer deleting/merging to adding. Reuse
   existing Darshan + library helpers. Every added line in `darshan/` must have a
   vetted reason; note non-obvious reasons in the "darshan line-vetting log" below.
2. Never break the known-good e2e. After structural moves, re-run e2e before
   moving on.
3. Config-driven, no hardcoded paths/accounts/usernames.
4. Structure target (final):
   - `darshan/`      near-perfect upstream connector (vetted line-by-line)
   - `diaspora-stream-api/`  done; reduce LOC if possible
   - `flowcept/`     consumer only; pin to a SHA; vet only if needed
   - `env/`          config_server.yaml + config_workload.yaml (+ structure info)
   - `server/`       ~3 files: start_server.sh (reads config), stop, groupfile
   - `Database/`     README with mongod download instructions + fetch script
   - `Client/`       flowcept consumer that drains DB
   - `workloads/`    c/ mpi/ dlio/ python-ml/ each with its own README
   - `build.sh`      minimal: check deps, auto-install missing (ask in --ask mode)
   - `job.sh`        start_server(config) -> run workload e2e -> jsonl + native
                     .darshan -> reconstruct -> 1:1 compare -> pydarshan HTML into
                     clearly-named result dirs
   - `results/`      per-run named dirs (workload_YYYYmmdd_HHMMSS/): jsonl,
                     native.darshan, partial.darshan, compare.txt, pydarshan HTML,
                     overhead csv

## Phase status (update in place)
## RUN 2 (branch feature/overnight-lcrc, 2026-07-23) -- see running log at bottom.
- [x] P0  Setup + baseline e2e passes (DONE)
- [x] P1  Restructure skeleton DONE: Database/ + get_mongod.sh, per-dir READMEs,
        old server/env*.sh shims + jobs/job.sh deleted (new path e2e-verified first).
- [x] P2  env/ split DONE. CORRECTION: the C++ runtime pin was NOT unneeded -- it
        broke the consumer on a COMPUTE node (GLIBCXX_3.4.32). Restored as
        cxx_runtime_pin() in env/common.sh, derived from $CXX (module), not a
        hardcoded .so. Called at end of env/server.sh + env/workload.sh.
- [x] P3  server/ minimal DONE: start_server.sh/stop_server.sh on env/server.sh;
        knobs env-driven (MOFKA_PROTOCOL/TOPIC/PARTITION_TYPE). No YAML parser (LOC).
- [x] P4  Database/ DONE: get_mongod.sh (tarball fallback) + README; env resolves it.
- [x] P5  Client/ DONE: capture_flowcept.sh on ENV_ROOT + Client/ template; README.
- [x] P6  build.sh DONE: auto-sources env/workload.sh when DIASPORA_C unset.
- [x] P7  job.sh DONE + E2E VERIFIED (job 7669510, VERDICT: PASS): new env, new
        paths, workload selection (c|mpi|dlio|python-ml), results/<wl>_<ts>/ with
        events.jsonl/partial+native.darshan/compare.txt/summary/pydarshan HTML.
        Added submit.sh (PBS wrapper). C smoke PASS.
- [~] P8  Workloads: c PASS. mpi/dlio/python-ml -- e2e runs pending.
- [~] P9  Overhead + multi-node config study (docs/MOFKA_NOTES.md grounds it) -- pending.
- [ ] P10 LOC/file reduction; vet darshan lines; reduce single-use vars (user ask).
- [~] P11 flowcept SHA pinned (branch tracking removed). spack-lcrc spec + from-scratch
        build in progress (see below). ~/mofka_tests still fallback until build lands.
- [ ] P12 Docs: schema doc, README overviews, REPRODUCE.md, EVALUATION.md refresh.
- [ ] P13 From-scratch stack build (login node, /home/hjajula/repro-fromscratch) -- running.
- [ ] P14 Humanify code comments + READMEs (plain sentences for people) -- user ask.
- [ ] FINAL Detailed morning report + independent evaluation sub-agent -- user ask.

## darshan line-vetting log (P10 -- vetted against sibling connectors)
Full report: results (P10 workflow). No dead code found in any connector file.
- darshan-mofka.c: every include used except <string.h> (removable); all globals
  used; now_ns/mofka_took/json_escape_into/hex_into all used; initialize/send/
  finalize are the entry points (called from darshan-core.c). Only single-use
  scalar was `file_path` in send() (inlined candidate). ~265 lines all justified.
- darshan-mofka.h: include guard + 3 prototypes + DARSHAN_MOFKA_SEND macro
  (fixed contract, do not change) + extern "C" (C++ TUs include it). All needed.
- darshan-mofka-reconstruct.c (722): two layers -- provider-agnostic JSON/hex
  scanner (65-295) + darshan reconstruction core (297-722). Already reuses
  libdarshan-util (log_create/put_job/exe/mounts/namehash, mod_logutils,
  darshan_module_names, HASH_*). Hand-rolled add_name_record + decode_hex/JSON
  scanners are REQUIRED (no exported lib equivalent).
- uthash: NOT vendored -- uses the tree's shared "uthash-1.9.2/src/uthash.h"
  (same as every darshan-util TU). Nothing to remove. (Closes the EVALUATION item.)
- Hook footprint (pure additions, 0 deletions): darshan-core.c +9, posix +5,
  stdio +9, mpiio +9, hdf5 +7 = 39 hook lines; configure.ac +23, Makefile.am +14,
  check_diaspora_c.m4 (51). Small and HAVE_MOFKA-gated.

## P10 connector reductions deferred to the upstream PR (need rebuild + dual-config retest)
- inline single-use `file_path`; drop dead `s` in reconstruct json_get_string;
  drop unused <string.h>; collapse the double AM_CONDITIONAL([HAVE_MOFKA]) into one
  grouped call in configure.ac; fix copyright wording to "University of Chicago";
  trim two comments. (~6 LOC; pure PR polish.)
- robustness (behavioral, PR): rec_hex[4096]/MOFKA_JSON_BUF[8192] silently drop
  oversized records -- add a dropped-record counter + heap fallback.
- reconstruct: fold the 4x JSON key-prologue into one helper; macro-generate the
  3 numeric getters; optionally split the scanner into its own TU (~350 LOC core).
Applied now (harness, safe): inlined single-use vars in job.sh (STAMP, MPILIB) +
install/setup.sh (REQS); fixed setup.sh sourcing the deleted server/env.sh.

## Restructure mapping (P1) - old -> new (preserve ALL logic; git mv)
- server/env*.sh                 -> env/ (split: env/common.sh toolchain+C++ pin,
                                   env/server.sh, env/workload.sh; keep profile
                                   files env/lcrc.sh env/polaris.sh). config drives it.
- env/config_server.yaml         NEW: server node structure (protocol, batch default 0
                                   adaptive, topic, max_batches, flush_ms, mongo port/db)
- env/config_workload.yaml       NEW: workload node env (which workload, ranks, darshan
                                   knobs, logpath)
- server/start-server.sh         -> server/start_server.sh (reads config)
- server/stop-server.sh          -> server/stop_server.sh
- server/bedrock-config.json     -> server/ (kept; templated from config)
- server/capture_flowcept.sh     -> Client/ (the flowcept consumer)
- server/capture.py              -> Client/ (debug drain) OR drop if redundant (P10)
- server/export_jsonl.py         -> Client/
- server/flowcept_settings.template.yaml -> Client/
- server/_mongo_env, mongod deps -> Database/ (+ Database/README.md download instr,
                                   Database/get_mongod.sh fetch script)
- workloads/c/mofka_forward_mpiio.c -> workloads/mpi/  [DONE]
- workloads/python-ml/           NEW: torch (or fallback) train/eval doing real I/O
- results/                       NEW: per-run named dirs
- darshan/, diaspora-stream-api/, flowcept/  unchanged (submodules)
- build.sh, job.sh               rewritten minimal + config-driven (P6/P7)
- install/, jobs/, docs/         fold into new structure; reduce LOC

NOTE: keep old scripts working until the new ones are verified e2e, THEN delete.
Do not break the known-good pipeline mid-flight.

## Running log (append newest at bottom; timestamp each entry)
- 2026-07-22: P0 started. Created branch feature/restructure-overnight. Wrote plan.
- 2026-07-22: P1 started. Created env/ Database/ Client/ workloads/{mpi,python-ml}/
  results/. git mv workloads/c/mofka_forward_mpiio.c -> workloads/mpi/.
- 2026-07-22: P2 env split done + VETTED line/file by line.
  KEY EVIDENCE-BASED SIMPLIFICATION: DELETED the entire C++ runtime pin machinery
  (env_pin_cxx_runtime, DARSHAN_MOFKA_CXX_RUNTIME_DIR, LD_PRELOAD libstdc++, and
  the "re-source env.sh after building diaspora" workaround). Proven unnecessary:
    * `module load gcc/13.2.0` + `spack env activate` put a gcc-13 libstdc++
      (GLIBCXX_3.4.32) on LD_LIBRARY_PATH via the view (view/lib/libstdc++.so.6 ->
      gcc-runtime-13.2.0).
    * Verified `import mochi.mofka.client` works module-only (no pin/preload).
    * Verified `ldd libdarshan.so` resolves ALL deps + picks GLIBCXX_3.4.32
      module-only. No "not found", correct libstdc++.
  New env/ layout (138 LOC total vs 269 in the 3 old files):
    env/_profile.sh  (15)  resolve profile once (was duplicated in 5 places)
    env/common.sh    (33)  module load + env_prepend() only
    env/lcrc.sh      (31)  spack view + cmake (both sides need)
    env/polaris.sh   (35)  same for polaris; libfabric via `module load libfabric`
                           (NOT hardcoded /opt/cray path)
    env/server.sh    (28)  PY(venv), MOFKA_PYTHONPATH, MONGOD  (server-only)
    env/workload.sh  (24)  CC, DIASPORA_C, DARSHAN_PREFIX, darshan_lib (workload-only)
  FILE-COUNT justification: 6 files vs 3, but each earns its place -
    _profile removes 5x duplication; common is genuinely shared; lcrc/polaris
    mirror the pre-existing split; server vs workload have DISJOINT var sets
    (server: MONGOD/PY/MOFKA_PYTHONPATH; workload: CC/DIASPORA_C/DARSHAN_*) - the
    split the user explicitly asked for and it's real, not cosmetic.
  TESTED: both `source env/server.sh --lcrc` and `source env/workload.sh --lcrc`
    produce working envs (bedrock OK, mofka import OK, libdarshan deps all resolve).
  TODO: server/env.sh still exists (old); keep as shim until job.sh/build.sh
    rewired, then delete. MONGOD resolves empty until P4 moves mongod to Database/.
  ABS-PATH policy: polaris libfabric now via module; remaining ~/mofka_tests
    fallback kept ONLY as a fallback (install/_spack preferred) - documented.
- 2026-07-22: P0 findings:
  - Login node = ilogin1.lcrc.anl.gov (LCRC/Improv), RHEL8. PBS present.
  - Queues: compute (default), debug, bigmem, etc. Use debug for cheap e2e checks.
  - `source server/env.sh --lcrc` sources cleanly; all tools resolve:
    MOFKA_SPACK_VIEW, PY (venv), CC (gcc-13.2.0), DIASPORA_C, DARSHAN_PREFIX,
    bedrock found. Stack already built.
  - darshan-util tools live at darshan/darshan-util/install/bin/
    (darshan-parser, darshan-mofka-reconstruct) -- NOT darshan/install/bin.
    job.sh already knows this (var B).
  - mongod present at server/_mongo_env/bin/mongod.
  - PYDARSHAN WAS NOT INSTALLED. `import darshan` resolved to the repo's own
    darshan/ SOURCE DIR as a namespace package (because CWD=repo root puts
    darshan/ on sys.path). Installed pydarshan 3.5.0 into the venv.
    ACTION for HTML step: (a) add `darshan==3.5.0` to server/requirements.txt;
    (b) run pydarshan CLI from a dir where repo `darshan/` does NOT shadow it
    (e.g. cd into the results dir, or set PYTHONPATH carefully). This shadow is a
    real trap -- document it.
  - Submodule SHAs now: darshan beffbf63, diaspora 29556b23,
    flowcept 63298bc7 (currently tracking branch experiment/f1-v2-unpack-batches
    -> must pin to this SHA in P11).

---


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

## Evaluation Framework (see EVALUATION.md)

A detailed evaluation framework for this work lives in `EVALUATION.md` at the repo
root. It is **git-ignored on purpose** (working notes, not for commit). It scores
the project on: size/reviewability, connector upstream-fit, reproducibility,
compactness/reuse, documentation clarity, instruction quality, robustness, and
hygiene — plus an upstream-merge blueprint and binary pass/fail gates.

The most important axis called out there is **reduce the number of files and lines
of code**: a small, self-contained diff is the gating factor for getting the
Darshan connector reviewed and merged upstream. Measured baseline at time of
writing:

```text
connector new source: darshan-mofka.c 265, .h 42, check_diaspora_c.m4 50,
                      darshan-mofka-reconstruct.c 722 (largest single unit)
harness: 37 tracked files, ~3652 LOC (excl. submodules and _venv/)
```

Top size-reduction targets: drop the vendored uthash and reuse tree helpers in the
reconstruct tool (or split it into a follow-up PR); deduplicate RUNBOOK vs README;
merge/remove redundant scripts (`jobs/job.sh`, `server/capture.py`).

## Current Branch Note

Push changes to the current branch only:

```text
docs/readme-restructure
```

Do not push this work to `main`.

`EVALUATION.md` must not be committed (it is listed in `.gitignore`).
