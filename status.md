# STATUS — Darshan→Mofka connector overhead study (handoff)

_Last updated 2026-08-03 ~21:05 by the previous session. Point a fresh agent here._

Worktree root: `/eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight`
(alias `/lus/eagle/projects/radix-io/...` — same filesystem). Git branch: `polaris_clean`.

---

## 1. The mission

Measure the **Darshan→Mofka streaming connector's overhead** on Polaris:
connector init/finalize/per-push cost **and** per-arm wall time, across
workloads × node-scales × 3 arms. Report as tables using p50/p99 of the warm rep.

**Three arms** (all must run in ONE allocation on the SAME node — cross-node wall
comparison is invalid; this was an explicit, repeated user requirement):
- `baseline`      — `NO_DARSHAN=1` (no libdarshan at all)
- `runtimeonly`   — `DARSHAN_MOFKA_ENABLE=0` (libdarshan writes native .darshan, streams nothing)
- `streaming`     — `DARSHAN_MOFKA_ENABLE=1` (streams events to Mofka)

**Protocols/topology:**
- CXI (`ofi+cxi`): 1 rank/node, `PARTITIONS=4 CONSUMERS=1`. Workloads: `io_bench`(C), `io_bench_py`, `python-ml`.
- TCP (`ofi+tcp`): 32 ranks/node, `PARTITIONS=16 CONSUMERS=16`. Workloads: `mpi`, `dlio`.
  (mpi is blocked on CXI by `workloads/job.sh:36` Gate-0.)

The full study is **PAUSED** behind a performance bug (below). Don't run the study
until the bug's fix is chosen. The study driver files already exist under
`overhead_study/` (15 per-config files + `_submit_lib.sh` + `extract_all.sh` + README);
see the plan at `/home/hjajula/.claude/plans/hjajula-polaris-login-02-eagle-radix-io-iridescent-russell.md`.

---

## 2. THE BUG we're fixing (Task #5, in_progress)

**Streaming makes the compute-bound Python workload ~44% slower in wall time.**
Root cause is fully diagnosed: the Mercury/Margo **client progress thread
busy-polls the CXI NIC**, pegging a full core for the whole run.

Fingerprint (a CPU_PROBE was added to `workloads/python-ml/io_bench.py` and
`workloads/c/io_bench.c`; prints `CPU_PROBE wall=W cpu_self=S cpu_thread=T` over
the WORK region, where `cpu_self`=RUSAGE_SELF all-threads, `cpu_thread`=RUSAGE_THREAD app-thread):
- Busy-poll present ⇔ `cpu_self − cpu_thread ≈ wall` (one bg thread ran 100% of a core).

**Selectivity (important):** the wasted core is universal, but it only *slows the
app* if the app is sensitive to turbo down-clock + L3/bandwidth contention:
- `io_bench_py` (CPython, pointer-chasing): **+43–48%** wall — hammered.
- `io_bench` (C, register-bound matmul): **+1–2%** wall — nearly immune (but the core is still pegged).

### What is PROVEN DEAD (do not re-test these)
| Hypothesis | Result | Evidence |
|---|---|---|
| `progress_timeout_ub_msec` (sleep between polls) | **INERT on CXI.** t=100 ≡ t=0, byte-identical busy-poll. | job 7325089, `diag_samenode_fix.sh` |
| `use_progress_thread:false` (NOPROG, LDMS-style on-caller progress) | Reclaims the core (`cpu_self` 681→338, **no deadlock**) but wall stays **+44%** — the spin just MOVES onto the app thread. | job 7325340, `diag_ldms_equiv.sh` |
| `DARSHAN_MOFKA_ASYNC=0` (sync inline push, user's hypothesis) | **No effect.** sync `wall 65.15/self 129.91` ≡ async `wall 65.16/self 129.92`. ASYNC toggles OUR drain thread, not Margo's progress thread. | job 7325494, `diag_sync.sh` (this session) |

**Key insight — two SEPARATE harms that trade off; no single knob fixes both:**
On CXI ~1 core of progress-spin MUST happen somewhere (the fabric has no
`fi_trywait`/pollable fd — `HG_Progress` returns immediately and busy-spins
regardless of timeout). A dedicated thread wastes a core AND contends with the app.
NOPROG reclaims the core but steals the app's own cycles. **You cannot eliminate
the spin — you can only ISOLATE it.**

**`use_progress_thread:true` is NOT connector misuse** — it's the documented normal
producer pattern (3 of 4 Mofka examples use it). The core-peg is the expected cost
of `true` on CXI. Batching (`DARSHAN_MOFKA_BATCH`) was also ruled out for io_bench_py
by arithmetic: 100 events × ~22µs = 2.2ms, cannot explain a +100s CPU rise.

---

## 3. THE FIX TO TEST NEXT (this is where you pick up)

Two config-only fixes remain, both injected through a **verified passthrough**:
`MofkaDriver.cpp:113` reads `config.value("margo", …)` from the same opts JSON as
`group_file` and passes it straight to `thallium::engine{…, margo_config_str}`.
diaspora-c wraps the opts JSON with **zero key filtering**, so arbitrary margo JSON
(incl. `argobots` pools/xstreams + `cpubind`) flows through with no C++ rewrite.

A new connector knob **`DARSHAN_MOFKA_MARGO_JSON`** was added + built + installed
this session (see §5). It splices its value verbatim as the `margo` object:
`{"group_file":"…","margo":<DARSHAN_MOFKA_MARGO_JSON>}`.

### Fix A′ — yielding progress ES (try first; may not help on CXI)
Replicates Mofka's own `startProgressThread()` declaratively: a dedicated progress
xstream with the `basic_wait`/`fifo_wait` yielding scheduler. **EXACT string**
(schema-verified against compiled `libmargo.so` validation strings + shipped
`install/_mofka/docs/_code/advanced-config.json` + margo.h — see §6 for the traps):

```
DARSHAN_MOFKA_MARGO_JSON='{"use_progress_thread":false,"rpc_thread_count":0,"argobots":{"pools":[{"name":"__primary__","kind":"fifo_wait","access":"mpmc"},{"name":"__progress__","kind":"fifo_wait","access":"mpmc"}],"xstreams":[{"name":"__primary__","scheduler":{"type":"basic_wait","pools":["__primary__"]}},{"name":"__progress__","scheduler":{"type":"basic_wait","pools":["__progress__"]}}]},"progress_pool":"__progress__"}'
```

**Prediction (medium confidence): A′ probably will NOT reclaim the core on CXI** —
same reason the timeout knob was inert. `basic_wait` only sleeps the execution
stream when its pool has no runnable ULT, but the margo progress loop is a
self-re-queuing ULT, so the ES stays runnable and `basic_wait` degrades to `basic`
(busy). The spin lives inside `HG_Progress`/`na_cxi` *below* Argobots. A′ IS correct
and WILL help on tcp/verbs (wait objects exist there), and is strictly no worse than
default — but on CXI the core likely stays pegged. **Measure it; don't assume.**

### Fix A — cpubind (the likely real answer for CXI)
Same as A′ but pins the progress xstream to an isolated core so the (unavoidable)
spin stops stealing cycles from the compute thread:

```
DARSHAN_MOFKA_MARGO_JSON='{"use_progress_thread":false,"rpc_thread_count":0,"argobots":{"pools":[{"name":"__primary__","kind":"fifo_wait","access":"mpmc"},{"name":"__progress__","kind":"fifo_wait","access":"mpmc"}],"xstreams":[{"name":"__primary__","scheduler":{"type":"basic_wait","pools":["__primary__"]}},{"name":"__progress__","cpubind":31,"scheduler":{"type":"basic_wait","pools":["__progress__"]}}]},"progress_pool":"__progress__"}'
```

Expected win: `cpu_self` stays ~2× wall (core still pegged) but the app's
`cpu_thread` and **wall return to ~baseline** (contention gone).

**CRITICAL for the cpubind test to be valid:** core 31 must be OUTSIDE the app's
CPU set. With 1 rank/node the Python process is otherwise unpinned and floats
across all cores (incl. 31), so it can still land on 31 and contend. Either pin the
app away from 31 (mpiexec `--cpu-bind`, or `OMP_NUM_THREADS`/numactl on the workload
rank) or verify the app's affinity mask excludes 31. If the win doesn't appear,
check this FIRST before concluding cpubind failed. On packed nodes (32–64 ranks/node
TCP arms) there is no spare core — cpubind is a CXI-only mitigation.

---

## 4. HOW TO RUN THE TEST

Reuse the diagnostic harness pattern (all diag scripts live in `overhead_study/`).
The cleanest path: copy `overhead_study/diag_ldms_equiv.sh` to
`overhead_study/diag_cpubind.sh` and change the streaming arms' extra env to
`DARSHAN_MOFKA_MARGO_JSON='…'` (one arm A′, one arm Fix A), keeping a `baseline` +
`baseline2` drift check and both a Python and a C arm. Then submit small:

```
cd /eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight
qsub -A radix-io -q debug -l select=2:ncpus=32:mpiprocs=32 \
     -l walltime=00:30:00 -l filesystems=home:eagle -j oe \
     -o overhead_study/diag_cpubind.OU \
     -v CMP_PY=3,CMP_C=8,ITERS=8 \
     overhead_study/diag_cpubind.sh
```
(`CMP_PY=3,CMP_C=8,ITERS=8` = ~45s/arm for fast iteration; the diag scripts read
those env overrides. Full-size defaults are CMP_PY=8/CMP_C=24/ITERS=16.)

**Read the result** from `results/diag_cpubind.log`: grep `CPU_PROBE` and
`margo opts` per arm. Success for Fix A = the streaming arm's `wall` ≈ baseline
`wall`, even though `cpu_self` ≈ 2× (core still pegged, but off the app's core).
ALSO confirm the `darshan-mofka[cfg] margo opts:` line shows your full argobots JSON
reached the engine, with ZERO `options ignored` / `Could not find __primary__`
warnings in `results/…/streaming*/RUN1/workload.*.err`.

### env-forwarding mechanism (so you know the knob will arrive)
- **CXI / MPMD path (our study):** `run.sh` launches one MPMD `mpiexec`; PALS
  forwards the ambient environment to the rank. So a `DARSHAN_MOFKA_*` var set via
  `env KEY=VAL … bash workloads/job.sh` reaches the connector **without** being in
  any whitelist. (Empirically confirmed: `PROGRESS_THREAD=0`, `TIMEOUT_MS=0` all
  showed up in the emitted `margo opts` line despite not being whitelisted.)
- **Legacy separate-node / TCP path:** the workload env is rebuilt from the
  `CONNECTOR_ENV` array (`lib/run.sh:97-112`), NOT inherited. For that path (and for
  robustness), add `DARSHAN_MOFKA_MARGO_JSON` (and the progress knobs) to the
  whitelist loop at **`lib/run.sh:109-112`**. The round-trip (array → space-join
  ESTR → `printf %q` bake → `env $ESTR` re-split at `run.sh:393/489/491`) was proven
  to deliver JSON with `{}[]":,` metacharacters byte-exact. **This edit is still
  PENDING** — do it before running any TCP-path test with the knob.

---

## 5. What was changed this session (built + installed)

`darshan/darshan-runtime/lib/darshan-mofka.c`:
- `opts` buffer `char[1200]` → `char[4096]` (holds full argobots JSON).
- Added `DARSHAN_MOFKA_MARGO_JSON` verbatim-splice branch (~line 363). When set,
  emits `{"group_file":"…","margo":<value>}`; else the default
  `{…"margo":{"use_progress_thread":…,"progress_timeout_ub_msec":…,"rpc_thread_count":…}}`.
- The default (no-knob) path is byte-identical to before → safe for in-flight jobs.
- Env knobs read at `darshan-mofka.c:356-358` (PROGRESS_TIMEOUT_MS / RPC_THREADS /
  PROGRESS_THREAD), `:363` (MARGO_JSON), `:412` (ASYNC).
- Rebuilt via `make -j8` in `darshan/_build` then `make install` (do NOT use high
  `-j` — a prior `make -j256` fork-bombed the shared login node). Verified the
  `DARSHAN_MOFKA_MARGO_JSON` string is present in installed
  `darshan/install/lib/libdarshan.so`.

New diagnostic scripts in `overhead_study/`: `diag_sync.sh` (this session),
`diag_ldms_equiv.sh`, `diag_samenode_fix.sh`.

---

## 6. margo 0.24 argobots JSON schema — VERIFIED, with traps

Verified against compiled `libmargo.so` validation strings + margo.h doc-comment
(lines ~199-262) + `install/_mofka/docs/_code/advanced-config.json`.

- **Pool type field is `"kind"`, NOT `"type"`.** `"type"` exists ONLY inside the
  `scheduler` sub-object. `libmargo.so` has `Invalid type for "kind in pool
  configuration`; there is NO `"type in pool configuration` string. **TRAP:** do
  NOT copy `MofkaDriver::startProgressThread()` verbatim — its literal uses pool
  `"type":"fifo_wait"` because that blob goes through a *different* API
  (`margo_add_pool_from_json`). Our env JSON goes through the engine-init parser,
  which needs `"kind"`. Using `"type"` for the pool silently falls back to default
  kind (no error) — a silent mis-parse.
- **You MUST define `__primary__` yourself** as the first pool AND the first pool of
  the `__primary__` xstream when you supply an `argobots` block — margo does NOT
  merge an auto-created one (else `Could not find __primary__ pool after
  initialization from configuration`). Both §3 JSONs do this correctly.
- **`progress_pool`** is a top-level margo key (sibling of `argobots`); value =
  name-string or int index. When set explicitly with `use_progress_thread:false`,
  margo honors it and does NOT spawn the spinning default ES (emits
  `"use_progress_thread" will be ignored because "progress_pool" field was specified`).
- Valid pool `kind`: `fifo_wait`(default), `fifo`, `prio_wait`. Valid scheduler
  `type`: `basic`, `basic_wait`, `prio`, `randws`. `access`: `mpmc`/`mpsc`/`spmc`/`spsc`.
- **`MOFKA_CLIENT_MODE`**: ensure it's set for a pure producer so the engine is
  non-listening (`mercury.listening=false`), no extra RPC pool. `run.sh` sets it via
  `C_CLIENT_MODE` (`lib/run.sh:116`).

---

## 7. Reference numbers (all same-node, warm)

io_bench_py (CMP_PY=8, matrix 256), job 7325340:
| arm | wall | cpu_self | cpu_thread |
|---|---|---|---|
| baseline | 234.3 | 233.5 | 233.5 |
| streaming DEFAULT (thread ON) | 340.9 | **681** | 340 |
| streaming NOPROG (thread OFF) | 338.6 | 338 | 338 |
| baseline2 (drift) | 238.8 | — | — |

io_bench_py (CMP_PY=3, this session, job 7325494 diag_sync):
| arm | wall | cpu_self | cpu_thread |
|---|---|---|---|
| baseline | 44.00 | 43.60 | 43.60 |
| streaming_sync (ASYNC=0) | 65.15 | 129.91 | 64.75 |
| streaming_async (ASYNC=1) | 65.16 | 129.92 | 64.76 |
| baseline2 (drift) | 45.58 | 45.18 | 45.18 |

io_bench C (CMP_C=8, this session): streaming_sync `wall 25.30 / self 50.10 /
thread 24.90` — core pegged, but C app nearly immune (baseline ~24.8).

---

## 8. Live state / gotchas

- **Debug queue: max_queued ≈ 1 running + 1 queued per user.** Check `qstat -u hjajula`
  and let job 7325494 (diag_sync) finish before submitting the cpubind test, or it
  won't queue. See memory `polaris-queue-max-queued-limit`.
- The `runtimeonly` clean-completion fix is already applied (`workloads/job.sh:236`,
  `lib/run.sh:552`) — Task #1 done.
- Overhead-study driver files exist (Task #2 done) but the full drip-feed run
  (Task #3) is intentionally PAUSED until the fix is settled.
- Memory file `mofka-progress-thread-busypoll-overhead.md` in the user's auto-memory
  has the full running record. **NOTE:** its current text still concludes "Fix A′ is
  effectively dead" from the NOPROG result — the schema-verified A′/Fix A JSON in §3
  here supersedes that framing (A′ is a distinct config that keeps a dedicated thread;
  NOPROG's deadlock-free result does not rule it out). Update the memory once the
  cpubind test returns.

## 9. Immediate next action
1. `qstat -u hjajula` — wait for the debug slot.
2. Create `overhead_study/diag_cpubind.sh` (copy diag_ldms_equiv.sh; streaming arms
   use the §3 A′ and Fix-A `DARSHAN_MOFKA_MARGO_JSON` strings; keep baseline+baseline2+C).
3. Ensure the workload rank's CPU affinity excludes core 31 for the Fix-A arm.
4. Submit small (`CMP_PY=3,CMP_C=8,ITERS=8`), read `results/diag_cpubind.log`
   CPU_PROBE + margo-opts lines.
5. If Fix A restores wall≈baseline → that's the fix; wire it as the connector default
   for CXI and update the memory file. Then resume the full study (Task #3).
