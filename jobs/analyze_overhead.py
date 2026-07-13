#!/usr/bin/env python3
"""
analyze_overhead.py -- turn a run's results.csv into the OVERHEAD table.

The overhead study emits one row per (mode, knobs, rep) into results.csv. The
raw table is fine for auditing but the *result* people want is the per-op /
flush / wall cost averaged over reps, plus the delta of streaming (mofka) over
native darshan and over the bare app (none). That delta cannot live in the C
workload (it only sees its own single run) -- it is a cross-row reduction, so
it lives here.

Handles BOTH schemas automatically (detected from the CSV header):
  C  (single-node): mode,rpc_threads,batch,max_batches,rep,events,init_ms,
                    send_avg_us,send_p50_us,send_p99_us,finalize_ms,wall_s,
                    broker_rss_mb,rc
  MPI (multi-node): mode,rpc,ranks,rep,events,send_avg_us,init_ms,finalize_ms,wall_s

Usage:
  python3 jobs/analyze_overhead.py                     # newest run (via .current_C/.current_MPI)
  python3 jobs/analyze_overhead.py <run_dir|results.csv>
  python3 jobs/analyze_overhead.py <path> --md         # also write SUMMARY_AUTO.md next to the csv
Outputs: prints the tables to stdout and writes overhead_summary.csv into the run dir
(and SUMMARY_AUTO.md with --md).
"""
import csv
import glob
import json
import os
import sys
from statistics import mean, pstdev

HERE = os.path.dirname(os.path.abspath(__file__))
RUNS = os.path.join(HERE, "runs")


def event_types(rundir):
    """Count captured events by op-type and module from a captured events/*.jsonl.
    Types are a property of the workload (same every cell), so one file suffices."""
    files = [f for f in glob.glob(os.path.join(rundir, "events", "*.jsonl")) if os.path.getsize(f) > 0]
    if not files:
        return None
    biggest = max(files, key=os.path.getsize)
    ops, mods, total = {}, {}, 0
    with open(biggest) as fh:
        for ln in fh:
            try:
                m = json.loads(ln)
            except ValueError:
                continue
            ops[m.get("op", "?")] = ops.get(m.get("op", "?"), 0) + 1
            mods[m.get("module", "?")] = mods.get(m.get("module", "?"), 0) + 1
            total += 1
    return {"ops": sorted(ops.items(), key=lambda kv: -kv[1]), "mods": mods,
            "total": total, "file": os.path.basename(biggest)}


def find_csv(arg):
    """Resolve arg (or newest current run) to a results.csv path."""
    if arg:
        if os.path.isdir(arg):
            return os.path.join(arg, "results.csv")
        return arg
    # no arg: pick the most recently modified of the two .current pointers
    cands = []
    for ptr in (".current_C", ".current_MPI"):
        p = os.path.join(RUNS, ptr)
        if os.path.isfile(p):
            d = open(p).read().strip()
            csvp = os.path.join(d, "results.csv")
            if os.path.isfile(csvp):
                cands.append(csvp)
    if not cands:
        sys.exit("no results.csv found: pass a run dir or results.csv path")
    return max(cands, key=os.path.getmtime)


def fnum(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def load(csvp):
    with open(csvp, newline="") as fh:
        rows = list(csv.DictReader(fh))
    if not rows:
        sys.exit(f"{csvp}: no data rows")
    header = set(rows[0].keys())
    kind = "mpi" if "ranks" in header else "c"
    return rows, kind


def agg(cells, col):
    """mean of a numeric column over a list of rows (None-safe)."""
    vals = [fnum(r.get(col)) for r in cells]
    vals = [v for v in vals if v is not None]
    return mean(vals) if vals else 0.0


def std(cells, col):
    vals = [fnum(r.get(col)) for r in cells]
    vals = [v for v in vals if v is not None]
    return pstdev(vals) if len(vals) > 1 else 0.0


def rows_for(rows, mode):
    return [r for r in rows if r.get("mode") == mode]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    csvp = find_csv(args[0] if args else None)
    rundir = os.path.dirname(os.path.abspath(csvp))
    rows, kind = load(csvp)

    none_rows = rows_for(rows, "none")
    native_rows = rows_for(rows, "native")
    mofka_rows = rows_for(rows, "mofka")

    wall_none = agg(none_rows, "wall_s") if none_rows else None
    wall_native = agg(native_rows, "wall_s") if native_rows else None
    # baseline for the delta: prefer native (darshan on, stream off); fall back to none
    base = wall_native if wall_native is not None else wall_none
    base_label = "native" if wall_native is not None else "none"

    # group mofka cells by the swept knobs
    if kind == "c":
        keyf = lambda r: (r.get("batch", "-"), r.get("rpc_threads", "-"))
        knob_hdr = ["batch", "rpc"]
    elif "batch" in rows[0]:                      # MPI with a batch sweep
        keyf = lambda r: (r.get("rpc", "-"), r.get("batch", "-"))
        knob_hdr = ["rpc", "batch"]
    else:                                         # MPI, rpc-only (legacy schema)
        keyf = lambda r: (r.get("rpc", "-"),)
        knob_hdr = ["rpc"]

    keys = sorted(
        {keyf(r) for r in mofka_rows},
        key=lambda k: tuple(fnum(x) if fnum(x) is not None else 1e18 for x in k),
    )

    out = []
    line = out.append
    line(f"# overhead summary  ({os.path.basename(rundir)}, schema={kind})")
    line(f"# source: {csvp}")
    line("")
    line("== baselines (mean wall_s over reps) ==")
    if wall_none is not None:
        line(f"  none   (no darshan)      : {wall_none:.3f} s   (n={len(none_rows)})")
    if wall_native is not None:
        line(f"  native (darshan, no stream): {wall_native:.3f} s   (n={len(native_rows)})")
    if wall_none is not None and wall_native is not None:
        line(f"  instrumentation cost (native - none): {wall_native - wall_none:+.3f} s")
    line("")

    # what darshan actually streamed, broken down by op-type (from a captured jsonl)
    et = event_types(rundir)
    if et:
        line("== event types captured (streamed to mofka) ==")
        line("  by op:  " + "  ".join(f"{op}={cnt}" for op, cnt in et["ops"]))
        mods = ", ".join(f"{m}={c}" for m, c in et["mods"].items())
        line(f"  module: {mods}   (total {et['total']} events in {et['file']})")
        line("")

    # overhead table
    cols = knob_hdr + ["n", "events", "init_ms", "send_avg_us", "finalize_ms", "wall_s", "wall_sd",
                       f"d_wall_vs_{base_label}", "d_pct", "note"]
    if kind == "c":
        cols.insert(cols.index("wall_sd") + 1, "rss_mb")
    line("== mofka streaming overhead (averaged over reps) ==")
    widths = {c: len(c) for c in cols}
    table = []
    summ_csv = [cols]
    for k in keys:
        cells = [r for r in mofka_rows if keyf(r) == k]
        wall = agg(cells, "wall_s")
        rec = dict(zip(knob_hdr, k))
        rec["n"] = str(len(cells))
        rec["events"] = f"{agg(cells, 'events'):.0f}"
        rec["init_ms"] = f"{agg(cells, 'init_ms'):.1f}"
        rec["send_avg_us"] = f"{agg(cells, 'send_avg_us'):.1f}"
        fin = agg(cells, "finalize_ms")
        rec["finalize_ms"] = f"{fin:.1f}"
        rec["wall_s"] = f"{wall:.3f}"
        rec["wall_sd"] = f"{std(cells, 'wall_s'):.3f}"
        if kind == "c":
            rec["rss_mb"] = f"{agg(cells, 'broker_rss_mb'):.0f}"
        if base is not None:
            rec[f"d_wall_vs_{base_label}"] = f"{wall - base:+.3f}"
            rec["d_pct"] = f"{100.0 * (wall - base) / base:+.0f}%" if base > 0 else "-"
        else:
            rec[f"d_wall_vs_{base_label}"] = "-"
            rec["d_pct"] = "-"
        # flag cells whose wall is dominated by the shutdown drain (tiny batch, e.g. batch=1)
        rec["note"] = "drain-bound" if fin >= 4900 else ""
        table.append(rec)
        summ_csv.append([rec.get(c, "") for c in cols])
        for c in cols:
            widths[c] = max(widths[c], len(rec.get(c, "")))

    def fmt(vals):
        return "  ".join(str(v).ljust(widths[c]) for c, v in zip(cols, vals))

    line("  " + fmt(cols))
    line("  " + "  ".join("-" * widths[c] for c in cols))
    for rec in table:
        line("  " + fmt([rec.get(c, "") for c in cols]))
    line("")
    line(f"  delta is streaming wall MINUS the {base_label} baseline; "
         f"'drain-bound' = wall dominated by the shutdown finalize drain (large for tiny batch, e.g. batch=1).")

    text = "\n".join(out)
    print(text)

    # write machine-readable summary next to the csv
    outcsv = os.path.join(rundir, "overhead_summary.csv")
    with open(outcsv, "w", newline="") as fh:
        csv.writer(fh).writerows(summ_csv)
    print(f"\n[wrote] {outcsv}")

    if "--md" in flags:
        mdp = os.path.join(rundir, "SUMMARY_AUTO.md")
        with open(mdp, "w") as fh:
            fh.write("```\n" + text + "\n```\n")
        print(f"[wrote] {mdp}")


if __name__ == "__main__":
    main()
