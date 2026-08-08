# PyDarshan HTML reports: rec_hex removal, then rich reconstruct

python-ml workload, ofi+cxi, one example process (RUN2). Each report is rendered with
`python -m darshan summary <log>.darshan`:

- **native_\*** — rendered from the native `.darshan` log Darshan writes at process
  exit. This log is never affected by streaming, so it is the byte-exact source of
  truth.
- **streamed_\*** — rendered from a `.darshan` reconstructed *from the Mofka stream*.

## The three stages

| File | Log source | Stream carries | Report content |
|---|---|---|---|
| `native_with_rechex.html`   | native   | (n/a)            | full |
| `native_no_rechex.html`     | native   | (n/a)            | full — unchanged |
| `native_approachA.html`     | native   | (n/a)            | full — unchanged |
| `streamed_with_rechex.html` | stream   | full struct hex  | rich, but ~1634 B/event |
| `streamed_no_rechex.html`   | stream   | slim envelope    | **thin** — heatmap only, no counters |
| `streamed_approachA.html`   | stream   | counter arrays @ close | **rich again** — Access Sizes, Access Pattern, I/O Cost, Common Access, Heat Map |

## Takeaways

1. **Native reports are identical across all three stages** — none of the connector
   changes touch the native log or its full pydarshan report.

2. **`rec_hex` (stage 1 → 2):** the old stream hex-encoded the ENTIRE native record
   struct into *every* event (~1634 B/event). Removing it dropped payload to ~380 B
   (−77%), but left the stream-reconstructed report thin: no per-file POSIX/STDIO
   counter records, so pydarshan lost Access Sizes, Access Pattern, I/O Cost, and the
   counts. (`streamed_no_rechex.html` is only ~168 KB vs ~1.16 MB for the rich ones.)

3. **Approach A (stage 2 → 3):** recover the rich report *without* bringing back the
   per-event hex bloat. The connector snapshots each finished record ONCE, at its
   `close` op, and the drain thread serializes `counters[]`/`fcounters[]` as JSON
   number arrays. Per-op events stay slim (heatmap); exactly one fat event per file
   carries the final counters. The reconstructor rebuilds the native struct from the
   arrays (enum order == array index on both sides, shared log-format headers).

   `streamed_approachA.html` has the SAME section set as `native_approachA.html`
   (Access Sizes, Access Pattern, I/O Cost, Common Access, Heat Map, Operation
   Counts), and counters match the native per-process record — e.g. POSIX_BYTES_READ
   and POSIX_READS are byte-exact (8392671466 / 64322).

## What Approach A still cannot reproduce (honest gaps)

- **Files still open at process exit.** The snapshot is taken at `close`; a file
  flushed by Darshan's shutdown (no close event in the stream) is undercounted. Seen
  as a small write delta (83 vs 100 POSIX_WRITES here).
- **Cross-rank shared-file rollup** (`rank -1`: FASTEST/SLOWEST_RANK, VARIANCE_RANK).
  Built by an MPI reduction across ranks, which a per-process reconstructor never sees.

## Cost

Measured python-ml streaming overhead (warm reps, vs runtimeonly reference):
Fix1 numpy +2.09% · slim/no-rechex +1.47% · **Approach A +2.08%**. Recovering every
dropped panel costs only ~+0.61 pp over the slim envelope — the close-only snapshot
(one fat event per file, not per op) keeps the hot path slim.

Open any file in a browser. To render directly on GitHub, prefix the raw URL with
`https://htmlpreview.github.io/?`. See `RECONSTRUCT_DESIGN.md` for the full design.
