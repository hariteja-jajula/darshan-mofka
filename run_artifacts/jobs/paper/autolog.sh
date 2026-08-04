#!/bin/bash
R="/eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight"
for i in $(seq 1 200); do   # ~16h
  echo "===== $(date '+%F %T') ====="
  bash "$R/run_artifacts/jobs/paper/extract.sh"
  qstat -u hjajula 2>/dev/null | grep '^[0-9]' | awk '{print $1,$3,$10,$11}'
  echo
  sleep 300
done
