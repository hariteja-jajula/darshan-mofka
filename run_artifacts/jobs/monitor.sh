#!/bin/bash
# monitor.sh <jobid> <study> -- single-shot status snapshot for an overhead job.
# Prints: job state, which arms have RUN dirs, CPU_PROBE lines, VERDICTs, any FAIL/wedge
# signals, and freshness of the workload err (to detect a mid-run wedge). Designed to be
# called repeatedly; each call is a self-contained snapshot (no long-lived loop).
JOB="${1:?usage: monitor.sh <jobid> <study>}"
STUDY="${2:?usage: monitor.sh <jobid> <study>}"
ROOT="/eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight"
R="$ROOT/results/$STUDY"

echo "===== $(date '+%H:%M:%S') monitor $JOB ($STUDY) ====="
st=$(qstat -u hjajula 2>/dev/null | grep "$JOB" | awk '{print $10" elapsed="$11}')
[ -n "$st" ] && echo "job: $st" || echo "job: NOT in queue (finished/exited)"

echo "--- arms present ---"
for arm in baseline runtimeonly streaming; do
  n=$(ls -d "$R/$arm"/RUN* 2>/dev/null | wc -l)
  echo "  $arm: $n RUN dir(s)"
done

echo "--- CPU_PROBE ---"
grep -rhE 'CPU_PROBE' "$R"/*/RUN*/workload*.out 2>/dev/null | sed 's/^/  /' || echo "  (none yet)"

echo "--- VERDICT ---"
grep -rhE 'VERDICT' "$R"/*/RUN*/compare.txt 2>/dev/null | sort | uniq -c | sed 's/^/  /' || echo "  (none yet)"

echo "--- run_mpmd verdicts / sends (job .OU) ---"
grep -hE 'run_mpmd_rep verdict|===== ARM|3-ARM JOB DONE' "$R"/*.OU 2>/dev/null | tail -8 | sed 's/^/  /'

echo "--- health: freshest workload.err + last line (wedge check) ---"
f=$(find "$R" -name 'workload*.err' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
if [ -n "$f" ]; then
  age=$(( $(date +%s) - $(stat -c %Y "$f") ))
  echo "  $f (age ${age}s)"
  tail -1 "$f" | sed 's/^/    /'
  [ "$age" -gt 180 ] && echo "  WARNING: err stale >180s -- possible wedge or between-arm gap"
else
  echo "  (no workload.err yet)"
fi

echo "--- failure signals ---"
grep -rhiE 'FAILED|parse error|driver_create failed|Could not find __primary__|options ignored|abort|deadlock' \
  "$R"/*/RUN*/workload*.err "$R"/*.OU 2>/dev/null | grep -v 'will be ignored because' | tail -5 | sed 's/^/  /' || echo "  (clean)"
echo "======================================================"
