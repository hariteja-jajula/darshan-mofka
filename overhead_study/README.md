# overhead_study/ — per-test connector-overhead jobs

One standalone job script per **(workload × workload-node scale)**. Each script
submits **3 arms** (baseline / runtimeonly / streaming) as 3 separate PBS jobs.
Goal: measure the Darshan→Mofka connector's **init**, **finalize**, and
**per-push** cost, plus per-arm wall time.

## Files (15)
`<W>wlnode_1srvnode_<workload>_<R>rnkpernd_<proto>.sh`, for `W ∈ {1,2,4}`:

| workload | proto | ranks/node | scale knob (10-min) |
|---|---|---|---|
| io_bench (C)   | cxi | 1  | COMPUTE=72 @ MATRIX=512 |
| io_bench_py    | cxi | 1  | COMPUTE=15 @ MATRIX=256 |
| python-ml      | cxi | 1  | ML_EPOCHS (EVENTS) — **uncalibrated** |
| mpi (MPI-IO)   | tcp | 32 | STEPS (EVENTS) ≈ 900 |
| dlio           | tcp | 32 | num_files (EVENTS) ≈ 320 |

Total nodes = workload nodes + 1 broker/consumer node → **queue by size**:
`2 total → debug`, `3 & 5 total → debug-scaling` (both ≤ 1 h wall).

## Submit
```bash
# preview the qsub commands without submitting:
DRYRUN=1 bash overhead_study/1wlnode_1srvnode_iobench_1rnkpernd_cxi.sh
# actually submit this config's 3 arms:
bash overhead_study/1wlnode_1srvnode_iobench_1rnkpernd_cxi.sh
```
Run with **`bash`**, not `qsub` — the scripts call `qsub` internally with `-A`.
Watch: `qstat -u $USER`. Results land in `results/OVH_<workload>_<W>wl/<arm>/RUN*`.

Note: **both** `debug` and `debug-scaling` enforce `max_queued = 1` per user (only
one job may sit in `Q` state per queue at a time). So you cannot bulk-submit — the
2nd/3rd arm of a file is rejected until the 1st starts *running*. Use the feeder:
```bash
nohup bash overhead_study/dripfeed.sh >/dev/null 2>&1 &   # drip-submits all arms
tail -f overhead_study/.dripfeed.log                      # watch progress
```
It keeps one queued job per queue (debug + debug-scaling advance independently),
submits the next arm as slots free, records progress in `.dripfeed_state`
(re-runnable/resumable), and orders proven workloads first. **`python-ml` 2wl/4wl
are held** (uncalibrated) — submit them manually after validating 1wl python-ml.

## Read the results
```bash
bash overhead_study/extract_all.sh
```
Prints init_us / finalize_us / push avg+max / work_s / VERDICT per run.
Only the **streaming** arm has push timing (baseline has no libdarshan;
runtimeonly streams 0 events → wall-time only).

## Caveats
- **python-ml on cxi streaming is unproven** (`workloads/job.sh:37` flood warning)
  and its ML_EPOCHS scale is uncalibrated — validate `1wl` first, then set 2/4wl.
- **dlio** has a known single-counter reconstruct gap (`POSIX_SEEKS` aggregation)
  → its streaming VERDICT may show `MISMATCH(1)`; not an overhead-study failure.
- Knobs target ~10 min of workload; job overhead (build skipped, broker bring-up,
  drain, reconstruct) adds a few minutes — all within the 1 h wall.
