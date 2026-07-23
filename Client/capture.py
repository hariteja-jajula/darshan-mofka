#!/usr/bin/env python3
# capture.py <groupfile> <topic> [target] [idle_s] -- drain a mofka topic to STDOUT as
# JSONL (one compact JSON object per event): a durable, verifiable record of exactly what
# the darshan connector streamed. The final count ("captured N") goes to STDERR so stdout
# stays pure JSONL.
#
# Stops when EITHER:
#   * <target> events have been pulled -- pass the known 'sent' count so a lossless drain
#     exits immediately with no trailing idle wait, OR
#   * no new event arrives for <idle_s> seconds (topic drained, or delivery was lossy).
#
# Uses the BLOCKING consumer.pull().wait(); the timeout form future.wait(ms) returns empty
# immediately on this binding. A blocked pybind11 .wait() ignores Python signals, so the
# idle stop is enforced by a daemon watchdog thread that flushes the count and os._exit()s
# (the outer shell `timeout` is only a backstop).
#
#   "$PY" capture.py mofka.json darshan "$sent" > events/rpcN.jsonl 2> events/rpcN.count
import sys, json, os, time, threading
from mochi.mofka.client import MofkaDriver, AdaptiveBatchSize

gf     = sys.argv[1]
topic  = sys.argv[2] if len(sys.argv) > 2 else "darshan"
target = int(sys.argv[3]) if len(sys.argv) > 3 and int(sys.argv[3]) > 0 else 10_000_000
idle_s = float(sys.argv[4]) if len(sys.argv) > 4 else 20.0

n = 0
last = time.time()


def _watchdog():
    # A blocked .wait() won't run Python signal handlers, but this separate thread keeps
    # ticking and hard-exits after idle_s of silence -- our topic-drained / lossy detector.
    while True:
        time.sleep(0.5)
        if time.time() - last > idle_s:
            sys.stdout.flush()
            sys.stderr.write(f"captured {n}\n")
            sys.stderr.flush()
            os._exit(0)


driver   = MofkaDriver(group_file=gf)
th       = driver.open_topic(topic)
consumer = th.consumer("capture", batch_size=AdaptiveBatchSize,
                       data_selector=lambda m, d: None,   # metadata-only (no payload copy)
                       data_allocator=lambda m, d: [])

# start the idle watchdog only after the (possibly slow) connect, so connect time is not
# mistaken for idle; reset the clock right before the pull loop.
last = time.time()
threading.Thread(target=_watchdog, daemon=True).start()

while n < target:
    ev = consumer.pull().wait()        # blocking -- the form that actually delivers events
    if not ev:                          # defensive: some bindings return falsy at end-of-stream
        break
    md = ev.metadata if isinstance(ev.metadata, dict) else json.loads(ev.metadata)
    sys.stdout.write(json.dumps(md, separators=(',', ':')) + "\n")
    n += 1
    last = time.time()

sys.stdout.flush()
sys.stderr.write(f"captured {n}\n")
