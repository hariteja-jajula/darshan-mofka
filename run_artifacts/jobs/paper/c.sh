#!/bin/bash
PBS_ACCOUNT=radix-io WL=io_bench PROTO=ofi+cxi TASKS=1 QUEUE=debug NODES=2 WALL=01:00:00 \
  EV=100 PART=4 CONS=1 IO_ITERS=9500 IO_SLEEP_MS=50 SREPS=3 STUDY=PAPER_iobench \
  bash /eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/jobs/paper_repro.sh
