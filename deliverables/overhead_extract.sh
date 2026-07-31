#!/bin/bash
# overhead_extract.sh <RUN_dir> -- print the connector overhead breakdown for one run:
#   init_us, finalize_us, push count/avg/sum, send count/avg/sum, WORK wall (s),
#   events.jsonl lines, VERDICT. Reproducible: parses workload.*.err + .out + compare.txt.
# Usage: bash deliverables/overhead_extract.sh results/OH_IOBENCH_10MIN/streaming/RUN1
set -u
R="${1:?usage: overhead_extract.sh <RUN_dir>}"
ERR=$(ls "$R"/workload.*.err 2>/dev/null | head -1)
OUT=$(ls "$R"/workload.*.out 2>/dev/null | head -1)

awk -v r="$R" '
/darshan-mofka\[timing\]/{op=$2; c[op]++; s[op]+=$3; if($3>m[op])m[op]=$3}
END{
  printf "init_us=%.1f finalize_us=%.1f\n", s["initialize"], s["finalize"]
  printf "push: count=%d avg_us=%.3f sum_us=%.1f max_us=%.1f\n", c["push"], (c["push"]?s["push"]/c["push"]:0), s["push"], m["push"]
  printf "send: count=%d avg_us=%.3f sum_us=%.1f max_us=%.1f\n", c["send"], (c["send"]?s["send"]/c["send"]:0), s["send"], m["send"]
}' "$ERR" 2>/dev/null

# work wall from WORK_START/END ns (self-timed), else elapsed=
ws=$(grep -hoE 'WORK_START_NS [0-9]+' "$OUT" 2>/dev/null | awk '{print $2}' | head -1)
we=$(grep -hoE 'WORK_END_NS [0-9]+'   "$OUT" 2>/dev/null | awk '{print $2}' | head -1)
if [ -n "$ws" ] && [ -n "$we" ]; then
  awk -v a="$ws" -v b="$we" 'BEGIN{printf "work_s=%.2f\n", (b-a)/1e9}'
fi
ev=$( [ -f "$R/events.jsonl" ] && wc -l < "$R/events.jsonl" || echo 0 )
echo "events_jsonl=$ev"
grep -hE 'VERDICT' "$R/compare.txt" 2>/dev/null | tail -1
