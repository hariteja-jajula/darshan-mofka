#!/bin/bash
# chain.sh -- submit a list of job files to ONE queue, one at a time. PBS enforces
# max 1 queued job per user per queue, so each submit is RETRIED until it succeeds
# (a jobid is returned). Only then advance to the next job. Robust to "would exceed
# per-user limit" rejections (waits and retries) rather than skipping the job.
# Usage: QUEUE=debug bash chain.sh job_mpi_N1.sh job_dlio_N1.sh
set -uo pipefail
ROOT="/eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight"
JOBS="$ROOT/run_artifacts/jobs"
export PBS_ACCOUNT="${PBS_ACCOUNT:-radix-io}"
Q="${QUEUE:?set QUEUE}"
say(){ echo "[$(date '+%H:%M:%S')][$Q] $*"; }

for jf in "$@"; do
  say "next: $jf -- attempting submit (retry until accepted)"
  while :; do
    out="$(bash "$JOBS/$jf" 2>&1)"
    if echo "$out" | grep -qE '^[0-9]+\.'; then
      jid="$(echo "$out" | grep -oE '^[0-9]+' | head -1)"
      say "SUBMITTED $jf -> $jid"
      break
    fi
    # rejected (per-user limit or transient) -> wait and retry
    say "rejected ($(echo "$out" | tr '\n' ' ' | tail -c 80)); retry in 45s"
    sleep 45
  done
  sleep 10
done
say "CHAIN DONE ($*)"
