#!/usr/bin/env python
"""Generate deliverables/overhead_perrep.pptx: 4 slides, one per workload
(c, python-ml, mpi, dlio). Each slide is a native PowerPoint table with 5 rows --
Baseline, Darshan runtime, Streaming rep1/rep2/rep3 -- and 7 columns:
Wall (s) | Init (ms) | Push avg (us) | Finalize (s) | Overhead vs baseline | Pushes.

Reads each workload's results/OVERHEAD_STUDY_<W>_2NODE_1PROC_1Broker-separate/summary.csv
at runtime, so re-running after a workload re-runs refreshes that slide with no code edits.
Baseline/Darshan rows show the MEAN wall over their 3 reps; streaming shows each rep.
Lossless block mode (pushes == events)."""
import csv
import os

from pptx import Presentation
from pptx.util import Inches, Pt
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN

# --- palette (matches deliverables/make_overhead_pptx.py dark theme) ---
BG     = RGBColor(0x0f, 0x14, 0x19)
CARD   = RGBColor(0x1a, 0x22, 0x2c)
INK    = RGBColor(0xe8, 0xed, 0xf2)
MUTED  = RGBColor(0x93, 0xa1, 0xaf)
ACCENT = RGBColor(0x4f, 0xc3, 0xf7)
HEAD   = RGBColor(0x14, 0x1b, 0x23)
STREAM = RGBColor(0x12, 0x20, 0x2b)
WHITE  = RGBColor(0xff, 0xff, 0xff)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# workload -> (display name, subtitle, results dir)
WORKLOADS = [
    ("c", "Tight-loop POSIX/STDIO microbenchmark - back-to-back 64-byte write()s, one push each.",
     "results/OVERHEAD_STUDY_C_2NODE_1PROC_1Broker-separate"),
    ("python-ml", "Shard read + train + checkpoint; real compute interleaves I/O.",
     "results/OVERHEAD_STUDY_PYTHONML_2NODE_1PROC_1Broker-separate"),
    ("mpi", "Collective MPI-IO with fsync each step; each push rides an fsync-bound step.",
     "results/OVERHEAD_STUDY_MPI_2NODE_1PROC_1Broker-separate"),
    ("dlio", "DLIO Benchmark dataset-generation stage - writes NPZ dataset files (TF/numpy).",
     "results/OVERHEAD_STUDY_DLIO_2NODE_1PROC_1Broker-separate"),
]

SETUP = "2 nodes, 1 task + 1 broker, memory partition, ofi+tcp. Lossless block mode."

BASELINE_ARM  = "Baseline_nodarshan_nomofka"
DARSHAN_ARM   = "Enable_darshan_runtimeonly"

COLS = ["Arm / Rep", "Wall (s)", "Init (ms)", "Push avg (us)",
        "Finalize (s)", "Overhead vs baseline", "Pushes"]


def load_rows(results_dir):
    """Return {arm: [row_dict, ...]} from summary.csv, or None if absent."""
    path = os.path.join(ROOT, results_dir, "summary.csv")
    if not os.path.exists(path):
        return None
    by_arm = {}
    with open(path, newline="") as fh:
        for r in csv.DictReader(fh):
            by_arm.setdefault(r["arm"], []).append(r)
    return by_arm


def mean(vals):
    vals = [v for v in vals if v is not None]
    return sum(vals) / len(vals) if vals else None


def fnum(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def streaming_arm_key(by_arm):
    for k in by_arm:
        if k.startswith("Streaming"):
            return k
    return None


def build_table_rows(by_arm):
    """Produce the 5 display rows as lists of 7 formatted strings."""
    base = by_arm.get(BASELINE_ARM, [])
    dar  = by_arm.get(DARSHAN_ARM, [])
    base_mean = mean([fnum(r["wall_s"]) for r in base])

    def overhead(wall):
        if wall is None or not base_mean:
            return "-"
        return "+%.1f%%" % ((wall - base_mean) / base_mean * 100.0)

    rows = []

    # 1. Baseline (mean wall)
    rows.append(["Baseline (no Darshan)",
                 "%.3f" % base_mean if base_mean else "-",
                 "-", "-", "-", "- (ref)", "-"])

    # 2. Darshan runtime (mean wall + mean init)
    dar_mean  = mean([fnum(r["wall_s"]) for r in dar])
    dar_init  = mean([fnum(r["init_us"]) for r in dar])
    rows.append(["Darshan runtime",
                 "%.3f" % dar_mean if dar_mean else "-",
                 "%.3f" % (dar_init / 1000.0) if dar_init else "-",
                 "-", "-", overhead(dar_mean), "-"])

    # 3-5. Streaming reps (one row each, verbatim)
    skey = streaming_arm_key(by_arm)
    reps = sorted(by_arm.get(skey, []), key=lambda r: int(r["rep"])) if skey else []
    for r in reps:
        wall  = fnum(r["wall_s"])
        init  = fnum(r["init_us"])
        pavg  = fnum(r["push_mean_us"])
        fin   = fnum(r["finalize_us"])
        push  = fnum(r["pushes"])
        rows.append(["Streaming rep%s" % r["rep"],
                     "%.3f" % wall if wall is not None else "-",
                     "%.3f" % (init / 1000.0) if init is not None else "-",
                     "%.3f" % pavg if pavg is not None else "-",
                     "%.3f" % (fin / 1e6) if fin is not None else "-",
                     overhead(wall),
                     "{:,}".format(int(push)) if push is not None else "-"])
    return rows


def paint_bg(slide):
    slide.background.fill.solid()
    slide.background.fill.fore_color.rgb = BG


def add_text(slide, left, top, width, height, text, size, color,
             bold=False, align=PP_ALIGN.LEFT):
    tb = slide.shapes.add_textbox(left, top, width, height)
    tf = tb.text_frame
    tf.word_wrap = True
    p = tf.paragraphs[0]
    p.alignment = align
    r = p.add_run(); r.text = text
    f = r.font
    f.size = Pt(size); f.bold = bold; f.color.rgb = color
    f.name = "Segoe UI"
    return tb


def set_cell(cell, text, *, color=INK, bold=False, align=PP_ALIGN.LEFT, fill=CARD, size=15):
    cell.fill.solid(); cell.fill.fore_color.rgb = fill
    cell.margin_left = Inches(0.12); cell.margin_right = Inches(0.12)
    cell.margin_top = Inches(0.03); cell.margin_bottom = Inches(0.03)
    tf = cell.text_frame; tf.word_wrap = True
    p = tf.paragraphs[0]; p.alignment = align
    r = p.add_run(); r.text = text
    f = r.font; f.size = Pt(size); f.bold = bold; f.color.rgb = color; f.name = "Segoe UI"


prs = Presentation()
prs.slide_width  = Inches(13.333)
prs.slide_height = Inches(7.5)
blank = prs.slide_layouts[6]

for name, sub, results_dir in WORKLOADS:
    s = prs.slides.add_slide(blank); paint_bg(s)
    add_text(s, Inches(0.6), Inches(0.4), Inches(12.1), Inches(0.8),
             name, 32, ACCENT, bold=True)
    add_text(s, Inches(0.6), Inches(1.2), Inches(12.1), Inches(0.5),
             sub, 14, MUTED)
    add_text(s, Inches(0.6), Inches(1.62), Inches(12.1), Inches(0.4),
             SETUP, 12, MUTED)

    by_arm = load_rows(results_dir)
    if by_arm is None:
        add_text(s, Inches(0.6), Inches(3.0), Inches(12.1), Inches(1.0),
                 "no summary.csv found at %s" % results_dir, 16, MUTED)
        continue

    data_rows = build_table_rows(by_arm)
    nrows = len(data_rows) + 1  # + header
    ncols = len(COLS)
    tbl_shape = s.shapes.add_table(nrows, ncols, Inches(0.6), Inches(2.25),
                                   Inches(12.1), Inches(0.62 * nrows))
    tbl = tbl_shape.table
    tbl.columns[0].width = Inches(2.7)
    for c in range(1, ncols):
        tbl.columns[c].width = Inches((12.1 - 2.7) / (ncols - 1))

    # header
    for c, label in enumerate(COLS):
        set_cell(tbl.cell(0, c), label, color=ACCENT, bold=True, fill=HEAD,
                 align=PP_ALIGN.LEFT if c == 0 else PP_ALIGN.RIGHT)

    # body
    for ri, row in enumerate(data_rows, start=1):
        is_stream = row[0].startswith("Streaming")
        fill = STREAM if is_stream else CARD
        col  = WHITE if is_stream else INK
        for c, val in enumerate(row):
            set_cell(tbl.cell(ri, c), val, color=col, bold=is_stream, fill=fill,
                     align=PP_ALIGN.LEFT if c == 0 else PP_ALIGN.RIGHT)

    add_text(s, Inches(0.6), Inches(7.02), Inches(12.1), Inches(0.4),
             "Overhead vs baseline = (rep wall - mean baseline wall) / mean baseline wall. "
             "Pushes == events (lossless).", 11, MUTED)

# --- slide 5: reasonable_io moderate-I/O standalone run (PID 2406583) ---
# Single streaming run (no baseline/darshan arms) -> phase-metrics table, not the 5-row A/B/C form.
s = prs.slides.add_slide(blank); paint_bg(s)
add_text(s, Inches(0.6), Inches(0.4), Inches(12.1), Inches(0.8),
         "reasonable_io  (moderate-I/O, PID 2406583)", 32, ACCENT, bold=True)
add_text(s, Inches(0.6), Inches(1.2), Inches(12.1), Inches(0.5),
         "Representative C workload: ~600 application writes of 1 MiB each over a 5-minute run "
         "(not the tight-loop 64-byte microbenchmark).", 14, MUTED)
add_text(s, Inches(0.6), Inches(1.62), Inches(12.1), Inches(0.4),
         "2 nodes, 1 task + 1 broker, memory partition, ofi+tcp. Lossless block mode. "
         "Fidelity PASS (18 counters, 0 diffs, native == streamed).", 12, MUTED)

RIO_ROWS = [
    ("Application writes",              "599"),
    ("Bytes written",                  "628,097,024  (599.0 MiB)"),
    ("Wall time (elapsed)",            "300.274 s"),
    ("Streamed docs (events)",         "639"),
    ("Push latency per op (sampled)",  "~5-21 us typical  (0.95-30.3 us range)"),
    ("Finalize (drain + flush)",       "0.629 s"),
    ("Finalize tail vs run",           "~0.21% of 300 s"),
]
nrows = len(RIO_ROWS) + 1
tbl_shape = s.shapes.add_table(nrows, 2, Inches(0.6), Inches(2.25),
                               Inches(12.1), Inches(0.6 * nrows))
tbl = tbl_shape.table
tbl.columns[0].width = Inches(5.6)
tbl.columns[1].width = Inches(6.5)
set_cell(tbl.cell(0, 0), "Metric", color=ACCENT, bold=True, fill=HEAD)
set_cell(tbl.cell(0, 1), "Value", color=ACCENT, bold=True, fill=HEAD, align=PP_ALIGN.RIGHT)
for i, (label, val) in enumerate(RIO_ROWS, start=1):
    hot = label.startswith("Push") or label.startswith("Finalize")
    fill = STREAM if hot else CARD
    col  = WHITE if hot else INK
    set_cell(tbl.cell(i, 0), label, color=col, bold=hot, fill=fill)
    set_cell(tbl.cell(i, 1), val, color=col, bold=hot, fill=fill, align=PP_ALIGN.RIGHT)

add_text(s, Inches(0.6), Inches(6.7), Inches(12.1), Inches(0.6),
         "At realistic I/O granularity (1 MiB writes) the connector streams few, large events, so "
         "per-push cost stays a few us and the finalize/drain tail is negligible (~0.2%).", 11, MUTED)

out = os.path.join(ROOT, "deliverables", "overhead_perrep.pptx")
prs.save(out)
print("wrote", out, "with", len(prs.slides._sldIdLst), "slides")
