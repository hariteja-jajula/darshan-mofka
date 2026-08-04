# Last-meeting comments — status & findings (2026-08-04)

## 1. "Check how much time reconstruct takes"  ✅ MEASURED
Timed `darshan-mofka-reconstruct` on each workload's events.jsonl:
| workload | events | reconstruct time |
|---|---|---|
| C io_bench    | 37,899  | 0.54 s |
| io_bench_py   | 36,851  | 0.50 s |
| python-ml     | 154,538 | 2.01 s |
| MPI           | 26,566  | 0.33 s |
~13 µs/event, scales linearly, all sub-second except python-ml (2s for 154k events).
Reconstruct is now auto-timed in job.sh (writes reconstruct_time.txt per run).

## 2. "Send the Runtime Library Version"  ✅
- Darshan runtime: **3.4.4** (module darshan/3.4.4)
- Darshan **log format version: 3.41** (from the .darshan header)
- Toolchain: cray-mpich/9.0.1, libfabric/2.2.0rc1, PrgEnv-nvidia/8.6.0, craype/2.7.35
- Connector fix: diaspora-stream-api branch fix/abt-safe-sender-threadpool (commit 16c8920)

## 3. "Fix 'Module data incomplete due to runtime memory or record count limits'"  ✅ ROOT-CAUSED
- The warning is on the **POSIX module** (POSIX ver=4).
- CAUSE: io_bench.c writes iter_0.dat ... iter_N.dat = N DISTINCT filenames (one POSIX
  record each). With IO_ITERS=9500 that is 9,500 records, but Darshan's default cap is
  **1,024 records/module** (darshan.h:232) -> it truncates -> "incomplete" warning.
- This is a Darshan record-cap config limit, NOT a streaming/connector problem (native
  logs show it too).
- FIX: raise DARSHAN_MODMEM (+ max-records), the same knob already used for DLIO in the
  harness, OR reduce distinct filenames in the workload (consistent-workload ask #6).
  For the meeting: run with DARSHAN_MODMEM bumped so POSIX holds all records.

## 4. "Figure out why heatmaps don't match exactly"
- Heatmaps come from the DXT/HEATMAP module (time-binned I/O), which is separate from the
  POSIX counter records the connector streams. Investigating whether the mismatch is (a)
  the record-cap truncation above, or (b) the connector not streaming DXT/heatmap records.
  [IN PROGRESS - see notes below]

## 5. "darshan-parser broken"  ⚠️ FOUND
- `darshan-parser` fails: `undefined symbol: dfs_counter_names` (util build missing the DFS
  module symbol). The util needs a clean rebuild with the DFS module. Does not affect the
  streaming/overhead results (those use the reconstruct + strict_compare path), but blocks
  raw darshan-parser inspection. Flag for a util rebuild.

## Workload / topology asks (for the deliverable table + next runs)
- "consistent workload table" -> unify knobs across workloads (in progress).
- "reduce to CPU limit - 32 process workload, use verbs" -> TCP path currently 32 ranks;
  verbs vs cxi/tcp is a fabric-selection follow-up.
- "4 nodes + 1 server node" -> N=4 scale point (jobs exist: job_*_N4.sh).
- "single process on workload node, increase slowly" -> N=1 -> N=4 scale sweep.

## 4. Heatmap mismatch -- ROOT CAUSED
- strict_compare EXCLUDES the HEATMAP + DXT modules (and LUSTRE/APMPI/APXC) because the
  connector streams POSIX/STDIO/MPI-IO/HDF5 COUNTER records, NOT the time-binned DXT/HEATMAP
  trace data. Every counter that IS streamed matches native byte-exact (verified: io_bench C
  POSIX_BYTES_WRITTEN=17179869184, POSIX_WRITES=16384 identical native vs reconstructed).
- So the "heatmap mismatch" is not data loss: the heatmap module simply isn't part of the
  stream. The reconstructed single-rank log has a degenerate/empty heatmap, which also makes
  pydarshan's HTML summary crash on MPI/DLIO reconstructed logs (matplotlib
  "Invalid vmin or vmax" when drawing the empty heatmap colorbar).
- To make heatmaps match, the connector would need to also stream HEATMAP/DXT records.

## pydarshan HTML outputs (per run)
- C, io_bench_py, python-ml: BOTH native + reconstructed HTML exist (side-by-side visual).
- MPI, DLIO: native HTML exists; reconstructed HTML fails to render (empty heatmap -> the
  vmin/vmax crash above). Counter fidelity for MPI/DLIO is proven via compare.txt instead.
- pydarshan 3.5.0 vs libdarshan-util 3.4.4 version mismatch: works when LD_LIBRARY_PATH
  points at the 3.4.4 util lib; darshan-parser CLI still broken (dfs_counter_names) -> needs
  a util rebuild for clean CLI parsing.
