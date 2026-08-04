#!/usr/bin/env python
"""deliverables/paper_overhead_tables.pptx -- title + one slide per workload (5).
Each slide: a 4-row x 7-column table.
  rows:    baseline, streaming rep1, rep2, rep3
  columns: events, send(s), push(s), init(s), finalize(s), walltime(s), overhead(s)
Batch size = Adaptive (always). Overhead = streaming walltime - baseline walltime.
Data from the 2026-08-04 paper-reproduction study (overlap-friendly regime, COMPUTE=0;
message service on its own node; Adaptive batching). Fidelity EXACT (every streamed
integer counter matches native). Darshan runtime 3.4.4, log format 3.41.
send/push/init/finalize are self-timed TOTALS in seconds. C/Py/python-ml walltime is the
WORK region; mpi/dlio have no WORK markers so walltime is arm-to-arm (setup+drain incl.)."""
from pptx import Presentation
from pptx.util import Inches, Pt
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN

BG=RGBColor(0x0f,0x14,0x19); CARD=RGBColor(0x1a,0x22,0x2c); INK=RGBColor(0xe8,0xed,0xf2)
MUTED=RGBColor(0x93,0xa1,0xaf); ACCENT=RGBColor(0x4f,0xc3,0xf7); HEAD=RGBColor(0x14,0x1b,0x23)
BASE=RGBColor(0x12,0x20,0x2b); WHITE=RGBColor(0xff,0xff,0xff)

COLS = ["arm","events","send avg (us)","push avg (us)","init (s)","finalize (s)","walltime (s)","overhead (s)"]

# per workload: (name, subtitle, [ (arm, events, send_avg_us, push_avg_us, init_s, finalize_s, wall_s, overhead_s) ])
# "-" where not applicable (baseline has no connector). overhead = wall - baseline_wall.
# send/push are PER-EVENT AVERAGES in microseconds. init/finalize/wall/overhead in seconds.
WORKLOADS = [
 ("io_bench (C)  -  CXI, 1 rank/node, Adaptive batching",
  "Overlap-friendly. Fidelity EXACT. Overhead small but CONSISTENT across 3 reps (+1.1 to +1.3 s, ~0.2%).",
  [("baseline",    "-",     "-",   "-",    "-",   "-",    "600.7", "0.0"),
   ("streaming r1","37,899","2.19","19.16","1.245","0.0001","602.0","+1.3"),
   ("streaming r2","37,899","2.21","19.04","0.192","0.0001","601.8","+1.1"),
   ("streaming r3","37,899","2.23","18.76","0.183","0.0001","601.8","+1.1")]),
 ("io_bench_py (Python)  -  CXI, 1 rank/node, Adaptive batching",
  "Overlap-friendly. Fidelity EXACT. Overhead is BELOW run-to-run noise (~0): reps 2-3 land "
  "slightly under baseline (-1.6, -2.1 s) -- i.e. streaming is effectively free here.",
  [("baseline",    "-",     "-",   "-",    "-",   "-",    "558.4", "0.0"),
   ("streaming r1","36,851","2.14","21.55","0.223","0.0001","558.5","+0.1"),
   ("streaming r2","36,851","2.12","24.50","0.416","0.0001","556.8","-1.6"),
   ("streaming r3","36,851","2.21","19.49","0.165","0.0001","556.3","-2.1")]),
 ("python-ml (real ML: dataset + train + checkpoint)  -  CXI, 1 rank/node, Adaptive",
  "NumPy/PyTorch, compute-bound. Fidelity EXACT. LARGE, reproducible overhead: +137 to +140 s (+66%) across 3 reps.",
  [("baseline",    "-",      "-",   "-",    "-",   "-",    "211.3", "0.0"),
   ("streaming r1","154,538","0.73","46.10","0.542","0.0001","351.6","+140.3"),
   ("streaming r2","154,538","0.79","45.35","0.159","0.0002","348.5","+137.2"),
   ("streaming r3","154,538","0.77","41.60","0.182","0.0001","350.4","+139.1")]),
 ("mpi (collective MPI-IO, shared file)  -  TCP, 32 ranks/node, Adaptive",
  "MPI unsupported over CXI. Paced (~600 s wall). Fidelity EXACT (32->1). Overhead below noise "
  "(~0): the one rep lands -1.7 s vs baseline -- streaming effectively free on this I/O-bound run.",
  [("baseline",    "-",     "-",    "-",    "-",   "-",    "602.4", "0.0"),
   ("streaming r1","39,770","15.0","67.2","2.70","0.003","600.7","-1.7")]),
 ("dlio (DLIO benchmark dataset-generation)  -  TCP, 32 ranks/node, Adaptive",
  "TensorFlow NPZ data-gen. Fidelity EXACT (32->1 aggregated). Wall = cold/warm-dominated -> per-event cost is the metric.",
  [("baseline",    "-",      "-",   "-",    "-",   "-",    "n/a","n/a"),
   ("streaming r1","475,994","3.0","38.0","3.25","0.004","n/a","n/a"),
   ("streaming r2","475,994","4.6","42.5","4.09","0.005","n/a","n/a")]),
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

# title
s=prs.slides.add_slide(blank); paint_bg(s)
add_text(s,Inches(0.8),Inches(2.3),Inches(11.7),Inches(1.2),
         "Darshan -> Mofka streaming overhead",40,WHITE,bold=True)
add_text(s,Inches(0.8),Inches(3.6),Inches(11.7),Inches(2.4),
         "Per-workload table: events, send, push, init, finalize, walltime, overhead (all seconds). "
         "Batch size = Adaptive. Rows = baseline + 3 streaming reps. Overhead = streaming walltime "
         "- baseline walltime. Overlap-friendly regime; message service on its own node. Fidelity "
         "EXACT (every streamed integer counter matches native). Darshan 3.4.4, log format 3.41. "
         "CXI 1 rank/node (C/Python/ML); TCP 32 ranks/node (MPI/DLIO).",
         17,MUTED)

for name,sub,rows in WORKLOADS:
    s=prs.slides.add_slide(blank); paint_bg(s)
    add_text(s,Inches(0.5),Inches(0.4),Inches(12.3),Inches(0.9),name,24,ACCENT,bold=True)
    add_text(s,Inches(0.5),Inches(1.25),Inches(12.3),Inches(0.7),sub,13,MUTED)
    nrows=len(rows)+1; ncols=len(COLS)
    tbl=s.shapes.add_table(nrows,ncols,Inches(0.4),Inches(2.2),Inches(12.5),Inches(0.7*nrows)).table
    tbl.columns[0].width=Inches(2.1)
    for i in range(1,ncols): tbl.columns[i].width=Inches((12.5-2.1)/(ncols-1))
    for j,h in enumerate(COLS):
        set_cell(tbl.cell(0,j),h,color=ACCENT,bold=True,fill=HEAD,size=13)
    for i,row in enumerate(rows,start=1):
        isbase = row[0]=="baseline"
        fill=BASE if isbase else CARD; col=WHITE if isbase else INK
        for j,val in enumerate(row):
            set_cell(tbl.cell(i,j),val,color=(ACCENT if j==0 else col),bold=isbase,
                     align=(PP_ALIGN.LEFT if j==0 else PP_ALIGN.CENTER),fill=fill)
    add_text(s,Inches(0.5),Inches(6.7),Inches(12.3),Inches(0.6),
             "send = app-critical-path enqueue (total s). push/init/finalize = drain-thread + one-time "
             "connector cost (total s). Baseline has no connector (-). overhead in seconds vs baseline.",
             11,MUTED)

out="deliverables/paper_overhead_tables.pptx"
prs.save(out); print("wrote",out,"with",len(prs.slides._sldIdLst),"slides (title + 5 workloads, 4x7 tables)")
