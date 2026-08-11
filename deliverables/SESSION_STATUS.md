# Darshan→Mofka overhead — session status (2026-08-10)

Worktree: `/eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight`
Branch: `lean-main-cleanup`. Git identity: hariteja-jajula <hjajula@crimson.ua.edu>. No AI attribution in commits.

---

## THE HEADLINE RESULT

Found and fixed the root cause of streaming overhead: the connector ran margo's
**DEFAULT spinning scheduler**, which pegs a whole core and doubled wall time.
**Fix = 2 env vars on the streaming arm:**
1. `DIASPORA_C_SENDER_THREADS=1`  (dedicated sender ES)
2. `DARSHAN_MOFKA_MARGO_JSON=<basic_wait config>` (blocking scheduler, not spinning)

The exact margo JSON (must be `export`ed inside the PBS body — commas break qsub `-v`):
```
{"use_progress_thread":false,"rpc_thread_count":0,"argobots":{"pools":[{"name":"__primary__","kind":"fifo_wait","access":"mpmc"},{"name":"__progress__","kind":"fifo_wait","access":"mpmc"}],"xstreams":[{"name":"__primary__","scheduler":{"type":"basic_wait","pools":["__primary__"]}},{"name":"__progress__","scheduler":{"type":"basic_wait","pools":["__progress__"]}}]},"progress_pool":"__progress__"}
```
Effect on io_bench: **+100% → +4%**. Baked into `overhead_study/run_overhead.sh` streaming arm.

---

## THE 4 SLIDES — verified status (audited by skeptical agents)

| slide | overhead | events (sent==stored?) | status |
|---|---|---|---|
| **io_bench 1wl** | **+4.05%** (3.9/4.3/3.9) | 1,383 = 1,383 ✓ no loss | READY |
| **io_bench 4wl** (CONS=2) | **+2.4%** (2.3/2.4/2.4) | 5,532 = 5,532 ✓ no loss | READY |
| **python-ml 1wl** | **+2.85%** (3.1/2.2/3.3) | 641,597 = 641,597 ✓ no loss | READY |
| **python-ml 4wl** (CONS=1) | +2.57% wall | **41% LOSS: 2.57M produced → 1.5M stored** | RERUNNING w/ CONS=2 (job 7418427) |

baseline walls: io_bench 1wl=205.8, io_bench 4wl=341.7, python-ml 1wl=249.0, python-ml 4wl=250.3

### KNOWN CAVEATS (must disclose, do NOT overclaim):
- **baseline & runtimeonly are n=1** (single rep) in all studies → no CI on the overhead. Should run 3 baseline reps for confidence.
- VERDICT is **"TELEMETRY"** not "PASS" — rec_hex was dropped, so NOT byte-exact reconstruction; native .darshan is source of truth. Represent honestly.
- CPU_PROBE accurate statement: streaming `cpu_self` is **no longer ~2× cpu_thread** (fix worked); there is still a small ~8s gap on io_bench (NOT "cpu_self ≈ cpu_thread").
- python-ml 4wl CONS=1 dropped 41% of events (single consumer can't drain 2.57M events; mongod "Broken pipe" before drain). RUN3 had corrupt counts (total<darshan<file).

---

## OPEN WORK
1. **python-ml 4wl CONS=2** (job 7418427, debug-scaling) — verify sent==stored. CONS=2 may STILL be
   insufficient for 2.57M events (io_bench 4wl only had 5,532). If it still drops → CONS=4/higher PART,
   or REDUCE python-ml event volume (fewer ML_FILES/EVENTS) so the pipeline keeps up.
2. Add 3 baseline reps to each study for confidence intervals.
3. Build the 2 io_bench slides to match the python-ml deck (deliverables/make_pythonml_slides.py format:
   5 rows baseline/darshan-only/stream1-3, 7 cols init/per-push/per-send/finalize/events/wall/overhead).

## DLIO (separate, characterized by agents — NOT for these 4 slides)
- **Fail #1 "tcp provider not available" (multi-node):** scale-specific. tcp provider IS in libfabric;
  Cray PE injects FI_PROVIDER=cxi on multi-node launch. **Candidate fix: `FI_PROVIDER=tcp`** on producer
  env (untested). Works at 1 workload node, fails at ≥2.
- **Fail #2 NA_TIMEOUT (rep 2+):** broker-reuse-across-reps bug. Broker started once (job.sh:142), core-dumps
  at end of rep1, rep2 hits dead broker. **Fix: broker-per-rep in legacy loop** (mirror mpmd path).

## CONSUMER SCALING / CXI LIMITS (learned the hard way)
- CXI at 5 nodes: broker + N consumers on ONE node share the NIC's fixed resource pool (PTEs/TXQs/EQs/ACs).
  **CONS=4/PART=16 EXCEEDS the limit → "CXI alloc failed".** CONS=2/PART=4 fits. (Confirmed by ALCF bug
  tracker #12 — multiple mpiexec on same node not supported.)
- Also saw transient `NA_IO_ERROR` (CXI fabric send error) on one io_bench 4wl run — retry succeeded, so transient.

## CODE CHANGES IN TREE (uncommitted)
- `darshan/darshan-runtime/lib/darshan-mofka.c`: RAW_JSON path (DARSHAN_MOFKA_RAW_JSON, push_raw) — built, NOT
  the fix for the +100% (that was the margo config). RAW_JSON needs libraw.so serializer (was missing/rebuilt).
- `darshan/darshan-util/darshan-mofka-reconstruct.c`: rank-normalization fix (32/32 logs parse, pydarshan renders).
- `lib/run.sh`: topic-race TOPIC_READY flag + 3s sleep (consumer waits for topic create); ML_FILES/CHECKPOINT_EVERY
  forwarded to io_bench.
- `workloads/c/io_bench.c`: REWRITTEN to realistic C train-style (dataset write + per-epoch re-read + tiled matmul
  + checkpoints). Compiled. Old pure-I/O version gone.
- `overhead_study/run_overhead.sh`: single-job 3-arm runner WITH the margo fix baked into streaming arm.
- Deleted overhead_study io_bench_py/mpi/dlio/2wl scripts (scope cut to io_bench + python-ml, 1wl+4wl).

## KEY KNOBS (reuse to reproduce)
Submit: `WORKLOAD=io_bench|python-ml WLNODES=1|4 CONSUMERS=1|2 PARTITIONS=4 STUDY=<tag> bash overhead_study/run_overhead.sh`
- 1wl → debug queue (2 nodes); 4wl → debug-scaling (5 nodes). DRYRUN=1 to preview.
- io_bench knobs: IO_ITERS=8 ML_FILES=8 IO_SIZE_MB=16 COMPUTE=72 MATRIX_SIZE=512 CHECKPOINT_EVERY=4 (~340s/rep)
- python-ml knobs: EVENTS=1000 ML_FILES=64 ML_ROWS=4096 ML_COLS=64 (~250s/rep, ~641K events/node)
- verify delivery: compare `wc -l events.jsonl` vs `tasks total=` in ingest.txt (must be EQUAL = no drop)
