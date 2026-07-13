#!/usr/bin/env python3
"""
plot_overhead.py -- charts for a darshan->mofka overhead run.

Reads <rundir>/overhead_summary.csv (produced by analyze_overhead.py) plus
<rundir>/progress.log (for reliability), and writes PNGs into the run dir.
Works for the C, Python (io_heavy), and MPI schemas alike -- it groups bars by
`batch` when that column exists, otherwise by `rpc`.

Only dependency: matplotlib (NOT installed in the repo mofka-view python -- see
VISUALIZE.md for a one-line venv).

Usage:
  python plot_overhead.py [<rundir> | <overhead_summary.csv>]   # default: newest run
Outputs (into the run dir): overhead_wall.png, overhead_finalize.png,
  overhead_send.png, overhead_rss.png (C/PY only), reliability.png
"""
import csv
import os
import re
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
RUNS = os.path.join(HERE, "runs")

# --- validated categorical palette (dataviz skill, light mode) ----------------
# CVD-safe (worst adjacent ΔE 24.2); the sub-3:1 slots are relieved by the value
# labels drawn on every bar. Assigned in FIXED order to rpc values (never cycled).
SERIES = ["#2a78d6", "#1baf7a", "#eda100", "#008300", "#4a3aa7", "#e34948"]
INK, SEC, MUTED = "#0b0b0b", "#52514e", "#898781"
GRID, BASE, SURFACE = "#e1e0d9", "#c3c2b7", "#fcfcfb"
GOOD = "#0ca30c"


def find_csv(arg):
    if arg:
        return arg if os.path.isfile(arg) and arg.endswith(".csv") else os.path.join(arg, "overhead_summary.csv")
    cands = []
    for ptr in (".current_PY", ".current_C", ".current_MPI"):
        p = os.path.join(RUNS, ptr)
        if os.path.isfile(p):
            d = open(p).read().strip()
            c = os.path.join(d, "overhead_summary.csv")
            if os.path.isfile(c):
                cands.append(c)
    if not cands:
        sys.exit("no overhead_summary.csv found -- pass a run dir; run analyze_overhead.py first")
    return max(cands, key=os.path.getmtime)


def fnum(x):
    try:
        return float(str(x).replace("+", ""))
    except (TypeError, ValueError):
        return None


def style(ax, title, ylabel, logy=False):
    ax.set_facecolor(SURFACE)
    ax.set_title(title, color=INK, fontsize=12, fontweight="bold", loc="left", pad=10)
    ax.set_ylabel(ylabel, color=SEC, fontsize=10)
    if logy:
        ax.set_yscale("log")
    ax.grid(axis="y", color=GRID, linewidth=0.8, zorder=0)
    ax.set_axisbelow(True)
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    ax.spines["bottom"].set_color(BASE)
    ax.tick_params(colors=MUTED, labelsize=9, length=0)


def grouped_bar(rows, value_key, title, ylabel, outpng, logy=False, fmt="{:.2f}", pct_key=None):
    """x = batch groups (or rpc if no batch), series = rpc (fixed color order)."""
    has_batch = "batch" in rows[0]
    xs_key, ser_key = ("batch", "rpc") if has_batch else ("rpc", None)
    x_vals = sorted({r[xs_key] for r in rows}, key=lambda v: (fnum(v) if fnum(v) is not None else 1e18))
    ser_vals = sorted({r[ser_key] for r in rows}, key=lambda v: (fnum(v) if fnum(v) is not None else 1e18)) if ser_key else [None]

    fig, ax = plt.subplots(figsize=(max(6, 1.6 * len(x_vals) + 2), 4.2), dpi=140)
    fig.patch.set_facecolor(SURFACE)
    n = len(ser_vals)
    full = 0.8
    bw = full / n
    for si, sv in enumerate(ser_vals):
        vals, xpos = [], []
        for xi, xv in enumerate(x_vals):
            match = [r for r in rows if r[xs_key] == xv and (ser_key is None or r[ser_key] == sv)]
            v = fnum(match[0][value_key]) if match else None
            if v is None:
                continue
            v = abs(v)
            vals.append(v)
            xpos.append(xi - full / 2 + bw * (si + 0.5))
        bars = ax.bar(xpos, vals, width=bw * 0.9, color=SERIES[si % len(SERIES)],
                      zorder=3, label=(f"rpc={sv}" if ser_key else None))
        # direct value labels (relief rule for the sub-3:1 hues + readability)
        for b, v in zip(bars, vals):
            ax.annotate(fmt.format(v), (b.get_x() + b.get_width() / 2, v),
                        xytext=(0, 3), textcoords="offset points", ha="center",
                        va="bottom", fontsize=7.5, color=SEC,
                        fontfamily="monospace")
    ax.set_xticks(range(len(x_vals)))
    ax.set_xticklabels([f"{xs_key}={v}" for v in x_vals])
    style(ax, title, ylabel, logy=logy)
    if ser_key and n > 1:
        leg = ax.legend(frameon=False, fontsize=9, loc="upper left")
        for t in leg.get_texts():
            t.set_color(INK)  # labelcolor kwarg needs mpl>=3.3; set manually for portability
    fig.tight_layout()
    fig.savefig(outpng, facecolor=SURFACE, bbox_inches="tight")
    plt.close(fig)
    print(f"[wrote] {outpng}")


def reliability_plot(rundir, outpng):
    prog = os.path.join(rundir, "progress.log")
    if not os.path.isfile(prog):
        return
    pat = re.compile(r"rpc=(\S+)\s+capture:\s+consumed\s+(\d+).*?sent=(\d+)", re.I)
    got = {}
    for line in open(prog):
        m = pat.search(line)
        if m:
            got[m.group(1)] = (int(m.group(2)), int(m.group(3)))
    if not got:
        return
    rpcs = sorted(got, key=lambda v: (fnum(v) if fnum(v) is not None else 1e18))
    consumed = [got[r][0] for r in rpcs]
    sent = [got[r][1] for r in rpcs]
    fig, ax = plt.subplots(figsize=(max(5, 1.4 * len(rpcs) + 2), 4.2), dpi=140)
    fig.patch.set_facecolor(SURFACE)
    xi = range(len(rpcs))
    ax.bar([x - 0.2 for x in xi], sent, width=0.36, color=MUTED, zorder=3, label="sent")
    ax.bar([x + 0.2 for x in xi], consumed, width=0.36, color=GOOD, zorder=3, label="consumed")
    for x, s, c in zip(xi, sent, consumed):
        pct = 100.0 * c / s if s else 0
        ax.annotate(f"{pct:.0f}%", (x + 0.2, c), xytext=(0, 3), textcoords="offset points",
                    ha="center", va="bottom", fontsize=8, color=SEC, fontfamily="monospace")
    ax.set_xticks(list(xi))
    ax.set_xticklabels([f"rpc={r}" for r in rpcs])
    style(ax, "Delivery reliability: consumed vs sent", "events", logy=False)
    leg = ax.legend(frameon=False, fontsize=9, loc="upper right")
    for t in leg.get_texts():
        t.set_color(INK)
    fig.tight_layout()
    fig.savefig(outpng, facecolor=SURFACE, bbox_inches="tight")
    plt.close(fig)
    print(f"[wrote] {outpng}")


def main():
    csvp = find_csv(sys.argv[1] if len(sys.argv) > 1 else None)
    rundir = os.path.dirname(os.path.abspath(csvp))
    rows = list(csv.DictReader(open(csvp, newline="")))
    if not rows:
        sys.exit(f"{csvp}: no rows")
    dcol = next((c for c in rows[0] if c.startswith("d_wall_vs_")), None)

    grouped_bar(rows, dcol or "wall_s",
                "Streaming overhead (wall vs native)", "seconds  (log)",
                os.path.join(rundir, "overhead_wall.png"), logy=True, fmt="{:.2f}")
    grouped_bar(rows, "finalize_ms",
                "Finalize / drain time", "milliseconds  (log)",
                os.path.join(rundir, "overhead_finalize.png"), logy=True, fmt="{:.0f}")
    grouped_bar(rows, "send_avg_us",
                "Per-op send latency (fire-and-forget)", "microseconds",
                os.path.join(rundir, "overhead_send.png"), logy=False, fmt="{:.1f}")
    if "rss_mb" in rows[0] and any(fnum(r.get("rss_mb")) for r in rows):
        grouped_bar(rows, "rss_mb",
                    "Broker resident memory", "MB",
                    os.path.join(rundir, "overhead_rss.png"), logy=False, fmt="{:.0f}")
    reliability_plot(rundir, os.path.join(rundir, "reliability.png"))
    print(f"\n[done] charts in {rundir}")


if __name__ == "__main__":
    main()
