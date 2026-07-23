# results

Each run of `job.sh` creates a new folder here named after the workload and the
time it ran, for example `c_20260723_014500/`. The folder holds everything that
run produced, so you can look back at any run later.

Inside each folder:

- `events.jsonl` — the Darshan events that were streamed, one per line.
- `partial.darshan` — the log rebuilt from those events.
- `native.darshan` — the real Darshan log the run also wrote, for comparison.
- `compare.txt` — whether the rebuilt log matches the real one (PASS or MISMATCH).
- `summary.txt` — a count of the modules and operations that were captured.
- `overhead.csv` — timing numbers, when the run is part of an overhead study.
- an HTML report from pydarshan, when a native log was available.

These folders are not checked into git.
