# darshan-mofka

Stream Darshan I/O events from a running job into Mofka and reconstruct a
Darshan-compatible log from the stream.

## Why

Darshan normally writes its log at application shutdown. If a job crashes, is
killed, or never reaches finalization, the Darshan log may never be written.

This project adds a Darshan runtime connector that publishes I/O events while the
job is still running. The streamed events can later be reconstructed into a
`.darshan` log.

## Pipeline

```text
application
  |
  | Darshan intercepts I/O calls
  v
Darshan runtime + Mofka connector
  |
  v
Mofka broker
  |
  v
FlowCept consumer
  |
  v
MongoDB
  |
  v
events.jsonl
  |
  v
darshan-mofka-reconstruct
  |
  v
partial.darshan
```

The connector lives in:

```text
darshan/darshan-runtime/lib/darshan-mofka.c
```

The rest of this repository is the harness for building, running, consuming,
reconstructing, and comparing logs.

## Quick Start

Clone with submodules:

```bash
git clone https://github.com/hariteja-jajula/darshan-mofka.git
cd darshan-mofka
git submodule update --init --recursive
```

Check dependencies:

```bash
bash check-deps.sh
```

If needed, build the fallback stack:

```bash
DARSHAN_MOFKA_PROFILE=lcrc bash install/setup.sh
```

Submit the configured workload:

```bash
PBS_ACCOUNT=<project> bash submit.sh
```

For workload configuration and run details, see:

```text
workloads/README.md
```

For environment setup details, see:

```text
env/README.md
```

## Repository Layout

```text
darshan/              Darshan with the Mofka connector
diaspora-stream-api/  C streaming API used by the connector
flowcept/             consumer used to drain Mofka into MongoDB
env/                  cluster/runtime environment setup
server/               Mofka broker configuration and helpers
Client/               FlowCept consumer and JSON export tools
Database/             local MongoDB helper
workloads/            workloads and the main runner
install/              fallback source-build setup
results/              curated artifacts and ignored per-run outputs
submit.sh             PBS submission wrapper
check-deps.sh         read-only dependency checker
```

## More Docs

```text
env/README.md          server/workload environment setup
workloads/README.md    workload selection, topology, submit flow, outputs
install/README.md      source-build fallback setup
server/spack/README.md Spack/Mofka stack details
```
