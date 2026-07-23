# Client

This is the consumer side of the demo. It reads the Darshan events off the Mofka
topic and turns them into files you can inspect.

There are two ways to consume, and you usually only need the first one.

## The main path: FlowCept into MongoDB

`capture_flowcept.sh` starts a local MongoDB and a FlowCept consumer. FlowCept
listens on the Mofka topic and writes every event it receives into MongoDB. When
you signal it to stop, it flushes and shuts down cleanly so nothing is lost.

`export_jsonl.py` then reads those events back out of MongoDB and writes them as
JSON, one event per line. That JSON file is what the reconstruct tool reads to
rebuild a partial `.darshan` log.

You do not normally run these by hand. `job.sh` runs the whole sequence for you
(start broker, start this consumer, run the workload, export, reconstruct,
compare). Look there to see how the pieces fit together.

## The simple path: capture.py

`capture.py` is a small debugging tool. It reads the topic directly and prints
each event as JSON, with no MongoDB and no FlowCept involved. Use it when you just
want to see what the connector is sending and don't care about storing it.

## Files

- `capture_flowcept.sh` — start MongoDB + the FlowCept consumer.
- `export_jsonl.py` — dump the stored events from MongoDB to JSON lines.
- `capture.py` — quick, dependency-light way to watch the stream (debugging only).
- `flowcept_settings.template.yaml` — FlowCept's settings, filled in per run.
