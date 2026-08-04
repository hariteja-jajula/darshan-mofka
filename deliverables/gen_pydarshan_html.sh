#!/bin/bash
# gen_pydarshan_html.sh -- regenerate pydarshan summary HTML for the native and
# reconstructed .darshan of each PAPER_* streaming_rep1 run. Writes into each run dir.
set -uo pipefail
R="/eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight"
export LD_LIBRARY_PATH="$R/darshan/darshan-util/install/lib:${LD_LIBRARY_PATH:-}"
PY="$R/install/_venv/bin/python3"
for wl in PAPER_iobench PAPER_iobenchpy PAPER_pythonml PAPER_mpi PAPER_dlio; do
  d="$R/results/$wl/streaming_rep1/RUN1"
  [ -d "$d" ] || { echo "$wl: no run dir"; continue; }
  nat=$(ls "$d"/native/*.darshan 2>/dev/null | head -1)
  rec=$(ls "$d"/streamed/*.darshan 2>/dev/null | head -1)
  echo "=== $wl ==="
  if [ -n "$nat" ]; then
    cp "$nat" "$d/example_native.darshan"
    ( cd "$d" && "$PY" -m darshan summary example_native.darshan >/dev/null 2>&1 ) \
      && echo "  native  -> $d/example_native_report.html" || echo "  native  FAILED"
  fi
  if [ -n "$rec" ]; then
    cp "$rec" "$d/example_streamed.darshan"
    ( cd "$d" && "$PY" -m darshan summary example_streamed.darshan >/dev/null 2>&1 ) \
      && echo "  streamed-> $d/example_streamed_report.html" || echo "  streamed FAILED"
  fi
done
