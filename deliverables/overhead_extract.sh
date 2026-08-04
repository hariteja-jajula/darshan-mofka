#!/bin/bash
# overhead_extract.sh <RUN_dir> -- print the connector overhead breakdown for one run:
#   init/finalize (avg+max across ranks), push & send count/avg/p50/p99/max/sum,
#   WORK wall (s), events.jsonl lines, VERDICT.
# Reproducible: parses ALL workload.*.err (one per rank) + .out + compare.txt.
# Usage: bash deliverables/overhead_extract.sh results/OVH_iobench_1wl/streaming/RUN1
#
# Percentiles: per-push/-send are emitted once PER EVENT (601/rank), so p50/p99 from
# a single rep are well-sampled and robust to the fat-tail outliers that poison the
# mean (a lone 100 ms drain-thread stall skews avg, not p50). init/finalize emit once
# per rank, so we report avg + max (slowest rank) across ranks, not a percentile.
set -u
R="${1:?usage: overhead_extract.sh <RUN_dir>}"
# ALL per-rank err files (was head -1 -> silently dropped every rank but one on 2wl/4wl).
ERR=$(ls "$R"/workload.*.err 2>/dev/null)
OUT=$(ls "$R"/workload.*.out 2>/dev/null | head -1)

# shellcheck disable=SC2086
awk '
function isort(a, n,   i, j, key) {           # insertion sort (n<=~1200, fine)
  for (i=2; i<=n; i++) { key=a[i]; j=i-1
    while (j>=1 && a[j]>key) { a[j+1]=a[j]; j-- }
    a[j+1]=key }
}
function pctl(a, n, p,   idx) {                # nearest-rank percentile, p in [0,100]
  if (n<=0) return 0
  idx = int(p/100.0*(n-1) + 0.5) + 1
  if (idx<1) idx=1; if (idx>n) idx=n
  return a[idx]
}
function report(op,   i, tmp, k) {
  k=0; for (i=1;i<=c[op];i++){ k++; tmp[k]=vals[op,i] }
  isort(tmp, k)
  printf "%s: count=%d avg_us=%.3f p50_us=%.3f p99_us=%.3f max_us=%.3f sum_us=%.1f\n", \
    op, c[op], (c[op]?s[op]/c[op]:0), pctl(tmp,k,50), pctl(tmp,k,99), mx[op], s[op]
}
/darshan-mofka\[timing\]/{
  op=$2; v=$3+0; c[op]++; s[op]+=v
  if(v>mx[op]) mx[op]=v
  if(mn[op]=="" || v<mn[op]) mn[op]=v
  vals[op, c[op]] = v
}
END{
  # init/finalize: avg + max across ranks (they run in parallel; max = slowest rank).
  printf "init_us=%.1f init_max_us=%.1f init_n=%d finalize_us=%.1f finalize_max_us=%.1f finalize_n=%d\n", \
    (c["initialize"]?s["initialize"]/c["initialize"]:0), mx["initialize"], c["initialize"], \
    (c["finalize"]?s["finalize"]/c["finalize"]:0), mx["finalize"], c["finalize"]
  report("push")
  report("send")
}' $ERR 2>/dev/null

# work wall from WORK_START/END ns (self-timed), else elapsed=
ws=$(grep -hoE 'WORK_START_NS [0-9]+' "$OUT" 2>/dev/null | awk '{print $2}' | head -1)
we=$(grep -hoE 'WORK_END_NS [0-9]+'   "$OUT" 2>/dev/null | awk '{print $2}' | head -1)
if [ -n "$ws" ] && [ -n "$we" ]; then
  awk -v a="$ws" -v b="$we" 'BEGIN{printf "work_s=%.2f\n", (b-a)/1e9}'
fi
ev=$( [ -f "$R/events.jsonl" ] && wc -l < "$R/events.jsonl" || echo 0 )
echo "events_jsonl=$ev"
grep -hE 'VERDICT' "$R/compare.txt" 2>/dev/null | tail -1
