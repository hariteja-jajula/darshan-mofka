# workloads/dlio/ -- DLIO benchmark workload (optional)

[DLIO](https://github.com/argonne-lcf/dlio_benchmark) is a realistic deep-learning
I/O benchmark. Run it under the Darshan-Mofka connector to stream a more
representative POSIX workload than the tiny C smoke test.

Prereqs: the stack is built, the broker is up, and a FlowCept consumer is
draining the topic. Because DLIO is a separate run, use a **separate**
`MONGO_DB` and `EVENTS_JSONL` so its events don't mix with other workloads.

## Install DLIO

```bash
git clone https://github.com/argonne-lcf/dlio_benchmark
cd dlio_benchmark/
pip install .
```

## Generate data + run

```bash
dlio_benchmark ++workload.workflow.generate_data=True
```

Run the actual benchmark under Darshan the same way as the C smoke workload:
set `LD_PRELOAD="$(darshan_lib)"` and the `DARSHAN_MOFKA_*` variables in the
environment (see [`workloads/c/README.md`](../c/README.md) for the full env
block), then invoke `dlio_benchmark`.

## Verify

Point `EVENTS_JSONL` at the DLIO run's file and inspect it:

```bash
EVENTS_JSONL=/tmp/darshan-mofka-dlio-events.jsonl
grep '"module":"POSIX"' "$EVENTS_JSONL" | head
grep -Ei '"op":"(open|read|write|close)"' "$EVENTS_JSONL" | head
```
