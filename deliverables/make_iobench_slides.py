#!/usr/bin/env python
"""deliverables/iobench_overhead_slides.pptx -- 2 slides (io_bench 1wl + 4wl), nothing else.
Realistic C training-style workload (dataset write once + per-epoch re-read + cache-tiled
matmul + periodic checkpoint + stdio log). CXI 1 rank/node. State-B connector (counters[]
at close, rec_hex gone), margo basic_wait fix + dedicated sender ES on the streaming arm.
Each slide: 6-row x 8-col table.
  rows:    baseline, darshan-only (runtimeonly), streaming rep1, rep2, rep3
  columns: init cost (s), per-push (us), per-send (us), finalize (s), events, walltime (s), overhead
Data from the 2026-08-11 run (OVH_io_bench_{1wl,4wl}_B). Fidelity: POSIX+HEATMAP exact,
STDIO 232/261 (files open at exit not captured). overhead = streaming walltime - baseline walltime.
"""
from pptx import Presentation
from pptx.util import Inches, Pt
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN

BG=RGBColor(0x0f,0x14,0x19); CARD=RGBColor(0x1a,0x22,0x2c); INK=RGBColor(0xe8,0xed,0xf2)
MUTED=RGBColor(0x93,0xa1,0xaf); ACCENT=RGBColor(0x4f,0xc3,0xf7); HEAD=RGBColor(0x14,0x1b,0x23)
BASE=RGBColor(0x12,0x20,0x2b); WHITE=RGBColor(0xff,0xff,0xff)

COLS = ["arm", "init (s)", "per-push (us)", "per-send (us)", "finalize (s)",
        "events", "walltime (s)", "overhead"]

# per slide: (name, subtitle, [ (arm, init, push, send, finalize, events, wall, overhead) ])
SLIDES = [
 ("io_bench (C)  -  1 workload node + 1 broker/consumer  (CXI, 1 rank/node)",
  "Realistic C train-style: dataset write + per-epoch re-read + cache-tiled matmul + stdio log. "
  "Overhead ~2.7% and stable across 3 reps. Events delivered with no loss. baseline=342.2s.",
  [("baseline",     "-",     "-",    "-",      "-",      "-",     "342.2", "0.0%"),
   ("darshan-only", "-",     "-",    "-",      "-",      "-",     "343.1", "+0.26%"),
   ("streaming r1", "0.898", "10.11","1518.5", "0.290",  "1,407", "351.8", "+2.81%"),
   ("streaming r2", "0.848", "9.86", "1470.1", "0.250",  "1,407", "350.9", "+2.54%"),
   ("streaming r3", "0.602", "10.02","1511.2", "0.283",  "1,407", "352.0", "+2.86%")]),
 ("io_bench (C)  -  4 workload nodes + 1 broker/consumer  (CXI, 1 rank/node, 2 consumers)",
  "Same workload at 4x scale, 2 sharded consumers. Overhead does NOT grow with scale (~2.2%). "
  "events = sum across 4 workload nodes; delivered with no loss. baseline=342.2s.",
  [("baseline",     "-",     "-",    "-",      "-",      "-",     "342.2", "0.0%"),
   ("darshan-only", "-",     "-",    "-",      "-",      "-",     "342.4", "+0.06%"),
   ("streaming r1", "2.095", "10.11","1409.6", "0.232",  "5,628", "349.7", "+2.19%"),
   ("streaming r2", "0.796", "10.13","1454.6", "0.215",  "5,628", "349.9", "+2.25%"),
   ("streaming r3", "0.857", "10.36","1427.3", "0.259",  "5,628", "349.9", "+2.25%")]),
]

prs=Presentation(); prs.slide_width=Inches(13.333); prs.slide_height=Inches(7.5)
blank=prs.slide_layouts[6]
def paint_bg(s): s.background.fill.solid(); s.background.fill.fore_color.rgb=BG
def add_text(s,l,t,w,h,txt,sz,c,bold=False,align=PP_ALIGN.LEFT):
    tb=s.shapes.add_textbox(l,t,w,h); tf=tb.text_frame; tf.word_wrap=True
    p=tf.paragraphs[0]; p.alignment=align; r=p.add_run(); r.text=txt
    f=r.font; f.size=Pt(sz); f.bold=bold; f.color.rgb=c; f.name="Segoe UI"; return tb
def set_cell(cell,text,*,color=INK,bold=False,align=PP_ALIGN.CENTER,fill=CARD,size=14):
    cell.fill.solid(); cell.fill.fore_color.rgb=fill
    cell.margin_left=Inches(0.05); cell.margin_right=Inches(0.05)
    cell.margin_top=Inches(0.03); cell.margin_bottom=Inches(0.03)
    p=cell.text_frame.paragraphs[0]; p.alignment=align; r=p.add_run(); r.text=text
    f=r.font; f.size=Pt(size); f.bold=bold; f.color.rgb=color; f.name="Segoe UI"

for name,sub,rows in SLIDES:
    s=prs.slides.add_slide(blank); paint_bg(s)
    add_text(s,Inches(0.5),Inches(0.4),Inches(12.3),Inches(0.9),name,22,ACCENT,bold=True)
    add_text(s,Inches(0.5),Inches(1.25),Inches(12.3),Inches(0.8),sub,13,MUTED)
    nrows=len(rows)+1; ncols=len(COLS)
    tbl=s.shapes.add_table(nrows,ncols,Inches(0.4),Inches(2.3),Inches(12.5),Inches(0.7*nrows)).table
    tbl.columns[0].width=Inches(1.9)
    for i in range(1,ncols): tbl.columns[i].width=Inches((12.5-1.9)/(ncols-1))
    for j,h in enumerate(COLS):
        set_cell(tbl.cell(0,j),h,color=ACCENT,bold=True,fill=HEAD,size=13)
    for i,row in enumerate(rows,start=1):
        isbase = row[0]=="baseline"
        fill=BASE if isbase else CARD; col=WHITE if isbase else INK
        for j,val in enumerate(row):
            set_cell(tbl.cell(i,j),val,color=(ACCENT if j==0 else col),bold=isbase,
                     align=(PP_ALIGN.LEFT if j==0 else PP_ALIGN.CENTER),fill=fill)
    add_text(s,Inches(0.5),Inches(6.7),Inches(12.3),Inches(0.6),
             "init/finalize = one-shot connector cost (total s). per-push/per-send = per-event "
             "averages (us); send is on the app critical path, push runs on the drain thread. "
             "baseline = no Darshan; darshan-only = Darshan instrumented, streaming off.",
             11,MUTED)

out="deliverables/iobench_overhead_slides.pptx"
prs.save(out); print("wrote",out,"with",len(prs.slides._sldIdLst),"slides (io_bench 1wl + 4wl, 6x8 tables)")
