#!/bin/bash
# run_all.sh -- submit all 8 overhead jobs in priority order, respecting the per-user
# queue limits (debug: ~1 running+1 queued; debug-scaling: 1 queued). Waits for a free
# slot before submitting the next. Priority: failing workload (io_bench_py) first, then
# io_bench (C), then mpi, then dlio; N=1 (debug) across all, then N=4 (debug-scaling).
# Run in the background:  nohup bash run_all.sh > results/run_all.log 2>&1 &
set -uo pipefail
ROOT="/eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight"
JOBS="$ROOT/run_artifacts/jobs"
export PBS_ACCOUNT="${PBS_ACCOUNT:-radix-io}"
LOG="$ROOT/results/run_all.log"
say(){ echo "[$(date '+%H:%M:%S')] $*"; }

# priority order: N=1 first (debug), then N=4 (debug-scaling)
ORDER=(
  ${RUN_ALL_ORDER:-job_iobenchpy_N1.sh job_iobench_N1.sh job_mpi_N1.sh job_dlio_N1.sh job_iobenchpy_N4.sh job_iobench_N4.sh job_mpi_N4.sh job_dlio_N4.sh}
)

# how many of MY jobs are currently in the given queue (Q or R)
qcount(){ qstat -u hjajula 2>/dev/null | awk -v q="$1" '$3==q && ($10=="Q"||$10=="R"){c++} END{print c+0}'; }
# total of my jobs anywhere
mycount(){ qstat -u hjajula 2>/dev/null | grep -c '^[0-9]'; }

for jf in "${ORDER[@]}"; do
  q=debug; [[ "$jf" == *_N4.sh ]] && q=debug-scaling
  # wait until that queue has room (keep at most 1 running + 1 queued of mine there = <2)
  while [ "$(qcount "$q")" -ge 2 ]; do
    say "wait: $q has $(qcount "$q") of my jobs (need <2) before $jf"
    sleep 60
  done
  say "SUBMIT $jf (queue=$q)"
  bash "$JOBS/$jf" 2>&1 | sed 's/^/    /'
  sleep 15   # let it register before checking counts for the next
done
say "ALL 8 SUBMITTED"
