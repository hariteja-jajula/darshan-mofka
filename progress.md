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

Fix under validation on a compute node: run DLIO as a workload against the **live**
consumer (diagnostic job 7263473 compares `DARSHAN_MOFKA_BATCH=0` vs `=1`). `jobs/job.sh`
will be finalized with whatever the diagnostic shows actually lands DLIO events in mongo.

## jobs/ directory

Reduced to a single script per request: **`jobs/job.sh`**. It is a README replica that,
on a login node, self-submits via `qsub` so all real work runs on a compute node; on the
compute node it runs the full pipeline for both the C workload and DLIO and prints the
mongo/JSONL verdict. (The whole `jobs/` dir was previously untracked; it is now added.)

## Multi-node scale test (out of repo, by request)

Not committed and not in the README. Script at `/tmp/dm_diag/multinode_scale.pbs`
(job 7263474): broker + consumer on the primary node, C workloads fanned across all nodes
via mpiexec, all draining into one mongo; verifies total events and distinct producer
hostnames.

## Committed this session

`f298b94` — de-hardcode `env_polaris.sh` (\$ROOT-derived, no user prefix), export
`DARSHAN_MOFKA_ENV`, `stop-server.sh` honors `MOFKA_SERVER_DIR`, `.gitignore` catches
`dm_*.o<id>` / `data/` / `hydra_log/` / per-job run dirs.

## Open / next

- [ ] Finalize `jobs/job.sh` DLIO settings from diagnostic 7263473, then commit `jobs/`.
- [ ] Confirm multi-node scale (7263474).
- [ ] (Low priority) Verify/fix `darshan/darshan-util/darshan-mofka-reconstruct.c`.
- [ ] Remove the stale `server/INSTRUCTIONS.md` reference in `capture_flowcept.sh:4`
      (file does not exist) and reconcile the flowcept version pin (template 0.10.6 vs
      installed 0.10.5) if it warns.
