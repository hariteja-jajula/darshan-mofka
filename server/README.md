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

## Settings

You can change a few things with environment variables. The defaults are fine for
the demo, so you rarely need these:

- `MOFKA_PROTOCOL` — the network transport (defaults to the right one for your
  cluster, e.g. `verbs` on LCRC).
- `MOFKA_TOPIC` — the topic name (default `darshan`).
- `MOFKA_PARTITION_TYPE` — how the topic stores data (default `memory`).
- `MOFKA_SERVER_DIR` — where to put `mofka.json` and the broker's log (default:
  this directory). `job.sh` sets this per run so parallel jobs don't collide.

## Files

- `start_server.sh`, `stop_server.sh` — start and stop the broker.
- `bedrock-config.json` — the broker's configuration.
- `requirements.txt` — the Python packages the consumer needs.
- `spack/` — the recipe for building the Mofka software stack (see its README).
