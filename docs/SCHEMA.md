# The event schema

Every time Darshan sees an I/O operation worth reporting, the connector sends one
small JSON message to Mofka. This page describes what is in that message. It is the
contract shared by three pieces of code:

- the C connector that produces the events (`darshan/darshan-runtime/lib/darshan-mofka.c`),
- the FlowCept consumer that stores them,
- the reconstruct tool that reads them back (`darshan-mofka-reconstruct.c`).

If you change a field in one place, change it in all three.

## What one event looks like

```json
{
  "schema": "darshan_runtime",
  "schema_version": 2,
  "module": "POSIX",
  "op": "open",
  "event_type": "MET",
  "record_id": "9c89bbbe7b2c3fe3",
  "file": "/tmp/mofka-forward-smoke/posix-smoke.dat",
  "rank": 0,
  "seq": 0,
  "hostname": "i001",
  "pid": 1740644,
  "uid": 23569,
  "job_id": 7669510,
  "cnt": 1, "off": -1, "len": -1, "max_byte": -1, "switches": -1, "flushes": -1,
  "started_at": 1784785457.85, "ended_at": 1784785457.85,
  "dur": 0.000028, "total": 0.000028, "t0_epoch": 1784785457.852959,
  "rec_size": 704,
  "rec_hex": "e33f2c7b...."
}
```

## The fields

| Field | Meaning |
|---|---|
| `type` | Always `"task"` — marks the message as a FlowCept task document. |
| `activity_id` | `"darshan_<MODULE>"`, e.g. `darshan_POSIX`. |
| `task_id` | A unique id for this event: `darshan-<record_id>-<pid>-<seq>`. |
| `schema`, `schema_version` | Marks this as a Darshan runtime event, format version 2. |
| `module` | Which Darshan module the event came from: `POSIX`, `STDIO`, `MPIIO`, etc. |
| `op` | The operation: `open`, `read`, `write`, or `close`. |
| `event_type` | Darshan's data type for the record (`MET` for metadata, `MOD` for a module record). |
| `record_id` | Darshan's 16-hex id for the file record. The same file keeps the same id. |
| `file` | The path of the file the operation touched. |
| `rank` | MPI rank that did the I/O (0 for non-MPI programs). |
| `seq` | A counter that increases with every event from one process, so order is recoverable. |
| `hostname`, `pid`, `uid`, `job_id` | Where and by whom the program ran. |
| `cnt` | How many times this record has been touched (Darshan's record count). |
| `off`, `len` | Offset and length for a read or write. `-1` when not applicable. |
| `max_byte` | Highest byte offset accessed so far. `-1` when not applicable. |
| `switches` | Read/write direction switches (a Darshan access-pattern counter). |
| `flushes` | Number of flushes (STDIO). |
| `started_at`, `ended_at` | Wall-clock time of the operation, in seconds since the epoch. |
| `dur` | `ended_at - started_at` for this operation. |
| `total` | Darshan's cumulative time in this module for this record. |
| `t0_epoch` | When the connector started, so relative times can be computed. |
| `rec_size` | Size in bytes of the raw Darshan record carried in `rec_hex`. |
| `rec_hex` | The raw Darshan module record, hex-encoded. This is what lets the reconstruct tool rebuild a real `.darshan` log. |

## A note on `rec_hex`

`rec_hex` is a hex copy of Darshan's own internal record for the file at the moment
of the event. It is profiling state (counters and timers), not the contents of your
files. The reconstruct tool decodes it to rebuild a partial `.darshan` log that
Darshan's own tools can read.

## What FlowCept adds

The connector emits every field above, including `type`, `activity_id`, and
`task_id`. When FlowCept stores an event in MongoDB it keeps all of them and adds a
little of its own bookkeeping (for example `registered_at`), and it stores
`started_at` / `ended_at` as datetimes rather than plain numbers. The reconstruct
tool ignores the extra bookkeeping, so events exported from MongoDB and events
captured straight off the topic both reconstruct the same way.
