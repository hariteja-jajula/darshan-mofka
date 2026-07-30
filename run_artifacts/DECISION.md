# DECISION LOG — cross-node ofi+cxi Darshan→Mofka→FlowCept wiring

Append-only. Every probe verdict and file landing goes here so a fresh session
resumes from this file alone. Orchestrator writes; subagents report diffs.

---

## MORNING SUMMARY (live — updated as phases complete; 2026-07-30 overnight)

**Single next action:** DONE — validation ladder complete + cleanup complete + behavior-unchanged
re-verify GREEN. Nothing pending. CLEANUP committed e5a16d3 (resolve-once DARSHAN_LIB_SO, dropped
4 dead CFG_* knobs, trimmed provenance comment tails across 4 files keeping all mechanism, README
cxi command-reference); DECISION update 6edce04. Post-cleanup C 1+1 re-verify (job 7301881) GREEN,
BIT-IDENTICAL to pre-cleanup baseline 7301622: ofi+cxi, verdict=all_done, events.jsonl=22,
1 pid reconstructed/0 failed, strict_compare PASS (perproc). Cleanup did NOT change behavior.
✅ VALIDATION LADDER COMPLETE over ofi+cxi: C 1+1 (7301622), io_bench 1+1 (7301654),
5-node 16-rank/4-host (7301662), multi-rep REPS=3 (7301837, RUN2/3/4 all PASS). CONSUMERS>1
dropped (Hari). CXI only, no TCP. 10-agent independent fidelity audit → CONTINUE, 0 critical
(all false-green risks LATENT/untriggered; heatmap-read lossy but documented exclusion).

**Mechanism:** cross-node ofi+cxi PROVEN (jobs 7301370/7301419). Implementation = `run_mpmd_rep`.
**CXI ONLY — no TCP fallback counts as done.** Overnight rules: [[bx-overnight-cxi-rules]] / see foot.

| Phase | State | Job id | Evidence |
|-------|-------|--------|----------|
| run_mpmd_rep written + syntax-clean | ✅ done | — | bash -n clean; 3 sections render+`bash -n` OK |
| run_mpmd_rep review | ✅ done (self) | — | 6-way wf stopped (API-degraded: retry 2-4, 300k+ tok, 0/6 @17m); self-review vs proven probe — see note |
| 2-node e2e workload C (1+1) | ✅ GREEN | 7301622 | RUN6: proto=ofi+cxi://0x00003600, ALL_DONE, events=22, INGEST PASS (POSIX10/STDIO11), strict_compare **PASS (perproc)** |
| io_bench (1+1) | ✅ GREEN | 7301654 | RUN1: proto=ofi+cxi://0x00005c00, ALL_DONE, events=598, INGEST PASS, strict_compare **PASS (perproc)** |
| 5-node scale (1+4, TASKS>1) | ✅ GREEN | 7301662 | RUN1: proto=ofi+cxi://0x00031a00, ALL_DONE, 16 WL_DONE, 16/16 native+recon logs, strict_compare **PASS (perproc)**, INGEST PASS 9568 docs, **4 distinct WL hosts** + broker on 5th |
| multi-rep (REPS>1) | ✅ GREEN | 7301837 | RUN2/3/4 each: ofi+cxi, ALL_DONE, 598 docs, INGEST PASS, strict_compare **PASS (perproc)**; per-rep RUN-dir isolation confirmed |
| 10-agent fidelity+bug audit | ✅ CONTINUE | wf_62d3e7d7 | 0 critical; independent pydarshan re-diffs (io_bench 1118 cells / 5-node 16800 cells, 0 mismatch, bytes exact); B4 pid-collision latent+fail-safe; 5 major all LATENT/untriggered; M5 heatmap-read lossy but documented HEATMAP exclusion (writes bit-exact) |
| ~~CONSUMERS>1~~ | ❌ DROPPED | — | Hari 2026-07-30: not needed for deliverable; stop ladder after multi-rep |
| **Cleanup** | ✅ done (commit e5a16d3) | — | resolve-once DARSHAN_LIB_SO; -4 dead CFG_* knobs; comment tails trimmed (mechanism kept); README cxi cmd-ref; bash -n + py_compile clean |
| Cleanup re-verify (C 1+1) | ✅ GREEN | 7301881 | ofi+cxi://0x00005400, verdict=all_done, events.jsonl=22, 1 pid reconstructed/0 failed, strict_compare **PASS (perproc)** — bit-identical to pre-cleanup baseline 7301622. Behavior unchanged. |

**SCOPE CHANGE (Hari 2026-07-30, night):** Drop CONSUMERS>1. Validation ends at multi-rep.
Then CLEANUP is the priority deliverable work: (1) **resolve-once** — `darshan_lib` called 5x
(job.sh:43,44,61,152; run.sh:402) + runtime `find`/`command -v` hunts (mongod, mpicc, *.darshan);
resolve each binary/path ONCE into a var, pass it everywhere ("find it once, give the
location directly, less number of operations"). (2) **minimal comments** — strip historical-rationale
blocks (rationale lives in git + this file). (3) **fewer files**, (4) **straightforward commands**.
Cleanup must NOT change behavior; re-verify with a C 1+1 after.

**CLEANUP GOTCHAS (agent-cross-checked 2026-07-30, 2 independent subagents — do NOT skip):**
- `darshan_lib` (defined env/workload.sh:47-58) is **state-dependent**: its answer changes
  after the build creates `install-mpi/libdarshan.so` for mpi/dlio. So resolve-once must cache
  **POST-build**, NOT at top of script. Line 43 is an inherently pre-build probe (SKIP_BUILD
  guard) and must stay a live call; line 44 can reuse it. `run_workload_once`/`run_mpmd_rep`
  already cache into `$dlib`/`$DLIB` — mirror that pattern. A blanket top-of-file cache BREAKS mpi.
- `darshan_env` (lib/run.sh:149-181): 23 comment lines / 8 code lines — but comments are
  **load-bearing** correctness rationale (why DARSHAN_ENABLE_NONMPI must be unset for mpi/dlio;
  record-cap fix; tied to real crash job 7297242). TRIM only the provenance tails ("BX date,
  N-subagent cross-check", commit hashes) — KEEP the mechanism explanations. Don't gut the block.

**AUDIT BACKLOG (from 10-agent audit wf_62d3e7d7, 2026-07-30 — all LATENT, none blocks done; harden only if the trigger condition arises):**
- M1 vacuous-pass floor: strict_compare PASS when BOTH sides reduce to 0 comparable cells (main :347-360). Fix: require compared-cells>0 else ERROR rc2. (untriggered: real runs compared 95–16800 cells)
- M2 sorted-pair mispairing: perproc pid-set mismatch w/ equal counts → only a NOTE, not a fail (compare_perproc :230-235, main :354). Relevant to future multi-proc scale. Fix: make pid-set mismatch HARD.
- M3 stale-mongo: only if MONGO_DBPATH knob is pinned+reused across reps (default is blank→fresh per-PID mongod, SAFE). Fix: workflow_id tag + filter, or drop collection per rep.
- M4 ingest rubber-stamp: INGEST PASS = count>0, no expected-count reconcile in mpmd path (capture_flowcept.sh:149-153). Real completeness is caught by strict_compare record-set diff. Fix: thread producer send-count into verdict.
- M5 heatmap-read lossy (ONLY finding triggered on a real run): reconstructed POSIX READ heatmap −6.25%/16MB bin-smear (reconstruct.c:1077-1113); HEATMAP is a wholesale strict_compare exclusion, writes bit-exact, stream carries all read ops. Fix: disclose as approximate OR byte-conserving rounding.
- m1/m2 verdict-label races (ALL_DONE checked before *_FAIL, run.sh:531-533): label-only at CONS_N=1; data loss still caught downstream. m3 env-serial not space-safe (run.sh:401); m4/m5 native-find window vs shared logdir (job.sh:224-225); m6 streamed rank always fallback (defended by pid-in-key).
- NOTE: 2 bug-hunt lenses (B1 flag-races, B4 collision) stalled out on API retries; B4's question was independently answered by the synthesizer (latent+fail-safe). B1 flag-races NOT independently re-audited — but run_mpmd_rep self-review already covered flag ordering + m1/m2 name the residual label-race.

**CLEANUP PLAN (agent-mapped 2026-07-30, 3 read-only inventory agents; execute post-validation, re-verify with C 1+1 after):**
Reachability graph (agent A): submit_cxi.sh → job.sh → {env/server.sh, env/workload.sh} → lib/run.sh(run_mpmd_rep) →
{env/common.sh, env/workload.sh} → Client/capture_flowcept.sh → export_jsonl.py → strict_compare.py → darshan-mofka-reconstruct(bin).

(1) FEWER FILES — remove candidates (all git-tracked → recoverable; NONE referenced by live cxi path):
  - run_artifacts/*probe*.sh (vni_probe, mpmd_cxi/cxi2/diag/nopmi/3section, gate0_mpi_hello, test_cxi) — all self-labeled THROWAWAY; findings preserved here in DECISION.md.
  - run_artifacts probe outputs: mpmd2/ mpmddiag/ mpmdnopmi/ mpmd3sec/ gate0mpi/ vniprobe/ mpmdprobe/ probe_pbs_logs/; *_RESULT (7), *.e73*/*.o73* PBS logs, last_submit.txt, last_probe_submit.txt, mpi_hello.c.
  - Client/capture.py — orphan debug tool (live bridge is export_jsonl.py); zero live refs.
  - server/bedrock-config.runtime.json — generated output committed by accident (start_server.sh:34 writes it; job/run render per-run into $srv/).
  - stale workloads/__pycache__/strict_compare.cpython-36.pyc (live interp is py3.14).
  KEEP always: submit_cxi.sh, DECISION.md, README.md.

(2) RESOLVE-ONCE (agent 2) — the ONE real hoist: darshan_lib re-run per-rep at job.sh:152 + run.sh:402 (+build sites 43,44,61).
  Fix: cache DLIB="$(darshan_lib)" ONCE after the build block (after job.sh:148, POST-build so mpi/dlio install-mpi path is correct), reuse at 152 & 402. Mirror the existing B="$ROOT/.../bin" pattern (job.sh:69).
  Pre-build probe job.sh:43 + msg :44 MUST stay live calls (lib may not exist yet). Everything else (MONGOD, CC/CXX, PY, util bin B) already resolve-once; find/ls log lookups (job.sh:224-225,245-246; run.sh:542) are per-rep state-dependent — MUST NOT hoist.

(3) STRAIGHTFORWARD COMMANDS (agent 4) — 4 canonical invocations (validated):
  C 1+1:      WORKLOAD=c       NODES=2 TASKS=1 REPS=1 bash run_artifacts/submit_cxi.sh
  io_bench:   WORKLOAD=io_bench NODES=2 TASKS=1 REPS=1 bash run_artifacts/submit_cxi.sh
  5-node:     WORKLOAD=io_bench NODES=5 TASKS=4 QUEUE=debug-scaling bash run_artifacts/submit_cxi.sh
  multi-rep:  WORKLOAD=io_bench NODES=2 TASKS=1 REPS=3 bash run_artifacts/submit_cxi.sh
  (PBS_ACCOUNT defaults to radix-io.) Dead knobs to drop: CFG_QUEUE/WALLTIME/NCPUS/ACCOUNT (run.sh:39-42, assigned never read — qsub uses env directly). Root README documents only LEGACY submit.sh — MISSING a cxi command-reference; add one.
  DO-NOT-TOUCH (legacy/tcp + shared): submit.sh, server/start_server.sh/stop_server.sh, bedrock-config-mpi.json, workloads/mpi/*, workloads/dlio/*, overhead_*.sh, and run.sh legacy fns (start_broker/start_consumer/stop_consumer_verdict). Vendored: darshan/, diaspora-stream-api/.
  STILL-PENDING: comment-triage agent (darshan_env-style TRIM-vs-KEEP) hit the classifier outage — re-run before touching comments.

**Overnight rules in force:** (1) commit per green phase, DECISION.md before each submit; (2) same
error twice → STOP + wait; (3) 5-node → debug-scaling/preemptable, ≤1 job in flight, wall ≤1h;
(4) API degrades → jobs run without me, record jobid, never resubmit unconfirmed; (5) this block
stays current; (6) never conclude from mpiexec exit code — flags/files/logs only.

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
**"VNI red herring" — scope clarification.** The red-herring verdict applies ONLY to
the `--single-node-vni` launch flag / VNI-*strategy* knobs during bring-up: those
made zero difference; the bring-up hang was PMI, fixed by PMI-strip. It does NOT
apply to `cxi collapse-to-first` above — collapsing Polaris's 2 VNIs to the first is
STILL REQUIRED (margo mishandles multi-VNI → "Invalid domain auth_key"). Keep it.

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

- **`lib/run.sh run_mpmd_rep` — DONE (orchestrator, self-written + self-reviewed).**
  Matches the proven probe (run_artifacts/mpmd3sec) + the contract above. `bash -n`
  clean; all 3 sections render + `bash -n` OK; ESTR bakes correctly. Two bugs caught
  and fixed pre-commit: (1) workload copy used `workload.0.out` but PALS_RANKID is
  GLOBAL so the workload rank is NOT 0 → now `ls workload.*.out | head -1`; (2) pkill
  `"bedrock ofi+cxi"` — the `+` is a regex metachar → now `pkill -f 'bedrock '`
  (matches job.sh's EXIT trap). Committed with this note.

### SELF-REVIEW (2026-07-30, orchestrator; 6-way wf abandoned — API-degraded)
The 6-way adversarial Workflow (wf_6ed48f08) was stopped: in a degraded API window
all 6 reviewers hit retry 2–4, 300k+ tokens, 0/6 complete at 17m — a retry loop, not
analysis. Reviewed the 6 lenses myself against the proven probe + the real helpers:
- **vni/pmi/fabric:** STRIP + COLLAPSE emitted literally into every section (via
  `printf '%s\n' "$STRIP"`), evaluated inside the launched proc — matches probe. ✅
- **flag races (C-gate):** subscribe-before-produce holds — lead creates topic
  (run.sh:450) → capture_flowcept starts consumer, waits 12s+alive → touches
  CONSUMER_READY (capture_flowcept.sh:115) → only then workload runs. ✅
- **env forwarding:** all config scalars (CONS_N/SRV_PARTITIONS/CONS_MQ_*/CONS_DB_*/
  SRV_TOPIC/SRV_MONGO_*/SRV_PROTOCOL) match `load_run_config` names exactly; ESTR/DLIB/
  CMD baked via `%q` (arrays don't cross mpiexec). ✅
- **teardown/verdict:** amendment #6 honored — verdict = ALL_DONE + non-empty
  events.jsonl; mpiexec exit code ignored; broker killed via `pkill -f 'bedrock '`. ✅
- **contract/reuse:** reuses render_bedrock_config/connector_env/darshan_env/
  workload_env/broker_topic_partitions/_shard_targets/pmi_strip/cxi_collapse/
  mpi_launch_mpmd — no duplication; legacy path + reconstruct tail untouched. ✅
- **reconstruct tail:** leaves native `.darshan` in $RES + events.jsonl; job.sh tail
  (:216) finds logs via `find $RES ... -name '*.darshan'`, cmp_mode=perproc. ✅

### KNOWN GAP — io_bench env (RESOLVED)
`workload_env()` NOW has an `io_bench` case (lib/run.sh:190–191) forwarding
`IO_SIZE_MB/IO_ITERS/IO_SLEEP_MS/IO_BLOCK_KB` when set; it passes the non-MPI guard
(`!= mpi && != dlio`) so nonmpi=1. No fix needed.

### DEFERRED — CONSUMERS>1 subscribe-before-topic race (fix before that phase)
At CONS_N>1, followers (shard≥1) wait only for `mofka.json` (broker startup), NOT for
the topic — but only the LEAD creates the topic (run.sh:450). A follower can start its
FlowCept consumer before the topic exists. Harmless at CONSUMERS=1 (lead only) and for
the C/io_bench/5-node gates. FIX before the CONSUMERS>1 phase: have the lead touch a
`TOPIC_READY` flag after `broker_topic_partitions`, and have followers poll it before
starting their consumer.
