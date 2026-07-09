# Reconstruction feasibility + minimal-LOC plan

Verified 2026-07-09 on Bebop (gcc 8, shared /home FS). No connector/source changed —
Phase 0 used only shipped tools.

## STATUS: Milestone 1 DONE ✅ (branch `mofka-reconstructor`)

`darshan-util/darshan-reconstruct.c` written + wired into `Makefile.am` (builds via `make`).
Two subcommands: `dump` (emitter/mofka stand-in) and `build` (the reconstructor: dedup
latest per (module,record_id) → write valid `.darshan` via libdarshan-util).

Round-trip on a real io_mpi log: **RECONSTRUCTED == ORIGINAL** — 25422 record lines,
all modules (POSIX 283, STDIO 10, HEATMAP 2). Bugs fixed: HEATMAP realloc buffer;
HEATMAP has no `log_sizeof_record` (added its size formula).

Not yet: dedup stress test (conflicting snapshots), crash test (T3), mofka input +
runtime emitter (the real step 2). Build is on Bebop; rebuild darshan-util on Improv.

## STATUS: Phase 0 PROVEN ✅

Built `darshan-util` 3.5.0 (was never built — the runtime build only configured
`darshan-runtime`). Produced: `darshan-parser`, `darshan-convert`, `darshan-diff`,
`libdarshan-util.so`/`.a` + headers, in `darshan/darshan-util/_build_util/`.

| Test | Result |
|---|---|
| **T0.1** parse a real reference `.darshan` | OK — contains **POSIX + STDIO + HEATMAP** |
| **T0.2** round-trip (`darshan-convert` read→write→re-parse, diff records) | **IDENTICAL** — libdarshan-util write path is lossless |
| **T0.3** record size | **POSIX = 720 B binary/record** (16 base + 70·8 + 18·8) |

Key finding: the `.darshan` file has **3 modules**, but our connector streams **POSIX only**.
To reconstruct ~98% we must stream STDIO + HEATMAP records too.

## Build commands (redo on Improv where you actually run)

```bash
cd ~/internship/darshan/darshan-util
autoreconf -fi
mkdir -p _build_util && cd _build_util
../configure --prefix=$PWD/../../../darshan-util-install
make -j && make install     # install optional; binaries run from _build_util via libtool
```

## The reconstructor recipe (= darshan-convert.c, input replaced by stream)

```
darshan_log_create(out, comp_type, partial_flag)
darshan_log_put_job(out, &job)
darshan_log_put_exe(out, exe_string)
darshan_log_put_mounts(out, mnt_array, n)
darshan_log_put_namehash(out, name_hash)          # record_id -> path
for each module m: for each record: mod_logutils[m]->log_put_record(out, rec_buf)
darshan_log_close(out)
```
The ONLY change vs darshan-convert: records come from the latest streamed snapshot
per (module, record_id) instead of `log_get_record(in)`.

## Minimal line-of-code plan

| Step | ~LOC | Where | Needs go-ahead? | Status |
|---|---|---|---|---|
| darshan-util build + T0.1/T0.2/T0.3 | 0 (shipped tools) | — | no | ✅ done |
| **P1** dump live record | ~12 | `darshan-posix.c` close site: `fwrite(&rec_ref->file_rec, sizeof(struct darshan_posix_file), 1, f)` → `/tmp/snap.$pid` | yes (touches source) | todo |
| **T1.2** fidelity check | ~40 | standalone C: read snaps → `log_put_record` → parse → diff RECORD lines vs native | no | todo |
| **R1** reconstructor | ~150–200 | clone `darshan-convert.c`; input = latest snapshot per (mod,rec_id) | yes | todo |
| **T3** crash harness | ~15 (shell) | run io_test under darshan, `kill -9` pre-exit; confirm NO native log; reconstruct from snaps | no | todo |
| **T5** overhead proxies | ~40 | microbench uthash lookup + serialize-720B; run `server/test-push` at 1 KB | no | todo |

Insight: **P1 + T1.2 (~50 LOC) already exercises the full live-read → write → verify path** —
validating the design is ~80% of building the reconstructor. R1 is that same code, hardened,
with stream input instead of a file.

## Commands to run the remaining tests (once P1 is in)

```bash
DUTIL=~/internship/darshan/darshan-util/_build_util
REF=$(ls -t ~/internship/darshan-logs/2026/*/*/*.darshan | head -1)

# T0.x (reproduce anytime, no code):
"$DUTIL/darshan-parser" "$REF" | grep -vE '^#' | awk '{print $1}' | sort | uniq -c
"$DUTIL/darshan-convert" "$REF" /tmp/rt.darshan
diff <("$DUTIL/darshan-parser" "$REF"        | grep -vE '^#') \
     <("$DUTIL/darshan-parser" /tmp/rt.darshan | grep -vE '^#') && echo "round-trip OK"

# T3 crash (after P1 dumps /tmp/snap.$pid):
LD_PRELOAD=$(cd ~/internship && server/env.sh >/dev/null 2>&1; echo)  # set env, then:
#   run io_test, kill -9 before it exits, confirm no darshan-logs entry, then reconstruct.
```

## Notes / caveats
- Built on Bebop (gcc 8); rebuild on Improv for the machine you run on.
- The ~2% gap = cross-rank shared-record reduction (only happens at MPI_Finalize) + byte-exact layout.
- STDIO/HEATMAP have their own struct sizes (smaller than POSIX 720 B); the writer already
  supports them (proven by T0.2, which round-tripped all three).
