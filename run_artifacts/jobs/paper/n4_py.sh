#!/bin/bash
PBS_ACCOUNT=radix-io WL=io_bench_py PROTO=ofi+cxi TASKS=1 QUEUE=debug-scaling NODES=5 WALL=01:00:00 \
  EV=100 PART=4 CONS=1 IO_ITERS=2000 IO_SLEEP_MS=50 BASE_REPS=1 SREPS=1 STUDY=N4_iobenchpy \
  bash /eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/jobs/paper_repro.sh
