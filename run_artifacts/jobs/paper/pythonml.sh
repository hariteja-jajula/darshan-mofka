#!/bin/bash
# python-ml (train.py: ML-style write dataset + read over epochs + checkpoints; PyTorch or
# NumPy). CXI, 1 rank/node. Overlap-friendly by nature (I/O + epoch reads). Adaptive x3 reps.
# EVENTS -> ML_EPOCHS. ML_FILES/ML_ROWS scale the dataset so the run is ~several minutes.
PBS_ACCOUNT=radix-io WL=python-ml PROTO=ofi+cxi TASKS=1 QUEUE=debug NODES=2 WALL=01:00:00 \
  EV=400 PART=4 CONS=1 ML_FILES=64 ML_ROWS=4096 ML_COLS=64 SREPS=3 STUDY=PAPER_pythonml \
  bash /eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/jobs/paper_repro.sh
