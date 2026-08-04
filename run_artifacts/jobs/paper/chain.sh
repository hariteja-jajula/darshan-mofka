#!/bin/bash
# chain.sh -- submit paper-repro wrapper scripts to ONE queue, retrying on the PBS
# "1 queued/user" limit. QUEUE=debug bash chain.sh py.sh ...
set -uo pipefail
D="/eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/jobs/paper"
export PBS_ACCOUNT="${PBS_ACCOUNT:-radix-io}"
Q="${QUEUE:?set QUEUE}"
QPAT="^${Q}$"; [ "$Q" = debug-scaling ] && QPAT="^debug-s"
say(){ echo "[$(date '+%H:%M:%S')][$Q] $*"; }
qcount(){ qstat -u hjajula 2>/dev/null | awk -v p="$QPAT" '$3 ~ p && $10=="Q"{c++} END{print c+0}'; }
for jf in "$@"; do
  say "next: $jf"
  while :; do
    out="$(bash "$D/$jf" 2>&1)"
    if echo "$out" | grep -qE '[0-9]+\.polaris'; then
      say "SUBMITTED $jf -> $(echo "$out"|grep -oE '[0-9]+\.polaris'|head -1)"; break
    fi
    say "rejected; retry 45s"; sleep 45
  done
  sleep 10
done
say "CHAIN DONE ($*)"
