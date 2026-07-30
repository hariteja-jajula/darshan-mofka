# DECISION LOG — cross-node ofi+cxi Darshan→Mofka→FlowCept wiring

Append-only. Every probe verdict and file landing goes here so a fresh session
resumes from this file alone. Orchestrator writes; subagents report diffs.

---

## The winning recipe (VERBATIM — job 7301370, `MPMD_NOPMI_RESULT`)

Cross-node `ofi+cxi` (workload on N1, broker on N0) **works** with two levers,
both required. Prior failures were 3 separate `mpiexec` launches → 3
non-routable VNIs. Fix = ONE MPMD launch + PMI-strip.

**Lever 1 — single MPMD `mpiexec`** (all CXI roles as `:`-separated sections in
one launch → PALS gives the whole launch ONE shared job VNI):
```
mpiexec --cpu-bind none \
  --hosts $N0 -n 1 s0.sh : \
  --hosts $N1 -n 1 s1.sh
```
Sections use `--hosts <comma-list> -n <count>`. Per-section `--hostfile`/`--ppn`
is KNOWN-INVALID (printed mpiexec help and died in an earlier probe). No
`--single-node-vni` (red herring; VNI strategy made zero difference).

**Lever 2 — PMI-strip before exec** (PALS injects `PMI_RANK/PMI_SIZE=2/PALS_*`
into every section; non-MPI bedrock hangs on a phantom PMI collective — 0-byte
log over BOTH tcp and cxi, so NOT a fabric problem). Inside each section, before
exec, KEEP `SLINGSHOT_*` (carries the VNI):
```
for v in $(compgen -v | grep -E "^(PMI_|PMIX_|PALS_)"); do unset "$v"; done
```

**cxi collapse-to-first** (margo multi-VNI bug on Polaris's 2 VNIs):
```
export SLINGSHOT_VNIS=${SLINGSHOT_VNIS%%,*} \
       SLINGSHOT_SVC_IDS=${SLINGSHOT_SVC_IDS%%,*} \
       SLINGSHOT_DEVICES=${SLINGSHOT_DEVICES%%,*}
```

**exec bedrock DIRECTLY** (don't background — grandchild backgrounding gave empty
logs), with `</dev/null`. Broker writes `mofka.json` to shared Eagle FS; other
sections poll for it (all sections start simultaneously → file-flag barrier
replaces sequential staging).

**Proof:** broker up at `ofi+cxi://0x0043d400` on N0; N1 client `RC topic=0
part=0`. Both `tcp_nopmi` and `cxi_nopmi` PASS. `mpmd exit=124` is the `timeout`
killing the still-running broker — **exit code means nothing; verdicts come from
flag/rc files only** (amendment #6).

---

## GATE 0 (2026-07-30)

- **git checkpoint:** committed `d846cb8` on branch `polaris_clean` — pre-rewire
  restore point (helpers, io_bench.c, capture_flowcept.sh edits, all probes).
- **grep workload C for MPI_Init:** `workloads/c/mofka_forward_smoke.c` (workload
  C) and `workloads/c/io_bench.c` are **NON-MPI** (POSIX only). The ONLY MPI
  workload is `workloads/mpi/mofka_forward_mpiio.c`. ⇒ The PMI/MPI tension does
  **not** block the first-green path (C → io_bench); it only bites if we later
  stream the MPI workload cross-node.
- **`mpiexec --help`:** `--hosts` (comma-list), `--hostfile`, `--ppn`, `:` all
  valid; command_options are per-section. Pipeline uses the proven `--hosts
  <list> -n <count>` form throughout — no per-section `--hostfile`/`--ppn`.
- **stripped-bedrock : 2-rank-MPI-hello probe (job 7301416, `GATE0_MPI_RESULT`):**
  - A (control, plain cross-node 2-rank MPI hello): **PASS** — `size=2`, toolchain OK.
  - B (bedrock N0 -n1 STRIPPED : mpi_hello N1 -n2 unstripped): **HANG** — hello came
    up `PMI_RANK=1,2 PMI_SIZE=3` (shared 3-rank PMI world; broker=rank0), then
    `MPI_Init` blocked forever (timeout 124, `B_ok` never written). Root cause: MPI
    ranks do a PMI fence across the whole world, and the stripped broker rank never
    participates. **⇒ the MPI-IO workload cannot stream over MPMD+strip as-is.**
  - **Consequence:** first-green path (C, io_bench — both non-MPI) is UNAFFECTED and
    proceeds. The MPI-IO workload is the only thing this blocks. FORK presented to
    Hari (option a babysitter+comm-split vs option b non-MPI-only). See below.
  - **FORK RESOLVED (Hari, 2026-07-30): option (b) NON-MPI ONLY.** CXI stream path
    carries C + io_bench (non-MPI POSIX). The MPI-IO workload is NOT streamed over
    CXI; it keeps running via the retained old/TCP path as the comparison baseline
    (amendment #4). `run_mpmd_rep` errors out (→`WL_FAIL`) if handed `WL_TYPE=mpi`.
    Babysitter+comm-split deferred indefinitely unless revisited.

- **3-section MPMD probe (job 7301419, `MPMD_3SEC_RESULT`):** broker up
  `ofi+cxi://0x0003be00` (N0); same-node consumer attached `RC topic=0 part=0`;
  **cross-node workload section on N1: `mofkactl topic create` returned rc=0** — a
  real N1→N0 RPC over the shared job VNI. **⇒ the 3-role shape WORKS cross-node.**
  The probe's own VERDICT printed FAIL only because it also ran `mofkactl topic
  list`, and this mofkactl build has no `list` subcommand (rc=2). Probe-logic bug,
  not a pipeline failure. Treated as PASS; a corrected check folds into the e2e test.

### PMI-strip rule (from Gate 0)
- strip PMI on **broker + consumer sections ONLY** — they are non-MPI.
- **NEVER strip the workload section IF it is the MPI workload** (would make each
  rank an MPI singleton → wrong-nprocs Darshan logs).
- The non-MPI workloads (C, io_bench) may be stripped safely (no MPI world).

---

## MPMD pipeline contract (orchestrator-owned; subagents implement against this)

**`run_mpmd_rep <RES>`** (new, `lib/run.sh`) runs ONE rep as a single MPMD
`mpiexec` and leaves `$RES/events.jsonl` for the existing reconstruct+compare in
`job.sh` (:196-230, UNCHANGED). It renders bedrock, generates 3 section scripts,
launches backgrounded, polls flags, tears down. `job.sh` per-rep loop calls it in
place of the `start_consumer`/`run_workload_once`/`stop_consumer_verdict` trio.

**Coordination dir:** `COORD=$RES/coord` on Eagle FS. Section scripts in
`$RES/sections`. Rendered broker cfg `$COORD/bedrock-config.json`.

**Three sections (one launch, shared VNI), via `mpi_launch_mpmd`:**
| # | host(s)        | ranks       | script         | strip? | collapse? |
|---|----------------|-------------|----------------|--------|-----------|
| broker   | N0        | 1           | s_broker.sh    | YES    | YES (cxi) |
| consumer | N0        | `$CONS_N`   | s_consumer.sh  | YES    | YES (cxi) |
| workload | N1..Nk    | `WL_TOTAL`  | s_workload.sh  | non-MPI only | YES (cxi) |

**Flag sequence (files in `$COORD`):**
1. `s_broker`: `cd $COORD; rm -f mofka.json`; strip; collapse; source env; `exec
   bedrock $SRV_PROTOCOL -c $COORD/bedrock-config.json -v info >broker.log 2>&1
   </dev/null`. Writes `mofka.json`. Runs until killed. On no-mofka: nothing to do
   (consumer/workload time out → FAIL flags).
2. `s_consumer` (each rank): capture `PALS_RANKID` (log only, amendment #5); strip;
   collapse; source env. Derive `SHARD_ID` by atomic claim:
   `for i in 0..CONS_N-1: mkdir $COORD/claim_$i && SHARD_ID=$i && break`. Poll
   `$COORD/mofka.json` (`MOFKA_GROUP_WAIT_S`). **SHARD 0 = lead:** `mofkactl topic
   create` + `broker_topic_partitions $COORD/mofka.json` (reuse). Then run
   `capture_flowcept.sh` in FG with: `FC_ROLE=lead|follower`, `FLAGDIR=$COORD`
   (→touches `CONSUMER_READY`), `MOFKA_GROUP=$COORD/mofka.json`,
   `MOFKA_TARGETS=$(_shard_targets SHARD_ID CONS_N SRV_PARTITIONS)`,
   `SHUTDOWN_FLAG=$COORD/SHUTDOWN`, `EXPORT_ON_STOP=1` (lead only),
   `EXPORT_OUT=$RES/events.jsonl`, `ALL_DONE_FLAG=$COORD/ALL_DONE` (lead only),
   `RUN_DIR=$RES/fc/c$SHARD_ID`, plus MONGO_*/TOPIC/buffer knobs (mirror
   `_launch_consumer` :311). A background watcher touches `$COORD/SHUTDOWN` once
   all workload ranks are done (sees `WL_DONE.*` count == `WL_TOTAL`).
3. `s_workload` (each rank): capture `PALS_RANKID`; if non-MPI: strip; collapse;
   source `env/workload.sh`. Poll `$COORD/CONSUMER_READY`. Per-rank scratch
   `/tmp/dm_..._$PALS_RANKID`. Run workload under `DARSHAN_LOGPATH=$RES`,
   `LD_PRELOAD=$(darshan_lib)`, `${CONNECTOR_ENV[@]}` (from `connector_env
   $COORD/mofka.json`), `${DARSHAN_ENV[@]}`, `${WORKLOAD_ENV[@]}`. On exit touch
   `$COORD/WL_DONE.$PALS_RANKID`. **MPI workload: not supported in this path yet —
   error out pointing here (Gate-0 pending); MPI still runs via the old/TCP path.**

**Teardown (inside `run_mpmd_rep`):** background the `mpiexec`; poll for
`$COORD/ALL_DONE` (success) OR any `$COORD/*_FAIL` OR mpiexec pid death OR a
walltime ceiling; then `kill` the mpiexec + `pkill -f "bedrock $SRV_PROTOCOL"`.
**mpiexec exit code is meaningless** (we kill it) — success = `ALL_DONE` present
AND `$RES/events.jsonl` non-empty (amendment #6).

**Reuse (do NOT duplicate):** `render_bedrock_config`, `broker_topic_partitions`,
`connector_env`, `darshan_env`, `workload_env`, `_shard_targets`, `pmi_strip`,
`cxi_collapse`, `mpi_launch_mpmd`. **Keep** `start_broker`/`start_consumer`/
`run_workload_once`/`stop_consumer_verdict` (old/TCP path, amendment #4).

---

## FILE LANDING (2026-07-30)

- **`workloads/job.sh` — DONE (orchestrator, task #7).** 5 edits, `bash -n` clean:
  1. `RUN_MODE` selector (:33) — `cxi → mpmd`, else `legacy`; env-overridable.
  2. MPI-in-mpmd guard (:36) — `die` if `WL_TYPE=mpi && RUN_MODE=mpmd` (Gate-0).
  3. broker §5 gated to `legacy` only (:119) — mpmd launches broker per-rep in
     `run_mpmd_rep`; mpmd trap just `pkill bedrock`.
  4. `io_bench` registered in the compile switch (:133) AND the legacy
     `run_workload_once` cmd switch (:157).
  5. per-rep loop (:200): `RUN_MODE=mpmd → run_mpmd_rep "$RES"`; else the legacy
     `start_consumer`/`run_workload_once`/`stop_consumer_verdict` trio (unchanged).
     reconstruct+strict_compare+HTML tail (:205-240) UNTOUCHED — consumes
     `$RES/events.jsonl` from either path.
  **Caller contract locked:** `run_mpmd_rep "$RES"`; must return 0 and leave a
  populated `$RES/events.jsonl` (+ `$RES/ingest.txt` with an INGEST line, nice to
  have). `lib/run.sh run_mpmd_rep` being written by subagent to match.

- **`run_artifacts/submit_cxi.sh` — DONE (orchestrator).** The ONE edit-and-submit
  file. Knobs at top (NODES/TASKS/WORKLOAD/REPS/EVENTS/PARTITIONS/CONSUMERS/QUEUE/
  WALLTIME + IO_* profile). Forces `MOFKA_PROTOCOL=ofi+cxi` (→ job.sh RUN_MODE=mpmd),
  builds `select=$NODES:...` so nodes has ONE source of truth, qsubs job.sh. `bash -n`
  clean. io_bench knob names verified against io_bench.c.

- **`lib/run.sh run_mpmd_rep` — IN PROGRESS (subagent).** Review diff vs the
  contract above when it lands; then 2-node e2e (task #9).

### KNOWN GAP (fix AFTER subagent lands — don't edit lib/run.sh concurrently)
- **`workload_env()` has no `io_bench` case** (lib/run.sh:218 `*) WORKLOAD_ENV=()`).
  In mpmd mode the workload section only inherits the serialized WORKLOAD_ENV array,
  so submit_cxi.sh's `IO_SIZE_MB/IO_ITERS/IO_SLEEP_MS/IO_BLOCK_KB` knobs do NOT reach
  io_bench on the workload node — it runs with its built-in defaults (moderate, fine
  for first-green). FIX: add `io_bench) WORKLOAD_ENV=(IO_SIZE_MB=... IO_ITERS=...
  IO_SLEEP_MS=... IO_BLOCK_KB=...)` forwarding the env if set. Also add io_bench to
  the DARSHAN_ENABLE_NONMPI guard's allow-list (it's non-MPI → nonmpi=1 is correct;
  the existing guard `[ "$WL_TYPE" != mpi ] && [ "$WL_TYPE" != dlio ]` already lets
  io_bench through, so nonmpi=1 — verify, no change likely needed).
