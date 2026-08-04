#!/bin/bash
# mpi (MPI-IO), TCP, 32 ranks/node. Paced with IO_SLEEP_MS so the workload runs ~600s
# (comparable to the CXI runs) instead of ~0.3s. STEPS=600 x 1s sleep ~= 600s, ~40k events.
PBS_ACCOUNT=radix-io WL=mpi PROTO=ofi+tcp TASKS=32 QUEUE=debug-scaling NODES=2 WALL=01:00:00 \
  EV=600 PART=16 CONS=16 RPC=4 IO_SLEEP_MS=1000 SREPS=3 STUDY=PAPER_mpi3 \
  bash /eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/jobs/paper_repro.sh
