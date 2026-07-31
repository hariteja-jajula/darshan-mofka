# Calibration — knob values for ~10 min (600 s) per rep

Purpose: each workload does "work" at a different rate; convert the 10-min-per-rep target
into a concrete work-knob value. Compute rates measured 2026-07-31.

## io_bench (C) — cxi, 1 rank/node   [COMPUTE knob, 16 iters/rep]
Measured (login node, cc -O2), per matmul:
- MATRIX_SIZE=512: 0.517 s/matmul  -> **COMPUTE=72** for ~10 min
- MATRIX_SIZE=256: 0.056 s/matmul  -> COMPUTE=669 for ~10 min
Recommended: **MATRIX_SIZE=512, COMPUTE=72** (fewer, bigger matmuls = cleaner).
Formula: COMPUTE = 600 / (16 * per_matmul).
Note: earlier COMPUTE=98@512 gave 1134 s (~19 min) on a compute node -> compute nodes are a
bit slower than login; expect to trim COMPUTE ~10-25% after a compute-node check. Safe start: 72.

## io_bench_py (Python) — cxi, 1 rank/node   [COMPUTE knob, 16 iters/rep]
Measured (venv py314), pure-Python triple loop, per matmul:
- MATRIX_SIZE=256: 2.425 s/matmul  -> COMPUTE=15 for ~10 min
- MATRIX_SIZE=128: 0.340 s/matmul  -> **COMPUTE=110** for ~10 min
Python is ~43x slower than C at N=256 (interpreter). Recommended: **MATRIX_SIZE=256, COMPUTE=15**
(keeps N comparable to C; small COMPUTE). Formula same as C.
Event count identical to C (~600) since same I/O loop -> compute and events are INDEPENDENT.

## mpi (mofka_forward_mpiio) — tcp, 32 ranks/node   [STEPS knob, pure I/O]
No compute knob; runtime set by STEPS (collective write+read iterations). Events grow with STEPS.
MEASURED (job 7307937, debug): STEPS=1000, 32 ranks/node (1 workload node) -> 66,166 events,
job walltime ~12m26s (includes build+broker+drain+reconstruct), **VERDICT: PASS**.
-> MPI streaming CONFIRMED at 32 ranks/node on tcp (not just 1 rank). ~66 events/step aggregate
   (2K/rank). For ~10 min of workload alone, STEPS~=1000 is roughly right (job overhead inflates
   the 12m). Use **STEPS~=800-1000** as the 10-min setting; refine per scale point.
Methodological note: for mpi, "10 min/rep" and "fixed event count" are COUPLED (more STEPS =
more time AND more events). Decision pending: target 10-min runtime OR fixed events.

## dlio — tcp, 32 ranks/node   [EVENTS->num_files_train knob, pure I/O, heavy]
No compute knob; runtime set by num_files (EVENTS). Heavier per unit than io_bench.
MEASURED (job 7307976, debug): EVENTS=500, 32 ranks/node -> 321,081 events, job walltime
~14m29s, **VERDICT: MISMATCH (1 difference)**. No dropped events.
The single mismatch: `POSIX_SEEKS aggregated=3 native=96` on one record. NOT data loss and NOT
a scale failure -- every other counter across 321K events matched. It's a dlio-specific MPI
seek-aggregation edge (the reconstructor's mpi-mode aggregation under-counts POSIX_SEEKS for
dlio's data loader). Flag as a known small fidelity gap for dlio, separate from overhead.
-> For ~10 min: EVENTS=500 gave ~14.5m job (data-gen heavy). Use **EVENTS~=300-350** for ~10 min
   workload. dlio is the heaviest/slowest per unit of the four.

## SUMMARY -- 10-min/rep knob values (use these in the study)
| workload    | protocol | density   | knob            | ~10-min value        | notes |
|-------------|----------|-----------|-----------------|----------------------|-------|
| io_bench    | cxi      | 1/node    | COMPUTE @N=512  | **72**               | events ~600, independent of compute |
| io_bench_py | cxi      | 1/node    | COMPUTE @N=256  | **15**               | ~43x slower matmul than C |
| mpi         | tcp      | 32/node   | STEPS           | **~800-1000**        | PASS @32 ranks; events ~66/step |
| dlio        | tcp      | 32/node   | EVENTS(num_files)| **~300-350**        | MISMATCH(1): POSIX_SEEKS agg edge |

All four RUN on the study path. io_bench/io_bench_py/mpi = clean PASS; dlio has 1 known
seek-aggregation mismatch to note (not a blocker for the overhead study).

## Server config (constant for all runs)
node 0 = broker (bedrock, 1 broker, rpc_thread_count=4, progress_thread=true, master_db=map,
warabi memory data store) + FlowCept consumer(s) + mongod (map->mongo, port 27017).
Tunables to scale the drain: PARTITIONS, CONSUMERS (raise with producer count).
