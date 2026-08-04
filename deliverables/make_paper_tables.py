#!/usr/bin/env python
"""deliverables/paper_overhead_tables.pptx -- title slide + one slide per workload (5),
each a native PowerPoint table with the SAME 5 rows:
    Init (one-time)
    Per-push cost (avg us) + total push
    Finalize (drain + flush)
    Total streaming overhead (self-timed)
    Wall time (baseline -> streaming)
Data: 2026-08-04 paper-reproduction study (overlap-friendly regime, COMPUTE=0; message
service on its own node; Adaptive batching; median of streaming reps). Fidelity EXACT
(every streamed integer counter matches native). Darshan runtime 3.4.4, log format 3.41."""
from pptx import Presentation
from pptx.util import Inches, Pt
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN

BG=RGBColor(0x0f,0x14,0x19); CARD=RGBColor(0x1a,0x22,0x2c); INK=RGBColor(0xe8,0xed,0xf2)
MUTED=RGBColor(0x93,0xa1,0xaf); ACCENT=RGBColor(0x4f,0xc3,0xf7); HEAD=RGBColor(0x14,0x1b,0x23)
TOTAL=RGBColor(0x12,0x20,0x2b); WHITE=RGBColor(0xff,0xff,0xff)

# name, subtitle, 5 rows (label, value). MEDIAN of streaming reps.
WORKLOADS = [
    ("io_bench (C)  -  CXI, 1 rank/node",
     "Overlap-friendly POSIX write/read + sleep. 37,899 events. 3 reps. Fidelity EXACT.",
     [("Init (one-time)",                         "0.19 s"),
      ("Per-push cost (37,899 events)",           "19.0 us/event  (0.72 s total)"),
      ("Finalize (drain + flush)",                "0.0001 s"),
      ("Total streaming overhead (self-timed)",   "0.98 s  =  0.16 % of run"),
      ("Wall time (baseline -> streaming)",       "600.7 -> 601.8 s")]),
    ("io_bench_py (Python)  -  CXI, 1 rank/node",
     "Overlap-friendly POSIX write/read + sleep. 36,851 events. 3 reps. Fidelity EXACT.",
     [("Init (one-time)",                         "0.17 s"),
      ("Per-push cost (36,851 events)",           "21.5 us/event  (0.79 s total)"),
      ("Finalize (drain + flush)",                "0.0001 s"),
      ("Total streaming overhead (self-timed)",   "1.10 s  =  0.20 % of run"),
      ("Wall time (baseline -> streaming)",       "558.4 -> 556.8 s")]),
    ("python-ml (real ML: dataset + train epochs + checkpoint)  -  CXI, 1 rank/node",
     "NumPy/PyTorch, compute-bound. 154,538 events. 3 reps. Fidelity EXACT.",
     [("Init (one-time)",                         "0.18 s"),
      ("Per-push cost (154,538 events)",          "45.3 us/event  (7.01 s total)"),
      ("Finalize (drain + flush)",                "0.0002 s"),
      ("Total streaming overhead (self-timed)",   "7.29 s  =  2.1 % of run"),
      ("Wall time (baseline -> streaming)",       "211.3 -> 348.5 s")]),
    ("mpi (collective MPI-IO, shared file)  -  TCP, 32 ranks/node",
     "MPI unsupported over CXI. 26,566 events. 3 reps. Fidelity EXACT (32->1 aggregated).",
     [("Init (one-time, median)",                 "3.05 s"),
      ("Per-push cost (26,566 events)",           "35.1 us/event  (0.93 s total)"),
      ("Finalize (drain + flush)",                "0.37 s"),
      ("Total streaming overhead (self-timed)",   "4.67 s"),
      ("Wall time (baseline -> streaming)",       "932 -> 918 s  (arm-to-arm, ~0 %)")]),
    ("dlio (DLIO benchmark dataset-generation)  -  TCP, 32 ranks/node",
     "TensorFlow NPZ data-gen. 475,994 events. 2 reps. Fidelity EXACT (32->1 aggregated).",
     [("Init (one-time)",                         "3.7 s"),
      ("Per-push cost (475,994 events)",          "40.3 us/event  (19.2 s total)"),
      ("Finalize (drain + flush)",                "0.004 s"),
      ("Total streaming overhead (self-timed)",   "24.7 s"),
      ("Wall time (baseline -> streaming)",       "1030 -> 943 s  (arm-to-arm, ~0 %)")]),
]

prs=Presentation(); prs.slide_width=Inches(13.333); prs.slide_height=Inches(7.5)
blank=prs.slide_layouts[6]
def paint_bg(s): s.background.fill.solid(); s.background.fill.fore_color.rgb=BG
def add_text(s,l,t,w,h,txt,sz,c,bold=False,align=PP_ALIGN.LEFT):
    tb=s.shapes.add_textbox(l,t,w,h); tf=tb.text_frame; tf.word_wrap=True
    p=tf.paragraphs[0]; p.alignment=align; r=p.add_run(); r.text=txt
    f=r.font; f.size=Pt(sz); f.bold=bold; f.color.rgb=c; f.name="Segoe UI"; return tb
def set_cell(cell,text,*,color=INK,bold=False,align=PP_ALIGN.LEFT,fill=None,size=16):
    cell.fill.solid(); cell.fill.fore_color.rgb=fill if fill is not None else CARD
    cell.margin_left=Inches(0.15); cell.margin_right=Inches(0.15)
    cell.margin_top=Inches(0.05); cell.margin_bottom=Inches(0.05)
    p=cell.text_frame.paragraphs[0]; p.alignment=align; r=p.add_run(); r.text=text
    f=r.font; f.size=Pt(size); f.bold=bold; f.color.rgb=color; f.name="Segoe UI"

s=prs.slides.add_slide(blank); paint_bg(s)
add_text(s,Inches(0.8),Inches(2.2),Inches(11.7),Inches(1.2),
         "Darshan -> Mofka streaming overhead",40,WHITE,bold=True)
add_text(s,Inches(0.8),Inches(3.5),Inches(11.7),Inches(2.6),
         "Per-workload connector cost: Init, Per-push, Finalize, Total streaming overhead, "
         "and Wall time. Overlap-friendly regime; message service on its own node; Adaptive "
         "batching; median of streaming reps. Lossless delivery, fidelity EXACT (every streamed "
         "integer counter matches native). Darshan runtime 3.4.4, log format 3.41. "
         "cray-mpich 9.0.1, libfabric 2.2.0rc1. CXI (1 rank/node) for C/Python/ML; "
         "TCP (32 ranks/node) for MPI/DLIO (MPI is unsupported over CXI).",
         17,MUTED)

for name,sub,rows in WORKLOADS:
    s=prs.slides.add_slide(blank); paint_bg(s)
    add_text(s,Inches(0.8),Inches(0.4),Inches(11.9),Inches(0.9),name,26,ACCENT,bold=True)
    add_text(s,Inches(0.8),Inches(1.3),Inches(11.9),Inches(0.7),sub,14,MUTED)
    nrows=len(rows)+1
    tbl=s.shapes.add_table(nrows,2,Inches(0.8),Inches(2.3),Inches(11.7),Inches(0.8*nrows)).table
    tbl.columns[0].width=Inches(6.6); tbl.columns[1].width=Inches(5.1)
    set_cell(tbl.cell(0,0),"Phase",color=ACCENT,bold=True,fill=HEAD)
    set_cell(tbl.cell(0,1),"Cost",color=ACCENT,bold=True,align=PP_ALIGN.RIGHT,fill=HEAD)
    for i,(label,val) in enumerate(rows,start=1):
        tot=label.startswith("Total")
        fill=TOTAL if tot else CARD; col=WHITE if tot else INK
        set_cell(tbl.cell(i,0),label,color=col,bold=tot,fill=fill)
        set_cell(tbl.cell(i,1),val,color=col,bold=tot,align=PP_ALIGN.RIGHT,fill=fill)
    add_text(s,Inches(0.8),Inches(6.9),Inches(11.7),Inches(0.5),
             "Self-timed overhead = Init + Push + Send + Finalize, measured inside the process. "
             "Per-push runs off the app critical path (drain thread); app pays only a ~2 us enqueue.",
             11,MUTED)

out="deliverables/paper_overhead_tables.pptx"
prs.save(out); print("wrote",out,"with",len(prs.slides._sldIdLst),"slides,",len(WORKLOADS),"workload tables x 5 rows")
