# Darshan -> Mofka -> FlowCept Progress

Date: 2026-07-20
Branch: `dev/env-polaris-cleanup`
Repo: `/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka`

Goal for the share-out: a stranger clones the repo, follows README.md, runs
`bash jobs/job.sh`, and sees Darshan I/O events land in MongoDB and export to JSONL.
No user-specific edits required.

## Pipeline (what "working" means)

Darshan (LD_PRELOAD) -> Mofka broker -> **live** FlowCept consumer -> MongoDB -> JSONL.

The consumer runs *during* the workload and drains the topic continuously. This is the
key design point: events are delivered as they are pushed, so capture does not depend on
a clean finalize-time flush (the failure mode that broke every earlier DLIO run).

## Verified working

- **FlowCept live-consumer path end-to-end (C workload).** Broker up, consumer reaches
  `consumer alive`, workload emits 12 sends, `touch SHUTDOWN` flushes, and MongoDB holds
  **12 darshan docs (POSIX: 4, STDIO: 8)**; `export_jsonl.py` writes matching JSONL.
  This supersedes the earlier "FlowCept never ran to completion" note.
- **Environment.** `source server/env.sh --polaris` resolves bedrock, PY (py3.14 venv),
  CC, DIASPORA_C, DARSHAN_PREFIX, `darshan_lib`. Python imports OK: pydiaspora_stream_api,
  mochi.mofka.client, flowcept.cli, pymongo.
- **C 2-node fan-in (prior job 7262662).** 24 sends -> 24 captured events, genuine POSIX
  records with real hostnames/pids. Durable evidence that cross-node delivery works.

## External dependency: mongod

`mongod` is not on PATH in the project env (it lives in a conda env). `jobs/job.sh` and
`capture_flowcept.sh` honor `$MONGOD`, then fall back to `command -v mongod`, then to a
project-dir glob. A user on another system sets `MONGOD=/path/to/mongod` or module-loads it.

## DLIO status (under test)

Root cause of every earlier DLIO failure: the old scripts captured **post-hoc** (run DLIO
to completion, then rely on one atexit `diaspora_producer_flush_timeout`). In the DLIO
Python-under-LD_PRELOAD process that flush makes zero progress and burns the whole timeout
(`finalize 30000190 us`), so ~4100 queued events were never delivered. Grounded in
`darshan/darshan-runtime/lib/darshan-mofka.c:225` (send = async push) and `:242` (single
flush). Secondary issue: DLIO runs under system python3.12, so it must run with a clean
python env (`-u PYTHONPATH -u PYTHONSAFEPATH -u PYTHONHOME`), not the py3.14 exports.

**PROVEN on compute nodes.** Diagnostic 7263486: DLIO under the live consumer landed
`INGEST: PASS, 28 darshan docs`, zero flush timeouts, `BATCH=0` finalize 96ms (vs 1.86s
for `BATCH=1`) — so `job.sh` uses `BATCH=0`. Full `bash jobs/job.sh` run 7263495:
`INGEST: PASS, 26 docs` from BOTH the C (12 sends) and DLIO (14 sends) workloads.

## jobs/ directory

Single script per request: **`jobs/job.sh`** (committed `770aa1a`). README replica that
self-submits via `qsub` on a login node (forwarding `$MONGOD`) so all real work runs on a
compute node; on the node it runs broker -> live consumer -> C + DLIO -> export -> verify.
Proven end-to-end (job 7263495). No user-specific content.

## export_jsonl.py fix (committed 770aa1a)

First clean run exposed `TypeError: Object of type datetime is not JSON serializable`
(FlowCept stores `ended_at` as a native datetime) -> 0 JSONL lines. Fixed with
`json.dumps(default=str)`. Re-verified against job 7263495's persisted mongo: 26 events
export to JSONL; reconstruct + parse both succeed.

## Reconstructor (README step 11) — verified

`darshan-mofka-reconstruct` already had its fix in submodule commit `bc17efd3`
(nprocs = max_rank+1). Verified working: 24-event JSONL -> 7 module records -> a partial
`.darshan` that `darshan-parser` reads cleanly (POSIX+STDIO, `partial=true`). Gap found:
`build.sh` built only the runtime, so step 11's binaries did not exist after the documented
build, and `darshan-parser` loaded a stale spack `libdarshan-util.so`. Fixed in `build.sh`
(darshan submodule, UNCOMMITTED pending review): also build darshan-util into the same
prefix with `-Wl,-rpath,$PREFIX/lib`, plus a broken-bzip2 uthash-untar workaround. Tested:
produces both binaries; parser now resolves its own lib via RUNPATH.

## Multi-node scale test (out of repo, by request) — PASSES at ppn=1

Not committed, not in the README. Scripts under `/tmp/dm_diag/*scale*.pbs`: broker +
live consumer on the primary node, C workloads fanned across all nodes via mpiexec into
one mongo.
- **2 nodes (7263514, ppn=1): PASS** — 24 events, 2 distinct hostnames.
- **4 nodes (7263522, ppn=1, debug-scaling): PASS** — 48 events, 4 distinct hostnames,
  INGEST PASS; reconstruct -> 11 module records -> parseable partial log.
- **2 nodes x 2 (7263528, cpu-bind): PASS** — 48 events, all 4 ranks 12 each, 24/host.
- **ppn=4 without cpu-bind (7263502): FAIL** — captured 0; half the ranks never launched.
  Root cause was missing `--cpu-bind`, NOT a Mofka connect-storm: adding
  `mpiexec --cpu-bind depth -d <cpus/ppn>` fixed multi-rank-per-node (see 7263528).
- **8 nodes x 4 = 32 ranks (7263531, cpu-bind -d 8): in flight.**

## Clean build verification (out of repo)

Job 7263523 wiped `darshan/{_build,install,darshan-util/_build}` and ran `build.sh` from
scratch on a compute node: Exit 0, all three binaries produced (libdarshan.so,
darshan-parser, darshan-mofka-reconstruct). Parser RPATH puts `install/lib` first.

## Committed this session (parent repo, dev/env-polaris-cleanup)

- `f298b94` — de-hardcode `env_polaris.sh`, export `DARSHAN_MOFKA_ENV`, `stop-server.sh`
  honors `MOFKA_SERVER_DIR`, `.gitignore` job-output patterns.
- `ad32580` — rewrite progress.md.
- `770aa1a` — add `jobs/job.sh`, fix `export_jsonl.py` datetime, broaden `.gitignore`.

- `1ccb47d` / `e791346` — bump darshan submodule to `feat/build-util` (build.sh now also
  builds darshan-util with rpath + `-j1` fallback + bzip2 workaround). Submodule commits
  `f9e85f2`, `8200251` pushed to the darshan fork.

## Reproducible stack (the big one) — DONE

The demo depended on a prebuilt Mofka/FlowCept spack stack that existed only as an
Improv-transferred tree derived by relative path from the author's home — so a fresh
clone by anyone else had no way to get or rebuild it. Fixed:

- Built the **Polaris-native** stack from source (`flowcept-mofka-polaris` spack env):
  gcc@12.3.0 + cray-mpich + PE externals, everything else from source. All specs
  installed incl. `mofka@main`, `mochi-bedrock`, darshan; `bedrock` runs natively (no
  dead RPATH).
- Vendored the spec into the repo: `server/spack/{spack.yaml,spack.lock,README.md}`.
- `env_polaris.sh` now defaults to the native view (falls back to Improv), pins the venv
  python, and adds Cray libfabric to `LD_LIBRARY_PATH` (native view uses it as a PE
  external). Verified from a clean env: flowcept + mochi + pydiaspora + pymongo import.
- **End-to-end proof against the native stack**: job 7263569, `bash jobs/job.sh`,
  INGEST PASS, 26 events (C:12 + DLIO:14) -> Mongo -> 26 JSONL. Broker ran from the
  native view.

Python side is now reproducible too: `server/requirements.txt` (curated PyPI deps) +
`server/requirements.lock.txt` (exact frozen set). **Verified**: a throwaway venv built
from the Spack-view python + `pip install -r server/requirements.txt` + `pip install -e
flowcept/` imports flowcept.cli, mochi.mofka, pydiaspora, pymongo, redis, msgpack. mochi/
pydiaspora come from the Spack view; only flowcept + PyPI deps are pip-installed.

Portability: `jobs/job.sh` no longer hardcodes an ALCF project — `#PBS -A` is a
placeholder; the allocation comes from `PBS_ACCOUNT` (bash path) or `qsub -A` (direct).
Verified both paths (7263603: `PBS_ACCOUNT=radix-io bash jobs/job.sh` -> Account_Name
radix-io -> INGEST PASS 26 events). A darshan-dev on any Polaris project can now run it.

## Status: ready to share

`bash jobs/job.sh` (with `mongod` on PATH or `$MONGOD` set) reproduces the whole README
on a compute node and prints `INGEST: PASS`. Verified: single-node C+DLIO (26 events),
2- and 4-node C fan-in, reconstruct+parse, clean from-scratch build. No user-specific
content in committed files.

## Open / next

- [ ] Finalize `jobs/job.sh` DLIO settings from diagnostic 7263473, then commit `jobs/`.
- [ ] Confirm multi-node scale (7263474).
- [ ] (Low priority) Verify/fix `darshan/darshan-util/darshan-mofka-reconstruct.c`.
- [ ] Remove the stale `server/INSTRUCTIONS.md` reference in `capture_flowcept.sh:4`
      (file does not exist) and reconcile the flowcept version pin (template 0.10.6 vs
      installed 0.10.5) if it warns.
