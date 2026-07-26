# Full-scale scaling campaign — 128 ranks/node × 4 nodes (updated 2026-07-26)

End-to-end validation of the Darshan→Mofka→FlowCept→MongoDB streaming pipeline at full node
scale on LCRC/Improv: **512 producers** (128 ranks/node × 4 workload nodes, no oversubscribe),
one dedicated broker node (5 nodes total, `separate` placement), verbs transport
(`ofi+verbs;ofi_rxm`, `MOFKA_NA_DOMAIN=mlx5_0`, producer `MOFKA_CLIENT_MODE=1`), and a
sharded drain of 8 partitions / 8 FlowCept consumers sharing one mongod (upsert on `task_id`).
Account `radix-io`, `debug` queue. All runs are smokes (small event counts); the point is the
pipeline at scale, not a long workload.

## Results

| Workload   | Producers | Attach errors | Produced | Drained | INGEST | VERDICT   | push p50 | init p50 | finalize p50 | walltime | node-hrs |
|------------|-----------|---------------|----------|---------|--------|-----------|----------|----------|--------------|----------|----------|
| **C**      | 512       | 0             | 109,056  | 109,568 | PASS   | **PASS**  | 27.7 µs  | 218 ms   | 131 ms       | 17:14    | 1.44     |
| python-ml  | 512       | 0             | 1,803    | 1,810   | PASS   | MISMATCH¹ | 32.7 µs  | 224 ms   | 71 ms        | 16:40    | 1.39     |
| MPI-IO     | 512       | 0             | 138,674  | 139,267 | PASS   | MISMATCH² | 23.4 µs  | 234 ms   | 39 ms        | 17:50    | 1.49     |

Jobs: C `7674801`, python-ml `7674839`, MPI `7674863`. Per-op / init / finalize are medians of the
per-rank `darshan-mofka[timing]` lines. "Produced" = per-op `send` calls across all 512 ranks;
"Drained" = darshan docs landed in MongoDB (`tasks total`).

## Headline findings

- **Attach scales cleanly to 512 producers.** Zero `fi_senddata` / `No provider` /
  `domain "(null)"` errors on any run — 128 producers/node × 4 nodes all attach over verbs. This is
  the verbs + `MOFKA_NA_DOMAIN` + `MOFKA_CLIENT_MODE` fix holding at full node scale across nodes.
- **End-to-end drain works at scale.** Every run is `INGEST: PASS` with **produced ≈ drained**
  (full drain, no shortfall) — the 8-shard consumer/one-mongod path keeps up with 512 producers.
- **Per-op streaming cost stays flat at scale:** push p50 ≈ **23–33 µs** at 512 producers, matching
  the ~25 µs single-node figure — the connector's per-I/O overhead does not degrade with node/rank
  count. Producer init (attach) is ~218–234 ms, finalize ~39–131 ms.
- **C is byte-exact at scale** (`VERDICT: PASS`): reconstructed op-totals equal native.

## Per-workload notes

**C (`docs/scaling/c/`)** — the clean reference. 512 producers stream ~109k ops, fully drain, and
the reconstruction matches native exactly. (C's I/O is entirely post-init, so nothing is missed.)

**python-ml (`docs/scaling/python-ml/`)** — INGEST PASS, full drain, but only **1,803 ops streamed
across 512 ranks (~3.5/rank)**. This is the documented **init-window gap**: nearly all of python-ml's
I/O is interpreter startup (imports, stdlib, `lib-dynload/*.so`) that happens during the ~224 ms
producer-init window, before the producer is up, so those ops are no-ops and never stream. What DOES
stream (the post-init training/checkpoint writes) drains fine. ¹`VERDICT: MISMATCH` is this expected
gap, not a scaling failure. (The finalize records-sweep that would recover the startup records is
disabled — it hangs python-ml; see the connector's KNOWN ISSUE note.)

**MPI-IO (`docs/scaling/mpi/`)** — INGEST PASS, full drain of ~139k ops (STDIO-heavy). ²`VERDICT:
MISMATCH` here is a **multi-rank comparison-scope artifact**, not a fidelity failure: the harness
copies a single rank's native log as `native.darshan`, whereas the reconstruction aggregates many
ranks (131 of 512 present). READS matched exactly (249=249); the OPENS/WRITES differences are the
single-rank-native vs aggregate-reconstruction scope. (Non-MPI workloads like C/python collapse to
rank 0 so their reconstruction dedups to one record/file, which is why C's single-vs-aggregate
compare happens to pass; MPI uses real ranks, so it doesn't.)

## Fidelity caveat at multi-rank

The `compare.txt` VERDICT was designed for single-rank byte-fidelity (where C and python-ml are
validated). At 512 ranks it compares one native rank against the full reconstruction, so VERDICT is
not a clean multi-rank fidelity metric — the trustworthy multi-rank signals here are **attach
(0 errors), INGEST PASS, and produced≈drained**. Byte-exact fidelity remains a single-rank result
(C exact; python-ml approximate by the init-window gap).

## Artifacts

Per workload: `native_report.html` + `partial_report.html` (pydarshan `python -m darshan summary`),
`compare.txt` (verdict), `ingest.txt` (drain counts), under `docs/scaling/<workload>/`.

## DLIO (fourth workload) — integrated + streaming; end-to-end run needs generous walltime

DLIO is now **wired into the harness** (`WORKLOAD=dlio`; `dlio)` cases in `job.sh`/`lib/run.sh`,
allowed value in `workload.config`) and **runs + streams under the connector**: across 2-node/4-rank
smokes DLIO generated its dataset and streamed **~8,600 POSIX I/O events over verbs at ~23–150 µs/push,
zero attach errors, no backpressure**. So the connector captures and streams a real DL I/O benchmark.

**Dependency wall (solved).** `dlio_benchmark 2.0.0` hard-requires `nvidia-dali-cuda110` (GPU-only;
Improv is CPU) and `torch*`, and its pinned `pydftracer==1.0.2` bundles a `gotcha` CMake project
modern CMake rejects. The working recipe (see `workloads/dlio/README.md`): an isolated **Python 3.11**
venv, `--no-deps` DLIO + `tensorflow-cpu` (torch/DALI stay lazy, avoided via the `tensorflow` data
loader), and `CMAKE_POLICY_VERSION_MINIMUM=3.5` to build pydftracer.

**Why no INGEST row yet.** Four 2-node smokes (15–30 min walltime) were all killed at walltime before
the drain/reconstruct/INGEST step: DLIO's TF-based startup + dataset generation is slow (observed
I/O-event rate ~5/s, generation is CPU-bound), and the connector's finalize flush times out (30 s) on
DLIO's end-of-run event pattern. It needs a **≥1 h walltime** (and/or a smaller dataset) to complete;
a 512-rank DLIO scale run is impractical because every rank pays the TensorFlow import. The
**512-producer scale is already demonstrated** by C/python-ml/MPI above, so DLIO adds "a real DL I/O
benchmark integrated and streaming under the connector," not a new scale point. Being Python-based,
DLIO is expected to show the same init-window gap as python-ml (VERDICT MISMATCH), not byte-exact.
The venv recipe + harness wiring are committed so a longer DLIO run can be launched directly later.

## Reproduce

```bash
# one full-scale run (swap WORKLOAD=c|python-ml|mpi); 5 nodes = 1 broker + 4 workload
PBS_ACCOUNT=radix-io QUEUE=debug WALLTIME=00:30:00 SKIP_BUILD=1 \
  WORKLOAD=c NODES=5 TASKS=128 PARTITIONS=8 CONSUMERS=8 EVENTS=200 bash submit.sh
# pydarshan HTML (auto-generated per run; or by hand from a run dir):
install/_venv/bin/python -m darshan summary native.darshan   # -> native_report.html
install/_venv/bin/python -m darshan summary partial.darshan  # -> partial_report.html
```
