# Consolidation plan (post-fidelity + overhead-study work)

This session added ~609 net lines on top of the working `run_time` baseline
(`darshan` fork `a07fd75d`): HEATMAP reconstruction, exe/mounts streaming, the
connector metadata event, and a new overhead-study driver. Three read-only
agents audited the files that grew, looking only for **behavior-preserving**
consolidation. Summary of findings, ranked; nothing here changes wire format,
the heatmap algorithm, record ids, or output bytes.

Total realistic net reduction across all files: **~100–110 lines**, dominated by
the shell runners (the study driver copy-pasted ~80 lines from `job.sh`). The two
C files are already tight (~20 and ~5 lines).

## A. Shell runners — biggest win (~61 net, all SAFE; up to ~80 with medium items)

`workloads/overhead_study.sh` was written by copying whole blocks out of
`workloads/job.sh`. Extract the shared pieces into `lib/run.sh` (both already
source it). Verified near-byte-identical by diff.

| Rank | Extract into `lib/run.sh` | net | risk |
|---|---|---:|---|
| 1 | `run_workload_once()` (identical but for wall-timing/ENABLE) | −25 | SAFE — also protects the duplicated `mpirun --host …` launch string from silent drift |
| 2 | `build_stack()` (2a diaspora + 2b darshan/util + tool check) | −21 | SAFE |
| 3 | `compare_ops.py` shared script (op-count VERDICT heredoc) | −17 | MEDIUM — must keep `sys.exit(0 if ok else 3)` for `job.sh`'s `FINAL_RC` |
| 4 | `compile_workload()` (c/mpi case) | −6 | SAFE |
| 5 | `resolve_topology()` (NODELIST/broker/workload nodes) | −4 | SAFE |
| 6 | `resolve_mongod()` | −3 | SAFE |
| 7 | `bringup_broker()` (echo stays per-caller) | −2 | LOW value |
| — | `bootstrap_env()` (needs `source lib/run.sh` moved earlier) | −3 | MODERATE — do last/separately |

**Drift to fix while unifying** (real divergences between the two copies):
- native-log search window: `-20 min` (`job.sh`) vs `-30 min` (study) in the `find -newermt` step.
- divergent VERDICT strings + the study omits the `exit 3`.
- **misleading dead comment** in `overhead_study.sh` ("errexit stays off…") — neither
  script sets `-e`, so the `set +e` is a no-op; drop the comment.

Recommended first pass (no reorder, no behavior questions): ranks 1,2,4,5,6,7 ≈ **−61 net, all SAFE**.

## B. `darshan-util/darshan-mofka-reconstruct.c` — modest (~15–20 net, all SAFE)

| # | Change | net | risk |
|---|---|---:|---|
| 1 | `record_should_prune(rec, name_hash)` helper — dedups the `record_is_empty(...lookup_record_name...)` predicate used in both `write_log` loops | −3 | SAFE (removes an easy-to-desync duplicate) |
| 2 | `set_str_if_empty(dst, cap, line, key)` — folds the 3 identical hostname/exe/mounts blocks in `update_job_info` | −12–15 | SAFE (biggest win) |
| 3 | name `MAX_MNT_ENTRIES 64` | +1 | SAFE (clarity) |
| 4 | extract `maybe_capture_heatmap_op()` from `read_events` | ~0 | SAFE (readability) |

**Explicitly NOT touched** (verified non-opportunities): the "`ended_at` parsed twice"
is intentional — line ~611 uses `json_get_double` for the `should_replace` seq/tiebreak,
line ~630 uses `json_get_epoch` for the heatmap; unifying would change the replacement
tiebreak and thus output bytes. `build_heatmap_records` two-pass scan is genuinely
sequential (pass 1 sizes bins, pass 2 fills). No dead code.

## C. `darshan-runtime/lib/darshan-mofka.c` — already tight (~3–5 net)

| # | Change | net | risk |
|---|---|---:|---|
| 1 | compile-time JSON-fragment `#define`s shared by `emit_metadata`/`send` (identical `type`/`schema_version`/identity fragments) | ~0 | SAFE — string-literal concatenation ⇒ **bytes provably unchanged**; removes schema-drift hazard |
| 3 | `mofka_push(buf, label)` for the two push+error-log blocks | −2–3 | needs-care (preserve exact stderr wording) |
| 4 | `mofka_teardown()` shared by init error paths + finalize | ~0 | SAFE (one canonical destroy order) |
| 5 | name buffer sizes (`REC_HEX_SZ`, `MOUNTS_SZ`, …) | +1 | SAFE (readability) |

**Explicitly AVOID**: a *runtime* shared preamble helper for the two `snprintf`s —
`activity_id`/`task_id`/middle-section genuinely differ, and splicing them through a
function risks the exact bytes FlowCept + reconstruct parse. Compile-time macros only.

## Sequencing suggestion
1. Shell ranks 1–2 first (biggest win, fixes the launch-string drift risk), rebuild-free.
2. reconstruct.c #1/#2 (rebuild darshan-util, re-run the login-node pydarshan check → byte-identical).
3. connector #1 macros (rebuild runtime, one e2e).
4. Defer B#4, C#3–5, shell rank 3/`bootstrap_env` unless doing a full cleanup pass.

Each C change must be verified byte-identical via `darshan-parser --all` + the
pydarshan heatmap/exe/mounts check before landing.
