import sys, json
from collections import Counter
# Multi-node verifier: pull `want` events from the topic and tally them by the
# producing host (the connector stamps "hostname" into each event's metadata).
# A PASS shows events arriving from every client node -> proves cross-node
# streaming, not just a single local producer.
from mochi.mofka.client import MofkaDriver, AdaptiveBatchSize

groupfile = sys.argv[1]
topic = sys.argv[2] if len(sys.argv) > 2 else "darshan"
want = int(sys.argv[3]) if len(sys.argv) > 3 else 51

driver = MofkaDriver(group_file=groupfile)
th = driver.open_topic(topic)
consumer = th.consumer(
    "verify-mn",
    batch_size=AdaptiveBatchSize,
    data_selector=lambda metadata, descriptor: None,
    data_allocator=lambda metadata, descriptor: [],
)

hosts = Counter()
n = 0
while n < want:
    ev = consumer.pull().wait()
    md = ev.metadata if isinstance(ev.metadata, dict) else json.loads(ev.metadata)
    hosts[md.get("hostname", "?")] += 1
    n += 1

print(f"--- received {n} events from {len(hosts)} host(s) (expected {want}) ---")
for h, c in sorted(hosts.items()):
    print(f"    {h}: {c} events")
