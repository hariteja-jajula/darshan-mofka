#!/bin/bash
# extract.sh -- pull the paper-repro overhead table for all 4 workloads.
# Per streaming rep: WORK_s, self-timed overhead %, push_avg_us, send_avg_us, events.
R="/eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/results"
printf "%-14s %-14s %8s %10s %10s %10s %9s\n" workload arm work_s overhead% push_us send_us events
for wl in PAPER_iobench PAPER_iobenchpy PAPER_mpi PAPER_dlio; do
  for arm in baseline streaming_rep1 streaming_rep2 streaming_rep3; do
    d="$R/$wl/$arm/RUN1"; [ -d "$d" ] || continue
    out=$(ls "$d"/workload*.out 2>/dev/null | head -1)
    ws=$(grep -hoE 'WORK_START_NS [0-9]+' "$out" 2>/dev/null|awk '{print $2}'|head -1)
    we=$(grep -hoE 'WORK_END_NS [0-9]+' "$out" 2>/dev/null|awk '{print $2}'|head -1)
    [ -n "$we" ] || { printf "%-14s %-14s %8s\n" "$wl" "$arm" "running"; continue; }
    work=$(awk -v a=$ws -v b=$we 'BEGIN{printf "%.1f",(b-a)/1e9}')
    ev=$(wc -l < "$d/events.jsonl" 2>/dev/null||echo 0)
    awk -v wl="$wl" -v arm="$arm" -v work="$work" -v ev="$ev" '
      /darshan-mofka\[timing\]/{op=$2;v=$3+0;c[op]++;s[op]+=v}
      END{ conn=(s["initialize"]+s["push"]+s["send"]+s["finalize"])/1e6;
           oh=(work>0?conn/work*100:0);
           printf "%-14s %-14s %8s %9.3f %10.1f %10.1f %9s\n", wl, arm, work, oh,
             (c["push"]?s["push"]/c["push"]:0),(c["send"]?s["send"]/c["send"]:0), ev }' \
      "$d"/workload*.err 2>/dev/null
  done
done
