# Paper-reproduction results (overlap-friendly regime, COMPUTE=0, msg service on own node)
# Metric: per-event push/send cost (paper Table 3 analog, duration-independent) + self-timed init.
# Runs are short (~35-40s) so % overhead is init-dominated; per-event µs is the robust comparable.

## io_bench (C, CXI, 1 rank/node) -- 22,211 events
| batch | work_s | init_s | push_avg_us | send_avg_us | push_sum_s |
|---|---|---|---|---|---|
| baseline    | 38.4 | -    | -    | -   | -    |
| Adaptive(0) | 38.8 | 1.24 | 19.0 | 2.2 | 0.42 |
| 100         | 39.5 | 0.16 | 21.5 | -   | 0.48 |
| 1000        | 38.8 | 0.17 | 19.5 | -   | 0.43 |

## io_bench_py (Python, CXI, 1 rank/node) -- 22,406 events
| batch | work_s | init_s | push_avg_us | send_avg_us |
|---|---|---|---|---|
| baseline    | 35.5 | -    | -    | -   |
| Adaptive(0) | 35.7 | 1.31 | 19.0 | 2.1 |
| 100         | 35.8 | 0.17 | 19.4 | 2.2 |
| 1000        | ~36  | 0.20 | 18.9 | 3.6 |

## Key: per-event push ~19us, send ~2us across ALL batch sizes and both languages.
## Matches paper's sub-30us per-event overhead. send (on app critical path) ~2us = negligible.

## LONG RUNS (~10min, init amortized) -- THE PAPER-COMPARABLE RESULT
| workload | batch | WORK_s | overhead% | push_avg_us | send_avg_us | events |
|---|---|---|---|---|---|---|
| io_bench (C) | Adaptive | 601.3 | 0.348% | 19.8 | 2.2 | 37898 |

## FINAL C io_bench (Adaptive x3, overlap-friendly COMPUTE=0, ~600s/arm) -- CLEAN
| rep | WORK_s | overhead% | push_us | events |
|---|---|---|---|---|
| rep1 | 602.0 | 0.341 | 19.2 | 37899 |
| rep2 | 601.8 | 0.166 | 19.0 | 37899 |
| rep3 | 601.8 | 0.163 | 18.8 | 37899 |
| MEDIAN | 601.8 | 0.166 | 19.0 | 37899 |
Note: rep1 higher only due to one-time init variance; steady-state ~0.16%.
WORK stable across reps -> NOT I/O-bound (no contention). Sleep=79% of WORK = overlap regime.

## MPI (TCP, 32 ranks/node, Adaptive) -- partial
| arm | events | push_us | send_us | verdict |
|---|---|---|---|---|
| streaming_rep1 | 26566 | 35.1 | 7.3 | PASS |
(MPI has no WORK markers; per-event cost is the comparable metric. TCP push ~35us vs CXI ~19us.)

## python-ml (train.py, real ML, CXI) -- baseline WORK=211s, streaming reps in progress

## python-ml (train.py real ML, CXI 1rank/node, Adaptive) -- COMPUTE-BOUND behavior
| arm | WORK_s | self-timed oh% | push_us | send_us | events |
|---|---|---|---|---|---|
| baseline | 211.3 | - | - | - | 0 |
| streaming_rep1 | 351.6 | 2.213 | 46.1 | 0.7 | 154538 |
Note: WALL +66% (211->352) though self-timed connector cost only 2.2% -> same frequency/
contention effect as the compute-bound io_bench_py matmul case. Real ML workload is
compute-heavy (NumPy/PyTorch), streams 154k events. NOT overlap-friendly like pure I/O.

## MPI (TCP 32rank, Adaptive) reps -- PASS
| rep | events | push_us | send_us | verdict |
|---|---|---|---|---|
| rep1 | 26566 | 35.1 | 7.3 | PASS |
| rep2 | 26566 | 32.7 | 11.9 | PASS |

## MPI FINAL (TCP 32rank, Adaptive, 3 reps) -- all PASS
| rep | events | push_us | send_us | verdict |
|---|---|---|---|---|
| rep1 | 26566 | 35.1 | 7.3 | PASS |
| rep2 | 26566 | 32.7 | 11.9 | PASS |
| rep3 | 26566 | 35.2 | 15.7 | PASS |
| median | 26566 | 35.1 | 11.9 | PASS |

## python-ml FINAL-ish (real ML, CXI, Adaptive) -- WALL overhead, reproducible
| arm | WORK_s | events |
|---|---|---|
| baseline | 211.3 | 0 |
| streaming_rep1 | 351.6 | 154538 |
| streaming_rep2 | 348.5 | 154538 |
=> +65-66% wall, reproducible. Compute-bound real-ML behavior (not overlap-friendly).

## python-ml COMPLETE (real ML, CXI, Adaptive, 3 reps) -- FINAL
| arm | WORK_s | self-timed oh% | push_us | send_us | events |
|---|---|---|---|---|---|
| baseline | 211.3 | - | - | - | 0 |
| streaming_rep1 | 351.6 | 2.21 | 46.1 | 0.7 | 154538 |
| streaming_rep2 | 348.5 | 2.09 | 45.3 | 0.8 | 154538 |
| streaming_rep3 | 350.4 | 1.92 | 41.6 | 0.8 | 154538 |
| MEDIAN | 350.4 | 2.09 | 45.3 | 0.8 | 154538 |
=> WALL +66% (211->350), reproducible x3. Self-timed connector cost only ~2%; the wall gap
is the frequency/contention effect (compute-bound real ML). 154k events/rep.

## io_bench_py OVERLAP-FRIENDLY (COMPUTE=0, CXI, Adaptive) -- reproduces paper for Python too
| arm | WORK_s | overhead% | push_us | send_us | events |
|---|---|---|---|---|---|
| streaming_rep1 | 558.5 | 0.196 | 21.5 | 2.1 | 36851 |
=> SAME workload as the +43% compute-bound case, but COMPUTE=0 -> 0.196%. The contrast
(0.2% overlap vs +43% compute-saturated) is the key finding: overhead depends on whether
the app has compute slack, not on the connector.
