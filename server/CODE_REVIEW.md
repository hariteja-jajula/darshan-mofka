# Code review — connector + reconstructor (verified, 37 findings)

> Generated 2026-07-16 by an adversarial line-by-line verification pass (45 agents,
> each finding re-checked against source). 37 of 38 raised findings survived.
> Paths are relative to the darshan/ submodule. This is REVIEW OUTPUT for the next
> session — no fixes applied yet. C1 is a real correctness bug worth a PR.

=== survivors: 37  refuted: 1

Branch confirmed (`darshan-mofka-reconstructor`), key lines verified against the tree. Here is the report.

---

# VERIFICATION REPORT — `darshan-mofka-reconstructor` branch

**Scope:** the Darshan→Mofka connector `darshan-runtime/lib/darshan-mofka.c` and the reconstructor `darshan-util/darshan-mofka-reconstruct.c`.
**Clone root (all paths below are relative to this):** `/eagle/radix-io/hjajula/scratch_clones/darshan-mofka-reconstructor/darshan/`
**Method:** every line of both files was reviewed line-by-line plus a whole-tree reuse scan; 38 issues were raised and put through adversarial re-verification against the actual source. 37 survived (35 CONFIRMED, 3 PARTLY where a sub-claim was wrong but the core defect is real). Each load-bearing claim below cites `file:line`.

---

## 1. Verdict — overall code quality

**Sound design, correct on the happy path, but not yet shippable: one confirmed correctness bug makes the reconstructor produce *no output at all* for the normal multi-module capture, and two more silently corrupt or mis-size the reconstructed log.** The connector (producer) side is in good shape — I found no present-day crash, all 26 snprintf format specifiers match their arguments (`darshan-mofka.c:201-225`), the diaspora API is used per its documented contract, and the license/style conventions match darshan. Its issues are robustness and dead-code, not correctness.

The reconstructor is where the risk concentrates. The write path reuses darshan's own `darshan_log_create → put_job → put_exe → put_mounts → put_namehash → log_put_record` idiom correctly (matches `darshan-convert.c`/`darshan-merge.c`), and the hand-rolled JSON/hex helpers are *justified* — there is genuinely no C JSON parser or hex codec anywhere in the darshan tree to reuse (verified by whole-tree grep; the only other in-tree JSON producer, `darshan-ldms.c:253`, hand-rolls with a raw `sprintf` and no escaping at all). But three defects break real inputs, and several hand-rolled tables/hashes duplicate authoritative darshan structures and will silently drift.

**Headline: fix the module-ordering bug (#1 below) before anyone runs this on a POSIX+MPIIO+STDIO trace — today that case emits an empty/unlinked log. Then the `\uXXXX` and `nprocs` bugs. The reuse and cut work is mostly mechanical and removes ~150 LOC net.**

---

## 2. Correctness / robustness bugs (ranked by blast radius)

### C1 — [CORRECTNESS] Module records written in insertion order → whole log rejected for any interleaved multi-module capture
`darshan-util/darshan-mofka-reconstruct.c:596-608`

The write loop iterates `records` in uthash insertion order (= first-seen order in the JSONL). `darshan_log_dzwrite` **hard-fails (`return -1`) the instant a record is written to a module region id lower than the previous one** (`darshan-util/darshan-logutils.c:1629-1630`; the ordering contract is documented at `darshan-logutils.c:809-811`). Region id == module id, and modules interleave in the stream because the runtime emits records inline from each I/O wrapper (POSIX=1, MPIIO=2, STDIO=9 at `include/darshan-log-format.h:164-182`).

**Failing input:** any trace with events ordered e.g. POSIX, STDIO, POSIX (the normal case). The second POSIX record has `mod_id=1 < 9` → `dzwrite` returns -1 → `goto fail` → `darshan_log_close` unlinks the output (`darshan-logutils.c:906-908`). **The user gets no file and, today, no clear reason.** Only single-module captures happen to work.

**Fix:** write modules in ascending id with an outer loop, which also fixes C7's out-of-bounds guard for free:
```c
int m;
for(m = 0; m < DARSHAN_KNOWN_MODULE_COUNT; m++) {
    if(!mod_logutils[m]) continue;
    HASH_ITER(hlink, records, rec, tmp) {
        if(rec->key.mod_id != m) continue;
        ret = mod_logutils[m]->log_put_record(out, rec->buf);
        if(ret < 0) { /* fprintf + goto fail */ }
    }
}
```
This is exactly the pattern darshan's own writers use (`darshan-convert.c:436-477`, `darshan-parser.c:302`). (Alternative: `HASH_SRT(hlink, records, rec_mod_cmp)` before the loop — `HASH_SRT` is vendored at `uthash.h:757-758` — but the outer loop is preferred because it also bounds the index correctly.)

### C2 — [CORRECTNESS] `nprocs` = count of distinct ranks, not `max_rank+1` → wrong process count AND parser abort / OOB write
`darshan-util/darshan-mofka-reconstruct.c:566` (with `add_rank` 293-303)

`int64_t nprocs = (int64_t)HASH_CNT(hlink, ranks);` counts *distinct* ranks (`HASH_CNT` is `num_items`, `uthash.h:896`; `add_rank` dedups at :297-298). darshan defines nprocs as the MPI comm size with ranks `0..nprocs-1` (`darshan-core.c:222,313`), so the correct value is `max_rank+1`.

**Failing input:** a sparse capture where only ranks {0, 2, 5} logged I/O → `nprocs` reported as 3 instead of ≥6. This is worse than a skewed metric: `nprocs` feeds `darshan_accumulator_create(i, job.nprocs, …)` (`darshan-parser.c:396`), which sizes a per-rank array `calloc(job_nprocs*3, …)` (`darshan-logutils-accumulator.c:79`) then indexes it by rank with `assert(rank < job_nprocs)` and `rank_cumul_io_total_time[rank] += …` (`:145-146`). Record rank=5 under nprocs=3 → **assert-abort (debug) or out-of-bounds heap write (NDEBUG)** in `darshan-parser`.

**Fix (also cuts LOC — see R-cut below):** track `max_rank` and set `nprocs = max_rank + 1`; the `nprocs > 0 ? : 1` floor already at `fill_job` (:541) handles the all-shared/rank=-1 case. `max_rank+1` is both a correct lower bound and guarantees `rank < nprocs`, closing the OOB. (Ideal follow-up: have the producer emit an authoritative `comm_size` — it currently emits per-record `rank` but no comm size, `darshan-mofka.c:201-225` — and prefer it when present.)

### C3 — [CORRECTNESS] `json_get_string` does not decode `\uXXXX` → every non-ASCII filename silently corrupted
`darshan-util/darshan-mofka-reconstruct.c:114-128`

The unescape switch has no `case 'u':`; `\u` falls to `default: out[n++] = *p;` (:127), copying the literal `u` then the 4 hex digits verbatim. The producer keeps raw UTF-8 bytes (`darshan-mofka.c:70`), but `capture.py:59` re-serializes with `json.dumps(md, separators=(',',':'))` — `ensure_ascii` defaults **True** — so a UTF-8 filename arrives in the JSONL as `\uXXXX`, and this JSONL is exactly the reconstructor's input.

**Failing input:** a file named `résumé`. The `é` (U+00E9) arrives as `\u00e9` and reconstructs to the literal name **`u00e9`**. This is a real defect for the known producer, not hypothetical.

**Fix:** add a `case 'u':` that parses 4 hex digits via the file's own `hex_value()` (`:214`), handles surrogate pairs, and UTF-8-encodes into `out[]`. No buffer resize needed — `out` is `malloc(strlen(p)+1)` (:105) and UTF-8 output is always shorter than the `\uXXXX` input. Full patch body is in the finding; keep the current default-case behavior for malformed escapes so non-`\u` escapes don't regress.

### C4 — [ROBUSTNESS] `decode_hex` silently truncates an oversized payload instead of rejecting it
`darshan-util/darshan-mofka-reconstruct.c:231-232`

```c
if(expected > 0 && n < expected) return NULL;
if(expected > 0 && n > expected) n = expected;   // <-- silent trim
```
The oversized branch trims to `expected` and reports `out_len == expected`, so the caller's guard `if(!buf || len != exp_size)` (:509) **passes a structurally-wrong record**. This masks record-format/version skew between the producing runtime and the linked `darshan-logutils`. Reachable on the defensive path where the producer's `rec_size` field is absent (default `rec_size_i=0`, guard at :501 is conditional on `>0`) but an oversized `rec_hex` is present.

**Fix:** one line — `if(expected > 0 && n != expected) return NULL;` (delete the trimming line). Exact-size match is the only safe case for a fixed-layout struct; the happy path (`n == expected`) is unaffected.

### C5 — [ROBUSTNESS] `json_find_key` is `strstr`-over-line, not structure-aware
`darshan-util/darshan-mofka-reconstruct.c:82-87`

`strstr(line, "\"<key>\":")` can match a needle occurring inside a string *value*. It works today **only** because the producer escapes quotes (`darshan-mofka.c:68` rewrites `"`→`\"`), an undocumented contract. The trailing `":` does prevent key-*prefix* collisions (`"off":` won't match `"offset":`), so the residual risk is a value carrying the literal bytes `"rank":`. Concrete break: the producer emits `"file":"…"` (`darshan-mofka.c:207`) *before* `"rank":…` (:209), and `json_get_i64` takes the first hit — so a filename containing `"rank":99` (reachable if any upstream ever emits unescaped quotes, or via the C3 `\u` gap) makes `json_get_i64(line,"rank")` return 99.

Hand-rolling is justified (no C JSON lib is vendored — grep for cjson/jansson/parson/yajl over the whole tree returns only a CI yaml). **Fix = contract-hardening, not replacement:** add a header comment above `:82` stating the flat/single-line/quote-escaped input contract these helpers trust. Optional defense-in-depth: scan for the key only at brace-depth 0 outside quoted spans.

### C6 — [ROBUSTNESS] Connector env parsing: `strtoull("-1")` → `SIZE_MAX` removes the backpressure/memory bound
`darshan-runtime/lib/darshan-mofka.c:115-116`

`DARSHAN_MOFKA_BATCH` / `DARSHAN_MOFKA_MAX_BATCHES` are parsed with `strtoull(e, NULL, 10)` (no endptr, no validation) and cast to `size_t`. Per C std 7.22.1.4 a leading `-` is accepted and negated in the unsigned result, so `-1` → `ULLONG_MAX` → `SIZE_MAX`, and `diaspora_c.h:82-84` documents that `max_num_batches` bounds client memory and sets backpressure — `SIZE_MAX` defeats both (unbounded pending client memory). Non-numeric input silently yields 0 (benign here since 0 is the default for both). **Fix:** a small validating parser (`parse_env_size`) that rejects sign/non-numeric/trailing-garbage with a `darshan_core_fprintf` warning and clamps `max_batches` to a ceiling. Matches the fprintf diagnostics already used in this function (:119,129,136,146).

### C7 — [ROBUSTNESS] Out-of-bounds read: guard bounds by `DARSHAN_MAX_MODS` (64) but `mod_logutils[]` has `DARSHAN_KNOWN_MODULE_COUNT` (~18) entries
`darshan-util/darshan-mofka-reconstruct.c:598` *(PARTLY — core confirmed)*

`DARSHAN_MAX_MODS` is 64 (`include/darshan-log-format.h:39`) but `mod_logutils[]` is declared with only `DARSHAN_KNOWN_MODULE_COUNT` entries (`darshan-util/darshan-logutils.c:83`). For any `mod_id` in `[KNOWN, 64)`, the `!mod_logutils[rec->key.mod_id]` clause (:599) is itself the OOB read. Currently *unreachable* (`module_name_to_id` only returns ids < KNOWN), so severity is robustness/latent, but the guard is wrong. **Fix:** change `DARSHAN_MAX_MODS` → `DARSHAN_KNOWN_MODULE_COUNT`; keep the NULL check (`darshan_log_put_mod` can't guard the caller's array indexing). *Refuted sub-claim:* the finding said the id-range check "duplicates a check `darshan_log_put_mod` already performs" — it does not; `log_put_mod` validates a different hardcoded id *after* the array is indexed, so this check is necessary. **Adopting C1's outer loop removes this guard entirely.**

### C8 — [ROBUSTNESS] Connector `hex_into` silently truncates records > 2047 B; reconstructor then silently drops them
`darshan-runtime/lib/darshan-mofka.c:179,198-199` (encoder :75-85)

`hex_into` is `void` with loop guard `o + 2 < dstsz` (:81), so `rec_hex[4096]` caps encoding at **2047 raw bytes** with no signal; a short hex string then fails `decode_hex` and is dropped at the reconstructor (`reconstruct.c:509-513`). **Safe today** — largest wired struct is `darshan_hdf5_dataset` = 912 B → 1824 hex chars (the finding's "904 B" omitted the 8-byte `file_rec_id`; POSIX = 704 B), all well under 2047 — but the coupling is undocumented and uncheckable: the connector includes no per-module header, so it cannot see struct sizes. **Fix:** a runtime guard before `hex_into` (a `_Static_assert` won't compile here — type not visible in this TU):
```c
if (rec_size * 2 + 1 > sizeof(rec_hex)) {
    darshan_core_fprintf(stderr, "darshan-mofka: record too big to hex (%llu B), dropping\n", …);
    goto out;   /* out: at :233 */
}
```
Diagnose loudly at the producer instead of shipping a truncated hex the reconstructor rejects in silence.

### C9 — [ROBUSTNESS] Connector `DARSHAN_MOFKA_GROUP_FILE` path truncates silently at 1024 chars
`darshan-runtime/lib/darshan-mofka.c:92`

`char gf_esc[1024]` receives the JSON-escaped group-file path, but paths run to `__DARSHAN_PATH_MAX = 4096` (`darshan.h:82`, used tree-wide) and `json_escape_into` can nearly double length (`"`/`\`→2 bytes). A clipped path is handed to `diaspora_driver_create` → confusing failure, or worse a driver silently reading the wrong file. **Fix:** either make `json_escape_into` report truncation and reject a clipped group-file (preferred — also catches the wrong-file case), or size `gf_esc[2*__DARSHAN_PATH_MAX]` **and** `opts` correspondingly (bumping only `gf_esc` just moves the truncation into the `opts` snprintf at :125).

### C10 — [ROBUSTNESS] `schema_version:2` on the wire is never read by any consumer
`darshan-runtime/lib/darshan-mofka.c:205`

Producer emits `"schema_version":2`; a tree-wide grep for `schema_version` returns *only* that line — no consumer parses it. The real compat gate is the `rec_size == sizeof(struct)` check (`reconstruct.c:499-505`), whose comment says "For v1". So the field gives zero compatibility protection. **Fix (preferred):** make it a real contract — the parse helper `json_get_i64` already exists, so add a `schema_version` check in the reconstructor that warns/skips on an unknown version, and share a `#define DARSHAN_MOFKA_SCHEMA_VERSION` header between both ends. (Or, if it's meant to be advisory only, say so in a comment and stop implying a guarantee.)

**Smaller silent-drop / diagnostic gaps (nit, same family):**
- `darshan-mofka.c:227` — event-too-large `snprintf` truncation does `goto out` with no log, unlike the push-failure path two lines below that *does* log (:230-231). Add a diagnostic (cannot fire at current buffer sizes — maxed content ≈ 5.9 KB < 8192 — but silence is the worst failure mode). 
- `reconstruct.c:564-571` — the partial flag is set for every written module (correct, matches `darshan-convert`), but the consequence is that plain `darshan-parser out.darshan` hard-errors (`darshan-parser.c:346-380`) and the user **must** pass `--show-incomplete`, which is never surfaced. Add a one-line hint to the success message (:652).

---

## 3. Reuse — what Darshan already provides that we should call instead

### RU1 — `module_name_to_id` re-hardcodes the canonical X-macro table
`darshan-util/darshan-mofka-reconstruct.c:251-260` → reuse `darshan_module_names[]`

The 5-way `strcmp` table duplicates `static const char * const darshan_module_names[]` (`include/darshan-log-format.h:197-201`), generated from the same X-macro as the `darshan_module_id` enum, so **array index == enum id**. It's already in scope (reconstruct.c includes `darshan-logutils.h` → `darshan-log-format.h`). Replace with a loop over the table (mirrors the existing pattern at `darshan-runtime/lib/darshan-config.c:64-70`):
```c
if(!module) return -1;
if(!strcmp(module, "MPIIO")) return DARSHAN_MPIIO_MOD; /* runtime alias; table says "MPI-IO" */
for(i = 0; i < DARSHAN_KNOWN_MODULE_COUNT; i++)
    if(!strcmp(module, darshan_module_names[i])) return i;
return -1;
```
**TRAP (must keep):** the connector emits `"MPIIO"` (`darshan-mpiio.c:262`) but `darshan_module_names[DARSHAN_MPIIO_MOD]` is `"MPI-IO"` (`log-format.h:167`) — a naive loop drops all MPIIO records. Safe to widen the map: `expected_record_size()` returns -1 for unknown layouts (:271) and the caller drops them (:499-500). **LOC: ~10 → ~6, and auto-tracks new modules.**

### RU2 — Redundant double-hash of name records
`darshan-util/darshan-mofka-reconstruct.c:391-414` (+ `struct name_ent` 44-49, `add_name` 275-291, `free_names` 427-436)

`add_name` builds a bespoke `struct name_ent` id→name hash, then `build_namehash` walks it to build a **second** hash of `struct darshan_name_record_ref` — the exact struct darshan defines (`darshan-logutils.h:55-59`) and consumes in `darshan_log_put_namehash` (`darshan-logutils.c:706-744`). darshan's own deserializer builds this hash inline (`darshan-logutils.c:1030-1049`). **Fix:** build the `darshan_name_record_ref` hash directly (thread `struct darshan_name_record_ref **name_hash` through `read_events`/`write_log`/`main`), keeping `add_name`'s empty-name guard (:278) and malloc-null checks. Deletes one struct, two functions, and an entire hash pass. No public "add name record" helper exists — building the ref directly is the correct reuse. **LOC: −1 struct, −2 functions, ~−40 net.** This also makes RU-cut (`:402` over-allocation) moot.

### RU3 — `expected_record_size` partly duplicates a real darshan accessor
`darshan-util/darshan-mofka-reconstruct.c:262-273` *(PARTLY — finding's "no size API" claim REFUTED)*

The finding claimed darshan has no record-size accessor. **That is wrong:** `struct darshan_mod_logutil_funcs` has `int (*log_sizeof_record)(void *rec)` (`darshan-logutils.h:160-161`), registered for POSIX (`darshan-posix-logutils.c:70`), STDIO, and MPIIO. Since the reconstructor already dereferences `mod_logutils[]` (:601), the switch can be reduced to `mod_logutils[mod_id]->log_sizeof_record(NULL)` for those three, with a `sizeof()` fallback **only** for H5F/H5D, which do *not* register the accessor (`darshan-hdf5-logutils.c:65-83`). So: partial reuse, not full elimination. **Ties the size to darshan's contract for 3 of 5 modules.**

### RU4 — `lib_ver=unknown` throws away recoverable provenance
`darshan-util/darshan-mofka-reconstruct.c:551-553` → reuse `darshan_log_get_lib_version()`

`darshan_log_get_lib_version()` exists (`darshan-logutils.h:218`, def `darshan-logutils.c:934-937`, returns `PACKAGE_VERSION`) and is already in scope. Add `reconstructor_ver=%s` alongside the existing keys so the log records which util built it. Keep `lib_ver=unknown` (the *runtime* version is genuinely unrecoverable, and pydarshan reads the `lib_ver` key at `summary.py:267`). Fits easily in the 1024-byte metadata buffer.

### `darshan_core_fprintf` idiom check — CORRECT as-is, do not touch
The reconstructor uses plain `fprintf(stderr,…)` (`reconstruct.c:70,471,574,604,652`); the connector uses `darshan_core_fprintf` (`darshan-mofka.c:58,119,230,250`). This is **right**: `darshan_core_fprintf` is declared only in the runtime header (`darshan-runtime/lib/darshan.h:448`, def `darshan-core.c:2754`) and is absent from `libdarshan-util` (grep confirms zero hits under `darshan-util/`). Calling it from the reconstructor would fail to link. Plain-fprintf is the util convention (`darshan-merge.c` 30×, `darshan-convert.c` 19×, `darshan-parser.c` 15×). **No change.**

### Reuse targets that DON'T exist — hand-rolling is justified, keep it
- **No C JSON escaper, no hex encoder, no JSON parser, no hex decoder anywhere in the tree** (whole-tree grep for `0123456789abcdef`/`%02x`/`bin2hex`/`json_escape`/cjson/jansson/parson/yajl returns only the two mofka files + a CI yaml). So `json_escape_into`/`hex_into` (connector) and `json_get_*`/`hex_value`/`decode_hex` (reconstructor) are **not** reinventing a darshan helper. Recommend a one-line comment on each noting darshan provides no such helper, so a future reviewer doesn't hunt.
- **`uthash` include path is correct** (`reconstruct.c:24` matches `darshan-merge.c:12`/`parser.c:23`/`diff.c:17`; vendored via `extern/uthash-1.9.2.tar.bz2`, extracted by `Makefile.am:92-97`; its absence from a clean checkout is expected). Build wiring present (`Makefile.am:64,89-90`). **No change.**
- **The write sequence** `create→put_job→put_exe→put_mounts→put_namehash→log_put_record` is the correct, standard idiom (matches `darshan-merge.c:355-391,477`, `darshan-convert.c:336-417,477`). No pre-existing tool reconstructs a `.darshan` from serialized records. **Keep.** *(The finding's aside that the write-loop guard "already replicates merge.c" is refuted — that's the C7 OOB; merge/convert bound by `DARSHAN_KNOWN_MODULE_COUNT`.)*

---

## 4. Cut-and-improve (net-negative diff, raises value)

| # | Location | What to cut | Why it's safe | ~LOC |
|---|----------|-------------|---------------|------|
| K1 | `darshan-mofka.c:27-29` + `:264-266` + `darshan-mofka.h:14-18` | Dead `struct darshanMofkaConnector mC` / `mofka_lib` (both branches + header typedef/extern) | `grep '\bmC\b'` finds only 2 defs + 1 extern, **never read**. It's a copy of the LDMS `dC.ldms_lib` gate (which *is* read 112×, e.g. `darshan-posix.c:256`) that was never wired. Removes an exported symbol. | −8 |
| K2 | `darshan-mofka.c:262-293` | `!HAVE_MOFKA` stub bodies (esp. the `send` stub with 16 `(void)` casts) | No in-tree caller: `initialize`/`finalize` are `#ifdef HAVE_MOFKA`-guarded (`darshan-core.c:356-359,772-773`), `send` routes through `DARSHAN_MOFKA_SEND` which is `do{}while(0)` when `!HAVE_MOFKA` (`darshan-mofka.h:45`). Keep only if an out-of-tree ABI consumer needs the symbols — if so, say so in a comment. | −20 |
| K3 | `reconstruct.c:293-303` + 51-55 + 449-457 | `struct rank_ent`, `add_rank`, `free_ranks`, hash threading → single `int64_t max_rank` | **Same change as C2.** The rank hash exists *only* to feed `HASH_CNT` at :566, which is the bug. Scalar `max_rank+1` is correct *and* leaner. | −25 |
| K4 | `reconstruct.c:73-80` | `xstrndup` — dead (0 callers tree-wide) | `_GNU_SOURCE` at :13 exposes glibc `strndup` if ever needed. | −8 |
| K5 | `reconstruct.c:92,103,137` | Dead local `s` in `json_get_string` (assigned :103, only silenced by `(void)s` :137) | Never read; removing it drops the `(void)` cast. | −3 |
| K6 | `darshan-mofka.c:45-46` | `MOFKA_BATCH_ADAPTIVE`/`MOFKA_BATCH_SIZE` macros → inline `size_t batch_size = 0 /* adaptive */` | Both collapse to literal 0, used once (:113). (Keep `MOFKA_JSON_BUF` — legitimately used.) | −2 |
| K7 | `reconstruct.c:402` | `sizeof(struct darshan_name_record)+name_len` (16+n) → `sizeof(darshan_record_id)+name_len+1` (9+n) | Over-allocates ~7 B/record vs darshan's own `rec_len` (`darshan-logutils.c:731,1022`). **Moot if RU2 lands.** | 0 |
| K8 | `darshan-mofka.c:55-58` | `mofka_took` calls `getenv("DARSHAN_MOFKA_TIMING")` on **every send** (:234, once per traced I/O event) | Cache once in `initialize` into `static int g_timing`. Removes a per-event environ scan on the path whose purpose is low overhead. *(Do NOT also cache `DARSHAN_MOFKA_VERBOSE` — it's already read once at :153.)* | ~0 |

**Nits worth folding into a cleanup commit (all confirmed):**
- `darshan-mofka.c:66-71` — `json_escape_into` maps control chars `<0x20` → `'?'` while the reconstructor decoder *decodes* `\n\t\r\b\f` (`reconstruct.c:122-126`), so a tab in a filename round-trips to `'?'`. Emit the 5 escapes the decoder understands (widen the guard to `o+3<dstsz`); keep `'?'` for other control bytes — **do NOT emit `\u00XX`**, the decoder has no `\u` case and would produce literal `u00XX`. This lossy-but-valid behavior is *deliberately compatible* with the decoder; add a one-line comment saying so.
- `darshan-mofka.c:256-259` — `finalize` never calls `diaspora_*_destroy` on the clean `rc==OK` path (leaks producer/topic/driver handles created at :127/134/143). Header advises leaking **only** on `TIMEOUT` (`diaspora_c.h:121-123`). Destroy on OK (reverse order), keep leaking on TIMEOUT (and, defensibly, ERR — the "dead broker may hang exit" rationale applies). Process-exit path so OS reclaims anyway; benefit is valgrind/leak-san cleanliness.
- `reconstruct.c:582` — string literal passed to non-const `darshan_log_put_exe(…, char *)`. Cosmetic; use `char exe[] = "…"` to match `convert.c:377`/`merge.c:372`. (No warning is actually emitted — `-Wwrite-strings` isn't in CFLAGS.)
- `reconstruct.c:1-8` — **missing the standard darshan-util copyright header** (`convert.c:1-5`/`parser.c:1-5` carry it; the connector already does). Prepend it for a clean upstream PR. (Near-universal, not literally every file — `merge.c` lacks one.)
- `darshan-mofka.c:49-52` — `now_ns` ignores `clock_gettime`'s return (uninit `ts` on failure). Matches darshan's own idiom (`darshan.h:410`); **fine to leave as-is**, or add `if(... != 0) return 0;`.

---

## 5. Proposed PR plan (ordered, minimal, scoped to this branch)

### Group A — safe / mechanical (no judgement call; land first)
1. **`cut: remove dead connector state (mC/mofka_lib)`** — K1. Deletes exported symbol + 2 struct copies, 0 behavior change. *Files:* `darshan-mofka.c`, `darshan-mofka.h`.
2. **`cut: drop dead reconstructor helpers`** — K4 (`xstrndup`) + K5 (dead `s`). *Files:* `darshan-mofka-reconstruct.c`.
3. **`cut: collapse batch-size macros; cache timing flag`** — K6 + K8. *Files:* `darshan-mofka.c`.
4. **`style: add darshan-util copyright header to reconstruct.c`** — §4 nit. *Files:* `darshan-mofka-reconstruct.c`.
5. **`reuse: record reconstructor version via darshan_log_get_lib_version()`** — RU4. *Files:* `darshan-mofka-reconstruct.c`.

### Group B — correctness fixes (review carefully, but not controversial)
6. **`fix: write module records in ascending module-id order`** — **C1, the blocker.** Also fixes C7's OOB guard. *Files:* `darshan-mofka-reconstruct.c:596-608`.
7. **`fix: decode \uXXXX escapes in json_get_string`** — C3. *Files:* `darshan-mofka-reconstruct.c:114-128`.
8. **`fix: nprocs = max_rank+1; replace rank hash with scalar`** — C2 **+** K3 (one change). Fixes the parser assert/OOB. *Files:* `darshan-mofka-reconstruct.c`.
9. **`fix: decode_hex rejects oversized payloads`** — C4, one line. *Files:* `darshan-mofka-reconstruct.c:231-232`.
10. **`robustness: guard connector against silent truncation`** — C8 (`rec_hex` size guard) + C9 (`gf_esc` group-file) + `:227` event-too-large diagnostic. *Files:* `darshan-mofka.c`.
11. **`robustness: validate connector env sizes`** — C6 (`parse_env_size`). *Files:* `darshan-mofka.c`.

### Group C — reuse refactors (net-LOC-negative; slightly larger diffs)
12. **`reuse: module_name_to_id loops over darshan_module_names[]`** — RU1 (keep the `"MPIIO"` alias!). *Files:* `darshan-mofka-reconstruct.c:251-260`.
13. **`reuse: build darshan_name_record_ref hash directly (drop double-hash)`** — RU2 (subsumes K7). Largest diff; threads a param through 3 functions. *Files:* `darshan-mofka-reconstruct.c`.
14. **`reuse: use log_sizeof_record for POSIX/STDIO/MPIIO sizes`** — RU3 (fallback `sizeof` for H5F/H5D). *Files:* `darshan-mofka-reconstruct.c:262-273`.

### Group D — needs-a-decision (don't merge blindly)
- **C10 `schema_version`:** decide *(a)* wire it through the reconstructor with a shared `#define` (a few lines, real forward-compat) vs *(b)* downgrade to an advisory comment. Recommend (a).
- **C5 `json_find_key`:** decide *(a)* document the flat/escaped input contract (sufficient for this PR) vs *(b)* make lookups depth/quote-aware. Recommend (a) now, (b) only if the reader is ever repositioned as a general JSONL tool.
- **`finalize` handle destroy (§4):** decide whether to destroy on `ERR` as well as `OK`, or leak on both `ERR`+`TIMEOUT`. Recommend leak on ERR+TIMEOUT, destroy on OK.
- **`--show-incomplete` UX (§2, `reconstruct.c:652`):** confirm you want the partial-flag behavior kept (recommended — it's honest) and just surface the required flag in the success message.
- **K2 `!HAVE_MOFKA` stubs:** decide whether any out-of-tree linker consumes these symbols. If not, delete; if yes, keep with a comment.

---

## 6. Coverage statement

Every line of both files was reviewed; the six review regions and their per-line dispositions:

- **Connector `darshan-mofka.c:1-159`** — all examined. Confirmed benign: license/config/header ordering (1-20, matches `darshan-dxt.c:7-12`), `HAVE_MOFKA` guard + diaspora include (22-25), globals (31-42), init casts `pid`/`uid`/`jobid` (96-107, verified against `darshan.h`/`darshan-log-format.h`), gethostname NUL-termination (98-100), `darshan_core_wtime_absolute` (102), driver/topic create+error paths (118-140, signatures match `diaspora_c.h:71-92`), verbose/timing (153-158).
- **Connector `darshan-mofka.c:160-294`** — all examined. **All 26 snprintf format specifiers hand-verified against their 26 args (:201-225) — exact match, no uninitialized `t0` on any `goto out` path.** Confirmed benign: send plumbing (161-200), push+out (229-236), flush handling (246-254, matches `diaspora_c.h` contract).
- **Reconstructor `:1-260`** — all examined. Confirmed clean: `hex_value` (214-220), numeric getters `json_get_i64/u64/double` (142-212, correctly guard `end==p` and skip the needle's colon).
- **Reconstructor `:261-530`** — all examined. Confirmed clean (no finding): `expected_record_size` switch (262-273), `add_record` key-memset+buf-ownership (313-351, no leak on any path), `update_job_info` first-wins + min/max tracking (353-389), all `free_*` (416-457), `read_events` buf lifecycle (459-530, no leak).
- **Reconstructor `:531-661`** — all examined. Confirmed correct: F_*_TIME counters round-trip verbatim (no byteswap/transform, `darshan-posix-logutils.c:297-308`), region write order JOB/NAME/mods (`darshan-logutils.c:35-37`), `fill_job` nsec math + metadata bounds.
- **Whole-tree reuse scan** — answered all 6 reuse questions with darshan `file:line` proof (or documented absence).

**Explicitly left as-is (with reason):**
- Hand-rolled `json_escape_into`/`hex_into`/`json_get_*`/`hex_value`/`decode_hex` — **no darshan equivalent exists** (verified by grep); hand-rolling is the correct choice for this flat, single-producer schema and avoids a new dependency.
- `darshan_core_fprintf` (connector) vs plain `fprintf` (reconstructor) split — **correct**; the symbol is runtime-only and would not link into `libdarshan-util`.
- `uthash` include path and build wiring — **correct and consistent** with sibling tools.
- The `create→put_job→…→log_put_record` write sequence — **correct reuse** of darshan's writer API; only its internal ordering (C1) and index guard (C7) need fixing.
- `now_ns` unchecked `clock_gettime` (§4) — acceptable, matches darshan's house idiom.

**One raised issue did NOT survive verification** (of 38): the sub-claim that the write-loop guard already matches `merge.c` — refuted; it's the C7 OOB and is a real defect, folded into C1/C7 above.
