# FlowCept-as-consumer ("scale mode") — additions on the `flowcept` branch

This branch adds an **optional, scalable, persistent** consumer path to the demo,
**without changing** the connector or the reconstructor. The original
`capture.py` path stays exactly as-is (portable, dependency-light). This document
explains what was added, why, and how to run it — so we can review it together
next session.

> Status: staged on branch `flowcept` (off `darshan-mofka-reconstructor`).
> Nothing here modifies `darshan/` or `diaspora-stream-api/`. Not yet built/run
> end-to-end on this machine (needs mongod + the Mofka/Mochi stack, same as the
> capture.py path already needs the broker).

---

## Why a second consumer path

`capture.py` is perfect for the smoke test: one Python process, `mochi.mofka`
directly, `consumer.pull().wait()` → one flat `events.jsonl` via shell redirect.
For large multi-node runs that same file becomes a multi-GB bottleneck and
capture is a single fragile process with no persistence or querying.

**FlowCept** is the scalable alternative. Important architectural facts (verified
against the pinned fork and the crosslayer reference service):

- FlowCept's Mofka consumer (`mq_dao_mofka.py`) is a **layer over the same
  `mochi.mofka` client** capture.py uses — same `consumer.pull().wait()` loop.
  So FlowCept does **not** give you consumer *throughput* parallelism for free;
  what it adds is **buffered batched inserts + MongoDB persistence + querying +
  a hardened graceful-stop/flush**. Throughput at real scale still comes from
  **more Mofka partitions + more consumers**, not from FlowCept alone.
- FlowCept has **no native "topic → JSONL" sink**. Its sinks are Mongo and LMDB.
  So the flow is: FlowCept drains the topic → Mongo → we **export Mongo → JSONL**
  → feed the unchanged reconstructor. That's why `export_jsonl.py` exists.
- The `DocumentInserter` stores each event **verbatim** (it only pops `type` and
  drops empty fields, then upserts the whole dict by `task_id`). So darshan's
  `rec_hex`, `off`, `len`, `seq`, timestamps all survive into Mongo intact and
  round-trip back out — the reconstructor still gets everything it needs.

---

## What was added (4 things)

| Item | Path | Role |
|---|---|---|
| Settings template | `server/flowcept_settings.template.yaml` | FlowCept config: `mq.type=mofka`, `channel=__TOPIC__`, `kv_db.enabled=false` (no Redis), `mongodb.enabled=true`. Rendered per-run. |
| Consumer launcher | `server/capture_flowcept.sh` | Starts `mongod`, renders the settings, launches `python3 -m flowcept.cli --start-consumption-services`, idles until a SHUTDOWN flag, graceful-stops (flush), prints an ingest verdict, keeps mongod up for export. Replaces the `capture.py` step. |
| Exporter | `server/export_jsonl.py` | Mongo `tasks` (schema in {darshan_runtime, darshan_runtime_agg}) → the same JSONL the reconstructor eats. Sorted by `seq`. |
| FlowCept submodule | `flowcept/` (+ `.gitmodules`) | Pinned to `hariteja-jajula/flowcept @ experiment/f1-v2-unpack-batches` (`63298bc`). **Must be this fork, not stock** — it null-guards `kv_db.enabled=false` (no Redis on compute) and unpacks the F1 packed-batch envelope. Stock upstream FlowCept fails on Polaris. |

The FlowCept "consumer" is literally the one CLI line
`python3 -m flowcept.cli --start-consumption-services` — there is **no custom
consumer.py** to maintain. `capture_flowcept.sh` is just the lifecycle around it.

---

## How to run (scale mode)

Prereqs beyond the capture.py path: a `mongod` binary on PATH (or `MONGOD=`), and
`deps`-installed FlowCept (`pip install -e flowcept` in the Mofka python env).

```bash
# 0. one-time
git submodule update --init --recursive            # pulls flowcept fork too
source server/env.sh
# ensure flowcept is importable in $PY:  "$PY" -c "import flowcept.cli"

# 1. broker (unchanged)
bash server/start-server.sh                         # writes server/mofka.json, topic 'darshan'

# 2. FlowCept consumer -> mongo (NEW; replaces the capture.py step)
MONGO_DB=darshan_stream TOPIC=darshan server/capture_flowcept.sh &
#    waits and prints "READY" once mongod + consumer are up

# 3. run the darshan-instrumented workload (README section 5, unchanged)
#    ... LD_PRELOAD=$(darshan_lib) DARSHAN_MOFKA_ENABLE=1 ... DARSHAN_MOFKA_TOPIC=darshan ...

# 4. tell the consumer to flush + stop
touch server/_flowcept_run/SHUTDOWN
#    it flushes DocumentInserter, prints an ingest verdict, and leaves mongod up

# 5. export mongo -> JSONL and reconstruct (reconstructor UNCHANGED)
"$PY" server/export_jsonl.py 127.0.0.1 darshan_stream > /tmp/events.jsonl
./darshan/install/bin/darshan-mofka-reconstruct /tmp/events.jsonl /tmp/job_partial.darshan
./darshan/install/bin/darshan-parser --show-incomplete /tmp/job_partial.darshan | head
```

`TOPIC` **must equal** the producer's `DARSHAN_MOFKA_TOPIC` (default `darshan`) or
the consumer subscribes to the wrong channel and lands 0 docs.

---

## Known gaps / decisions to make together (next session)

1. **Workflow linkage (optional).** FlowCept groups tasks by `workflow_id`. This
   branch's connector does not emit one, so exported docs have `workflow_id=null`
   — fine for the reconstructor (it ignores it), but if you want the tasks grouped
   under a job in Mongo, either (a) add `used:{workflow_id:"wf-<jobid>"}` to the
   connector's JSON (the DocumentInserter stamps `workflow_id` from `used`), or
   (b) push one `{type:"workflow", workflow_id:"wf-<jobid>", used:{...}}` message
   to the topic before stopping. Not required for reconstruction; decide if we
   want it for querying.

2. **Multi-process non-MPI record collision (separate from FlowCept).** The
   reconstructor keys on `{mod_id, record_id, rank}`; non-MPI darshan stamps every
   process `rank=0` and `record_id` is a filename hash, so N processes touching
   the same file collapse to one record. FlowCept/Mongo keeps them distinct docs
   (unique `task_id` per event), so the *export* preserves them — but the
   reconstructor still collapses them on the way into the `.darshan`. Fix options:
   key the reconstructor by `{mod,record_id,rank,hostname,pid}`, or add an
   `--aggregate` mode. This is orthogonal to the FlowCept work; noting it here so
   we track it.

3. **mongod at scale.** This demo runs a single memory-path mongod for
   correctness. For real multi-node scale, put mongod on a dedicated service node
   (see the crosslayer reference `node_service_unified.sh`: bedrock over ofi+tcp
   with `FI_TCP_IFACE` pinned to the HSN iface — that's the cross-node fix), and
   consider multiple Mofka partitions + consumers.

4. **Dependency weight.** Scale mode pulls in FlowCept (msgpack/pymongo/…) and
   requires a running mongod. The `capture.py` path stays as the zero-Mongo,
   dependency-light option; keep both.

---

## Reference (proven working recipe this was adapted from)

`/eagle/radix-io/hjajula/crosslayer-telemetry/src/consumer/` on this machine —
a hardened, multi-node-proven Darshan→Mofka→FlowCept→Mongo service:
- `node_service_unified.sh` — the full service (mongod + bedrock + 2 topics + 2
  consumers + graceful stop + per-run archive + ingest verdict). Line 192 is the
  `flowcept.cli --start-consumption-services` launch this branch copies.
- `flowcept_darshan_settings.template.yaml` — the settings this branch's template
  is adapted from.
- `emit_workflow_row.py` — the workflow-linkage helper (gap #1 above).

---

## Applied fixes (branch `fix/reconstructor-multimodule` in the darshan submodule)

Done 2026-07-16, syntax-checked with gcc `-fsyntax-only` against the real
darshan-util + uthash headers (exit 0). **NOT full-built** (needs autoconf +
diaspora-c + mochi). Diff: +92/-20, one file `darshan-util/darshan-mofka-reconstruct.c`.

- **C1 (blocker):** write module records in ascending module-id order (outer loop
  over DARSHAN_KNOWN_MODULE_COUNT). Fixes the "any multi-module capture is rejected"
  bug and also corrects C7's OOB index bound.
- **C3:** `json_get_string` now decodes `\uXXXX` (incl. surrogate pairs) to UTF-8,
  so non-ASCII filenames from capture.py (ensure_ascii=True) reconstruct correctly.
- **C4:** `decode_hex` rejects oversized payloads (exact-size match) instead of
  silently trimming.
- **K4:** removed dead `xstrndup`.
- Added the darshan-util copyright header.

**HELD (need a compiler / signature rethread — do next, carefully):**
- **C2+K3** nprocs = max_rank+1 (deletes struct rank_ent/add_rank/free_ranks,
  rethreads write_log signature). The parser assert/OOB fix.
- **C6/C8** connector robustness (env-size validation, rec_hex truncation guard).
- **RU1/RU2/RU3** reuse refactors.
Full plan + line refs: server/CODE_REVIEW.md §5.
