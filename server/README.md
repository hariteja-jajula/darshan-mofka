# server

This runs the Mofka broker, the message bus the Darshan connector streams to.

## Start and stop

```bash
bash server/start_server.sh    # start the broker and create the topic
bash server/stop_server.sh     # stop it
```

`start_server.sh` launches Bedrock (which hosts Mofka), waits for it to come up,
and creates the topic the connector publishes to. It writes a small file called
`mofka.json` that holds the broker's address. Both the producer (the workload) and
the consumer (FlowCept) read that file to find the broker.

## Settings: `server.config`

The broker's knobs live in one file — [`server.config`](server.config) — read by
`start_server.sh` and `job.sh`. The defaults are fine for the demo:

```yaml
protocol: auto         # auto = the right transport for your cluster (verbs on LCRC); or verbs | tcp | ofi+tcp
topic: darshan         # topic name (the ONE place it's set: producer, broker, consumer all use it)
partitions: 1          # how many partitions to create
partition_type: memory # how the topic stores data (memory | default)
mongo:
  db: darshan_stream
  port: 27017
```

Override any key for a single run with an env var of the same uppercase name
(`PARTITIONS=4 bash server/start_server.sh`). `MOFKA_SERVER_DIR` still sets where
`mofka.json` and the broker log go (default: this directory); `job.sh` sets it per
run so parallel jobs don't collide.

## Files

- `start_server.sh`, `stop_server.sh` — start and stop the broker.
- `bedrock-config.json` — the broker's configuration.
- `requirements.txt` — the Python packages the consumer needs.
- `spack/` — the recipe for building the Mofka software stack (see its README).
