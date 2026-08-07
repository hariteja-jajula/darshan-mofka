# PyDarshan HTML reports: before/after removing `rec_hex` from the stream

python-ml workload, ofi+cxi, one example process (RUN2). Each run produces two
pydarshan HTML reports:

- **native_\*** — rendered from the native `.darshan` log Darshan writes at process
  exit. This log is never affected by streaming, so it is the byte-exact source of
  truth.
- **streamed_\*** — rendered from a `.darshan` reconstructed *from the Mofka stream*.

| File | Log source | `rec_hex` in stream | Report content |
|---|---|---|---|
| `native_with_rechex.html`   | native   | (n/a) | full |
| `native_no_rechex.html`     | native   | (n/a) | full — unchanged |
| `streamed_with_rechex.html` | stream   | present | rich (Access Sizes, I/O Cost, DXT, Heat Map) |
| `streamed_no_rechex.html`   | stream   | removed | telemetry + Heat Map (POSIX/STDIO presence) |

## Takeaways
- **Native reports are identical** with or without `rec_hex` — removing it does not
  touch the native log or its full pydarshan report.
- The **stream-reconstructed** report is intentionally slimmer once `rec_hex` is
  removed: the stream now carries only the fields the heatmap + telemetry use
  (module/op/record_id/file/pid/rank/seq/len/started_at/ended_at), not the entire
  native record struct hex-encoded per event.
- Payload per event dropped ~1634 -> ~380 bytes (-77%) with identical event counts.

Open any file in a browser to view. To render directly on GitHub, prefix the raw
URL with `https://htmlpreview.github.io/?`.
