#!/usr/bin/env python
"""Generate deliverables/overhead_tables.pptx: title slide + one slide per workload,
each a native PowerPoint table (Init / Push / Finalize / Total streaming overhead /
Total run time). Numbers mirror deliverables/c_overhead_table.html cell-for-cell.
Lossless delivery (every event delivered, fidelity EXACT)."""
from pptx import Presentation
from pptx.util import Inches, Pt
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN

# --- palette (matches the HTML dark theme) ---
BG     = RGBColor(0x0f, 0x14, 0x19)
CARD   = RGBColor(0x1a, 0x22, 0x2c)
INK    = RGBColor(0xe8, 0xed, 0xf2)
MUTED  = RGBColor(0x93, 0xa1, 0xaf)
ACCENT = RGBColor(0x4f, 0xc3, 0xf7)
HEAD   = RGBColor(0x14, 0x1b, 0x23)
TOTAL  = RGBColor(0x12, 0x20, 0x2b)
WHITE  = RGBColor(0xff, 0xff, 0xff)

# workload -> (subtitle, rows). Each row: (label, value_seconds).
WORKLOADS = [
    ("c",
     "Tight-loop POSIX/STDIO microbenchmark - 250k back-to-back 64-byte write()s, one push each.",
     [("Init", "0.269"),
      ("Push (250,025 pushes)", "0.084"),
      ("Finalize (drain + flush)", "5.823"),
      ("Total streaming overhead", "6.674"),
      ("Total run time (streaming)", "19.274")]),
    ("python-ml",
     "Shard read + train + checkpoint; real compute interleaves I/O.",
     [("Init", "0.339"),
      ("Push (2,160,233 pushes)", "1.519"),
      ("Finalize (drain + flush)", "0.397"),
      ("Total streaming overhead", "21.676"),
      ("Total run time (streaming)", "178.110")]),
    ("mpi",
     "Collective MPI-IO with fsync each step; each push rides an fsync-bound step.",
     [("Init", "0.228"),
      ("Push (2,000,010 pushes)", "34.510"),
      ("Finalize (drain + flush)", "6.568"),
      ("Total streaming overhead", "35.195"),
      ("Total run time (streaming)", "63.224")]),
    ("dlio",
     "DLIO Benchmark dataset-generation stage - writes NPZ dataset files (TF/numpy).",
     [("Init", "0.299"),
      ("Push (161,363 pushes)", "0.268"),
      ("Finalize (drain + flush)", "0.206"),
      ("Total streaming overhead", "2.350"),
      ("Total run time (streaming)", "44.235")]),
]

prs = Presentation()
prs.slide_width  = Inches(13.333)
prs.slide_height = Inches(7.5)
blank = prs.slide_layouts[6]

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

# --- title slide ---
s = prs.slides.add_slide(blank); paint_bg(s)
add_text(s, Inches(0.8), Inches(2.4), Inches(11.7), Inches(1.2),
         "Darshan → Mofka streaming overhead", 40, WHITE, bold=True)
add_text(s, Inches(0.8), Inches(3.7), Inches(11.7), Inches(1.8),
         "Per-workload wall-clock breakdown of the connector's three timed phases - "
         "Init, Push, Finalize - plus total streaming overhead and total run time. "
         "Lossless delivery (every event delivered, fidelity EXACT). "
         "2 nodes, 1 task + 1 broker, memory partition, ofi+tcp. All times in seconds.",
         18, MUTED)

def set_cell(cell, text, *, color=INK, bold=False, align=PP_ALIGN.LEFT, fill=None, size=16):
    if fill is not None:
        cell.fill.solid(); cell.fill.fore_color.rgb = fill
    else:
        cell.fill.solid(); cell.fill.fore_color.rgb = CARD
    cell.margin_left = Inches(0.15); cell.margin_right = Inches(0.15)
    cell.margin_top = Inches(0.04); cell.margin_bottom = Inches(0.04)
    tf = cell.text_frame; tf.word_wrap = True
    p = tf.paragraphs[0]; p.alignment = align
    r = p.add_run(); r.text = text
    f = r.font; f.size = Pt(size); f.bold = bold; f.color.rgb = color; f.name = "Segoe UI"

# --- one slide per workload ---
for name, sub, rows in WORKLOADS:
    s = prs.slides.add_slide(blank); paint_bg(s)
    add_text(s, Inches(0.8), Inches(0.5), Inches(11.7), Inches(0.9),
             name, 32, ACCENT, bold=True)
    add_text(s, Inches(0.8), Inches(1.35), Inches(11.7), Inches(0.8),
             sub, 15, MUTED)

    nrows = len(rows) + 1  # + header
    tbl_shape = s.shapes.add_table(nrows, 2, Inches(0.8), Inches(2.3),
                                   Inches(11.7), Inches(0.72 * nrows))
    tbl = tbl_shape.table
    tbl.columns[0].width = Inches(8.7)
    tbl.columns[1].width = Inches(3.0)

    # header
    set_cell(tbl.cell(0, 0), "Phase", color=ACCENT, bold=True, fill=HEAD)
    set_cell(tbl.cell(0, 1), "Time (s)", color=ACCENT, bold=True,
             align=PP_ALIGN.RIGHT, fill=HEAD)

    for i, (label, val) in enumerate(rows, start=1):
        is_total = label.startswith("Total")
        fill = TOTAL if is_total else CARD
        col  = WHITE if is_total else INK
        set_cell(tbl.cell(i, 0), label, color=col, bold=is_total, fill=fill)
        set_cell(tbl.cell(i, 1), val, color=col, bold=is_total,
                 align=PP_ALIGN.RIGHT, fill=fill)

    add_text(s, Inches(0.8), Inches(6.7), Inches(11.7), Inches(0.6),
             "Total streaming overhead = streaming wall - baseline wall. "
             "Init/Finalize are near-constant; Push scales with I/O volume.",
             12, MUTED)

out = "deliverables/overhead_tables.pptx"
prs.save(out)
print("wrote", out, "with", len(prs.slides._sldIdLst), "slides")
