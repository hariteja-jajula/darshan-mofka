#!/bin/bash
PBS_ACCOUNT=radix-io WL=dlio PROTO=ofi+tcp TASKS=32 QUEUE=debug NODES=2 WALL=01:00:00 \
  EV=150 PART=16 CONS=16 RPC=4 BASE_REPS=2 SREPS=1 STUDY=DBG_dlio \
  bash /eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/jobs/paper_repro.sh
