# Mofka / Mochi Configuration Notes for the Darshan -> Mofka -> FlowCept Pipeline

Grounded ONLY in the official Mofka / Mochi / Diaspora / FlowCept documentation and
source. Where the docs are silent, this file explicitly says **"docs do not specify"**
rather than guessing. Every subsection cites the source URL it is based on. A full
`Sources` list is at the bottom.

> Terminology note: there are **two official CLIs** for driving a Mofka service.
> - `mofkactl` (native, shipped as `python -m mochi.mofka.mofkactl` in the `mochi-hpc/mofka`
>   repo). This is what **our project scripts use** (`server/start_server.sh`,
>   `flowcept/resources/mofka/bedrock_setup.sh`).
> - `diaspora-ctl` (from the Diaspora Stream API, the newer front-end used throughout the
>   current mofka.readthedocs.io pages).
>
> Both are documented below where they differ.

---

## 0. Practical recommendations for our single-node demo and a multi-node study

These are the doc-backed defaults for **many small Darshan metadata messages** (each event
is a small JSON metadata document, little/no data payload).

**Single-node demo (what to run now):**
- **Partition type = `memory`** for the lowest-overhead demo. The quickstart topic is
  "in-memory by default"; a memory partition keeps events in RAM, so there is no disk I/O
  on the hot path — ideal for measuring pure connector/broker overhead of small messages.
  Trade-off: **not persistent** (events are lost on server restart).
  (mofka.readthedocs.io quickstart; `mofkactl` `MemoryPartitionManager`.)
- **Partition count = 1** on a single server is fine for the demo. The docs say
  `num_partitions` are assigned to servers **round-robin**, so extra partitions mainly buy
  parallelism **across servers/ranks**; on one server they share the same Argobots pools.
  (mofka.readthedocs.io advanced.)
- **Producer batch size = Adaptive** (our `DARSHAN_MOFKA_BATCH=0` -> adaptive). The docs
  recommend Adaptive exactly for this case: it "aims to send batches as soon as possible
  but will increase the batch size if the server is not responding fast enough" — i.e. low
  latency for small messages, automatic batching only under backpressure.
  (diaspora producer page.)
- **Ordering = `Loose`** unless you need per-batch order; `Strict` "may limit parallelism".
  Our Darshan connector already uses `DIASPORA_C_ORDERING_LOOSE`.
  (diaspora producer page.)
- **Margo multithreading**: keep `use_progress_thread: true` + `rpc_thread_count: 4`
  (our config already does this) so RPC handling does not serialize on `__primary__`.
  (mofka.readthedocs.io advanced.)

**Multi-node throughput/overhead study (what to change):**
- **flock bootstrap: `self` -> `mpi`**, launch bedrock under `mpirun -n N bedrock ...`,
  and gate the single master Yokan DB to rank 0 with an `"__if__": "$MPI_COMM_WORLD.rank == 0"`.
  (mofka.readthedocs.io advanced; flock `04_bootstrap_mpi`.)
- **Transport: switch `na+sm` -> `tcp`/`verbs`/`cxi`** because `na+sm` is shared-memory,
  single-machine only. (mofka.readthedocs.io advanced.)
- **Scale partitions with servers**: create the topic then add one partition per rank
  (`mofkactl partition add <topic> --rank i ...` for each i), or with `diaspora-ctl` set
  `--topic.num_partitions N` (round-robin across servers). (advanced; `mofkactl` partition.py.)
- **For persistence and a real I/O study, use `default` (on-disk) partitions** with a
  `path` and an `abt-io` io_controller, and consider dedicating Argobots xstreams or
  io_uring to I/O. Make the **master DB persistent** with Yokan `rocksdb`.
  (mofka.readthedocs.io advanced + architecture.)

**Is our current setup aligned?** See the per-item verdict at the very end of this file
(section "Alignment check for our current config").

---

## 1. Mofka topics & partitions

### 1a. Topic vs partition; how to create them

**Answer.** A **topic** is "a distributed collection of *partitions* to which events are
appended." A **partition** is one of those append-only units; when producing, a
**partition selector** "is given a list of available partitions for a topic and ... makes a
decision on which partition each event will be sent to." If no selector is supplied, the
default one "will cycle through the partitions in a round robin manner." (diaspora topics.)

Creating them — **native `mofkactl` (what our project uses)**: topic creation and partition
creation are **two separate commands**; `topic create` does not take a partition count,
you `partition add` one partition at a time and pin each to a **server rank**:

```bash
# from our server/start_server.sh
mofkactl topic create "$MOFKA_TOPIC" --groupfile mofka.json
mofkactl partition add "$MOFKA_TOPIC" --rank 0 --type "$MOFKA_PARTITION_TYPE" --groupfile mofka.json
```

`mofkactl partition add` options (from `python/mochi/mofka/mofkactl/partition.py`):

```
add <name>                     # topic name (positional)
  -r, --rank    INT            # rank of the server in which to add the partition (required)
  -t, --type    STR = default  # partition manager type: default | memory | legacy | <custom>
  -p, --pool    STR = __primary__
  -m, --metadata STR           # metadata provider  (legacy partition manager only)
  -d, --data     STR           # data provider       (legacy partition manager only)
      --abt-io   STR           # ABT-IO instance locator (default partition manager only)
  -g, --groupfile STR = ./mofka.json
```

`mofkactl topic create` options (from `topic.py`): `-v/--validator`, `-p/--partition-selector`,
`-s/--serializer`, `-g/--groupfile` (all default to `"default"`). Note it has **no**
`num_partitions`.

Creating them — **newer `diaspora-ctl`** (current readthedocs). Here topic + partition count
are combined:

```bash
export DIASPORA_CTL_DRIVER_OPTIONS="--driver mofka --driver.group_file /path/to/mofka.json"
diaspora-ctl topic create --name my_topic --topic.num_partitions 1   # in-memory by default
diaspora-ctl topic list
```

Sources: https://diaspora-stream-api.readthedocs.io/en/latest/usage/topics.html ,
https://mofka.readthedocs.io/en/latest/usage/quickstart.html ,
https://github.com/mochi-hpc/mofka/blob/main/python/mochi/mofka/mofkactl/partition.py ,
https://github.com/mochi-hpc/mofka/blob/main/python/mochi/mofka/mofkactl/topic.py

### 1b. Partition types: memory vs default (log/on-disk) vs legacy — tradeoffs & persistence

**Answer.** The Mofka source ships **three** built-in partition managers plus a custom hook
(`partition.py`, and `src/{Memory,Default,Legacy}PartitionManager.*`):

- **`memory`** (`MemoryPartitionManager`): events held **in RAM**. Fastest, lowest overhead,
  no disk dependency. **Not persistent** — data is gone on restart. The quickstart topic is
  in-memory by default. `mofkactl partition add ... --type memory --rank R --pool P`.
- **`default`** (`DefaultPartitionManager`): the **log-based, on-disk** manager. It writes
  append-only **chunk files** under `<path>/<topic>-<uuid>/` using **abt-io**; needs an
  `abt_io` io_controller. Persistent and crash-recoverable. This is the type to use for a
  real I/O / persistence study.
- **`legacy`** (`LegacyPartitionManager`): the older design that stores **metadata in a
  Yokan database** and **data in a Warabi target** (hence `--metadata <yokan_provider>` and
  `--data <warabi_provider>`). Persistence depends on the Yokan/Warabi backend types chosen.

With `diaspora-ctl` the equivalent selection is `--topic.config.type` (`default` shown for
on-disk; memory is the implicit default):

```bash
# persistent on-disk ("default") partition via diaspora-ctl
diaspora-ctl topic create --name my_topic \
     --topic.config.type default \
     --topic.num_partitions 1 \
     --topic.config.partition.path /tmp/mofka \
     --topic.dependencies.io_controller io_controller \
     --topic.dependencies.pool __primary__
```

**Persistence implications / tradeoffs (from the default-partition architecture page):**
- `default` partition durability is controlled by `sync` (default `true` = `fdatasync`
  after every batch, "a server crash loses at most the in-flight batch"; `false` is faster
  but "exposes a wider crash window").
- `memory` has no on-disk state at all → zero durability, minimum overhead.
- `legacy` durability = whatever the Yokan (`map` vs `rocksdb`) and Warabi (`memory` vs a
  disk/pmdk target) backends provide.

Sources: https://github.com/mochi-hpc/mofka/blob/main/python/mochi/mofka/mofkactl/partition.py ,
https://mofka.readthedocs.io/en/latest/usage/architecture.html ,
https://mofka.readthedocs.io/en/latest/usage/advanced.html

### 1c. How the number of partitions affects throughput / parallelism; mapping to servers

**Answer.** With `diaspora-ctl`, `num_partitions` is the **total** number, and the docs
state partitions are "assigned to servers **in a round-robin manner**." With `mofkactl`
you place each partition explicitly on a server via `--rank` (validated against
`service.num_servers`). So partitions are the unit of distribution across servers/ranks.

On the producer side, the default partition selector **round-robins events across
partitions**, spreading load. More partitions across more servers therefore increases the
number of independent append paths and lets more consumers read in parallel.

The architecture "Tuning notes" add a related lever: smaller `max_chunk_size` /
`max_events_per_chunk` "let consumer reads parallelize across more files."

**Docs do not specify** an explicit throughput-vs-partition-count formula, nor do they
quantify the benefit of multiple partitions **co-located on a single server** (on one
server they share the same Argobots pools/RPC threads unless you dedicate pools/xstreams).

Sources: https://mofka.readthedocs.io/en/latest/usage/advanced.html ,
https://diaspora-stream-api.readthedocs.io/en/latest/usage/topics.html ,
https://mofka.readthedocs.io/en/latest/usage/architecture.html

### 1d. How a consumer reads across partitions; ordering guarantees

**Answer.** A `Consumer` "interfaces with a topic to consume events from a designated list
of partitions." A consumer is created from a `TopicHandle` and pulls events with
`consumer.pull()` (non-blocking, returns a `Future`); `event.acknowledge()` records that
all partition events up to that one are processed so a restarted consumer with the **same
name** resumes after the last ack. Consumers "sharing a name shouldn't pull from the same
partition."

**Ordering guarantees (grounded):**
- Event IDs are "monotonically increasing and are **per-partition**, so events in different
  partitions can share an ID." (producer page)
- Within a `default` partition, the architecture page states: "batches are stored in
  submission order — the in-memory index, the on-disk `.idx` records, and the
  consumer-visible event ids all agree."
- Therefore ordering is **per-partition FIFO**; there is **no global cross-partition
  ordering** (that follows directly from per-partition IDs).

**Docs do not specify** (in the pages fetched) the exact API parameter/syntax for
restricting a consumer to a subset of partitions, nor an ordering guarantee across
partitions. In practice FlowCept's consumer (section 6) is created without naming
partitions, i.e. it consumes the topic's partitions with the default targeting.

Sources: https://diaspora-stream-api.readthedocs.io/en/latest/usage/consumer.html ,
https://diaspora-stream-api.readthedocs.io/en/latest/usage/producer.html ,
https://mofka.readthedocs.io/en/latest/usage/architecture.html

---

## 2. Mofka producer tuning (this drives connector overhead)

### 2a. batch_size, AdaptiveBatchSize — good value for many small metadata messages

**Answer.** `batch_size` is "the count of events grouped before sending." Using
`BatchSize::Adaptive()` (C++) / `AdaptiveBatchSize` (Python) / `0` (C API) tells the
producer to "adapt the batch size at run time"; it "will aim to send batches as soon as
possible but will increase the batch size if the server is not responding fast enough."

For **many small metadata messages** the doc-endorsed choice is **Adaptive**: you get
near-immediate sends (low latency) at low rates, and automatic batching (higher throughput)
only when the server pushes back. The docs give **no fixed numeric recommendation**; a
positive integer is only for when you want a fixed grouping. (Our Darshan connector default
`DARSHAN_MOFKA_BATCH=0` maps to Adaptive.)

```python
# diaspora producer page (Python)
from diaspora_stream.api import ThreadPool, AdaptiveBatchSize, Ordering
topic = driver.open_topic("collisions")
thread_pool = driver.make_thread_pool(4)
batch_size = AdaptiveBatchSize            # or an integer > 0
max_num_batches = 2
ordering = Ordering.Strict                # or Ordering.Loose
producer = topic.producer(name="app1", batch_size=batch_size,
    max_num_batches=max_num_batches, thread_pool=thread_pool, ordering=ordering)
```

Source: https://diaspora-stream-api.readthedocs.io/en/latest/usage/producer.html

### 2b. thread_count, ordering, flush — latency vs throughput

**Answer.**
- **Thread pool / `ThreadCount{N}`** (C++) / `make_thread_pool(N)` (Python): "Runs the
  validator, partition selector, and serializer in user-level threads." More threads =
  more client-side parallelism for those steps.
- **`max_num_batches`**: "the maximum number of batches that can be pending on the client
  before `push` calls start blocking." Raising it "may be useful in bursty applications"
  (helps throughput / absorbs bursts; higher memory).
- **Ordering**: `Loose` "permits events targeting the same batch to be reordered based on
  validation timing"; `Strict` "forces events that target the same batch to be added to the
  batch in the same order they were produced." Strict "may limit parallelism opportunities
  and should be used only when needed." -> **`Loose` minimizes latency/maximizes parallelism.**
- **`push`** returns a `Future`; `future.wait(-1)` blocks for the `EventID`. You can drop
  the future if you don't need the ID.
- **`flush()`** "forces all the pending batches of events to be sent, regardless of whether
  they have reached the requested size." It is non-blocking and returns a Future; "useful
  periodically or at shutdown."

**Latency vs throughput summary (per docs):** minimize per-push latency with Adaptive batch
+ `Loose` ordering + `flush()` when you need immediacy; maximize throughput by letting
Adaptive grow batches, raising `max_num_batches` for bursts, and not flushing after every
message.

Source: https://diaspora-stream-api.readthedocs.io/en/latest/usage/producer.html

### 2c. Documented guidance for high-frequency small-message producers

**Answer.** The producer page states outright: "The document does not give explicit
thresholds for small vs. high-frequency messages." The **levers it does endorse** are:
use `Adaptive()` batch sizing (sends quickly, grows only under server backpressure), raise
`max_num_batches` for "bursty applications," and prefer `Loose` ordering for parallelism
unless strict ordering is required. Beyond that, **docs do not specify** numeric tuning for
high-frequency small messages.

Server-side, the architecture "Tuning notes" add that producer buffer pools should have
`first_size` set "close to the typical batch payload size" (small for tiny metadata), and
`sync=false` on a `default` partition trades durability for speed.

Sources: https://diaspora-stream-api.readthedocs.io/en/latest/usage/producer.html ,
https://mofka.readthedocs.io/en/latest/usage/architecture.html

---

## 3. Bedrock server config

### 3a. Structure of a Bedrock JSON config

**Answer.** A Bedrock config has four top-level sections: **`libraries`**, **`margo`**,
**`bedrock`**, and **`providers`** (`bedrock/02_json.html`).
- **`libraries`**: shared objects to load ("tell Bedrock how to instantiate providers for
  various component types").
- **`margo`**: Mercury/Argobots engine config (see 3b).
- **`bedrock`** (optional): Bedrock's own pool + provider_id (`{"pool": "...", "provider_id": 0}`).
- **`providers`**: array; each provider is:

```json
{
    "name" : "<string>",
    "type" : "<string>",          // must match a loaded module name
    "provider_id" : "<int>",      // 0..65534, all distinct (65535 reserved)
    "config" : { },               // component-specific, passed unchanged
    "dependencies" : {            // resolved by Bedrock before creation
        "<key>" : "<name-or-remote-ref>"
    }
}
```

Dependency values can be an Argobots **pool** name, an **xstream** name, a **local provider**
name, or a **remote provider** (`"<name>@<location>"` / `"<type>:<id>@<location>"`, location
`local` or a Mercury address). (`tags` is used by Mofka providers but is not documented on
the JSON page.)

The **Mofka deployment config** (quickstart, verbatim) and what each provider we use does:

```json
{
    "libraries": [
        "libflock-bedrock-module.so",
        "libyokan-bedrock-module.so",
        "libwarabi-bedrock-module.so",
        "libabt-io-bedrock-module.so",
        "libmofka-bedrock-module.so"
    ],
    "providers": [
        {
            "name" : "group_manager", "type" : "flock", "provider_id" : 1,
            "config": { "bootstrap": "self", "file": "mofka.json",
                        "group": { "type": "static" } }
        },
        {
            "name": "master_database", "provider_id": 2, "type": "yokan",
            "tags" : [ "mofka:master" ],
            "config" : { "database" : { "type": "map" } }
        },
        {
            "name" : "io_controller", "type" : "abt_io", "provider_id" : 3,
            "config" : {}, "dependencies": { "pool": "__primary__" }
        }
    ]
}
```

Provider roles for the ones we use:
- **flock (group manager)**: forms/advertises the server group and writes the **group file**
  (`mofka.json`) that clients use to connect. `bootstrap` = how the group is formed (see 3c);
  `group.type` = membership backend (`static`, `centralized`, `swim`).
- **yokan (master db)**: key-value store holding Mofka's **topic/partition metadata**
  ("master" tag `mofka:master`). `database.type` = `map` (in-memory) or `rocksdb` (persistent),
  etc. In a **legacy** partition it also stores per-event **metadata**.
- **warabi (data store)**: Mochi data/blob store (`target.type` = `memory`, or a disk target).
  In current Mofka it is the **data backend of the *legacy* partition manager** (tag
  `mofka:data`). The `default` partition manager does **not** use Warabi — it writes chunk
  files itself via abt-io. (The quickstart notes: if Mofka was built `~legacy`, drop
  `libwarabi-bedrock-module.so`; the "Full configuration" in advanced omits Warabi entirely.)
- **abt-io**: async I/O provider (thread- or io_uring-based) used by the **`default`** on-disk
  partition manager for reads/writes.
- **mofka**: the `libmofka-bedrock-module.so` that registers the streaming service itself.

Deploy / shut down:

```bash
bedrock na+sm -c config.json        # creates mofka.json (client group file)
bedrock-shutdown na+sm -f mofka.json
```

Sources: https://mochi.readthedocs.io/en/latest/bedrock/02_json.html ,
https://mofka.readthedocs.io/en/latest/usage/quickstart.html ,
https://mofka.readthedocs.io/en/latest/usage/advanced.html

### 3b. margo use_progress_thread / rpc_thread_count

**Answer.** By default all providers, the Mercury progress loop, and RPC handlers share the
`__primary__` execution stream, so **RPCs serialize**. Add shortcut fields to `margo`:

```json
"margo": {
    "use_progress_thread": true,
    "rpc_thread_count": 4
}
```

- `use_progress_thread` "moves Mercury's progress loop to its own dedicated execution stream."
- `rpc_thread_count` "creates an `__rpc__` pool and N execution streams pulling from it";
  with four ES, up to four RPCs run concurrently.
- The docs note a non-zero `rpc_thread_count` already separates progress from RPC-servicing
  streams, so setting `use_progress_thread` is not strictly required; and that for finer
  control you use the long-form `argobots.pools` / `argobots.xstreams` arrays. (When running
  multiple Margo engines in one process, child engines "**must not**" set `argobots`,
  `rpc_thread_count`, or `use_progress_thread` — pools/xstreams are inherited from engine 0.)

Sources: https://mofka.readthedocs.io/en/latest/usage/advanced.html ,
https://mochi.readthedocs.io/en/latest/bedrock/09_multi_margo.html

### 3c. Running a MULTI-NODE Mofka service (one group across bedrock processes)

**Answer (from mofka advanced "Running multiple processes").** Two changes distribute
Mofka across processes/machines:

1. **flock bootstrap `self` -> `mpi`.** With `self`, "each process forms its own single-member
   group"; `mpi` "lets them form one group."
2. **A single master database.** Add an `"__if__"` condition so only rank 0 owns the master
   Yokan DB (the condition is evaluated at bootstrap; if false the object is disabled):

```json
{
   "__if__": "$MPI_COMM_WORLD.rank == 0",
   "name": "master",
   "provider_id": 2,
   "type": "yokan",
   "tags" : [ "mofka:master" ],
   "config" : { "database" : { "type": "rocksdb",
                "config": { "create_if_missing": true, "path": "/tmp/mofka/master" } } }
}
```

Also switch the transport: `na+sm` is shared-memory (single machine only); for clusters use
`tcp`, `verbs`, `cxi`, etc. (use `margo-info` to list available protocols).

**flock bootstrap modes (from the flock tutorials):**
- **`self`** — "Creates a single-member group with just the current process." Use for a
  single process, testing/prototyping, or when you will add members dynamically later.
- **`mpi`** — "Uses MPI to bootstrap a group from all MPI processes." Launch under
  `mpirun -n N bedrock ...` and "all ranks will automatically form a group." Mechanism: each
  rank gets its Margo address, an `MPI_Allgather` exchanges addresses, every rank builds an
  identical group view. **All ranks must call bootstrap simultaneously or the collective
  hangs.** Requires flock built with `+mpi`. You can restrict membership with a provider-config
  field `"mpi_ranks": [0, 1, 2, 3]` (Bedrock-only; uses `MPI_COMM_WORLD`).
- **`join`** — "Joins an existing group by contacting a member." A new process loads a view
  (e.g. from the group file), registers a provider with `"bootstrap": "join"`, contacts
  existing members and is added; all members get an updated view. Requires a **dynamic**
  backend (`group.type` must support dynamic membership, e.g. `centralized`, **not** `static`).
- (`view` and `file` also exist: initialize from a provided view / load membership from a file.)

flock `mpi` Bedrock provider config (flock example `04_bootstrap_mpi`):

```json
{
    "libraries": ["libflock-bedrock-module.so"],
    "providers": [{
        "type": "flock", "name": "my_flock_provider", "provider_id": 42,
        "config": {
            "bootstrap": "mpi",
            "group": { "type": "static", "config": {} },
            "file": "mygroup.flock"
        }
    }]
}
```

flock `join` Bedrock provider config (flock example `05_bootstrap_join`):

```json
{
    "libraries": ["libflock-bedrock-module.so"],
    "providers": [{
        "type": "flock", "name": "my_flock_provider", "provider_id": 42,
        "config": {
            "bootstrap": "join",
            "file": "mygroup.flock",
            "group": { "type": "centralized", "config": {} }
        }
    }]
}
```

Sources: https://mofka.readthedocs.io/en/latest/usage/advanced.html ,
https://github.com/mochi-hpc/mochi-flock/blob/main/docs/source/flock/01_intro.rst ,
https://github.com/mochi-hpc/mochi-flock/blob/main/docs/source/flock/02_bootstrap_self.rst ,
https://github.com/mochi-hpc/mochi-flock/blob/main/docs/source/flock/04_bootstrap_mpi.rst ,
https://github.com/mochi-hpc/mochi-flock/blob/main/docs/source/flock/05_bootstrap_join.rst

### 3d. How adding servers/partitions changes client setup (group file)

**Answer.** Clients do not hard-code server addresses; they read the **flock group file**
(the `file` field of the flock provider, e.g. `mofka.json` / `mygroup.flock`). This file is
produced by the flock provider and, per the quickstart, "contains the server address among
other things." When you add servers via the `mpi` bootstrap the same group file lists all
members, so **the client side is unchanged**: point the driver at the one group file.

- Native: `MofkaDriver(group_file="mofka.json")` (see FlowCept DAO, section 6).
- diaspora-ctl: `export DIASPORA_CTL_DRIVER_OPTIONS="--driver mofka --driver.group_file /path/to/mofka.json"`.
- Our Darshan connector: `DARSHAN_MOFKA_GROUP_FILE=<mofka.json>` (passed as
  `{"group_file": "..."}` to `diaspora_driver_create("mofka", ...)`).

Adding **partitions** is a service-side operation (`mofkactl partition add --rank i` per
server, or `diaspora-ctl --topic.num_partitions N` round-robin); it does not change how the
client connects, only how many partitions the producer's selector and consumers see.

Sources: https://mofka.readthedocs.io/en/latest/usage/quickstart.html ,
https://mofka.readthedocs.io/en/latest/usage/advanced.html ,
https://github.com/mochi-hpc/mochi-flock/blob/main/docs/source/flock/01_intro.rst

---

## 4. MPI support

**Answer.** Yes. MPI support is a **flock (group-manager) feature**, enabling a **multi-node
broker** (one Mofka group spanning many bedrock processes):

- Enabled by building flock with MPI: `spack install mochi-flock +mpi +bedrock` (and Mofka's
  advanced page assumes this when it flips `"bootstrap": "self"` -> `"bootstrap": "mpi"`).
- Benefit: "all ranks will automatically form a group with each other," so launching
  `mpirun -n N bedrock -c config.json` gives an N-member Mofka service with one shared group
  file. Membership can be narrowed with `"mpi_ranks": [...]` (Bedrock-only). The mechanism is
  an `MPI_Allgather` of Margo addresses; all ranks must bootstrap simultaneously.
- Bedrock itself "can be run alone or as a parallel application" (bedrock overview). Note:
  the Bedrock *multi-margo* page is about multiple **engines in one process**, not MPI
  multi-process; **docs do not** provide an `mpiexec` recipe on that page — the MPI recipe
  lives in the flock tutorials and the Mofka advanced page.

Sources: https://github.com/mochi-hpc/mochi-flock/blob/main/docs/source/flock/04_bootstrap_mpi.rst ,
https://github.com/mochi-hpc/mochi-flock/blob/main/docs/source/flock/01_intro.rst ,
https://mofka.readthedocs.io/en/latest/usage/advanced.html ,
https://mochi.readthedocs.io/en/latest/bedrock/09_multi_margo.html

---

## 5. Diaspora Stream API (the C binding the Darshan connector uses)

**Answer — relationship to Mofka.** The Diaspora Stream API "provides ... an API for
implementing streaming frameworks for HPC applications." Mofka is **one backend/driver**
implementation of it ("a streaming framework based on Mochi"); the API also has Kafka, Files,
and Octopus drivers. The Mofka driver "is an event-driven service for HPC based on the Mochi
suite ... relies on RPC and RDMA using the Mercury library and on user-level threads thanks
to Argobots." Our Darshan connector uses the **C binding**: `diaspora_driver_create("mofka",
{"group_file": ...})`, `diaspora_topic_open`, `diaspora_producer_create(...)`.

**Producer options exposed** (producer page; mirrored in the C binding our connector calls):
- **name** (reserved; multi-process apps should share it),
- **thread pool** (`ThreadCount{N}` / `make_thread_pool(N)`),
- **batch_size** — integer, or **Adaptive** (`0` in the C binding),
- **max_num_batches** — "maximum number of batches that can be pending on the client before
  `push` calls start blocking",
- **ordering** — `Loose` / `Strict`,
- **flush** — `producer.flush()` "forces all the pending batches of events to be sent,
  regardless of whether they have reached the requested size" (non-blocking, returns a Future).

Our connector (`darshan/darshan-runtime/lib/darshan-mofka.c`) reads
`DARSHAN_MOFKA_BATCH` (default `0` = adaptive) and `DARSHAN_MOFKA_MAX_BATCHES` (default `0`)
and calls `diaspora_producer_create(topic, name, batch_size, max_batches,
DIASPORA_C_ORDERING_LOOSE)` — i.e. Adaptive batch + Loose ordering, matching the doc guidance
for small high-frequency messages.

**Docs do not specify** the exact C-binding function signatures on the readthedocs pages
(the Mofka driver page just points to Mofka's README); the option **semantics** above are
from the (language-agnostic) producer page.

Sources: https://github.com/diaspora-project/diaspora-stream-api ,
https://diaspora-stream-api.readthedocs.io/en/latest/usage/producer.html ,
https://diaspora-stream-api.readthedocs.io/en/latest/usage/drivers.html

---

## 6. FlowCept Mofka consumer

**Answer — how FlowCept subscribes.** FlowCept selects a message queue via its settings /
env. The MQ block (from `resources/sample_settings.yaml`) is:

```yaml
mq:
  enabled: false
  type: redis  # or kafka, mofka, rabbitmq; ... If mofka, also set group_file.
  host: localhost
  # group_file: mofka.json
  channel: interception
  buffer_size: 50
  insertion_buffer_time_secs: 5
```

Relevant keys: **`mq.type: mofka`**, **`mq.channel`** (the Mofka **topic** name; default
`interception`), and **`mq.group_file`** (path to the flock group file, `mofka.json`).
Env-var equivalents: `MQ_TYPE`, `MQ_CHANNEL`, and the group file is read from the settings
`group_file` key. (Setup page + sample settings.)

**How the consumer is created** (`src/flowcept/commons/daos/mq_dao/mq_dao_mofka.py`):

```python
import mochi.mofka.client as mofka
from mochi.mofka.client import AdaptiveBatchSize, ThreadPool

_driver = mofka.MofkaDriver(group_file=MQ_SETTINGS.get("group_file", None))
_topic  = _driver.open_topic(MQ_SETTINGS["channel"])

def subscribe(self):
    self.consumer = MQDaoMofka._topic.consumer(
        name=MQ_CHANNEL + str(uuid.uuid4()),
        thread_pool=ThreadPool(0),
        batch_size=AdaptiveBatchSize)

def message_listener(self, message_handler):
    while True:
        event = self.consumer.pull().wait()
        message = event.metadata
        if not message_handler(message):
            break
```

Notes grounded in that code:
- FlowCept uses the **native `mochi.mofka.client`** (pymofka), not the diaspora Python
  package. Driver = `MofkaDriver(group_file=...)`; topic = `open_topic(channel)`.
- Consumer uses a **unique name per instance** (`channel + uuid4`), **`ThreadPool(0)`**
  (Python GIL — the consumer page says the default pool must be used for consuming data),
  and **Adaptive** batch size. It reads `event.metadata` and loops on `pull().wait()`.
- Its **producer** side uses `AdaptiveBatchSize`, `ThreadPool(1)`, `Ordering.Strict`, and
  flushes after each publish batch.

**Consuming multiple partitions:** the consumer is created **without naming target
partitions**, so it consumes the topic (default partition targeting). **Docs do not specify**
FlowCept-side handling for multiple partitions beyond what the underlying Mofka consumer
provides; ordering is per-partition (see 1d).

Sources: https://flowcept.readthedocs.io/en/latest/setup.html ,
https://github.com/ORNL/flowcept/blob/main/resources/sample_settings.yaml ,
https://github.com/ORNL/flowcept/blob/main/src/flowcept/commons/daos/mq_dao/mq_dao_mofka.py

---

## Alignment check for our current config

Our `server/bedrock-config.json`: single bedrock, `flock bootstrap=self` + `group.type=static`,
`yokan type=map` (master), `warabi type=memory` (data_store, tagged `mofka:data`),
`margo.use_progress_thread=true` + `rpc_thread_count=4`; one partition `type=memory`;
producer `DARSHAN_MOFKA_BATCH=0` (adaptive), Loose ordering.

| Setting | Verdict vs docs |
|---|---|
| **flock bootstrap = self** | **Aligned** for single-node/demo. Docs list `self` for "single process ... testing or prototyping." For multi-node, switch to `mpi`. |
| **flock group.type = static** | **Aligned** for fixed single-node membership. For `join`/elastic scaling you'd need `centralized`. |
| **yokan master type = map** | **Aligned** with the quickstart config (which uses `map`). Caveat: `map` is in-memory, so **topic/partition metadata is lost on restart**; use `rocksdb` if you need persistence (advanced page). |
| **warabi type = memory (data_store)** | **Vestigial for our setup.** Warabi is the data backend of the **legacy** partition manager only; a **memory** partition does not use it. Harmless but unused. Remove it, or switch to a `legacy`/`default` partition if you actually want it exercised. |
| **partition type = memory** | **Aligned** for a low-overhead single-node demo (RAM-only, fastest for small messages), but **not persistent**. For a persistence / real-I/O study switch to `default` (on-disk, abt-io) partitions. |
| **1 partition** | **Fine** for single node. For multi-node throughput scaling, add partitions round-robin across ranks. |
| **margo use_progress_thread + rpc_thread_count=4** | **Aligned** with the advanced page's multithreading guidance (avoids serializing RPCs on `__primary__`). |
| **producer BATCH=0 (Adaptive) + Loose ordering** | **Aligned / recommended** for many small metadata messages (Adaptive = send ASAP, batch under backpressure; Loose = max parallelism). |

**Bottom line:** the setup is well aligned with the docs for a **single-node, low-overhead
demo**. The only cleanup is the unused `warabi` (`mofka:data`) provider (only needed for a
`legacy` partition). For the **multi-node study** and/or **persistence**, the doc-directed
changes are: flock `self -> mpi` (+ `__if__` rank-0 master + non-`na+sm` transport), Yokan
master `map -> rocksdb`, and partitions `memory -> default` spread across ranks.

---

## Sources

- https://mofka.readthedocs.io/en/latest/
- https://mofka.readthedocs.io/en/latest/usage/installation.html
- https://mofka.readthedocs.io/en/latest/usage/quickstart.html
- https://mofka.readthedocs.io/en/latest/usage/advanced.html
- https://mofka.readthedocs.io/en/latest/usage/architecture.html
- https://diaspora-stream-api.readthedocs.io/en/latest/
- https://diaspora-stream-api.readthedocs.io/en/latest/usage/topics.html
- https://diaspora-stream-api.readthedocs.io/en/latest/usage/producer.html
- https://diaspora-stream-api.readthedocs.io/en/latest/usage/consumer.html
- https://diaspora-stream-api.readthedocs.io/en/latest/usage/drivers.html
- https://github.com/diaspora-project/diaspora-stream-api
- https://mochi.readthedocs.io/en/latest/bedrock.html
- https://mochi.readthedocs.io/en/latest/bedrock/02_json.html
- https://mochi.readthedocs.io/en/latest/bedrock/09_multi_margo.html
- https://github.com/mochi-hpc/mofka
- https://github.com/mochi-hpc/mofka/blob/main/python/mochi/mofka/mofkactl/partition.py
- https://github.com/mochi-hpc/mofka/blob/main/python/mochi/mofka/mofkactl/topic.py
- https://github.com/mochi-hpc/mochi-flock
- https://github.com/mochi-hpc/mochi-flock/blob/main/docs/source/flock/01_intro.rst
- https://github.com/mochi-hpc/mochi-flock/blob/main/docs/source/flock/02_bootstrap_self.rst
- https://github.com/mochi-hpc/mochi-flock/blob/main/docs/source/flock/04_bootstrap_mpi.rst
- https://github.com/mochi-hpc/mochi-flock/blob/main/docs/source/flock/05_bootstrap_join.rst
- https://github.com/mochi-hpc/mochi-flock/blob/main/docs/source/flock/12_bedrock.rst
- https://flowcept.readthedocs.io/en/latest/setup.html
- https://github.com/ORNL/flowcept/blob/main/resources/sample_settings.yaml
- https://github.com/ORNL/flowcept/blob/main/src/flowcept/commons/daos/mq_dao/mq_dao_mofka.py
