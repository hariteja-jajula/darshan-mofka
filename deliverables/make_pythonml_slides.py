#!/usr/bin/env python
"""deliverables/pythonml_overhead_slides.pptx -- 2 slides (python-ml 1wl + 4wl).

Each slide: a 6-row x 8-column table.
  rows:    baseline, darshan-only (runtimeonly), streaming rep1, rep2, rep3
  columns: init cost (s), per-push (us), per-send (us), finalize (s),
           events, walltime (s), overhead vs baseline
Data from the 2026-08-08 overhead study (results/OVH_pythonml_{1wl,4wl}), 3-arm
fixed-work method, CXI 1 rank/node, Adaptive batching. Numpy/BLAS thread-capped.
init/finalize are one-shot connector totals (s); per-push/per-send are per-event
averages (us). events = total streamed events (4wl = sum across workload nodes).
overhead = streaming walltime - baseline walltime.
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
# "-" where not applicable (baseline / darshan-only stream nothing -> no connector timing).
SLIDES = [
 ("python-ml  -  1 workload node + 1 broker/consumer  (CXI, 1 rank/node)",
  "Real NumPy MLP: dataset + train + checkpoint. Thread-capped. Fixed identical work. "
  "Overhead ~3% and stable across 3 reps. baseline=249.0s.",
  [("baseline",       "-",     "-",    "-",   "-",      "-",       "249.0", "0.0%"),
   ("darshan-only",   "-",     "-",    "-",   "-",      "-",       "251.1", "+0.8%"),
   ("streaming r1",   "1.319", "14.29","0.77","0.0009", "641,597", "256.7", "+3.09%"),
   ("streaming r2",   "0.156", "16.84","0.91","0.0001", "641,597", "254.5", "+2.21%"),
   ("streaming r3",   "0.186", "15.29","0.94","0.0001", "641,597", "257.1", "+3.25%")]),
 ("python-ml  -  4 workload nodes + 1 broker/consumer  (CXI, 1 rank/node)",
  "Same workload at 4x scale. Overhead does NOT grow with scale (~2.6%). events = sum "
  "across 4 workload nodes (~1.5-1.7M). per-push/send are per-event averages. baseline=250.3s.",
  [("baseline",       "-",     "-",    "-",   "-",      "-",         "250.3", "0.0%"),
   ("darshan-only",   "-",     "-",    "-",   "-",      "-",         "250.3", "0.0%"),
   ("streaming r1",   "2.065", "16.44","0.97","0.0017", "1,505,890", "258.2", "+3.16%"),
   ("streaming r2",   "0.153", "11.55","1.01","0.0009", "1,502,173", "256.0", "+2.28%"),
   ("streaming r3",   "0.196", "9.99", "1.05","0.0001", "1,706,380", "256.0", "+2.28%")]),
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

out="deliverables/pythonml_overhead_slides.pptx"
prs.save(out); print("wrote",out,"with",len(prs.slides._sldIdLst),"slides (python-ml 1wl + 4wl, 6x8 tables)")
