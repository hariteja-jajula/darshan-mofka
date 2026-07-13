# Visualizing the darshan → mofka overhead results

Every overhead run (`overhead_C`, `overhead_PY`, `overhead_MPI`) drops its output
into `jobs/runs/<UTC-STAMP>/`. This is how to read and plot it.

## TL;DR

```bash
# no plotting — just the computed table
cat jobs/runs/<STAMP>/SUMMARY_AUTO.md

# 5 PNG charts into the run dir (system python3 already has matplotlib)
python3 jobs/plot_overhead.py jobs/runs/<STAMP>
#   ...or with no arg it uses the newest run (via .current_PY/_C/_MPI)
```

---

## 1. What each run produces (the files you'll see)

In `jobs/runs/<STAMP>/`:

| File | What it is |
|---|---|
| `results.csv` | **raw** table — one row per (mode, knobs, rep) |
| `results.txt` | same, column-aligned for eyeballing |
| `overhead_summary.csv` | **computed** table — averaged over reps + `mofka − native` deltas (from `analyze_overhead.py`) |
| `SUMMARY_AUTO.md` | the computed table as pretty text (paste into notes/paper) |
| `progress.log` | timestamped run log incl. the `consumed … sent=…` reliability lines |
| `events/rpc<N>.jsonl` | every event the consumer actually drained (reliability record) |
| `events/rpc<N>.count` | `captured <N>` — consumed count per broker |
| `overhead_*.png`, `reliability.png` | charts, once you run `plot_overhead.py` |
| `*.out`, `*.snd`, `bedrock-*.log` | per-cell raw stdout / sorted send latencies / broker logs (debug) |

**The two files you actually want: `SUMMARY_AUTO.md` (numbers) and the PNGs (pictures).**

---

## 2. The two CSV schemas

`analyze_overhead.py` and `plot_overhead.py` auto-detect which one they're reading.

**C / Python** (`overhead_C`, `overhead_PY` — single process):
```
mode, rpc_threads, batch, max_batches, rep, events, init_ms,
send_avg_us, send_p50_us, send_p99_us, finalize_ms, wall_s, broker_rss_mb, rc
```

**MPI** (`overhead_MPI` — 256 producers; has `ranks`, no per-op percentiles/rss):
```
mode, rpc, batch, ranks, rep, events, send_avg_us, init_ms, finalize_ms, wall_s
```
(`batch` column is present only for the batch-sweep MPI run; the earlier rpc-only
run omits it — both are handled.)

`mode` is `none` (no darshan) / `native` (darshan, no stream) / `mofka` (streaming).

---

## 3. Quick views (no plotting)

```bash
S=jobs/runs/<STAMP>

cat $S/SUMMARY_AUTO.md                 # computed overhead table + baselines
column -s, -t $S/results.txt | less    # raw per-cell table
python3 jobs/analyze_overhead.py $S    # regenerate the summary on demand
grep -E 'consumed|sent=' $S/progress.log   # reliability, one line per rpc
```

---

## 4. Plots

**Dependency:** the repo python (`mofka-view`) has no matplotlib, but the system
`python3` does (3.0.3), which is enough. If you're elsewhere:
```bash
python3 -m venv ~/vizenv && ~/vizenv/bin/pip install matplotlib
~/vizenv/bin/python jobs/plot_overhead.py jobs/runs/<STAMP>
```

**Run:**
```bash
python3 jobs/plot_overhead.py jobs/runs/<STAMP>
```
It reads `overhead_summary.csv` + `progress.log` and writes these into the run dir:

| PNG | Shows | Why this form |
|---|---|---|
| `overhead_wall.png` | streaming overhead = **wall − native**, by batch, grouped by rpc | magnitude → grouped bars; **log y** because `batch=1` is ~500× the others |
| `overhead_finalize.png` | finalize/**drain** time (the driver of the overhead) | log y — same reason |
| `overhead_send.png` | per-op **send latency** (avg) | linear — the point is it's *flat* (~30 µs) regardless of batch = fire-and-forget |
| `overhead_rss.png` | broker resident memory (C/PY only) | linear bars |
| `reliability.png` | **consumed vs sent** per rpc, with % delivered | paired bars |

Colors follow a CVD-safe categorical palette (blue/aqua/yellow = rpc 1/4/16, fixed
order); every bar is directly labeled, so it's readable in grayscale/print too.

---

## 5. Where the data lives (this session's runs)

| Study | Run dir | Status |
|---|---|---|
| **C** (`io_test`) | `jobs/runs/20260713T013546Z` | ✅ done — 55 cells |
| **Python** (`io_heavy`) | `jobs/runs/20260713T025341Z` | ✅ done — 55 cells |
| **MPI batch sweep** (`io_mpi`) | `cat jobs/runs/.current_MPI` | ⏳ job 7651778 finishing |
| **MPI rpc-only** (earlier) | `jobs/runs/20260713T013550Z` | ✅ done |

`.current_C` / `.current_PY` / `.current_MPI` always point at the newest run of
each kind.

---

## 6. Comparing the studies

The interesting comparisons the plots let you make side by side:
- **C vs Python** (`20260713T013546Z` vs `20260713T025341Z`): same single-node
  path, different language runtime → the *language* overhead of streaming.
- **single-node vs MPI**: the concurrency dimension — does batching's drain benefit
  survive 256 concurrent producers?

To compare, just plot each run dir and put the `overhead_wall.png` files next to
each other, or diff the three `overhead_summary.csv` files.

---

## 7. Caveat on the reliability numbers

`consumed` is measured by draining the broker **once per rpc, after all reps**, so
for the in-memory partition it reflects the partition's **retained capacity**, not a
per-event loss rate. A `consumed < sent` gap is expected and is *not* "N% of events
were dropped in flight." For a true delivery rate, drain after each rep or size the
partition to hold the full run. The **overhead/timing** numbers (the headline) do
not depend on this.
