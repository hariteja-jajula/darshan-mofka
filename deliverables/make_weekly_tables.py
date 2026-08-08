#!/usr/bin/env python3
"""deliverables/weekly_overhead_tables.pptx -- title + one slide per (workload x scale).

Ten workload slides (5 workloads x 2 scales: 1 workload node, 4 workload nodes), same
visual style as make_paper_tables.py. Each slide is a table:
  rows:    baseline, runtimeonly, streaming rep1..3
  columns: events, send avg (us), push avg (us), init (s), finalize (s), walltime (s), overhead (s)
Overhead = streaming walltime - baseline walltime (per streaming rep, vs mean baseline).

DATA IS READ LIVE from results/OVH_<wl>_<scale>/<arm>/RUN* via deliverables/overhead_extract.sh.
Only RUN dirs newer than --since (study start) are used, so stale same-tag runs from earlier
weeks are ignored. Run: python3 deliverables/make_weekly_tables.py --since '2026-08-08 16:19:00'
"""
import argparse, os, subprocess, sys, glob

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
EXTRACT = os.path.join(HERE, "overhead_extract.sh")

# (study-tag stem, pretty name, subtitle) -- one row per workload; scale appended per slide.
WORKLOADS = [
    ("iobench",   "io_bench (C)",            "CXI, 1 rank/node, Adaptive batching. Compute-paced (~10 min/rep)."),
    ("iobenchpy", "io_bench_py (Python)",    "CXI, 1 rank/node, Adaptive batching. Pure-Python matmul pacing."),
    ("pythonml",  "python-ml (real ML)",     "CXI, 1 rank/node. NumPy MLP: dataset + train + checkpoint (compute-bound)."),
    ("mpi",       "mpi (collective MPI-IO)", "TCP, 32 ranks/node. MPI unsupported over CXI -> legacy/TCP."),
    ("dlio",      "dlio (DLIO data-gen)",    "TCP, 32 ranks/node. TensorFlow NPZ data-generation."),
]
SCALES = [("1wl", "1 workload node"), ("4wl", "4 workload nodes")]

COLS = ["arm", "events", "send avg (us)", "push avg (us)",
        "init (s)", "finalize (s)", "walltime (s)", "overhead (s)"]


def sh_mtime_after(path, since_epoch):
    try:
        return os.path.getmtime(path) >= since_epoch
    except OSError:
        return False


def run_dirs(tag, scale, arm, since_epoch):
    """Today's RUN dirs for one arm, sorted, filtered by mtime >= study start."""
    base = os.path.join(ROOT, "results", "OVH_%s_%s" % (tag, scale), arm)
    dirs = sorted(glob.glob(os.path.join(base, "RUN*")))
    return [d for d in dirs if sh_mtime_after(d, since_epoch)]


def extract(run_dir):
    """Parse overhead_extract.sh key=val / 'op: k=v' output into a flat dict."""
    try:
        p = subprocess.run(["bash", EXTRACT, run_dir],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True, timeout=120)
        out = p.stdout
    except subprocess.TimeoutExpired:
        return {"_timeout": True}
    d = {}
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("push:") or line.startswith("send:"):
            op = line.split(":", 1)[0]
            for kv in line.split(":", 1)[1].split():
                if "=" in kv:
                    k, v = kv.split("=", 1)
                    d["%s_%s" % (op, k)] = v
        elif line.startswith("VERDICT"):
            d["verdict"] = line
        else:
            for kv in line.split():
                if "=" in kv:
                    k, v = kv.split("=", 1)
                    d[k] = v
    return d


def f(d, key, default=0.0):
    try:
        return float(d.get(key, default))
    except (TypeError, ValueError):
        return default


def collect(tag, scale, since_epoch):
    """Return (rows, meta) for one workload x scale slide.
    rows: list of (arm_label, events, send_avg_us, push_avg_us, init_s, fin_s, wall_s, overhead_s)
    meta: dict with baseline_wall, verdict, missing arms.
    """
    arms = {a: [extract(r) for r in run_dirs(tag, scale, a, since_epoch)]
            for a in ("baseline", "runtimeonly", "streaming")}
    # baseline walltime = mean work_s across baseline reps (fallback: runtimeonly if no baseline)
    base_walls = [f(x, "work_s") for x in arms["baseline"] if f(x, "work_s") > 0]
    base_wall = sum(base_walls) / len(base_walls) if base_walls else 0.0

    rows = []
    # baseline row (single, averaged)
    if arms["baseline"]:
        rows.append(("baseline", "-", "-", "-", "-", "-",
                     "%.1f" % base_wall if base_wall else "-", "0.0"))
    # runtimeonly row (single, averaged wall)
    if arms["runtimeonly"]:
        rw = [f(x, "work_s") for x in arms["runtimeonly"] if f(x, "work_s") > 0]
        rwall = sum(rw) / len(rw) if rw else 0.0
        ov = (rwall - base_wall) if (rwall and base_wall) else 0.0
        rows.append(("runtimeonly", "-", "-", "-",
                     "%.3f" % (f(arms["runtimeonly"][0], "init_us") / 1e6),
                     "%.4f" % (f(arms["runtimeonly"][0], "finalize_us") / 1e6),
                     "%.1f" % rwall if rwall else "-",
                     ("%+.1f" % ov) if base_wall else "-"))
    # streaming rows (per rep)
    for i, x in enumerate(arms["streaming"], start=1):
        if x.get("_timeout"):
            rows.append(("streaming r%d" % i, "TIMEOUT", "-", "-", "-", "-", "-", "-"))
            continue
        wall = f(x, "work_s")
        ov = (wall - base_wall) if (wall and base_wall) else 0.0
        ev = x.get("events_jsonl", "-")
        rows.append((
            "streaming r%d" % i,
            "{:,}".format(int(ev)) if str(ev).isdigit() else str(ev),
            "%.2f" % f(x, "send_avg_us"),
            "%.2f" % f(x, "push_avg_us"),
            "%.3f" % (f(x, "init_us") / 1e6),
            "%.4f" % (f(x, "finalize_us") / 1e6),
            "%.1f" % wall if wall else "-",
            ("%+.1f" % ov) if base_wall else "-",
        ))
    verdicts = [x.get("verdict", "") for x in arms["streaming"] if x.get("verdict")]
    meta = {"base_wall": base_wall,
            "verdict": verdicts[-1] if verdicts else "",
            "n_base": len(arms["baseline"]), "n_rt": len(arms["runtimeonly"]),
            "n_stream": len(arms["streaming"])}
    return rows, meta


def build(rows_by_slide, out_path):
    from pptx import Presentation
    from pptx.util import Inches, Pt
    from pptx.dml.color import RGBColor
    from pptx.enum.text import PP_ALIGN

    BG = RGBColor(0x0f, 0x14, 0x19); CARD = RGBColor(0x1a, 0x22, 0x2c)
    INK = RGBColor(0xe8, 0xed, 0xf2); MUTED = RGBColor(0x93, 0xa1, 0xaf)
    ACCENT = RGBColor(0x4f, 0xc3, 0xf7); HEAD = RGBColor(0x14, 0x1b, 0x23)
    BASE = RGBColor(0x12, 0x20, 0x2b); WHITE = RGBColor(0xff, 0xff, 0xff)

    prs = Presentation(); prs.slide_width = Inches(13.333); prs.slide_height = Inches(7.5)
    blank = prs.slide_layouts[6]

    def paint_bg(s):
        s.background.fill.solid(); s.background.fill.fore_color.rgb = BG

    def add_text(s, l, t, w, h, txt, sz, c, bold=False, align=PP_ALIGN.LEFT):
        tb = s.shapes.add_textbox(l, t, w, h); tf = tb.text_frame; tf.word_wrap = True
        p = tf.paragraphs[0]; p.alignment = align; r = p.add_run(); r.text = txt
        ft = r.font; ft.size = Pt(sz); ft.bold = bold; ft.color.rgb = c; ft.name = "Segoe UI"
        return tb

    def set_cell(cell, text, color=INK, bold=False, align=PP_ALIGN.CENTER, fill=CARD, size=14):
        cell.fill.solid(); cell.fill.fore_color.rgb = fill
        cell.margin_left = Inches(0.05); cell.margin_right = Inches(0.05)
        cell.margin_top = Inches(0.03); cell.margin_bottom = Inches(0.03)
        p = cell.text_frame.paragraphs[0]; p.alignment = align; r = p.add_run(); r.text = text
        ftt = r.font; ftt.size = Pt(size); ftt.bold = bold; ftt.color.rgb = color; ftt.name = "Segoe UI"

    # title
    s = prs.slides.add_slide(blank); paint_bg(s)
    add_text(s, Inches(0.8), Inches(2.2), Inches(11.7), Inches(1.2),
             "Darshan -> Mofka streaming overhead", 40, WHITE, bold=True)
    add_text(s, Inches(0.8), Inches(3.5), Inches(11.7), Inches(2.6),
             "Per-workload x scale: events, send, push, init, finalize, walltime, overhead. "
             "5 workloads (C / Python / python-ml / MPI / DLIO) at two scales (1 and 4 workload "
             "nodes), each with one broker/consumer node. Rows = baseline + runtimeonly + 3 "
             "streaming reps. Overhead = streaming walltime - baseline walltime. "
             "3 arms/job: 1 baseline rep, 1 runtimeonly rep, 3 streaming reps; ~10 min real "
             "work/rep. CXI 1 rank/node (C/Python/ML); TCP 32 ranks/node (MPI/DLIO).",
             17, MUTED)

    for name, sub, rows in rows_by_slide:
        s = prs.slides.add_slide(blank); paint_bg(s)
        add_text(s, Inches(0.5), Inches(0.4), Inches(12.3), Inches(0.9), name, 24, ACCENT, bold=True)
        add_text(s, Inches(0.5), Inches(1.25), Inches(12.3), Inches(0.7), sub, 13, MUTED)
        if not rows:
            add_text(s, Inches(0.5), Inches(3.0), Inches(12.3), Inches(1.0),
                     "(no completed runs yet for this workload x scale)", 18, MUTED)
            continue
        nrows = len(rows) + 1; ncols = len(COLS)
        tbl = s.shapes.add_table(nrows, ncols, Inches(0.4), Inches(2.2),
                                 Inches(12.5), Inches(0.6 * nrows)).table
        tbl.columns[0].width = Inches(2.1)
        for i in range(1, ncols):
            tbl.columns[i].width = Inches((12.5 - 2.1) / (ncols - 1))
        for j, h in enumerate(COLS):
            set_cell(tbl.cell(0, j), h, color=ACCENT, bold=True, fill=HEAD, size=13)
        for i, row in enumerate(rows, start=1):
            isbase = row[0] == "baseline"
            fill = BASE if isbase else CARD; col = WHITE if isbase else INK
            for j, val in enumerate(row):
                set_cell(tbl.cell(i, j), str(val),
                         color=(ACCENT if j == 0 else col), bold=isbase,
                         align=(PP_ALIGN.LEFT if j == 0 else PP_ALIGN.CENTER), fill=fill)
        add_text(s, Inches(0.5), Inches(6.7), Inches(12.3), Inches(0.6),
                 "send = app-critical-path enqueue (per-event avg, us). push/init/finalize = "
                 "drain-thread + one-time connector cost. Baseline has no connector (-). "
                 "overhead in seconds vs baseline walltime.",
                 11, MUTED)

    prs.save(out_path)
    print("wrote", out_path, "with", len(prs.slides._sldIdLst), "slides")


def main():
    import datetime
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", default="2026-08-08 16:19:00",
                    help="only use RUN dirs modified at/after this local time")
    ap.add_argument("--out", default=os.path.join(HERE, "weekly_overhead_tables.pptx"))
    a = ap.parse_args()
    since_epoch = datetime.datetime.strptime(a.since, "%Y-%m-%d %H:%M:%S").timestamp()

    rows_by_slide = []
    for tag, pretty, sub in WORKLOADS:
        for scale, scale_label in SCALES:
            rows, meta = collect(tag, scale, since_epoch)
            title = "%s  -  %s" % (pretty, scale_label)
            subtitle = sub
            if meta["verdict"]:
                subtitle += "   [%s]" % meta["verdict"].replace("VERDICT: ", "")
            note = "  (arms present: base=%d runtimeonly=%d streaming=%d)" % (
                meta["n_base"], meta["n_rt"], meta["n_stream"])
            rows_by_slide.append((title, subtitle + note, rows))
            sys.stderr.write("[%s %s] base=%d rt=%d stream=%d base_wall=%.1f\n" % (
                tag, scale, meta["n_base"], meta["n_rt"], meta["n_stream"], meta["base_wall"]))
    build(rows_by_slide, a.out)


if __name__ == "__main__":
    main()
