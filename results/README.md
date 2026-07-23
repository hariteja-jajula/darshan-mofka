# results

Run folders are named after **what the run does**, not when it ran, so you can tell
them apart at a glance. These folders are not checked into git.

## Naming convention

```
<WORKLOAD>_<N>NODE_<P>PROC_<B>Broker-<placement>/
    RUN1/  RUN2/  ...        # one sub-folder per repetition
```

- `<WORKLOAD>` — `C`, `PYTHONML`, `OVERHEAD`, ...
- `<N>NODE` / `<P>PROC` — nodes in the allocation / workload processes.
- `<B>Broker` — number of broker (bedrock) ranks.
- `<placement>` — `colocated` (workload shares a node with a broker) or `split`
  (broker on the server node, workload on a separate node).
- `RUN<n>` — repetitions of the same configuration.

Examples currently here:

| folder | what it is |
|---|---|
| `C_1NODE_1PROC_1Broker-colocated/` | single-node C e2e; reconstruct-vs-native validation (has pydarshan HTML) |
| `PYTHONML_1NODE_1PROC_1Broker-colocated/` | single-node python-ml e2e; reconstruct validation (HTML) |
| `C_2NODE_1PROC_2Broker-colocated/` | 2-node MPI(tm) broker, workload co-located; INGEST proof |
| `C_2NODE_1PROC_1Broker-split/` | broker on server node, workload on a separate node; INGEST proof |
| `OVERHEAD_2NODE_1PROC_1Broker-split/` | overhead study (RUN1..3 reps; `summary.txt`, `overhead.csv`) |

## Inside a RUN folder

- `events.jsonl` — the streamed Darshan events, one per line.
- `partial.darshan` — the log rebuilt from those events (by `darshan-mofka-reconstruct`).
- `native.darshan` — the real Darshan log, for comparison.
- `native.html` / `reconstructed.html` — pydarshan reports (compare side by side).
- `run.out` / `run.err` — workload stdout / connector timing (`DARSHAN_MOFKA_TIMING`).
- `ingest_verdict.txt`, `summary.txt`, `overhead.csv` — as applicable.
