import sys, json
# Current mochi.mofka API: AdaptiveBatchSize lives in mochi.mofka.client
# (older harness imported it from pymofka_client). Events from the darshan
# connector are metadata-only, so we use a no-op data selector/allocator.
from mochi.mofka.client import MofkaDriver, AdaptiveBatchSize

groupfile = sys.argv[1]
topic = sys.argv[2] if len(sys.argv) > 2 else "darshan"
want = int(sys.argv[3]) if len(sys.argv) > 3 else 10

driver = MofkaDriver(group_file=groupfile)
th = driver.open_topic(topic)
consumer = th.consumer(
    "darshan-consumer",
    batch_size=AdaptiveBatchSize,
    data_selector=lambda metadata, descriptor: None,  # metadata-only: load no data
    data_allocator=lambda metadata, descriptor: [],
)

n = 0
while n < want:
    ev = consumer.pull().wait()
    # newer bindings hand back metadata already parsed into a dict; older ones a JSON string
    md = ev.metadata if isinstance(ev.metadata, dict) else json.loads(ev.metadata)
    print(f"[{n}] module={md.get('module')} op={md.get('op')} "
          f"rank={md.get('rank')} file={md.get('file','')[:50]} bytes={md.get('len')}")
    n += 1
print(f"--- received {n} events from topic '{topic}' ---")
