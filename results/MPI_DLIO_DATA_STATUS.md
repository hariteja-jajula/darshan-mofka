# MPI / DLIO data status (2-node, debug-fittable) -- 2026-08-04

## What we have (all 2-node = 1 workload + 1 broker, fits debug queue)
| run | workload | streaming | events | push_avg | send_avg | verdict | valid wall? |
|---|---|---|---|---|---|---|---|
| PAPER_mpi3   | mpi (PACED)  | rep1 | 39,770  | ~35us | ~7us  | PASS | YES: base 602.4s / stream 600.7s (~0% oh) |
| PAPER_mpi    | mpi          | 3 reps | 26,566 | 35.1us | 11.9us | PASS | no (arm-to-arm only) |
| ALLOC_mpi_N1 | mpi          | 1 rep | 59,566  | 37.8us | 41.4us | PASS | no marker |
| PAPER_dlio   | dlio         | 2 reps | 475,994 | 40us | 3.8us | PASS | no valid wall |
| PAPER_dlio3  | dlio         | rep1+ | 475,994 | ~40us | ~4us | PASS | UNRELIABLE (cold 139s vs warm 15s) |
| ALLOC_dlio_N1| dlio         | 1 rep | 480,420 | 42.9us | 40.7us | PASS | no marker |

## Verdict
- MPI: FIXED. PAPER_mpi3 (paced with IO_SLEEP_MS) gives a valid ~600s wall:
  baseline 602.4s -> streaming 600.7s = ~0% wall overhead (I/O-bound, streaming overlaps).
  Fidelity PASS every run. Use PAPER_mpi3 for the table.
- DLIO: fidelity PASS + per-event push/send are solid, BUT the wall is unreliable --
  baseline runs COLD (TF import + FS warmup ~124s), streaming runs WARM (~15s), so
  baseline-vs-streaming wall is dominated by cold/warm variance, NOT streaming. Report DLIO
  as per-event cost + PASS; mark wall as "I/O-bound, cold/warm-dominated -> further study".
- The OVH_*_1wl / OVH_*_N1 dirs are empty/failed; ALLOC_*_N1 are the completed 2-node runs.

## For the tables (5 slides)
- io_bench (C), io_bench_py, python-ml: full 4-arm data with VALID WORK walls. READY.
- mpi: PAPER_mpi3 (valid paced wall). READY.
- dlio: per-event + PASS; wall = further study.
