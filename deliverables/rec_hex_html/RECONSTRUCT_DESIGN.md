# Rich reconstruct: near-native pydarshan report from the Mofka stream

## Problem

Fix 2 removed `rec_hex` (the entire native record struct hex-encoded into every
event, ~1254 B/event). That was the right call for payload, but it left the
*stream-reconstructed* pydarshan report thin: with no `rec_hex` in the stream, the
reconstructor's `decode_hex()` returns NULL, so it emits **only heatmap records** --
no per-file POSIX/STDIO counter records at all. Hence the streamed report lost Access
Sizes, I/O Cost, counts, etc. (native report is unaffected -- it comes from the native
`.darshan` log, not the stream).

## Is a near-native report theoretically possible? YES.

Verified in the runtime source:

- Every `darshan_mofka_connector_send()` callsite -- including `close` -- already
  passes `(const void*)file_rec, sizeof(*file_rec)` (darshan-posix.c:353/423,
  darshan-stdio.c). The connector *holds the full record* at emit time. `rec_hex` was
  just blindly hex-dumping it.
- The record struct is uniform and flat:
  `struct darshan_{posix,stdio}_file = { base_rec; int64 counters[N]; double fcounters[M]; }`.
- All the report-relevant counters are populated **incrementally, per op**, so they
  are correct at close:
  - size histograms `POSIX_SIZE_*` via `DARSHAN_BUCKET_INC` (darshan-posix.c:319)
  - top-4 access sizes + strides via `DARSHAN_UPDATE_COMMON_VAL_COUNTERS`
    (darshan-posix.c:322-331) -- these write straight into
    `counters[POSIX_ACCESS1_ACCESS]` etc. per op
  - byte counts, max byte, seq/consec, R/W switches, alignment, all `POSIX_F_*` timers
  - `posix_finalize_file_records()` (darshan-posix.c:2188) only frees the tree roots;
    it writes NO additional counters.

**Boundary (the only thing a per-process snapshot cannot reproduce):** the cross-rank
*shared-file* aggregate record (`base_rec.rank = -1`) built in
`posix_record_reduction_op` / `posix_shared_record_variance` at MPI redux --
fastest/slowest rank, variance-across-ranks. Those are computed by reducing across
ranks, which a per-process reconstructor never sees. Per-process records are complete;
the shared-file rollup is the honest gap. (DXT is a separate opt-in trace module, out
of scope here -- rebuildable by accumulating stream ops if ever wanted.)

## Design

### Serialization: counter arrays as JSON numbers, not a hex struct

On the terminal op for a record (`close`; also any op carries current state), the
connector serializes the two arrays in **enum order**:

    "counters":[<int64>,...], "fcounters":[<double>,...]

Both the connector and the reconstructor `#include` the same
`darshan-{posix,stdio}-log-format.h`, so array index == enum index on both sides by
construction. This is *more* robust than `rec_hex` (raw struct bytes were
endian/padding-sensitive) and human-readable.

Cost control: one snapshot per record **at close**, not per op. The per-op events stay
slim (heatmap). The reconstructor already does max-seq / last-writer-wins dedup, so the
close snapshot (highest seq for that record) wins. Net streaming payload stays ~flat vs
Fix 2 for I/O-heavy workloads (one fat close event per file vs many slim op events).

### Reconstructor: build the struct from the arrays

Replace the `decode_hex(rec_hex)` path with: allocate `expected_record_size(mod_id)`,
set `base_rec.id/rank`, and copy the parsed `counters[]`/`fcounters[]` into the struct.
Keep a `rec_hex` fallback so *old* logs still reconstruct. Heatmap path unchanged.

## Validation plan

Rebuild connector .so + reconstruct util, run a small streaming job, reconstruct the
per-process log, render pydarshan HTML, and diff sections against the native report.
Target: Access Sizes + I/O Cost + Data Transfer counts + Heat Map all present and
numerically matching the native per-process record (shared-file rollup excepted).
