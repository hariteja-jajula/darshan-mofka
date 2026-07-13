#!/usr/bin/env python3
# dump_events.py <groupfile> <topic> <count> -- print the FULL JSON of each event
# on a mofka topic, so you can see exactly what the darshan connector sends.
import sys, json
from mochi.mofka.client import MofkaDriver, AdaptiveBatchSize

gf    = sys.argv[1]
topic = sys.argv[2] if len(sys.argv) > 2 else "darshan"
want  = int(sys.argv[3]) if len(sys.argv) > 3 else 20

driver   = MofkaDriver(group_file=gf)
th       = driver.open_topic(topic)
consumer = th.consumer("dump-events", batch_size=AdaptiveBatchSize,
                       data_selector=lambda m, d: None,   # metadata-only
                       data_allocator=lambda m, d: [])
n = 0
while n < want:
    fut = consumer.pull()
    try:
        ev = fut.wait(5000)          # stop if the topic drains (5s idle)
    except TypeError:
        ev = fut.wait()              # older binding: no timeout arg
    if not ev:
        print("(no more events)"); break
    md = ev.metadata if isinstance(ev.metadata, dict) else json.loads(ev.metadata)
    print(f"========== event {n} ==========")
    print(json.dumps(md, indent=2, sort_keys=True))
    n += 1
print(f"--- dumped {n} events from topic '{topic}' ---")
